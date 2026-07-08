import AVFoundation
import AppKit
import SwiftUI

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
            duration: CMTime(seconds: duration, preferredTimescale: 600),
            phoneTrackID: preview.phoneTrackID, cameraTrackID: preview.cameraTrackID,
            phoneRotation: preview.phoneRotation, cameraRotation: preview.cameraRotation,
            layout: engine.currentLayout(), zooms: zooms)
    }

    /// Re-renders the preview after any look/zoom change. Cheap — it swaps
    /// instruction metadata, not media.
    func refreshPreview() {
        guard player.currentItem != nil else { return }
        player.currentItem?.videoComposition = currentVideoComposition()
        if !isPlaying {
            // Nudge the paused frame so the change shows immediately.
            player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
        save()
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

    func export() {
        guard exportProgress == nil, let _ = preview else { return }
        player.pause()
        exportProgress = 0
        lastExportProgressAt = .now
        let trim: CMTimeRange? = (trimStart > 0.05 || trimEnd < duration - 0.05)
            ? CMTimeRange(start: CMTime(seconds: trimStart, preferredTimescale: 600),
                          end: CMTime(seconds: trimEnd, preferredTimescale: 600))
            : nil
        save()

        let work = Task {
            do {
                let out = try await Exporter.export(
                    phoneURL: phoneURL, cameraURL: cameraURL, cameraOffset: cameraOffset,
                    layout: engine.currentLayout(), zooms: zooms, trim: trim,
                    onProgress: { p in
                        Task { @MainActor in
                            self.exportProgress = p
                            self.lastExportProgressAt = .now
                        }
                    })
                NSLog("[export] editor export OK: %@", out.path)
                NSWorkspace.shared.activateFileViewerSelecting([out])
            } catch {
                if error is CancellationError || Task.isCancelled {
                    self.engine.errorMessage = "Saving stalled and was stopped. Your raw recordings and edits are safe — try Export again."
                } else {
                    NSLog("[export] editor export FAILED: %@", String(describing: error))
                    self.engine.errorMessage = "Export failed: \(error.localizedDescription). Your raw recordings and edits are safe."
                }
            }
            self.exportProgress = nil
        }

        // Same watchdog as before: a healthy export reports progress
        // constantly; a minute of silence means it's dead.
        Task {
            while self.exportProgress != nil {
                try? await Task.sleep(for: .seconds(10))
                guard self.exportProgress != nil else { return }
                if Date.now.timeIntervalSince(self.lastExportProgressAt) > 60 {
                    NSLog("[export] editor watchdog: no progress for 60s, cancelling")
                    work.cancel()
                    return
                }
            }
        }
    }

    func close() {
        save()
        player.pause()
        player.replaceCurrentItem(with: nil)
        onClose()
        engine.editor = nil
    }
}
