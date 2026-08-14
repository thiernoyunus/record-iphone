import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

    /// Consumes any leftover unterminated buffer as a final line (used when
    /// the worker exits and no trailing newline was written).
    func flushRemainder() {
        lock.lock(); defer { lock.unlock() }
        let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            if tail.hasPrefix("OK ") || tail.hasPrefix("FAIL") {
                finalResult = tail
            }
            buffer = ""
        }
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

/// Drives the post-recording editor: a layered phone+camera preview, trim,
/// zoom segments, thumbnails, and the final export. Edits persist to
/// project.json next to the raw recordings, so nothing is baked in until
/// export.
@MainActor
final class EditorState: ObservableObject {

    struct ProjectDoc: Codable {
        var trimStart: Double
        var trimEnd: Double
        var zooms: [ZoomSegment]
        // Look settings — optional for older project.json files.
        var background: BackgroundPreset?
        var showBezel: Bool?
        var bubbleFraction: CGFloat?
        var bubbleCenterX: Double?
        var bubbleCenterY: Double?
        var canvas: CanvasPreset?
        var presenterLayout: PresenterLayout?
        var phoneScale: CGFloat?
        /// Phone/camera start offset measured at record time; read back by
        /// CaptureEngine.openProject so reopened projects stay in sync.
        var cameraOffsetSeconds: Double?
        var customBackgroundRGB: [CGFloat]?
        var cameraShape: CameraShape?
        var ringRGB: [CGFloat]?
        var frameStyle: DeviceFrameStyle?
        var cameraEnabled: Bool?
        var deviceOnLeft: Bool?
        var cameraLeads: Bool?
        var overlapArrangement: Bool?
        var splitBalance: CGFloat?
        var splitGap: CGFloat?
        var scenes: [SceneClip]?
        var screenCorners: Bool?
        var phoneAudioLevel: CGFloat?
        var micAudioLevel: CGFloat?
        var wantedCamera: Bool?
    }

    let dir: URL
    let phoneURL: URL
    let cameraURL: URL
    let cameraOffset: CMTime
    private var playbackPhoneURL: URL
    private var playbackCameraURL: URL
    unowned let engine: CaptureEngine
    private let onClose: @MainActor @Sendable () -> Void

    let player = AVPlayer()
    /// Second player for the camera clip. Review draws the two files as
    /// layers (like the live window) instead of asking AVPlayer to stitch
    /// them — that stitch has to run on the main thread and froze the app.
    let cameraPlayer = AVPlayer()
    @Published var hasCamera = false
    @Published var wantedCamera = false
    @Published var hasMic = false
    /// True only when camera.mov actually has a sound track (your voice).
    @Published var hasMicAudio = false
    /// Loudness for this take only (0…1). Live Setup sliders stay on the engine.
    @Published var phoneMix: CGFloat = 1
    @Published var micMix: CGFloat = 1
    /// True when project.json already stored a phone mix for this take.
    private var phoneMixFromProject = false
    @Published var cameraClipStatus: CameraClipStatus = .phoneOnly
    /// Once a project.json has been read (or we know there isn't one),
    /// saves may write. Until then, never overwrite an existing file.
    private var projectApplied = false
    @Published var duration: Double = 1
    @Published var currentTime: Double = 0
    @Published var isPlaying = false
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 1
    @Published var zooms: [ZoomSegment] = []
    @Published var selectedZoomID: UUID?
    @Published var scenes: [SceneClip] = []
    @Published var selectedSceneID: UUID?
    @Published var mode: EditorMode = .edit

    enum EditorMode {
        case edit, scenes
    }

    /// Mutate a zoom's aim without rebuilding the composition (used while dragging).
    func setZoomCenter(_ id: UUID, center: CGPoint) {
        guard let i = zooms.firstIndex(where: { $0.id == id }) else { return }
        zooms[i].center = CGPoint(
            x: min(max(center.x, 0.05), 0.95),
            y: min(max(center.y, 0.05), 0.95))
    }
    @Published var thumbnails: [CGImage] = []
    @Published var cameraThumbnails: [CGImage] = []
    @Published var phoneFileDuration: Double = 0
    @Published var cameraFileDuration: Double = 0
    @Published var exportProgress: Double?   // nil = not exporting
    @Published var loadFailed: String?
    @Published var isReady = false
    @Published var exportSucceeded = false
    /// Set when an export finishes and the file is confirmed on disk.
    @Published var exportedURL: URL?

    private var timeObserver: Any?
    private var clockOnCamera = false
    private var stallObserver: NSObjectProtocol?
    private var endObserver: NSObjectProtocol?
    private var cameraEndObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var thumbTask: Task<Void, Never>?
    private var thumbGen = 0
    private var lastExportProgressAt = Date.now
    private var exportWorker: Process?

    var selectedZoom: ZoomSegment? {
        get { zooms.first { $0.id == selectedZoomID } }
    }

    init(dir: URL, phoneURL: URL, cameraURL: URL,
         playbackPhone: URL? = nil, playbackCamera: URL? = nil,
         cameraOffset: CMTime,
         engine: CaptureEngine, onClose: @escaping @MainActor @Sendable () -> Void) {
        self.dir = dir
        self.phoneURL = phoneURL
        self.cameraURL = cameraURL
        self.playbackPhoneURL = playbackPhone ?? phoneURL
        self.playbackCameraURL = playbackCamera ?? cameraURL
        self.cameraOffset = cameraOffset
        self.engine = engine
        self.onClose = onClose
        Task { await load() }
    }

    deinit {
        // Players die with this object; do not hop to MainActor from deinit.
    }

    private func removeClock() {
        guard let timeObserver else { return }
        (clockOnCamera ? cameraPlayer : player).removeTimeObserver(timeObserver)
        self.timeObserver = nil
    }

    private func installClock() {
        removeClock()
        clockOnCamera = (hasCamera || hasMic)
            && ClipAlignment.cameraIsClock(cameraOffsetSeconds: cameraOffset.seconds)
        let master = clockOnCamera ? cameraPlayer : player
        timeObserver = master.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 24), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let a = ClipAlignment.startAtMic(cameraOffsetSeconds: self.cameraOffset.seconds)
                let timeline = self.clockOnCamera ? time.seconds : (time.seconds - a.phoneSkip)
                let seconds = min(max(timeline, 0), max(self.duration, 0.1))
                self.syncHoldPlayers()
                if self.isPlaying { self.resyncIfDrifted(at: seconds) }
                if abs(seconds - self.currentTime) < 0.04, self.isPlaying {
                    if seconds >= self.trimEnd - 0.04 {
                        self.stopAtTrimEnd()
                    }
                    return
                }
                self.currentTime = seconds
                if self.isPlaying, seconds >= self.trimEnd - 0.04 {
                    self.stopAtTrimEnd()
                }
            }
        }
    }

    private func stopAtTrimEnd() {
        player.pause()
        cameraPlayer.pause()
        isPlaying = false
        seek(to: trimStart)
    }

    private func alignedSources(at timeline: Double) -> ClipAlignment.SourceTimes {
        ClipAlignment.sourceTimes(
            timeline: timeline,
            cameraOffsetSeconds: cameraOffset.seconds,
            phoneDuration: phoneFileDuration > 0.05 ? phoneFileDuration : .infinity,
            cameraDuration: cameraFileDuration > 0.05 ? cameraFileDuration : .infinity)
    }

    /// Two independent players drift. Nudge them back onto the export timeline.
    private func resyncIfDrifted(at timeline: Double) {
        let src = alignedSources(at: timeline)
        let slack = CMTime(seconds: 0.03, preferredTimescale: 600)
        if src.phonePlaying,
           abs(player.currentTime().seconds - src.phone) > 0.12 {
            seekSources(to: timeline, slack: slack)
            return
        }
        if hasCamera, src.cameraPlaying,
           abs(cameraPlayer.currentTime().seconds - src.camera) > 0.12 {
            seekSources(to: timeline, slack: slack)
        }
    }

    private func syncHoldPlayers() {
        guard isPlaying else { return }
        let src = alignedSources(at: currentTime)
        if src.phonePlaying {
            if player.rate == 0 {
                player.seek(to: CMTime(seconds: src.phone, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero)
                player.volume = Float(phoneMix)
                player.isMuted = phoneMix <= 0.001
                player.play()
            }
        } else if player.rate != 0 {
            player.pause()
        }
        guard hasCamera else { return }
        if src.cameraPlaying {
            if cameraPlayer.rate == 0 { cameraPlayer.play() }
        } else if cameraPlayer.rate != 0 {
            cameraPlayer.pause()
        }
    }

    private func load() async {
        // Phone file is required; camera may be a placeholder (same path).
        let phoneSize = (try? phoneURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if phoneSize < 1024 {
            loadFailed = "This recording looks incomplete (phone video is nearly empty). The connection may have dropped during the take."
            return
        }

        // Copy live sliders into this take, then put Setup back on defaults
        // so Look edits here cannot change the next recording.
        phoneMix = min(max(engine.phoneAudioLevel, 0), 1)
        micMix = min(max(engine.micAudioLevel, 0), 1)
        engine.resetMixToDefaults()

        // Playback URLs must already be remuxed sidecars (*.play.mov).
        // Never open the raw just-written file in AVPlayer.
        let rawPhone = phoneURL
        let rawCamera = cameraURL
        if !playbackPhoneURL.lastPathComponent.hasSuffix(".play.mov") {
            do {
                playbackPhoneURL = try await Task.detached(priority: .userInitiated) {
                    try await Exporter.preparePlaybackCopy(rawPhone)
                }.value
                if rawCamera.standardizedFileURL != rawPhone.standardizedFileURL {
                    playbackCameraURL = (try? await Task.detached(priority: .userInitiated) {
                        try await Exporter.preparePlaybackCopy(rawCamera)
                    }.value) ?? playbackPhoneURL
                }
            } catch {
                loadFailed = "Couldn't open this recording yet. Tap Back, then open it from Library. Your files are in Movies/Record iPhone."
                NSLog("[editor] prepare playback failed: %@", error.localizedDescription)
                return
            }
        }
        let playPhone = playbackPhoneURL
        let playCam = playbackCameraURL
        let seconds = await Task.detached(priority: .userInitiated) { () -> (Double, Double) in
            let opts: [String: Any] = [AVURLAssetPreferPreciseDurationAndTimingKey: false]
            let phone = (try? await AVURLAsset(url: playPhone, options: opts).load(.duration).seconds) ?? 0
            let cam = (try? await AVURLAsset(url: playCam, options: opts).load(.duration).seconds) ?? 0
            return (phone, cam)
        }.value
        await installSimpleItems()
        installClock()
        player.automaticallyWaitsToMinimizeStalling = false
        cameraPlayer.automaticallyWaitsToMinimizeStalling = false
        isReady = true
        loadFailed = nil
        phoneFileDuration = seconds.0
        cameraFileDuration = seconds.1
        duration = ClipAlignment.timelineDuration(
            phone: seconds.0, camera: seconds.1,
            cameraOffsetSeconds: cameraOffset.seconds)
        trimEnd = duration
        applySavedProject()
        // Phone writer often dies while the camera keeps rolling. With no
        // mic that leftover is a frozen picture and no sound.
        let useful = ClipAlignment.usefulEnd(
            phone: seconds.0, camera: seconds.1,
            cameraOffsetSeconds: cameraOffset.seconds,
            cameraHasMic: hasMicAudio)
        if duration > useful + 0.4 {
            duration = useful
        }
        if trimEnd > duration { trimEnd = duration }
        let audible = ClipAlignment.audiblePhoneLevel(
            saved: Double(phoneMix), hasMic: hasMicAudio,
            explicitSaved: phoneMixFromProject)
        phoneMix = CGFloat(audible)
        if phoneMix > 0.02 { restoredPhoneAudio = Double(phoneMix) }
        if micMix > 0.02 { restoredMicAudio = Double(micMix) }
        applyPlaybackVolumes()
        applyTrimToPlayback()
        seek(to: trimStart)
        undoStack = [currentSnapshot]
        updateUndoFlags()
        Task { await makeThumbnails() }
        Task { await loadWaveform() }
    }

    private func installSimpleItems() async {
        installPhoneOnlyItem()
        let camURL = playbackCameraURL
        let phoneURL = playbackPhoneURL
        let camExists = camURL.standardizedFileURL != phoneURL.standardizedFileURL
            && FileManager.default.fileExists(atPath: camURL.path)
            && ((try? camURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 1024
        let hasPicture: Bool
        let camHasAudio: Bool
        if camExists {
            let pair = await Task.detached {
                let video = (try? await AVURLAsset(url: camURL).loadTracks(withMediaType: .video)) ?? []
                let audio = (try? await AVURLAsset(url: camURL).loadTracks(withMediaType: .audio)) ?? []
                return (!video.isEmpty, !audio.isEmpty)
            }.value
            hasPicture = pair.0
            camHasAudio = pair.1
        } else {
            hasPicture = false
            camHasAudio = false
        }
        let intent = TakeIntentDoc.load(from: dir)
        wantedCamera = intent?.wantedCamera ?? false
        cameraClipStatus = CameraClipStatus.resolve(
            wantedCamera: wantedCamera, cameraFileExists: camExists, hasVideoTrack: hasPicture)
        hasCamera = cameraClipStatus.hasPicture
        hasMic = cameraClipStatus.hasMicFile
        hasMicAudio = camHasAudio
        if camExists {
            // Mic-only takes also write camera.mov. Don't force the bubble on
            // unless this file actually has a picture.
            if hasPicture { engine.cameraEnabled = true }
            let item = AVPlayerItem(url: playbackCameraURL)
            item.preferredForwardBufferDuration = 1
            item.audioTimePitchAlgorithm = .timeDomain
            cameraPlayer.replaceCurrentItem(with: item)
            cameraPlayer.volume = Float(micMix)
            cameraPlayer.isMuted = micMix <= 0.001
            cameraPlayer.automaticallyWaitsToMinimizeStalling = false
            if let cameraEndObserver { NotificationCenter.default.removeObserver(cameraEndObserver) }
            cameraEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if !self.clockOnCamera {
                        self.cameraPlayer.pause()
                        return
                    }
                    self.isPlaying = false
                    self.seek(to: self.trimStart)
                }
            }
        } else {
            cameraPlayer.replaceCurrentItem(with: nil)
        }
    }

    /// Restores trim / look from project.json. Safe to call more than once.
    private func applySavedProject() {
        guard FileManager.default.fileExists(atPath: projectURL.path) else {
            projectApplied = true
            return
        }
        guard let data = try? Data(contentsOf: projectURL) else { return }
        do {
            let doc = try JSONDecoder().decode(ProjectDoc.self, from: data)
            apply(doc)
            projectApplied = true
        } catch {
            NSLog("[editor] project.json did not load — leaving the file untouched: %@", error.localizedDescription)
        }
    }

    private func apply(_ doc: ProjectDoc) {
        trimStart = min(max(0, doc.trimStart), duration - 0.5)
        trimEnd = min(max(trimStart + 0.5, doc.trimEnd), duration)
        zooms = doc.zooms
        if let bg = doc.background { engine.background = bg }
        if let bezel = doc.showBezel { engine.showBezel = bezel }
        if let frac = doc.bubbleFraction {
            engine.bubbleFraction = min(max(frac, ExportLayout.bubbleMin), ExportLayout.bubbleMax)
        }
        if let x = doc.bubbleCenterX, let y = doc.bubbleCenterY {
            engine.bubbleCenter = CGPoint(x: x, y: y)
        }
        if let canvas = doc.canvas { engine.canvas = canvas }
        if let pl = doc.presenterLayout { engine.presenterLayout = pl }
        if let ps = doc.phoneScale {
            engine.phoneScale = min(max(ps, ExportLayout.phoneScaleMin),
                                    ExportLayout.phoneScaleMax)
        }
        if let rgb = doc.customBackgroundRGB { engine.customBackgroundRGB = rgb }
        if let shape = doc.cameraShape { engine.cameraShape = shape }
        if let ring = doc.ringRGB { engine.ringRGB = ring }
        if let frame = doc.frameStyle { engine.frameStyle = frame; engine.showBezel = frame.showsBezel }
        if let wanted = doc.wantedCamera { wantedCamera = wanted || wantedCamera }
        if doc.cameraEnabled == true { wantedCamera = true }
        cameraClipStatus = CameraClipStatus.resolve(
            wantedCamera: wantedCamera, cameraFileExists: hasCamera || hasMic, hasVideoTrack: hasCamera)
        if let camOn = doc.cameraEnabled, hasCamera { engine.cameraEnabled = camOn }
        if let left = doc.deviceOnLeft { engine.deviceOnLeft = left }
        if let leads = doc.cameraLeads { engine.cameraLeads = leads }
        if let overlap = doc.overlapArrangement { engine.overlapArrangement = overlap }
        if let bal = doc.splitBalance { engine.splitBalance = bal }
        if let gap = doc.splitGap { engine.splitGap = gap }
        if let corners = doc.screenCorners { engine.screenCorners = corners }
        if let p = doc.phoneAudioLevel {
            phoneMix = min(max(p, 0), 1)
            phoneMixFromProject = true
        }
        if let m = doc.micAudioLevel { micMix = min(max(m, 0), 1) }
        scenes = doc.scenes ?? []
        applyPlaybackVolumes()
    }

    private func installPhoneOnlyItem() {
        let item = AVPlayerItem(url: playbackPhoneURL)
        item.preferredForwardBufferDuration = 1
        item.audioTimePitchAlgorithm = .timeDomain
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        attach(item)
    }

    private func attach(_ item: AVPlayerItem) {
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        statusObservation?.invalidate()

        player.replaceCurrentItem(with: item)
        applyPlaybackVolumes()
        player.isMuted = false
        player.automaticallyWaitsToMinimizeStalling = false

        stallObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification,
            object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.exportProgress == nil else { return }
                if self.isPlaying, self.player.rate == 0 {
                    NSLog("[editor] playback stalled — resuming")
                    self.player.play()
                    if self.hasCamera { self.cameraPlayer.play() }
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Phone file is shorter than the camera on many takes. Ending
                // the phone must NOT rewind the whole movie — export keeps
                // going with the last phone frame.
                if self.clockOnCamera {
                    self.player.pause()
                    return
                }
                self.isPlaying = false
                self.seek(to: self.trimStart)
            }
        }
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if item.status == .failed {
                    let msg = item.error?.localizedDescription ?? "unknown error"
                    NSLog("[editor] player item failed: %@", msg)
                    self.loadFailed = "Playback failed: \(msg). Try Reload (⌘R)."
                }
            }
        }
    }

    // MARK: - Live preview refresh

    /// Rebuilds the player item from scratch at the current position. Recovers
    /// a wedged playback pipeline (e.g. audio that has gone silent).
    func reloadPreview() {
        loadFailed = nil
        let t = currentTime
        let wasPlaying = isPlaying
        Task { @MainActor in
            await self.installSimpleItems()
            self.installClock()
            self.applyTrimToPlayback()
            self.seek(to: t)
            if wasPlaying {
                self.isPlaying = true
                let src = self.alignedSources(at: t)
                if src.phonePlaying { self.player.play() }
                if self.hasCamera, src.cameraPlaying { self.cameraPlayer.play() }
            }
        }
    }

    func applyPlaybackVolumes() {
        player.volume = Float(phoneMix)
        player.isMuted = phoneMix <= 0.001
        cameraPlayer.volume = Float(micMix)
        cameraPlayer.isMuted = micMix <= 0.001
    }

    /// Look changes are SwiftUI layers now — just save. No compositor rebuild.
    private var refreshTask: Task<Void, Never>?

    func refreshPreview(immediate: Bool = false) {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(360))
            }
            guard let self, !Task.isCancelled else { return }
            self.save()
        }
    }

    /// Commit a bubble drag without thrashing during the gesture.
    func commitBubbleMove() {
        refreshPreview(immediate: true)
    }

    // MARK: - Transport

    func togglePlay() {
        if isPlaying {
            player.pause()
            cameraPlayer.pause()
            isPlaying = false
        } else {
            if currentTime >= trimEnd - 0.05 || currentTime < trimStart {
                seek(to: trimStart)
            }
            isPlaying = true
            let src = alignedSources(at: currentTime)
            if src.phonePlaying { player.play() } else { player.pause() }
            if hasCamera, src.cameraPlaying { cameraPlayer.play() } else { cameraPlayer.pause() }
        }
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        // Always stay inside the trim window so scrubbing matches export.
        let lo = trimStart
        let hi = max(trimStart + 0.05, trimEnd)
        let clamped = min(max(seconds, lo), hi)
        currentTime = clamped
        let slack = CMTime(seconds: 0.04, preferredTimescale: 600)
        seekSources(to: clamped, slack: slack)
    }

    /// Timeline scrub may target raw timeline positions (including outside
    /// trim) when dragging the playhead; use this so dimmed regions remain
    /// reachable for re-trimming.
    func seekRaw(to seconds: Double) {
        seekRaw(to: seconds, precise: false)
    }

    func seekRaw(to seconds: Double, precise: Bool) {
        guard seconds.isFinite else { return }
        let clamped = min(max(seconds, 0), duration)
        currentTime = clamped
        let slack = precise ? CMTime.zero : CMTime(seconds: 0.05, preferredTimescale: 600)
        seekSources(to: clamped, slack: slack)
    }

    private func seekSources(to timeline: Double, slack: CMTime) {
        let src = alignedSources(at: timeline)
        player.seek(to: CMTime(seconds: src.phone, preferredTimescale: 600),
                    toleranceBefore: slack, toleranceAfter: slack)
        guard hasCamera else { return }
        cameraPlayer.seek(to: CMTime(seconds: src.camera, preferredTimescale: 600),
                          toleranceBefore: slack, toleranceAfter: slack)
    }

    func applyTrimToPlayback() {
        let start = alignedSources(at: trimStart)
        let end = alignedSources(at: trimEnd)
        let item = player.currentItem
        item?.forwardPlaybackEndTime = CMTime(seconds: end.phone, preferredTimescale: 600)
        item?.reversePlaybackEndTime = CMTime(seconds: start.phone, preferredTimescale: 600)
        if hasCamera {
            cameraPlayer.currentItem?.forwardPlaybackEndTime = CMTime(seconds: end.camera, preferredTimescale: 600)
            cameraPlayer.currentItem?.reversePlaybackEndTime = CMTime(seconds: start.camera, preferredTimescale: 600)
        }
        if currentTime < trimStart || currentTime > trimEnd {
            seek(to: trimStart)
        }
        save()
    }

    // MARK: - Zooms

    func addZoom() {
        addZoom(at: currentTime)
    }

    func addZoom(at time: Double) {
        guard isReady else { return }
        var z = ZoomSegment(start: max(trimStart, min(time, trimEnd - 1.2)), duration: 2.4)
        z.level = 1.5
        z.duration = min(2.4, max(0.8, trimEnd - z.start))
        z.center = CGPoint(x: 0.5, y: 0.45)
        clampAgainstNeighbors(&z)
        guard z.duration >= 0.5 else { return }
        zooms.append(z)
        zooms.sort { $0.start < $1.start }
        selectedZoomID = z.id
        refreshPreview()
    }

    func update(_ zoom: ZoomSegment, rebuild: Bool = true) {
        guard let i = zooms.firstIndex(where: { $0.id == zoom.id }) else { return }
        var z = zoom
        z.start = min(max(z.start, 0), duration - 0.5)
        z.duration = min(max(z.duration, 0.5), duration - z.start)
        z.center.x = min(max(z.center.x, 0.05), 0.95)
        z.center.y = min(max(z.center.y, 0.05), 0.95)
        z.level = min(max(z.level, 1.2), 3.5)
        clampAgainstNeighbors(&z)
        zooms[i] = z
        if rebuild {
            zooms.sort { $0.start < $1.start }
            refreshPreview()
        }
    }

    /// Zooms may not overlap — two active zooms with different aims make the
    /// picture jump mid-zoom. Squeeze the segment into the gap between its
    /// neighbors instead.
    private func clampAgainstNeighbors(_ z: inout ZoomSegment) {
        let others = zooms.filter { $0.id != z.id }.sorted { $0.start < $1.start }
        let lowerBound = others.filter { $0.start < z.start + 0.001 }.map(\.end).max() ?? 0
        let upperBound = others.first { $0.start >= lowerBound + 0.001 }?.start ?? duration
        z.start = min(max(z.start, lowerBound), max(lowerBound, upperBound - 0.5))
        z.duration = min(z.duration, upperBound - z.start)
    }

    func deleteSelectedZoom() {
        zooms.removeAll { $0.id == selectedZoomID }
        selectedZoomID = nil
        refreshPreview()
    }

    func addScene(kind: SceneKind, start: Double, duration: Double) {
        var clip = SceneClip(kind: kind, start: max(0, start), duration: max(0.4, duration))
        clip.duration = min(clip.duration, max(0.4, duration - 0.01))
        clampScene(&clip)
        scenes.append(clip)
        scenes.sort { $0.start < $1.start }
        selectedSceneID = clip.id
        refreshPreview()
    }

    func updateScene(_ clip: SceneClip, rebuild: Bool = true) {
        guard let i = scenes.firstIndex(where: { $0.id == clip.id }) else { return }
        var c = clip
        clampScene(&c)
        scenes[i] = c
        if rebuild {
            scenes.sort { $0.start < $1.start }
            refreshPreview()
        }
    }

    func deleteSelectedScene() {
        scenes.removeAll { $0.id == selectedSceneID }
        selectedSceneID = nil
        refreshPreview()
    }

    private func clampScene(_ c: inout SceneClip) {
        c.start = min(max(c.start, 0), duration - 0.4)
        c.duration = min(max(c.duration, 0.4), duration - c.start)
    }

    // MARK: - Persistence

    private var projectURL: URL { dir.appendingPathComponent("project.json") }

    func save() {
        guard isReady else { return }
        if !projectApplied, FileManager.default.fileExists(atPath: projectURL.path) {
            NSLog("[editor] skip save — existing project.json was not loaded")
            return
        }
        let doc = ProjectDoc(
            trimStart: trimStart, trimEnd: trimEnd, zooms: zooms,
            background: engine.background, showBezel: engine.showBezel,
            bubbleFraction: engine.bubbleFraction,
            bubbleCenterX: engine.bubbleCenter.x, bubbleCenterY: engine.bubbleCenter.y,
            canvas: engine.canvas, presenterLayout: engine.presenterLayout,
            phoneScale: engine.phoneScale,
            cameraOffsetSeconds: cameraOffset.seconds,
            customBackgroundRGB: engine.customBackgroundRGB,
            cameraShape: engine.cameraShape,
            ringRGB: engine.ringRGB,
            frameStyle: engine.frameStyle,
            cameraEnabled: engine.cameraEnabled,
            deviceOnLeft: engine.deviceOnLeft,
            cameraLeads: engine.cameraLeads,
            overlapArrangement: engine.overlapArrangement,
            splitBalance: engine.splitBalance,
            splitGap: engine.splitGap,
            scenes: scenes,
            screenCorners: engine.screenCorners,
            phoneAudioLevel: phoneMix,
            micAudioLevel: micMix,
            wantedCamera: wantedCamera)
        if let data = try? JSONEncoder().encode(doc) {
            try? data.write(to: projectURL, options: .atomic)
        }
        pushUndoSnapshotIfChanged()
    }

    // MARK: - Undo / redo

    /// One editing state — everything save() persists. Undo/redo restores whole
    /// snapshots, which is simple and covers trim, zooms, and the look.
    private struct EditSnapshot: Equatable {
        var trimStart: Double, trimEnd: Double
        var zooms: [ZoomSegment]
        var background: BackgroundPreset
        var showBezel: Bool
        var bubbleFraction: CGFloat
        var bubbleCenter: CGPoint
        var canvas: CanvasPreset
        var presenterLayout: PresenterLayout
        var phoneScale: CGFloat
        var cameraShape: CameraShape
        var ringRGB: [CGFloat]
        var customBackgroundRGB: [CGFloat]?
        var frameStyle: DeviceFrameStyle
        var deviceOnLeft: Bool
        var cameraLeads: Bool
        var overlapArrangement: Bool
        var splitBalance: CGFloat
        var splitGap: CGFloat
        var screenCorners: Bool
        var cameraEnabled: Bool
        var phoneAudioLevel: CGFloat
        var micAudioLevel: CGFloat
    }

    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private var undoStack: [EditSnapshot] = []
    private var redoStack: [EditSnapshot] = []
    private var isRestoringSnapshot = false

    private var currentSnapshot: EditSnapshot {
        EditSnapshot(trimStart: trimStart, trimEnd: trimEnd, zooms: zooms,
                     background: engine.background, showBezel: engine.showBezel,
                     bubbleFraction: engine.bubbleFraction, bubbleCenter: engine.bubbleCenter,
                     canvas: engine.canvas, presenterLayout: engine.presenterLayout,
                     phoneScale: engine.phoneScale,
                     cameraShape: engine.cameraShape,
                     ringRGB: engine.ringRGB,
                     customBackgroundRGB: engine.customBackgroundRGB,
                     frameStyle: engine.frameStyle,
                     deviceOnLeft: engine.deviceOnLeft,
                     cameraLeads: engine.cameraLeads,
                     overlapArrangement: engine.overlapArrangement,
                     splitBalance: engine.splitBalance,
                     splitGap: engine.splitGap,
                     screenCorners: engine.screenCorners,
                     cameraEnabled: engine.cameraEnabled,
                     phoneAudioLevel: phoneMix,
                     micAudioLevel: micMix)
    }

    /// Called from save() — every committed edit lands here exactly once.
    private func pushUndoSnapshotIfChanged() {
        guard isReady, !isRestoringSnapshot else { return }
        let snap = currentSnapshot
        if undoStack.last == snap { return }
        undoStack.append(snap)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack = []
        updateUndoFlags()
    }

    func undo() {
        // Top of undoStack is the current state; the one below is the target.
        guard undoStack.count >= 2 else { return }
        redoStack.append(undoStack.removeLast())
        apply(undoStack.last!)
    }

    func redo() {
        guard let snap = redoStack.popLast() else { return }
        undoStack.append(snap)
        apply(snap)
    }

    private func apply(_ s: EditSnapshot) {
        isRestoringSnapshot = true
        trimStart = s.trimStart; trimEnd = s.trimEnd; zooms = s.zooms
        engine.background = s.background; engine.showBezel = s.showBezel
        engine.bubbleFraction = s.bubbleFraction; engine.bubbleCenter = s.bubbleCenter
        engine.canvas = s.canvas; engine.presenterLayout = s.presenterLayout
        engine.phoneScale = s.phoneScale
        engine.cameraShape = s.cameraShape
        engine.ringRGB = s.ringRGB
        engine.customBackgroundRGB = s.customBackgroundRGB
        engine.frameStyle = s.frameStyle
        engine.deviceOnLeft = s.deviceOnLeft
        engine.cameraLeads = s.cameraLeads
        engine.overlapArrangement = s.overlapArrangement
        engine.splitBalance = s.splitBalance
        engine.splitGap = s.splitGap
        engine.screenCorners = s.screenCorners
        engine.cameraEnabled = s.cameraEnabled
        phoneMix = s.phoneAudioLevel
        micMix = s.micAudioLevel
        applyPlaybackVolumes()
        if !zooms.contains(where: { $0.id == selectedZoomID }) { selectedZoomID = nil }
        applyTrimToPlayback()
        refreshPreview(immediate: true)
        isRestoringSnapshot = false
        updateUndoFlags()
    }

    private func updateUndoFlags() {
        canUndo = undoStack.count >= 2
        canRedo = !redoStack.isEmpty
    }

    // MARK: - Waveform

    /// Downsampled loudness of the recording's audio, ~0…1 per bucket, for the
    /// timeline's waveform. Empty until loaded (or if there is no audio).
    @Published var waveform: [Float] = []
    @Published var phoneWaveform: [Float] = []
    @Published var micWaveform: [Float] = []
    @Published var phoneAudioDuration: Double = 0
    @Published var micAudioDuration: Double = 0
    @Published var timelineZoom: Double = 1
    @Published var timelineHeight: CGFloat = 248
    @Published var timelineHidden = false
    private var restoredPhoneAudio: Double = 1
    private var restoredMicAudio: Double = 1

    var phoneMuted: Bool { phoneMix <= 0.001 }
    var micMuted: Bool { micMix <= 0.001 }

    func togglePhoneMute() {
        if phoneMuted {
            phoneMix = CGFloat(restoredPhoneAudio > 0.02 ? restoredPhoneAudio : 1)
        } else {
            restoredPhoneAudio = Double(phoneMix)
            phoneMix = 0
        }
        applyPlaybackVolumes()
        save()
    }

    func toggleMicMute() {
        if micMuted {
            micMix = CGFloat(restoredMicAudio > 0.02 ? restoredMicAudio : 1)
        } else {
            restoredMicAudio = Double(micMix)
            micMix = 0
        }
        applyPlaybackVolumes()
        save()
    }

    private func loadWaveform() async {
        // Decode off the main thread — a long take would otherwise freeze the UI.
        let phoneURL = playbackPhoneURL
        let sidecars = PhoneAudioSegments.urls(in: dir)
        let micURL = hasMic ? playbackCameraURL : nil
        let pair = await Task.detached(priority: .utility) {
            var phone = await Self.computeWaveform(url: phoneURL)
            if phone.0.isEmpty, !sidecars.isEmpty {
                phone = await Self.computeWaveform(urls: sidecars)
            }
            let mic: ([Float], Double)
            if let micURL, micURL.standardizedFileURL != phoneURL.standardizedFileURL {
                mic = await Self.computeWaveform(url: micURL)
            } else {
                mic = ([], 0)
            }
            return (phone, mic)
        }.value
        phoneWaveform = pair.0.0
        phoneAudioDuration = pair.0.1
        micWaveform = pair.1.0
        micAudioDuration = pair.1.1
        waveform = pair.0.0
    }

    func bumpTimelineZoom(_ factor: Double) {
        timelineZoom = min(16, max(1, timelineZoom * factor))
        scheduleThumbnails()
    }

    private func scheduleThumbnails() {
        thumbTask?.cancel()
        thumbTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard let self, !Task.isCancelled else { return }
            await self.makeThumbnails()
        }
    }

    nonisolated private static func computeWaveform(urls: [URL]) async -> ([Float], Double) {
        if urls.isEmpty { return ([], 0) }
        if urls.count == 1 { return await computeWaveform(url: urls[0]) }
        let comp = AVMutableComposition()
        var cursor = CMTime.zero
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let src = try? await asset.loadTracks(withMediaType: .audio).first,
                  let range = try? await src.load(.timeRange),
                  range.duration.seconds > 0.05,
                  let dest = comp.addMutableTrack(withMediaType: .audio,
                                                  preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            do {
                try dest.insertTimeRange(range, of: src, at: cursor)
                cursor = CMTimeAdd(cursor, range.duration)
            } catch { continue }
        }
        guard cursor.seconds > 0.05 else { return ([], 0) }
        return await computeWaveform(asset: comp)
    }

    nonisolated private static func computeWaveform(url: URL) async -> ([Float], Double) {
        await computeWaveform(asset: AVURLAsset(url: url))
    }

    nonisolated private static func computeWaveform(asset: AVAsset) async -> ([Float], Double) {
        let fileDuration = (try? await asset.load(.duration).seconds) ?? 0
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return ([], fileDuration) }
        let buckets = 240
        var peaks = [Float](repeating: 0, count: buckets)
        do {
            let reader = try AVAssetReader(asset: asset)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: 1,
            ])
            guard reader.canAdd(out) else { return ([], fileDuration) }
            reader.add(out)
            guard reader.startReading() else { return ([], fileDuration) }
            let total = try await asset.load(.duration).seconds
            guard total > 0 else { return ([], fileDuration) }
            while let buf = out.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(buf) else { continue }
                let t = CMSampleBufferGetPresentationTimeStamp(buf).seconds
                let n = CMBlockBufferGetDataLength(block)
                guard n >= 2 else { continue }
                var data = [Int16](repeating: 0, count: n / 2)
                data.withUnsafeMutableBytes { raw in
                    guard let dest = raw.baseAddress else { return }
                    _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n,
                                                   destination: dest)
                }
                let bucket = min(buckets - 1, max(0, Int(t / total * Double(buckets))))
                let peak = data.reduce(Int16(0)) { max($0, Swift.max($1, $1 == .min ? .max : -$1)) }
                peaks[bucket] = max(peaks[bucket], Float(peak) / Float(Int16.max))
            }
            reader.cancelReading()
        } catch { return ([], fileDuration) }
        // Light normalization so quiet takes still show shape.
        let top = max(peaks.max() ?? 1, 0.05)
        return (peaks.map { min(1, $0 / top) }, fileDuration)
    }

    // MARK: - Thumbnails

    private func makeThumbnails() async {
        thumbGen += 1
        let gen = thumbGen
        let phoneURL = playbackPhoneURL
        let camURL = hasCamera ? playbackCameraURL : nil
        let align = ClipAlignment.startAtMic(cameraOffsetSeconds: cameraOffset.seconds)
        let zoom = timelineZoom
        let phoneCount = FilmstripBudget.count(zoom: zoom)
        let camCount = FilmstripBudget.cameraCount(zoom: zoom)
        let height = CGFloat(FilmstripBudget.maxHeight(zoom: zoom))
        let phoneSkip = align.phoneSkip
        let camSkip = align.cameraSkip
        let phoneFallback = phoneFileDuration > 0.05 ? phoneFileDuration : duration
        let camFallback = cameraFileDuration
        let pair = await Task.detached(priority: .utility) {
            let phone = await Self.generateThumbnails(
                url: phoneURL, fallbackDuration: phoneFallback,
                count: phoneCount, maxHeight: height, skip: phoneSkip)
            let camera: [CGImage]
            if let camURL, camURL.standardizedFileURL != phoneURL.standardizedFileURL {
                camera = await Self.generateThumbnails(
                    url: camURL, fallbackDuration: camFallback,
                    count: camCount, maxHeight: CGFloat(FilmstripBudget.cameraHeight(zoom: zoom)), skip: camSkip)
            } else {
                camera = []
            }
            return (phone, camera)
        }.value
        guard gen == thumbGen else { return }
        thumbnails = pair.0
        cameraThumbnails = pair.1
    }

    nonisolated private static func generateThumbnails(
        url: URL, fallbackDuration: Double, count: Int, maxHeight: CGFloat, skip: Double
    ) async -> [CGImage] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 0, height: maxHeight)
        let slack = FilmstripBudget.timeTolerance(count: count)
        generator.requestedTimeToleranceBefore = CMTime(seconds: slack, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: slack, preferredTimescale: 600)
        let fileDuration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? fallbackDuration
        let start = min(max(0, skip), max(0, fileDuration - 0.05))
        let span = max(0.05, fileDuration - start)
        guard fileDuration > 0, count > 0 else { return [] }
        var images: [CGImage] = []
        images.reserveCapacity(count)
        for i in 0..<count {
            let t = start + span * (Double(i) + 0.5) / Double(count)
            if let img = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                images.append(img)
            }
        }
        return images
    }

    // MARK: - Export & close

    /// Exports run in a separate worker process (a headless copy of this app
    /// binary running --export-json). The editor's preview pipeline has wedged
    /// AVFoundation before — a clean process is immune to all of that, and a
    /// stall is fixed by killing the worker, never the app.
    func nextExportURL(in folder: URL) -> URL {
        var outURL = folder.appendingPathComponent("Recording.mp4")
        var n = 2
        let combineBusy = engine.combineInFlight
            || FileManager.default.fileExists(atPath: dir.appendingPathComponent("Recording.inprogress.mp4").path)
        if combineBusy && folder.standardizedFileURL == dir.standardizedFileURL {
            outURL = folder.appendingPathComponent("Recording 2.mp4")
            n = 3
        }
        while FileManager.default.fileExists(atPath: outURL.path) {
            outURL = folder.appendingPathComponent("Recording \(n).mp4")
            n += 1
        }
        return outURL
    }

    static func askWhereToSave(suggestedName: String, startingIn folder: URL) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.title = "Export recording"
        panel.nameFieldStringValue = suggestedName
        panel.directoryURL = folder
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.prompt = "Export"
        return panel.runModal() == .OK ? panel.url : nil
    }

    func export() {
        export(to: nextExportURL(in: dir))
    }

    func export(to outURL: URL) {
        guard exportProgress == nil, isReady else { return }
        player.pause()
        cameraPlayer.pause()
        isPlaying = false
        exportProgress = 0
        exportSucceeded = false
        exportedURL = nil
        exportWatchdogKilled = false
        exportUserCancelled = false
        lastExportProgressAt = .now
        save()

        let spec = ExportSpec(
            phonePath: phoneURL.path, cameraPath: cameraURL.path,
            cameraOffsetSeconds: cameraOffset.seconds,
            layout: {
                var l = engine.currentLayout()
                l.scenes = scenes
                return l
            }(), zooms: zooms,
            trimStart: trimStart > 0.05 ? trimStart : nil,
            trimEnd: trimEnd < duration - 0.05 ? trimEnd : nil,
            outputPath: outURL.path,
            phoneAudioLevel: Double(phoneMix),
            micAudioLevel: Double(micMix))
        let specURL = dir.appendingPathComponent("export-spec.json")
        guard let specData = try? JSONEncoder().encode(spec),
              (try? specData.write(to: specURL, options: .atomic)) != nil,
              let exe = Bundle.main.executableURL else {
            engine.errorMessage = "Couldn't start the export."
            exportProgress = nil
            return
        }

        let worker = Process()
        worker.executableURL = exe
        worker.arguments = ["--export-json", specURL.path]
        let outPipe = Pipe()
        let errPipe = Pipe()
        worker.standardOutput = outPipe
        worker.standardError = errPipe
        let output = WorkerOutput()
        exportWorker = worker

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            NSLog("[export] worker stderr: %@", String(decoding: data, as: UTF8.self))
        }

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let chunk = String(decoding: data, as: UTF8.self)
            for line in output.completeLines(appending: chunk) {
                if line.hasPrefix("progress "), let p = Double(line.dropFirst(9)) {
                    Task { @MainActor [weak self] in
                        self?.exportProgress = min(max(p, 0), 1)
                        self?.lastExportProgressAt = .now
                    }
                } else if line.hasPrefix("OK ") || line.hasPrefix("FAIL") {
                    output.setResult(line)
                }
            }
        }

        worker.terminationHandler = { [weak self] proc in
            // Drain any remaining bytes so a trailing "OK …" without a flush
            // race isn't missed (the classic false "Export failed" bug).
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            if let leftover = try? outPipe.fileHandleForReading.readToEnd(), !leftover.isEmpty {
                for line in output.completeLines(appending: String(decoding: leftover, as: UTF8.self)) {
                    if line.hasPrefix("OK ") || line.hasPrefix("FAIL") {
                        output.setResult(line)
                    }
                }
            }
            output.flushRemainder()

            let status = proc.terminationStatus
            let result = output.result()
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? FileManager.default.removeItem(at: specURL)
                self.exportWorker = nil

                if self.exportUserCancelled {
                    self.exportProgress = nil
                } else if status == 0, let result, result.hasPrefix("OK ") {
                    NSLog("[export] worker OK: %@", result)
                    self.exportProgress = 1
                    self.exportSucceeded = true
                    if FileManager.default.fileExists(atPath: outURL.path) {
                        self.exportedURL = outURL
                        NSWorkspace.shared.activateFileViewerSelecting([outURL])
                    }
                    // Clear overlay after a beat so success is visible.
                    try? await Task.sleep(for: .milliseconds(600))
                    self.exportProgress = nil
                } else if self.exportWatchdogKilled {
                    self.engine.errorMessage = "Saving stalled and was stopped. Your raw recordings and edits are safe — try Export again."
                    self.exportProgress = nil
                } else {
                    let detail = result ?? "exit \(status)"
                    NSLog("[export] worker FAILED status=%d result=%@", status, detail)
                    self.engine.errorMessage = "Export failed (\(detail)). Your raw recordings and edits are safe — try Export again."
                    self.exportProgress = nil
                }
                self.exportWatchdogKilled = false
                self.exportUserCancelled = false
            }
        }

        do {
            try worker.run()
            NSLog("[export] worker started pid=%d", worker.processIdentifier)
        } catch {
            engine.errorMessage = "Couldn't start the export: \(error.localizedDescription)"
            exportProgress = nil
            exportWorker = nil
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
                    self.exportWorker?.terminate()
                    return
                }
            }
        }
    }

    func cancelExport() {
        guard exportProgress != nil else { return }
        exportUserCancelled = true
        exportWorker?.terminate()
    }

    private var exportWatchdogKilled = false
    private var exportUserCancelled = false

    func close() {
        refreshTask?.cancel()
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("preview-mix.m4a"))
        if exportProgress != nil {
            cancelExport()
        }
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let cameraEndObserver { NotificationCenter.default.removeObserver(cameraEndObserver) }
        statusObservation?.invalidate()
        save()
        player.pause()
        player.replaceCurrentItem(with: nil)
        cameraPlayer.pause()
        cameraPlayer.replaceCurrentItem(with: nil)
        onClose()
        engine.editor = nil
    }
}
