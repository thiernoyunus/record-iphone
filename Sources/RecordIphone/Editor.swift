import AVFoundation
import AppKit
import SwiftUI

/// Thread-safe accumulator for a worker process's line-based stdout.
final class WorkerOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private var finalResult: String?

    /// Appends a chunk and returns any newly completed lines.
    func completeLines(appending chunk: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        buffer += chunk
        var lines = buffer.components(separatedBy: "\n")
        buffer = lines.removeLast()   // keep the unterminated tail
        return lines.filter { !$0.isEmpty }
    }

    func setResult(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        finalResult = line
    }

    func result() -> String? {
        lock.lock(); defer { lock.unlock() }
        return finalResult
    }
}

/// Drives the post-recording editor: a live styled preview (same compositor as
/// the export), trim, zoom segments, thumbnails, and the final export. Edits
/// persist to project.json next to the raw recordings, so nothing is baked in
/// until export.
@MainActor
final class EditorState: ObservableObject {

    struct ProjectDoc: Codable {
        var trimStart: Double
        var trimEnd: Double
        var zooms: [ZoomSegment]
    }

    let dir: URL
    let phoneURL: URL
    let cameraURL: URL
    let cameraOffset: CMTime
    unowned let engine: CaptureEngine
    private let onClose: @Sendable () -> Void

    let player = AVPlayer()
    @Published var duration: Double = 1
    @Published var currentTime: Double = 0
    @Published var isPlaying = false
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 1
    @Published var zooms: [ZoomSegment] = []
    @Published var selectedZoomID: UUID?
    @Published var thumbnails: [CGImage] = []
    @Published var exportProgress: Double?   // nil = not exporting
    @Published var loadFailed: String?

    private var preview: Exporter.Preview?
    /// Exact composition duration. The video-composition instruction must
    /// cover the timeline EXACTLY — rebuilding this CMTime from a Double
    /// loses precision, and a coverage gap of even a fraction of a frame
    /// makes AVFoundation silently render black and stall exports at 0%.
    private var compositionDuration: CMTime = .zero
    private var timeObserver: Any?
    private var lastExportProgressAt = Date.now

    var selectedZoom: ZoomSegment? {
        get { zooms.first { $0.id == selectedZoomID } }
    }

    init(dir: URL, phoneURL: URL, cameraURL: URL, cameraOffset: CMTime,
         engine: CaptureEngine, onClose: @escaping @Sendable () -> Void) {
        self.dir = dir
        self.phoneURL = phoneURL
        self.cameraURL = cameraURL
        self.cameraOffset = cameraOffset
        self.engine = engine
        self.onClose = onClose

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = time.seconds
                self.isPlaying = self.player.rate != 0
            }
        }

        Task { await load() }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    private func load() async {
        do {
            let preview = try await Exporter.makePreview(
                phoneURL: phoneURL, cameraURL: cameraURL, cameraOffset: cameraOffset)
            self.preview = preview
            compositionDuration = try await preview.composition.load(.duration)
            duration = max(preview.duration, 0.1)
            trimEnd = duration

            // Restore a previous editing session if one exists.
            if let data = try? Data(contentsOf: projectURL),
               let doc = try? JSONDecoder().decode(ProjectDoc.self, from: data) {
                trimStart = min(doc.trimStart, duration)
                trimEnd = min(doc.trimEnd, duration)
                zooms = doc.zooms
            }

            let item = AVPlayerItem(asset: preview.composition)
            item.videoComposition = currentVideoComposition()
            player.replaceCurrentItem(with: item)
            applyTrimToPlayback()
            await makeThumbnails()
        } catch {
            loadFailed = "Couldn't open this recording for editing: \(error.localizedDescription)"
        }
    }

    // MARK: - Live preview refresh

    private func currentVideoComposition() -> AVMutableVideoComposition {
        guard let preview else { return AVMutableVideoComposition() }
        return Exporter.makeVideoComposition(
            duration: compositionDuration,
            phoneTrackID: preview.phoneTrackID, cameraTrackID: preview.cameraTrackID,
            phoneRotation: preview.phoneRotation, cameraRotation: preview.cameraRotation,
            layout: engine.currentLayout(), zooms: zooms)
    }

    /// Re-renders the preview after a look/zoom change — debounced. Reticle
    /// and slider drags fire per mouse-move; swapping the player's video
    /// composition hundreds of times a second wedges AVFoundation's pipeline
    /// (audio drops out, later exports stall), so changes settle for 140ms
    /// before one swap is applied.
    private var refreshTask: Task<Void, Never>?
    func refreshPreview() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard let self, !Task.isCancelled, self.player.currentItem != nil else { return }
            self.player.currentItem?.videoComposition = self.currentVideoComposition()
            if !self.isPlaying {
                // Nudge the paused frame so the change shows immediately.
                self.seek(to: self.currentTime)
            }
            self.save()
        }
    }

    // MARK: - Transport

    func togglePlay() {
        if isPlaying {
            player.pause()
        } else {
            if currentTime >= trimEnd - 0.05 || currentTime < trimStart {
                seek(to: trimStart)
            }
            player.play()
        }
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let clamped = min(max(seconds, 0), duration)
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func applyTrimToPlayback() {
        player.currentItem?.forwardPlaybackEndTime =
            CMTime(seconds: trimEnd, preferredTimescale: 600)
        save()
    }

    // MARK: - Zooms

    func addZoom() {
        var z = ZoomSegment(start: max(0, min(currentTime, duration - 2)), duration: 3)
        z.duration = min(3, duration - z.start)
        zooms.append(z)
        zooms.sort { $0.start < $1.start }
        selectedZoomID = z.id
        refreshPreview()
    }

    func update(_ zoom: ZoomSegment) {
        guard let i = zooms.firstIndex(where: { $0.id == zoom.id }) else { return }
        var z = zoom
        z.start = min(max(z.start, 0), duration - 0.5)
        z.duration = min(max(z.duration, 1), duration - z.start)
        zooms[i] = z
        refreshPreview()
    }

    func deleteSelectedZoom() {
        zooms.removeAll { $0.id == selectedZoomID }
        selectedZoomID = nil
        refreshPreview()
    }

    // MARK: - Persistence

    private var projectURL: URL { dir.appendingPathComponent("project.json") }

    func save() {
        let doc = ProjectDoc(trimStart: trimStart, trimEnd: trimEnd, zooms: zooms)
        if let data = try? JSONEncoder().encode(doc) {
            try? data.write(to: projectURL)
        }
    }

    // MARK: - Thumbnails

    private func makeThumbnails() async {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: phoneURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 0, height: 120)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let phoneDuration = (try? await AVURLAsset(url: phoneURL).load(.duration).seconds) ?? duration
        var images: [CGImage] = []
        for i in 0..<14 {
            let t = phoneDuration * (Double(i) + 0.5) / 14
            if let img = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                images.append(img)
            }
        }
        thumbnails = images
    }

    // MARK: - Export & close

    /// Exports run in a separate worker process (a headless copy of this app
    /// binary running --export-json). The editor's preview pipeline has wedged
    /// AVFoundation before — a clean process is immune to all of that, and a
    /// stall is fixed by killing the worker, never the app.
    func export() {
        guard exportProgress == nil, preview != nil else { return }
        player.pause()
        exportProgress = 0
        lastExportProgressAt = .now
        save()

        let spec = ExportSpec(
            phonePath: phoneURL.path, cameraPath: cameraURL.path,
            cameraOffsetSeconds: cameraOffset.seconds,
            layout: engine.currentLayout(), zooms: zooms,
            trimStart: trimStart > 0.05 ? trimStart : nil,
            trimEnd: trimEnd < duration - 0.05 ? trimEnd : nil)
        let specURL = dir.appendingPathComponent("export-spec.json")
        guard let specData = try? JSONEncoder().encode(spec),
              (try? specData.write(to: specURL)) != nil,
              let exe = Bundle.main.executableURL else {
            engine.errorMessage = "Couldn't start the export."
            exportProgress = nil
            return
        }

        let worker = Process()
        worker.executableURL = exe
        worker.arguments = ["--export-json", specURL.path]
        let pipe = Pipe()
        worker.standardOutput = pipe
        let output = WorkerOutput()

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = String(decoding: handle.availableData, as: UTF8.self)
            for line in output.completeLines(appending: chunk) {
                if line.hasPrefix("progress "), let p = Double(line.dropFirst(9)) {
                    Task { @MainActor [weak self] in
                        self?.exportProgress = p
                        self?.lastExportProgressAt = .now
                    }
                } else if line.hasPrefix("OK ") || line.hasPrefix("FAIL") {
                    output.setResult(line)
                }
            }
        }
        worker.terminationHandler = { proc in
            let status = proc.terminationStatus
            let result = output.result()
            Task { @MainActor [weak self] in
                guard let self else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                try? FileManager.default.removeItem(at: specURL)
                if status == 0, let result, result.hasPrefix("OK ") {
                    NSLog("[export] worker OK: %@", result)
                    let out = self.dir.appendingPathComponent("Recording.mp4")
                    NSWorkspace.shared.activateFileViewerSelecting([out])
                } else if self.exportWatchdogKilled {
                    self.engine.errorMessage = "Saving stalled and was stopped. Your raw recordings and edits are safe — try Export again."
                } else {
                    NSLog("[export] worker FAILED status=%d result=%@", status, result ?? "none")
                    self.engine.errorMessage = "Export failed. Your raw recordings and edits are safe — try Export again."
                }
                self.exportWatchdogKilled = false
                self.exportProgress = nil
            }
        }

        do {
            try worker.run()
            NSLog("[export] worker started pid=%d", worker.processIdentifier)
        } catch {
            engine.errorMessage = "Couldn't start the export: \(error.localizedDescription)"
            exportProgress = nil
            return
        }

        // Watchdog: a healthy worker prints progress ~3×/sec. A minute of
        // silence means it's dead — kill it and say so.
        Task { [weak self] in
            while let self, self.exportProgress != nil {
                try? await Task.sleep(for: .seconds(10))
                guard let s = self.exportProgress, s < 1 else { continue }
                if Date.now.timeIntervalSince(self.lastExportProgressAt) > 60 {
                    NSLog("[export] watchdog: worker silent for 60s, terminating")
                    self.exportWatchdogKilled = true
                    worker.terminate()
                    return
                }
            }
        }
    }

    private var exportWatchdogKilled = false

    func close() {
        refreshTask?.cancel()
        save()
        player.pause()
        player.replaceCurrentItem(with: nil)
        onClose()
        engine.editor = nil
    }
}
