@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// AVFoundation confines these three objects to one serial queue, but its
/// legacy Objective-C types do not declare that fact to Swift's checker.
private final class AudioMixIO: @unchecked Sendable {
    let reader: AVAssetReader
    let output: AVAssetReaderAudioMixOutput
    let input: AVAssetWriterInput

    init(reader: AVAssetReader, output: AVAssetReaderAudioMixOutput,
         input: AVAssetWriterInput) {
        self.reader = reader
        self.output = output
        self.input = input
    }
}

/// Everything a headless export run needs, written as JSON next to the
/// recording. Exports run in a separate worker process (spawned copy of this
/// app) so nothing the editor's preview pipeline has done can stall them.
struct ExportSpec: Codable {
    var phonePath: String
    var cameraPath: String
    var cameraOffsetSeconds: Double
    var layout: ExportLayout
    var zooms: [ZoomSegment]
    var trimStart: Double?
    var trimEnd: Double?
    /// Where to write the finished movie. Nil = "Recording.mp4" next to phonePath.
    var outputPath: String?
    /// 0…1. Missing on old specs = full volume.
    var phoneAudioLevel: Double?
    var micAudioLevel: Double?
}

/// How the camera sits relative to the phone on the canvas.
enum PresenterLayout: String, CaseIterable, Identifiable, Codable {
    case floating = "Floating"
    case split = "Side by side"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .floating: return "Camera bubble"
        case .split: return "Side by side"
        }
    }

    var subtitle: String {
        switch self {
        case .floating: return "Device primary, camera overlay"
        case .split: return "Phone and camera next to each other"
        }
    }
}

/// Look settings shared by the live preview and the export, in normalized
/// units so they map from the on-screen canvas to the export canvas.
struct ExportLayout: Codable, Equatable {
    var bubbleCenter: CGPoint     // 0...1, top-left origin (SwiftUI style)
    var bubbleFraction: CGFloat   // camera size / min canvas dimension (0.12…0.72)
    var canvas: CGSize
    var background: BackgroundPreset
    var showBezel: Bool
    var presenterLayout: PresenterLayout
    /// Phone height as a fraction of canvas height in floating layout —
    /// smaller = more background padding around the device.
    var phoneScale: CGFloat = ExportLayout.phoneHeightFraction
    var cameraShape: CameraShape = .circle
    var ringRGB: [CGFloat] = [1, 1, 1]
    var frameStyle: DeviceFrameStyle = .none
    var screenCorners: Bool = true
    var showBorder: Bool = false
    var customBackgroundRGB: [CGFloat]? = nil
    var cameraEnabled: Bool = true
    var deviceOnLeft: Bool = true
    var cameraLeads: Bool = false
    var overlapArrangement: Bool = false
    var splitBalance: CGFloat = 0.55
    var splitGap: CGFloat = 0.08
    var scenes: [SceneClip] = []

    /// Default phone content height as a fraction of canvas height (floating layout).
    static let phoneHeightFraction: CGFloat = 0.84
    /// Allowed range for the padding slider.
    static let phoneScaleMin: CGFloat = 0.55
    static let phoneScaleMax: CGFloat = 0.92
    /// Max phone width as a fraction of canvas width (landscape iPad).
    static let phoneMaxWidthFraction: CGFloat = 0.86
    /// Outer bezel thickness as a fraction of the phone's short side (thin metal rim).
    static let bezelThicknessFraction: CGFloat = 0.022
    /// Screen corner radius as a fraction of the phone's short side (modern iPhone).
    static let screenCornerFraction: CGFloat = 0.118
    /// Allowed camera size range (fraction of min canvas side).
    static let bubbleMin: CGFloat = 0.14
    static let bubbleMax: CGFloat = 0.72
    static let bezelColor: (CGFloat, CGFloat, CGFloat) = (0.10, 0.10, 0.11)
    static let bezelHighlight: (CGFloat, CGFloat, CGFloat) = (0.32, 0.32, 0.34)

    /// Backward-compatible decode for older project.json / export specs.
    enum CodingKeys: String, CodingKey {
        case bubbleCenter, bubbleFraction, canvas, background, showBezel, presenterLayout, phoneScale
        case cameraShape, ringRGB, frameStyle, screenCorners, showBorder
        case customBackgroundRGB, cameraEnabled, deviceOnLeft, cameraLeads
        case overlapArrangement, splitBalance, splitGap, scenes
    }

    init(bubbleCenter: CGPoint, bubbleFraction: CGFloat, canvas: CGSize,
         background: BackgroundPreset, showBezel: Bool,
         presenterLayout: PresenterLayout = .floating,
         phoneScale: CGFloat = ExportLayout.phoneHeightFraction,
         cameraShape: CameraShape = .circle,
         ringRGB: [CGFloat] = [1, 1, 1],
         frameStyle: DeviceFrameStyle = .none,
         screenCorners: Bool = true,
         showBorder: Bool = false,
         customBackgroundRGB: [CGFloat]? = nil,
         cameraEnabled: Bool = true,
         deviceOnLeft: Bool = true,
         cameraLeads: Bool = false,
         overlapArrangement: Bool = false,
         splitBalance: CGFloat = 0.55,
         splitGap: CGFloat = 0.08,
         scenes: [SceneClip] = []) {
        self.bubbleCenter = bubbleCenter
        self.bubbleFraction = bubbleFraction
        self.canvas = canvas
        self.background = background
        self.showBezel = showBezel
        self.presenterLayout = presenterLayout
        self.phoneScale = phoneScale
        self.cameraShape = cameraShape
        self.ringRGB = ringRGB
        self.frameStyle = frameStyle
        self.screenCorners = screenCorners
        self.showBorder = showBorder
        self.customBackgroundRGB = customBackgroundRGB
        self.cameraEnabled = cameraEnabled
        self.deviceOnLeft = deviceOnLeft
        self.cameraLeads = cameraLeads
        self.overlapArrangement = overlapArrangement
        self.splitBalance = splitBalance
        self.splitGap = splitGap
        self.scenes = scenes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bubbleCenter = try c.decode(CGPoint.self, forKey: .bubbleCenter)
        bubbleFraction = try c.decode(CGFloat.self, forKey: .bubbleFraction)
        canvas = try c.decode(CGSize.self, forKey: .canvas)
        background = try c.decode(BackgroundPreset.self, forKey: .background)
        showBezel = try c.decode(Bool.self, forKey: .showBezel)
        presenterLayout = try c.decodeIfPresent(PresenterLayout.self, forKey: .presenterLayout) ?? .floating
        phoneScale = try c.decodeIfPresent(CGFloat.self, forKey: .phoneScale) ?? ExportLayout.phoneHeightFraction
        cameraShape = try c.decodeIfPresent(CameraShape.self, forKey: .cameraShape) ?? .circle
        ringRGB = try c.decodeIfPresent([CGFloat].self, forKey: .ringRGB) ?? [1, 1, 1]
        frameStyle = try c.decodeIfPresent(DeviceFrameStyle.self, forKey: .frameStyle)
            ?? (showBezel ? .black : .none)
        screenCorners = try c.decodeIfPresent(Bool.self, forKey: .screenCorners) ?? true
        showBorder = try c.decodeIfPresent(Bool.self, forKey: .showBorder) ?? false
        customBackgroundRGB = try c.decodeIfPresent([CGFloat].self, forKey: .customBackgroundRGB)
        cameraEnabled = try c.decodeIfPresent(Bool.self, forKey: .cameraEnabled) ?? true
        deviceOnLeft = try c.decodeIfPresent(Bool.self, forKey: .deviceOnLeft) ?? true
        cameraLeads = try c.decodeIfPresent(Bool.self, forKey: .cameraLeads) ?? false
        overlapArrangement = try c.decodeIfPresent(Bool.self, forKey: .overlapArrangement) ?? false
        splitBalance = try c.decodeIfPresent(CGFloat.self, forKey: .splitBalance) ?? 0.55
        splitGap = try c.decodeIfPresent(CGFloat.self, forKey: .splitGap) ?? 0.08
        scenes = try c.decodeIfPresent([SceneClip].self, forKey: .scenes) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bubbleCenter, forKey: .bubbleCenter)
        try c.encode(bubbleFraction, forKey: .bubbleFraction)
        try c.encode(canvas, forKey: .canvas)
        try c.encode(background, forKey: .background)
        try c.encode(showBezel, forKey: .showBezel)
        try c.encode(presenterLayout, forKey: .presenterLayout)
        try c.encode(phoneScale, forKey: .phoneScale)
        try c.encode(cameraShape, forKey: .cameraShape)
        try c.encode(ringRGB, forKey: .ringRGB)
        try c.encode(frameStyle, forKey: .frameStyle)
        try c.encode(screenCorners, forKey: .screenCorners)
        try c.encode(showBorder, forKey: .showBorder)
        try c.encodeIfPresent(customBackgroundRGB, forKey: .customBackgroundRGB)
        try c.encode(cameraEnabled, forKey: .cameraEnabled)
        try c.encode(deviceOnLeft, forKey: .deviceOnLeft)
        try c.encode(cameraLeads, forKey: .cameraLeads)
        try c.encode(overlapArrangement, forKey: .overlapArrangement)
        try c.encode(splitBalance, forKey: .splitBalance)
        try c.encode(splitGap, forKey: .splitGap)
        try c.encode(scenes, forKey: .scenes)
    }

    func scene(at t: Double) -> SceneKind {
        if let hit = scenes.first(where: { t >= $0.start && t < $0.end }) {
            return hit.kind
        }
        return cameraEnabled ? .both : .device
    }

    // MARK: Split-mode zones — the ONE source of truth for split geometry.
    // Top-left-origin coordinates (SwiftUI style); the Core Image compositor
    // flips them. The live preview and the export must call these same
    // functions or the two drift apart.

    static func splitPad(canvas: CGSize) -> CGFloat { min(canvas.width, canvas.height) * 0.05 }

    /// Horizontal split: phone vs camera. `deviceShare` is how much of the
    /// content width the phone occupies (0.2…0.8).
    static func splitZones(canvas: CGSize, layout: ExportLayout) -> (phone: CGRect, camera: CGRect) {
        let inset = canvas.width * (0.04 + max(0, layout.phoneScale.distance(to: 0.92)) * 0.15)
        let pad = splitPad(canvas: canvas)
        let gap = max(8, min(canvas.width, canvas.height) * layout.splitGap)
        let inner = CGRect(x: inset, y: pad,
                           width: canvas.width - inset * 2,
                           height: canvas.height - pad * 2)
        let focus = layout.cameraLeads ? 1 - layout.splitBalance : layout.splitBalance
        let deviceShare = min(0.78, max(0.22, focus))
        var phoneW = (inner.width - gap) * deviceShare
        var camW = inner.width - gap - phoneW
        if layout.overlapArrangement {
            let overlap = min(phoneW, camW) * 0.18
            phoneW += overlap / 2
            camW += overlap / 2
        }
        let phoneX = layout.deviceOnLeft ? inner.minX : inner.maxX - phoneW
        let camX = layout.deviceOnLeft ? inner.maxX - camW : inner.minX
        return (
            CGRect(x: phoneX, y: inner.minY, width: phoneW, height: inner.height),
            CGRect(x: camX, y: inner.minY, width: camW, height: inner.height)
        )
    }

}

enum BackgroundPreset: String, CaseIterable, Identifiable, Codable {
    // Gradients
    case midnight = "Midnight"
    case graphite = "Graphite"
    case ocean = "Ocean"
    case sunset = "Sunset"
    case forest = "Forest"
    case aurora = "Aurora"
    case candy = "Candy"
    case ember = "Ember"
    // Solid colors
    case black = "Black"
    case slate = "Slate"
    case snow = "White"
    case indigo = "Indigo"

    var id: String { rawValue }

    /// True for the flat single-color presets (the inspector's "Color" tab).
    var isSolid: Bool {
        switch self {
        case .black, .slate, .snow, .indigo: return true
        default: return false
        }
    }

    /// (top, bottom) gradient colors as RGB 0–1. Solids use top == bottom.
    var colors: (top: (CGFloat, CGFloat, CGFloat), bottom: (CGFloat, CGFloat, CGFloat)) {
        switch self {
        case .midnight: return ((0.17, 0.17, 0.21), (0.09, 0.09, 0.11))
        case .graphite: return ((0.36, 0.36, 0.40), (0.14, 0.14, 0.16))
        case .ocean:    return ((0.12, 0.30, 0.52), (0.03, 0.07, 0.18))
        case .sunset:   return ((0.93, 0.44, 0.30), (0.38, 0.10, 0.32))
        case .forest:   return ((0.13, 0.36, 0.26), (0.03, 0.10, 0.08))
        case .aurora:   return ((0.16, 0.65, 0.60), (0.14, 0.12, 0.45))
        case .candy:    return ((0.95, 0.55, 0.75), (0.45, 0.20, 0.75))
        case .ember:    return ((0.95, 0.60, 0.15), (0.55, 0.10, 0.10))
        case .black:    return ((0.02, 0.02, 0.02), (0.02, 0.02, 0.02))
        case .slate:    return ((0.22, 0.24, 0.28), (0.22, 0.24, 0.28))
        case .snow:     return ((0.93, 0.93, 0.95), (0.93, 0.93, 0.95))
        case .indigo:   return ((0.26, 0.24, 0.60), (0.26, 0.24, 0.60))
        }
    }
}

enum CanvasPreset: String, CaseIterable, Identifiable, Codable {
    case device = "Device"
    case landscape = "16:9"
    case square = "1:1"
    case macbook = "16:10"
    case photo = "3:2"
    case ipad = "4:3"
    case fiveFour = "5:4"
    case portrait = "9:16"

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .device: return "Device size"
        case .landscape: return "16:9 Landscape"
        case .square: return "1:1 Square"
        case .macbook: return "16:10 Landscape"
        case .photo: return "3:2 Landscape"
        case .ipad: return "4:3 Landscape"
        case .fiveFour: return "5:4 Landscape"
        case .portrait: return "9:16 Portrait"
        }
    }

    var subtitle: String {
        switch self {
        case .device: return "Native size"
        case .landscape: return "YouTube"
        case .square: return "Instagram post"
        case .macbook: return "MacBook"
        case .photo: return "Photo"
        case .ipad: return "iPad · Slides"
        case .fiveFour: return "8 × 10 photo"
        case .portrait: return "Stories"
        }
    }

    func size(phoneAspect: CGFloat = 0.462) -> CGSize {
        switch self {
        case .device:
            let h: CGFloat = 1920
            return CGSize(width: max(720, h * max(phoneAspect, 0.4)), height: h)
        case .landscape: return CGSize(width: 1920, height: 1080)
        case .square: return CGSize(width: 1080, height: 1080)
        case .macbook: return CGSize(width: 1920, height: 1200)
        case .photo: return CGSize(width: 1920, height: 1280)
        case .ipad: return CGSize(width: 1920, height: 1440)
        case .fiveFour: return CGSize(width: 1600, height: 1280)
        case .portrait: return CGSize(width: 1080, height: 1920)
        }
    }

    var size: CGSize { size() }

    static func matching(size: CGSize) -> CanvasPreset {
        let r = size.width / max(size.height, 1)
        if abs(r - 16 / 9) < 0.05 { return .landscape }
        if abs(r - 1) < 0.05 { return .square }
        if abs(r - 16 / 10) < 0.05 { return .macbook }
        if abs(r - 3 / 2) < 0.05 { return .photo }
        if abs(r - 4 / 3) < 0.05 { return .ipad }
        if abs(r - 5 / 4) < 0.05 { return .fiveFour }
        if r < 0.75 { return .portrait }
        return .device
    }
}

/// A Screen-Studio-style zoom: over its time range the picture smoothly
/// scales up around `center`, holds, and eases back out.
struct ZoomSegment: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var start: Double            // seconds on the recording timeline
    var duration: Double
    /// Phone-screen point, 0…1, top-left origin. Preview and export convert
    /// this through the same phone rect before aiming the zoom.
    var center = CGPoint(x: 0.5, y: 0.5)
    var level: CGFloat = 2.0     // 1.0 = no zoom

    var end: Double { start + duration }

    /// Eased scale at time `t`: starts a little early, lands softly, eases out.
    /// Preview and export both call this so they stay in sync.
    func scale(at t: Double) -> CGFloat {
        guard level > 1 else { return 1 }
        let lead = min(0.45, duration * 0.22)
        let zoomIn = min(0.85, max(0.28, duration * 0.32))
        let zoomOut = min(0.7, max(0.22, duration * 0.24))
        let from = start - lead
        let to = end
        guard t >= from, t <= to else { return 1 }
        let k: Double
        if t < start + zoomIn - lead {
            let span = max(0.12, (start + zoomIn - lead) - from)
            k = (t - from) / span
        } else if t > to - zoomOut {
            k = (to - t) / zoomOut
        } else {
            k = 1
        }
        let x = min(max(k, 0), 1)
        // Ease-out cubic — fast start, soft landing (Recordly-style, not a copy).
        let eased = 1 - pow(1 - x, 3)
        return 1 + (level - 1) * eased
    }
}

/// Combines phone.mov (screen video + device audio) and camera.mov (camera +
/// mic) into one polished MP4: gradient background, rounded phone in the
/// middle, rounded camera bubble where the user dragged it. Audio tracks are
/// mixed into a single stereo track so every player hears both sources.
enum Exporter {

    static func export(phoneURL: URL, cameraURL: URL,
                       cameraOffset: CMTime, layout: ExportLayout,
                       zooms: [ZoomSegment] = [], trim: CMTimeRange? = nil,
                       outputURL: URL? = nil,
                       phoneAudioLevel: Double = 1,
                       micAudioLevel: Double = 1,
                       onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let composition = AVMutableComposition()

        // Timeline 0 is the mic / camera start so the first words are not
        // delayed by the time it took the camera writer to spin up.
        let align = ClipAlignment.startAtMic(cameraOffsetSeconds: cameraOffset.seconds)
        let phoneAt = CMTime(seconds: align.phoneAt, preferredTimescale: 600)
        let cameraAt = CMTime(seconds: align.cameraAt, preferredTimescale: 600)
        let phoneSkip = CMTime(seconds: align.phoneSkip, preferredTimescale: 600)
        let cameraSkip = CMTime(seconds: align.cameraSkip, preferredTimescale: 600)

        let phoneSource = await joinedPhoneURL(from: phoneURL)
        let readyPhone = try await ensureReadableMovie(phoneSource, label: "device")
        let cameraIsPhone = cameraURL.standardizedFileURL == phoneURL.standardizedFileURL
        let readyCamera = cameraIsPhone ? nil : (try? await ensureReadableMovie(cameraURL, label: "camera"))
        // Precise timing only for export (quality over speed).
        let precise: [String: Any] = [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        let phoneAsset = AVURLAsset(url: readyPhone, options: precise)
        let cameraAsset = readyCamera.map { AVURLAsset(url: $0, options: precise) }

        guard let phoneVideo = try await addTrack(from: phoneAsset, type: .video,
                                                  to: composition, at: phoneAt, skip: phoneSkip) else {
            throw ExportError.missingTrack(
                "the device recording has no usable video. Keep it unlocked and try again.")
        }
        var cameraTrackID = kCMPersistentTrackID_Invalid
        var cameraRot: CGFloat = 0
        if let cameraAsset {
            if let cam = try await addTrack(from: cameraAsset, type: .video,
                                            to: composition, at: cameraAt, skip: cameraSkip) {
                cameraTrackID = cam.trackID
            }
            cameraRot = try await rotationAngle(of: cameraAsset)
        }

        // Blend the phone's sound and the mic into ONE track.
        let mixedAudio = readyPhone.deletingLastPathComponent().appendingPathComponent("mixed-audio.m4a")
        var sources: [(AVURLAsset, CMTime)] = [(phoneAsset, phoneAt)]
        if let cameraAsset { sources.append((cameraAsset, cameraAt)) }
        var hadAnyAudio = false
        for (asset, _) in sources {
            if try await !asset.loadTracks(withMediaType: .audio).isEmpty {
                hadAnyAudio = true
                break
            }
        }
        if !hadAnyAudio,
           await joinedPhoneAudioURL(in: readyPhone.deletingLastPathComponent()) != nil {
            hadAnyAudio = true
        }
        if hadAnyAudio {
            let phoneVol = Float(min(max(phoneAudioLevel, 0), 1))
            let micVol = Float(min(max(micAudioLevel, 0), 1))
            var leveled: [(AVURLAsset, CMTime, Float, CMTime)] = [(phoneAsset, phoneAt, phoneVol, phoneSkip)]
            let takeDir = readyPhone.deletingLastPathComponent()
            if let sidecar = await joinedPhoneAudioURL(in: takeDir) {
                leveled.append((AVURLAsset(url: sidecar), phoneAt, phoneVol, phoneSkip))
            } else {
                let parts = PhoneAudioSegments.urls(in: takeDir)
                if AudioJoinPolicy.fallback(partCount: parts.count) == .refusePartial {
                    leveled.append(contentsOf: await sequentialAudioSources(
                        parts, start: phoneAt, skip: phoneSkip, volume: phoneVol))
                }
            }
            if let cameraAsset { leveled.append((cameraAsset, cameraAt, micVol, cameraSkip)) }
            guard let mixedURL = try await mixAudio(sources: leveled, into: mixedAudio),
                  try await addTrack(from: AVURLAsset(url: mixedURL), type: .audio,
                                     to: composition, at: .zero) != nil else {
                throw ExportError.missingTrack("the recorded sound could not be prepared for export")
            }
        }

        let phoneDur = (try? await phoneAsset.load(.duration).seconds) ?? 0
        let camDur = cameraAsset == nil ? 0 : ((try? await cameraAsset!.load(.duration).seconds) ?? 0)
        let phoneWin = ClipAlignment.clipWindow(fileDuration: phoneDur, at: align.phoneAt, skip: align.phoneSkip)
        let camWin = ClipAlignment.clipWindow(fileDuration: camDur, at: align.cameraAt, skip: align.cameraSkip)
        let videoComposition = makeVideoComposition(
            duration: try await composition.load(.duration),
            phoneTrackID: phoneVideo.trackID,
            cameraTrackID: cameraTrackID,
            phoneRotation: try await rotationAngle(of: phoneAsset),
            cameraRotation: cameraRot,
            layout: layout, zooms: zooms,
            holdPhone: firstFrame(of: phoneAsset),
            holdPhoneEnd: frame(of: phoneAsset, at: max(0, phoneDur - 0.08)),
            holdCamera: cameraAsset.flatMap { firstFrame(of: $0) },
            holdCameraEnd: cameraAsset.flatMap { frame(of: $0, at: max(0, camDur - 0.08)) },
            phoneStart: phoneWin.start, phoneEnd: phoneWin.end,
            cameraStart: camWin.start, cameraEnd: camWin.end)

        NSLog("[export] composition ready: duration=%.2fs canvas=%.0fx%.0f zooms=%d trimmed=%d",
              try await composition.load(.duration).seconds,
              layout.canvas.width, layout.canvas.height, zooms.count, trim != nil ? 1 : 0)

        guard let session = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.exportSetup
        }
        session.videoComposition = videoComposition
        if let trim {
            // Clamp to the composition — the editor measures duration off the
            // preview composition, which can run a hair longer than this one.
            // A timeRange past the real end makes the exporter wait forever
            // for frames that never come (hangs at 0%).
            let total = try await composition.load(.duration)
            let end = CMTimeMinimum(trim.end, total)
            let start = CMTimeClampToRange(trim.start, range: CMTimeRange(start: .zero, end: end))
            session.timeRange = CMTimeRange(start: start, end: end)
        }

        let outURL = outputURL
            ?? phoneURL.deletingLastPathComponent().appendingPathComponent("Recording.mp4")
        try? FileManager.default.removeItem(at: outURL)

        let progressWatcher = Task {
            for await state in session.states(updateInterval: 0.3) {
                if case .exporting(let progress) = state {
                    onProgress(progress.fractionCompleted)
                }
            }
        }
        defer { progressWatcher.cancel() }
        try await session.export(to: outURL, as: .mp4)
        try? FileManager.default.removeItem(
            at: readyPhone.deletingLastPathComponent().appendingPathComponent("mixed-audio.m4a"))
        return outURL
    }

    /// Everything the editor needs to drive an AVPlayer with the same look the
    /// export will have. Unchecked-sendable so the review screen can build
    /// this off the main thread (one owner at a time).
    struct Preview: @unchecked Sendable {
        let composition: AVMutableComposition
        let phoneTrackID: CMPersistentTrackID
        let cameraTrackID: CMPersistentTrackID
        let phoneRotation: CGFloat
        let cameraRotation: CGFloat
        let duration: Double
    }

    /// Builds a playable composition of the raw recordings for the editor.
    ///
    /// Phone video is required. Camera is optional (soft-fail).
    ///
    /// Preview audio is mixed to one stable track before AVPlayer sees the
    /// composition. Swapping or mutating audio tracks after playback starts can
    /// make AVPlayer silently drop the microphone.
    static func makePreview(phoneURL: URL, cameraURL: URL,
                            cameraOffset: CMTime) async throws -> Preview {
        let phoneSource = await joinedPhoneURL(from: phoneURL)
        let readyPhone = try await ensureReadableMovie(phoneSource, label: "device")
        let readyCamera: URL?
        if cameraURL.standardizedFileURL == readyPhone.standardizedFileURL {
            readyCamera = nil
        } else {
            readyCamera = try? await ensureReadableMovie(cameraURL, label: "camera")
            if readyCamera == nil {
                NSLog("[media] camera unusable — opening phone-only preview")
            }
        }

        let phoneAsset = AVURLAsset(url: readyPhone)
        let cameraAsset = readyCamera.map { AVURLAsset(url: $0) }
        let align = ClipAlignment.startAtMic(cameraOffsetSeconds: cameraOffset.seconds)
        let phoneAt = CMTime(seconds: align.phoneAt, preferredTimescale: 600)
        let cameraAt = CMTime(seconds: align.cameraAt, preferredTimescale: 600)
        let phoneSkip = CMTime(seconds: align.phoneSkip, preferredTimescale: 600)
        let cameraSkip = CMTime(seconds: align.cameraSkip, preferredTimescale: 600)

        let composition = AVMutableComposition()
        guard let phoneVideo = try await addTrack(from: phoneAsset, type: .video,
                                                  to: composition, at: phoneAt, skip: phoneSkip) else {
            throw ExportError.missingTrack(
                "the device recording has no usable video. Keep it unlocked while recording and try another take.")
        }
        var cameraTrackID = kCMPersistentTrackID_Invalid
        var cameraRot: CGFloat = 0
        if let cameraAsset {
            if let cam = try await addTrack(from: cameraAsset, type: .video,
                                            to: composition, at: cameraAt, skip: cameraSkip) {
                cameraTrackID = cam.trackID
            }
            cameraRot = try await rotationAngle(of: cameraAsset)
        }

        // Do NOT remux audio for preview. mixAudio() re-encodes the whole
        // take and can hang on a file that just finished recording — that's
        // the white spinner after Stop. Drop the tracks straight onto the
        // composition; export still remuxes later.
        _ = try await addTrack(from: phoneAsset, type: .audio,
                               to: composition, at: phoneAt, skip: phoneSkip)
        if let cameraAsset {
            _ = try await addTrack(from: cameraAsset, type: .audio,
                                   to: composition, at: cameraAt, skip: cameraSkip)
        }

        return Preview(
            composition: composition,
            phoneTrackID: phoneVideo.trackID,
            cameraTrackID: cameraTrackID,
            phoneRotation: try await rotationAngle(of: phoneAsset),
            cameraRotation: cameraRot,
            duration: try await composition.load(.duration).seconds)
    }

    /// Makes a sidecar `*.play.mov` the editor can open without touching the
    /// still-warm recording. Always copies (faststart). Never call this from
    /// the main thread — AVPlayerItem on a just-finished file is what froze
    /// the app after Stop.
    static func preparePlaybackCopy(_ url: URL) async throws -> URL {
        let dest = url.deletingPathExtension().appendingPathExtension("play.mov")
        let destSize = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let srcSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if destSize > 1024, destSize >= srcSize / 4 {
            return dest
        }
        if let remuxed = await remuxMovie(url) {
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.moveItem(at: remuxed, to: dest)
                return dest
            } catch {
                return remuxed
            }
        }
        if let copy = await passthroughCopy(url, to: dest) {
            return copy
        }
        throw ExportError.missingTrack("the recording isn't ready to play yet")
    }

    private static func passthroughCopy(_ url: URL, to dest: URL) async -> URL? {
        try? FileManager.default.removeItem(at: dest)
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ])
        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetPassthrough) else { return nil }
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await session.export(to: dest, as: .mov)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(8))
                    session.cancelExport()
                    throw ExportError.exportSetup
                }
                _ = try await group.next()
                group.cancelAll()
            }
        } catch {
            try? FileManager.default.removeItem(at: dest)
            return nil
        }
        let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size > 1024 ? dest : nil
    }

    /// Returns a URL AVFoundation can play. Retries briefly — right after
    /// `stopRecording` the header can lag a few hundred ms. Remux only if
    /// still broken. Callers that can live without the file use `try?`.
    static func ensureReadableMovie(_ url: URL, label: String) async throws -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ExportError.missingTrack("the \(label) recording file is missing")
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 1024 else {
            throw ExportError.missingTrack("the \(label) recording is empty")
        }

        // Fast path first; short retries only if the header isn't ready yet
        // (common in the first half-second after stopRecording).
        if await movieHasUsableVideo(url) { return url }
        for attempt in 0..<4 {
            try? await Task.sleep(for: .milliseconds(100 + attempt * 80))
            if await movieHasUsableVideo(url) { return url }
        }

        NSLog("[media] %@ unreadable after retries (size=%d) — remux", url.lastPathComponent, size)

        if let repaired = await remuxMovie(url), await movieHasUsableVideo(repaired) {
            let broken = url.deletingPathExtension().appendingPathExtension("broken.mov")
            try? FileManager.default.removeItem(at: broken)
            try? FileManager.default.moveItem(at: url, to: broken)
            do {
                try FileManager.default.moveItem(at: repaired, to: url)
                NSLog("[media] repaired %@", url.lastPathComponent)
                return url
            } catch {
                return repaired
            }
        }

        throw ExportError.missingTrack(
            "the \(label) recording can't be opened (corrupt or incomplete). Keep the device unlocked while recording and try another take.")
    }

    /// Fast header check only — never scans sample data (that was multi-second lag).
    static func movieHasUsableVideo(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            if duration.isValid, !duration.isIndefinite, duration.seconds > 0.1 {
                return true
            }
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                return false
            }
            let range = try await track.load(.timeRange)
            return range.duration.seconds > 0.1
        } catch {
            return false
        }
    }

    /// True when an audio file has a real duration (rejects half-written m4a).
    static func movieHasUsableAudio(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            guard duration.isValid, !duration.isIndefinite, duration.seconds > 0.05 else {
                return false
            }
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            return !tracks.isEmpty
        } catch {
            return false
        }
    }

    /// Glues phone.mov + phone-2.mov + … so a USB hiccup is one clip.
    static func joinedPhoneURL(from phoneURL: URL) async -> URL {
        let dir = phoneURL.deletingLastPathComponent()
        let parts = PhoneSegments.urls(in: dir)
        guard parts.count > 1 else { return phoneURL }
        let dest = dir.appendingPathComponent("phone.joined.mov")
        return await concatMovies(parts, into: dest) ?? phoneURL
    }

    static func preparePhonePlayback(in dir: URL) async throws -> URL {
        let parts = PhoneSegments.urls(in: dir)
        let source = parts.first ?? dir.appendingPathComponent("phone.mov")
        var video = source
        if parts.count > 1, let joined = await concatMovies(parts, into: dir.appendingPathComponent("phone.joined.mov")) {
            video = joined
        }
        if let audio = await joinedPhoneAudioURL(in: dir) {
            let hasAudio = await movieHasUsableAudio(video)
            if !hasAudio,
               let muxed = await muxVideo(video, audio: audio,
                                          into: dir.appendingPathComponent("phone.with-audio.mov")) {
                return try await preparePlaybackCopy(muxed)
            }
        }
        return try await preparePlaybackCopy(video)
    }

    static func joinedPhoneAudioURL(in dir: URL) async -> URL? {
        let parts = PhoneAudioSegments.urls(in: dir)
        guard !parts.isEmpty else { return nil }
        if parts.count == 1 { return parts[0] }
        let dest = dir.appendingPathComponent("phone-audio.joined.m4a")
        if let joined = await concatMovies(parts, into: dest) { return joined }
        let sources = await sequentialAudioSources(parts, start: .zero, skip: .zero, volume: 1)
        return try? await mixAudio(sources: sources, into: dest)
    }

    /// Laid end to end so a format-change `phone-audio-2.m4a` keeps speaking
    /// after the first file, even when we cannot write a joined sidecar.
    static func sequentialAudioSources(_ urls: [URL], start: CMTime, skip: CMTime, volume: Float)
    async -> [(AVURLAsset, CMTime, Float, CMTime)] {
        var result: [(AVURLAsset, CMTime, Float, CMTime)] = []
        var cursor = start
        var remainingSkip = skip
        let precise: [String: Any] = [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        for url in urls {
            let asset = AVURLAsset(url: url, options: precise)
            let dur = (try? await asset.load(.duration)) ?? .zero
            guard dur.seconds > 0.05 else { continue }
            if remainingSkip.seconds >= dur.seconds - 0.05 {
                remainingSkip = CMTimeSubtract(remainingSkip, dur)
                continue
            }
            result.append((asset, cursor, volume, remainingSkip))
            cursor = CMTime(seconds: AudioJoinPolicy.nextStart(
                current: cursor.seconds, duration: dur.seconds, skip: remainingSkip.seconds),
                            preferredTimescale: 600)
            remainingSkip = .zero
        }
        return result
    }

    private static var ffmpegPath: String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func muxVideo(_ video: URL, audio: URL, into dest: URL) async -> URL? {
        if let ffmpeg = ffmpegPath {
            try? FileManager.default.removeItem(at: dest)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ffmpeg)
            proc.arguments = [
                "-hide_banner", "-loglevel", "error",
                "-y", "-i", video.path, "-i", audio.path,
                "-map", "0:v:0", "-map", "1:a:0",
                "-c", "copy", dest.path
            ]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            do {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    proc.terminationHandler = { _ in cont.resume() }
                    do { try proc.run() } catch { cont.resume(throwing: error) }
                }
            } catch {
                /* fall through to the in-app mux */
            }
            let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > 1024 { return dest }
        }
        return await muxVideoAV(video, audio: audio, into: dest)
    }

    private static func muxVideoAV(_ video: URL, audio: URL, into dest: URL) async -> URL? {
        let composition = AVMutableComposition()
        let precise: [String: Any] = [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        do {
            guard try await addTrack(from: AVURLAsset(url: video, options: precise),
                                     type: .video, to: composition, at: .zero) != nil,
                  try await addTrack(from: AVURLAsset(url: audio, options: precise),
                                     type: .audio, to: composition, at: .zero) != nil else {
                return nil
            }
        } catch { return nil }
        return await exportComposition(composition, to: dest, audioOnly: false)
    }

    private static func concatMovies(_ urls: [URL], into dest: URL) async -> URL? {
        guard urls.count > 1 else { return nil }
        if let joined = await concatMoviesFFmpeg(urls, into: dest) { return joined }
        return await concatMoviesAV(urls, into: dest)
    }

    private static func concatMoviesFFmpeg(_ urls: [URL], into dest: URL) async -> URL? {
        guard let ffmpeg = ffmpegPath else { return nil }
        let list = dest.deletingLastPathComponent()
            .appendingPathComponent("phone.concat-\(UUID().uuidString).txt")
        let body = urls.map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: "\n")
        do {
            try body.write(to: list, atomically: true, encoding: .utf8)
        } catch { return nil }
        defer { try? FileManager.default.removeItem(at: list) }
        try? FileManager.default.removeItem(at: dest)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = [
            "-hide_banner", "-loglevel", "error",
            "-y", "-f", "concat", "-safe", "0", "-i", list.path,
            "-c", "copy", dest.path
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                proc.terminationHandler = { _ in cont.resume() }
                do { try proc.run() } catch { cont.resume(throwing: error) }
            }
        } catch {
            return nil
        }
        let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size > 1024 ? dest : nil
    }

    private static func concatMoviesAV(_ urls: [URL], into dest: URL) async -> URL? {
        let comp = AVMutableComposition()
        var videoTrack: AVMutableCompositionTrack?
        var audioTrack: AVMutableCompositionTrack?
        var cursor = CMTime.zero
        let precise: [String: Any] = [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        for url in urls {
            let asset = AVURLAsset(url: url, options: precise)
            let duration = (try? await asset.load(.duration)) ?? .zero
            guard duration.seconds > 0.05 else { continue }
            if let src = try? await asset.loadTracks(withMediaType: .video).first {
                if videoTrack == nil {
                    videoTrack = comp.addMutableTrack(withMediaType: .video,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                if let videoTrack {
                    let range = (try? await src.load(.timeRange)).flatMap { $0.duration.seconds > 0.05 ? $0 : nil }
                        ?? CMTimeRange(start: .zero, duration: duration)
                    try? videoTrack.insertTimeRange(range, of: src, at: cursor)
                }
            }
            if let src = try? await asset.loadTracks(withMediaType: .audio).first {
                if audioTrack == nil {
                    audioTrack = comp.addMutableTrack(withMediaType: .audio,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                if let audioTrack {
                    let range = (try? await src.load(.timeRange)).flatMap { $0.duration.seconds > 0.05 ? $0 : nil }
                        ?? CMTimeRange(start: .zero, duration: duration)
                    try? audioTrack.insertTimeRange(range, of: src, at: cursor)
                }
            }
            cursor = CMTimeAdd(cursor, duration)
        }
        guard cursor.seconds > 0.05 else { return nil }
        return await exportComposition(comp, to: dest, audioOnly: videoTrack == nil)
    }

    private static func exportComposition(_ asset: AVAsset, to dest: URL, audioOnly: Bool) async -> URL? {
        let presets: [(String, AVFileType)] = audioOnly
            ? [(AVAssetExportPresetAppleM4A, .m4a)]
            : [(AVAssetExportPresetPassthrough, .mov),
               (AVAssetExportPresetHEVCHighestQuality, .mov),
               (AVAssetExportPresetHighestQuality, .mov)]
        for (preset, type) in presets {
            try? FileManager.default.removeItem(at: dest)
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await session.export(to: dest, as: type)
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(30))
                        session.cancelExport()
                        throw ExportError.exportSetup
                    }
                    _ = try await group.next()
                    group.cancelAll()
                }
            } catch {
                try? FileManager.default.removeItem(at: dest)
                continue
            }
            let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > 1024 { return dest }
            try? FileManager.default.removeItem(at: dest)
        }
        return nil
    }

    /// Stream-copy remux via ffmpeg when available (Homebrew).
    private static func remuxMovie(_ url: URL) async -> URL? {
        let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let ffmpeg else {
            NSLog("[media] ffmpeg not found — cannot repair broken movie header")
            return nil
        }
        let out = url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".repaired.mov")
        try? FileManager.default.removeItem(at: out)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = [
            "-hide_banner", "-loglevel", "error",
            "-y", "-i", url.path,
            "-map", "0", "-c", "copy",
            "-movflags", "+faststart",
            out.path
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                        proc.terminationHandler = { _ in cont.resume() }
                        do { try proc.run() } catch { cont.resume(throwing: error) }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(12))
                    if proc.isRunning { proc.terminate() }
                    throw ExportError.exportSetup
                }
                _ = try await group.next()
                group.cancelAll()
            }
        } catch {
            NSLog("[media] ffmpeg launch failed: %@", error.localizedDescription)
            return nil
        }
        guard proc.terminationStatus == 0,
              FileManager.default.fileExists(atPath: out.path),
              ((try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 1024 else {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        return out
    }

    /// One instruction covering the whole timeline, rendered by our compositor.
    /// Used identically by the editor's player and the exporter, so what you
    /// see is exactly what you get.
    static func firstFrame(of asset: AVURLAsset) -> CIImage? {
        frame(of: asset, at: 0)
    }

    static func frame(of asset: AVURLAsset, at seconds: Double) -> CIImage? {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
        var actual = CMTime.zero
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        guard let cg = try? gen.copyCGImage(at: time, actualTime: &actual) else { return nil }
        return CIImage(cgImage: cg)
    }

    static func makeVideoComposition(duration: CMTime,
                                     phoneTrackID: CMPersistentTrackID,
                                     cameraTrackID: CMPersistentTrackID,
                                     phoneRotation: CGFloat, cameraRotation: CGFloat,
                                     layout: ExportLayout,
                                     zooms: [ZoomSegment],
                                     holdPhone: CIImage? = nil,
                                     holdPhoneEnd: CIImage? = nil,
                                     holdCamera: CIImage? = nil,
                                     holdCameraEnd: CIImage? = nil,
                                     phoneStart: Double = 0,
                                     phoneEnd: Double = .infinity,
                                     cameraStart: Double = 0,
                                     cameraEnd: Double = .infinity) -> AVMutableVideoComposition {
        let instruction = CanvasInstruction(
            timeRange: CMTimeRange(start: .zero, duration: duration),
            phoneTrackID: phoneTrackID, cameraTrackID: cameraTrackID,
            phoneRotation: phoneRotation, cameraRotation: cameraRotation,
            layout: layout, zooms: zooms,
            holdPhone: holdPhone, holdPhoneEnd: holdPhoneEnd,
            holdCamera: holdCamera, holdCameraEnd: holdCameraEnd,
            phoneStart: phoneStart, phoneEnd: phoneEnd,
            cameraStart: cameraStart, cameraEnd: cameraEnd)
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = CanvasCompositor.self
        vc.renderSize = layout.canvas
        vc.frameDuration = CMTime(value: 1, timescale: 60)
        vc.instructions = [instruction]
        return vc
    }

    /// Mixes several audio sources (each with its own start offset) down to a
    /// single stereo AAC file. AVAssetReaderAudioMixOutput is the purpose-built
    /// API for this — it handles differing sample rates and channel counts
    /// (phone stereo 44.1k + mic mono) and sums them into one stream.
    static func mixAudio(sources: [(AVURLAsset, CMTime, Float, CMTime)],
                         into output: URL) async throws -> URL? {
        let comp = AVMutableComposition()
        var tracks: [AVMutableCompositionTrack] = []
        var volumes: [Float] = []
        for (asset, at, vol, skip) in sources {
            guard let src = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            var range = try await src.load(.timeRange)
            if skip.seconds > 0.01 {
                let remaining = CMTimeSubtract(range.duration, skip)
                guard remaining.seconds > 0.05 else { continue }
                range = CMTimeRange(start: CMTimeAdd(range.start, skip), duration: remaining)
            }
            guard let t = comp.addMutableTrack(withMediaType: .audio,
                                               preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try t.insertTimeRange(range, of: src, at: at)
            tracks.append(t)
            volumes.append(vol)
        }
        guard !tracks.isEmpty else { return nil }

        let reader = try AVAssetReader(asset: comp)
        let mixOut = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
        ])
        // Two full-volume sources clip when summed — keep a little headroom
        // only when more than one track is actually mixed.
        let headroom: Float = tracks.count > 1 ? 0.85 : 1
        let params = zip(tracks, volumes).map { track, vol -> AVMutableAudioMixInputParameters in
            let p = AVMutableAudioMixInputParameters(track: track)
            p.setVolume(max(0, min(1, vol)) * headroom, at: .zero)
            return p
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = params
        mixOut.audioMix = mix

        guard reader.canAdd(mixOut) else { throw ExportError.exportSetup }
        reader.add(mixOut)

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(url: output, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192000,
        ])
        guard writer.canAdd(input) else { throw ExportError.exportSetup }
        writer.add(input)

        guard reader.startReading(), writer.startWriting() else {
            throw ExportError.exportSetup
        }

        let queue = DispatchQueue(label: "audio.mix")
        let io = AudioMixIO(reader: reader, output: mixOut, input: input)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let lock = NSLock()
            var resumed = false
            var sessionStarted = false
            func finish() {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                cont.resume()
            }
            io.input.requestMediaDataWhenReady(on: queue) {
                while io.input.isReadyForMoreMediaData {
                    if let buf = io.output.copyNextSampleBuffer() {
                        if !sessionStarted {
                            // Video begins at phoneAt. Keep the mix writer at
                            // zero so leading silence stays aligned with it.
                            writer.startSession(atSourceTime: .zero)
                            sessionStarted = true
                        }
                        guard io.input.append(buf) else {
                            io.input.markAsFinished()
                            io.reader.cancelReading()
                            finish()
                            return
                        }
                    } else {
                        if !sessionStarted { writer.startSession(atSourceTime: .zero) }
                        io.input.markAsFinished()
                        finish()
                        return
                    }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 180) {
                if io.reader.status == .reading {
                    io.input.markAsFinished()
                    io.reader.cancelReading()
                }
                finish()
            }
        }
        await writer.finishWriting()
        reader.cancelReading()
        if writer.status != .completed || reader.status == .failed {
            NSLog("[export] audio mix failed: %@", writer.error?.localizedDescription ?? "unknown")
            try? FileManager.default.removeItem(at: output)
            return nil
        }
        // Reject tiny/incomplete files (e.g. moov never written).
        let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size < 2048 {
            try? FileManager.default.removeItem(at: output)
            return nil
        }
        return output
    }

    /// Rotation stored as track metadata (radians). The pixels themselves are
    /// not rotated in the file, so the compositor must apply this.
    private static func rotationAngle(of asset: AVURLAsset) async throws -> CGFloat {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return 0 }
        let t = try await track.load(.preferredTransform)
        return atan2(t.b, t.a)
    }

    static func addTrack(from asset: AVURLAsset, type: AVMediaType,
                         to composition: AVMutableComposition,
                         at offset: CMTime,
                         skip: CMTime = .zero) async throws -> AVMutableCompositionTrack? {
        guard let source = try await asset.loadTracks(withMediaType: type).first else { return nil }
        var range = try await source.load(.timeRange)
        // Prefer track timeRange; if the header lies (duration 0), fall back to
        // the asset duration — remux repair should have fixed this already.
        if range.duration.seconds <= 0.05 {
            let assetDuration = try await asset.load(.duration)
            if assetDuration.seconds > 0.05 {
                range = CMTimeRange(start: .zero, duration: assetDuration)
            } else {
                return nil
            }
        }
        if skip.seconds > 0.01 {
            let remaining = CMTimeSubtract(range.duration, skip)
            guard remaining.seconds > 0.05 else { return nil }
            range = CMTimeRange(start: CMTimeAdd(range.start, skip), duration: remaining)
        }
        guard let track = composition.addMutableTrack(
            withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        try track.insertTimeRange(range, of: source, at: offset)
        return track
    }

    enum ExportError: LocalizedError {
        case missingTrack(String)
        case exportSetup
        var errorDescription: String? {
            switch self {
            case .missingTrack(let what): return what.hasPrefix("Can't") ? what : "Can't open recording: \(what)."
            case .exportSetup: return "Couldn't set up the video exporter."
            }
        }
    }
}

// MARK: - Composition instruction

final class CanvasInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let phoneTrackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID
    let phoneRotation: CGFloat
    let cameraRotation: CGFloat
    let layout: ExportLayout
    let zooms: [ZoomSegment]
    /// First decoded frame of each source — used when the track hasn't
    /// started yet so the export isn't a blank canvas for a second.
    let holdPhone: CIImage?
    let holdPhoneEnd: CIImage?
    let holdCamera: CIImage?
    let holdCameraEnd: CIImage?
    let phoneStart: Double
    let phoneEnd: Double
    let cameraStart: Double
    let cameraEnd: Double

    init(timeRange: CMTimeRange, phoneTrackID: CMPersistentTrackID,
         cameraTrackID: CMPersistentTrackID,
         phoneRotation: CGFloat, cameraRotation: CGFloat, layout: ExportLayout,
         zooms: [ZoomSegment] = [],
         holdPhone: CIImage? = nil,
         holdPhoneEnd: CIImage? = nil,
         holdCamera: CIImage? = nil,
         holdCameraEnd: CIImage? = nil,
         phoneStart: Double = 0,
         phoneEnd: Double = .infinity,
         cameraStart: Double = 0,
         cameraEnd: Double = .infinity) {
        self.timeRange = timeRange
        self.phoneTrackID = phoneTrackID
        self.cameraTrackID = cameraTrackID
        self.phoneRotation = phoneRotation
        self.cameraRotation = cameraRotation
        self.layout = layout
        self.zooms = zooms
        self.holdPhone = holdPhone
        self.holdPhoneEnd = holdPhoneEnd
        self.holdCamera = holdCamera
        self.holdCameraEnd = holdCameraEnd
        self.phoneStart = phoneStart
        self.phoneEnd = phoneEnd
        self.cameraStart = cameraStart
        self.cameraEnd = cameraEnd
        var ids = [NSNumber(value: phoneTrackID)]
        if cameraTrackID != kCMPersistentTrackID_Invalid {
            ids.append(NSNumber(value: cameraTrackID))
        }
        self.requiredSourceTrackIDs = ids
    }
}

// MARK: - Core Image compositor

/// Draws each output frame: gradient background, phone with a realistic bezel
/// and soft shadow, camera bubble with a ring on top. Coordinates here are
/// Core Image style (origin bottom-left), so the bubble's y is flipped from
/// the UI value.
final class CanvasCompositor: NSObject, AVVideoCompositing {
    private static let context = CIContext(options: [
        .cacheIntermediates: false,
        .useSoftwareRenderer: false,
    ])

    nonisolated let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_32BGRA,
        ]
    ]
    nonisolated let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? CanvasInstruction,
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "CanvasCompositor", code: 1))
            return
        }
        let size = request.renderContext.size
        let bg = background(size: size, layout: instruction.layout)
        var content = bg

        let layout = instruction.layout
        let isSplit = layout.presenterLayout == .split
        let t = request.compositionTime.seconds
        let kind = layout.scene(at: t)
        let showPhone = kind != .camera
        let showCamera = kind != .device && layout.cameraEnabled

        let phoneImage: CIImage? = {
            guard showPhone else { return nil }
            if let buf = request.sourceFrame(byTrackID: instruction.phoneTrackID) {
                return upright(CIImage(cvPixelBuffer: buf), angle: instruction.phoneRotation)
            }
            // Preview keeps the first frame before the clip and the last
            // frame after it. Export used to flash the first frame again.
            let hold = t + 0.02 < instruction.phoneStart
                ? instruction.holdPhone
                : (instruction.holdPhoneEnd ?? instruction.holdPhone)
            return hold.map { upright($0, angle: instruction.phoneRotation) }
        }()

        let phoneAspect: CGFloat = {
            if let phone = phoneImage, phone.extent.height > 1 {
                return phone.extent.width / phone.extent.height
            }
            return 0.462
        }()
        let uiScreen = CanvasDraw.phoneScreenRect(
            canvas: size, layout: layout, phoneAspect: phoneAspect)
        let activeZooms = instruction.zooms.filter { t >= $0.start && t <= $0.end }
        let zoom = activeZooms.max(by: { $0.scale(at: t) < $1.scale(at: t) })

        if let phone = phoneImage {
            if isSplit {
                content = place(phone: phone, on: content, canvas: size, layout: layout)
            } else {
                // Floating: zoom the phone (and its chrome) only. Camera stays put.
                let blank = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
                    .cropped(to: CGRect(origin: .zero, size: size))
                var layer = place(phone: phone, on: blank, canvas: size, layout: layout)
                if let z = zoom {
                    layer = applyZoom(z, at: t, to: layer, size: size, phoneScreenUI: uiScreen)
                }
                content = layer.composited(over: content)
            }
        }

        if showCamera {
            let camImage: CIImage? = {
                if instruction.cameraTrackID != kCMPersistentTrackID_Invalid,
                   let buf = request.sourceFrame(byTrackID: instruction.cameraTrackID) {
                    return upright(CIImage(cvPixelBuffer: buf), angle: instruction.cameraRotation)
                }
                let hold = t + 0.02 < instruction.cameraStart
                    ? instruction.holdCamera
                    : (instruction.holdCameraEnd ?? instruction.holdCamera)
                return hold.map { upright($0, angle: instruction.cameraRotation) }
            }()
            if let cam = camImage {
                content = place(camera: cam, on: content, canvas: size, layout: layout)
            }
        }

        // Split: zoom phone + camera together around the same canvas point.
        if isSplit, let z = zoom {
            content = applyZoom(z, at: t, to: content, size: size, phoneScreenUI: uiScreen)
        }

        let finalFrame = content.cropped(to: CGRect(origin: .zero, size: size))
        Self.context.render(finalFrame,
                            to: output,
                            bounds: CGRect(origin: .zero, size: size),
                            colorSpace: CGColorSpaceCreateDeviceRGB())
        request.finish(withComposedVideoFrame: output)
    }

    private func background(size: CGSize, layout: ExportLayout) -> CIImage {
        let rgb = layout.customBackgroundRGB
        let top: (CGFloat, CGFloat, CGFloat)
        let bottom: (CGFloat, CGFloat, CGFloat)
        if let rgb, rgb.count >= 3 {
            top = (rgb[0], rgb[1], rgb[2])
            bottom = top
        } else {
            let c = layout.background.colors
            top = c.top
            bottom = c.bottom
        }
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: 0, y: size.height)
        gradient.point1 = .zero
        gradient.color0 = CIColor(red: top.0, green: top.1, blue: top.2)
        gradient.color1 = CIColor(red: bottom.0, green: bottom.1, blue: bottom.2)
        return gradient.outputImage!.cropped(to: CGRect(origin: .zero, size: size))
    }

    private func applyZoom(_ z: ZoomSegment, at t: Double, to content: CIImage,
                           size: CGSize, phoneScreenUI: CGRect) -> CIImage {
        let s = z.scale(at: t)
        guard s > 1.001 else { return content }
        let unit = CanvasDraw.canvasUnit(fromPhone: z.center, screen: phoneScreenUI, canvas: size)
        let cx = unit.x * size.width
        let cy = (1 - unit.y) * size.height
        return content.clampedToExtent()
            .transformed(by:
                CGAffineTransform(translationX: -cx, y: -cy)
                    .concatenating(CGAffineTransform(scaleX: s, y: s))
                    .concatenating(CGAffineTransform(translationX: cx, y: cy)))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    /// Converts a top-left-origin rect (shared layout math) to Core Image's
    /// bottom-left origin.
    private func flipped(_ r: CGRect, in canvas: CGSize) -> CGRect {
        CGRect(x: r.minX, y: canvas.height - r.maxY, width: r.width, height: r.height)
    }

    /// Phone screen in Core Image coordinates (origin bottom-left).
    private func phoneScreenCI(sourceAspect: CGFloat, canvas: CGSize, layout: ExportLayout) -> CGRect {
        let ui = CanvasDraw.phoneScreenRect(canvas: canvas, layout: layout, phoneAspect: sourceAspect)
        return flipped(ui, in: canvas)
    }

    /// Scale the recording so it covers the screen hole, then crop.
    private func aspectFill(_ image: CIImage, into dest: CGRect) -> CIImage {
        let src = image.extent
        guard src.width > 0.5, src.height > 0.5, dest.width > 0.5, dest.height > 0.5 else {
            return image
        }
        let scale = max(dest.width / src.width, dest.height / src.height)
        return image.transformed(by:
            CGAffineTransform(scaleX: scale, y: scale)
                .translatedBy(x: dest.midX / scale - src.midX,
                              y: dest.midY / scale - src.midY))
            .cropped(to: dest)
    }

    private func place(phone: CIImage, on frame: CIImage, canvas: CGSize,
                       layout: ExportLayout) -> CIImage {
        let src = phone.extent
        let aspect = src.height > 0.5 ? src.width / src.height : 0.462
        let screen = phoneScreenCI(sourceAspect: aspect, canvas: canvas, layout: layout)
        let shortSide = min(screen.width, screen.height)
        let showBezel = CanvasDraw.showsBezel(layout)
        let screenRadius = CanvasDraw.screenRadius(
            shortSide: shortSide, showBezel: showBezel, screenCorners: layout.screenCorners)
        let t = shortSide * ExportLayout.bezelThicknessFraction
        let style = layout.frameStyle

        var out = frame
        // No contact shadow under the phone (FrameOS-style flat canvas).

        if showBezel {
            let outer = screen.insetBy(dx: -t, dy: -t)
            let outerRadius = screenRadius + t
            let (br, bg, bb) = style.rgb
            let (hr, hg, hb) = style.highlightRGB
            let (btnR, btnG, btnB) = style.buttonRGB
            let body = CIColor(red: br, green: bg, blue: bb)
            let highlight = CIColor(red: hr, green: hg, blue: hb,
                                    alpha: style == .white ? 0.55 : 0.40)
            let edgeDark = CIColor(red: 0, green: 0, blue: 0,
                                   alpha: style == .white ? 0.10 : 0.32)
            let btnColor = CIColor(red: btnR, green: btnG, blue: btnB)

            // Side buttons first so the shell covers most of them (thin metal lips).
            let btnW = max(1.5, t * 0.75)
            let actionH = shortSide * 0.038
            let volH = shortSide * 0.075
            let powerH = shortSide * 0.11
            // Core Image y is bottom-up: top of phone = larger y.
            let action = CGRect(x: outer.minX - btnW * 0.45,
                                y: outer.maxY - shortSide * 0.175 - actionH,
                                width: btnW, height: actionH)
            let volUp = CGRect(x: outer.minX - btnW * 0.45,
                               y: outer.maxY - shortSide * 0.26 - volH,
                               width: btnW, height: volH)
            let volDown = CGRect(x: outer.minX - btnW * 0.45,
                                 y: outer.maxY - shortSide * 0.36 - volH,
                                 width: btnW, height: volH)
            let power = CGRect(x: outer.maxX - btnW * 0.55,
                               y: outer.maxY - shortSide * 0.33 - powerH,
                               width: btnW, height: powerH)
            for btn in [action, volUp, volDown, power] {
                out = roundedRect(btn, radius: btnW * 0.35, color: btnColor).composited(over: out)
            }

            // Outer metal shell.
            out = roundedRect(outer, radius: outerRadius, color: body).composited(over: out)

            // Soft metallic rim highlight (slightly inset lighter ring).
            let rimPad = max(0.6, t * 0.28)
            let rim = outer.insetBy(dx: rimPad, dy: rimPad)
            out = roundedRect(rim, radius: max(0, outerRadius - rimPad), color: highlight)
                .composited(over: out)

            // Body fill again so the rim is only a thin edge, not a fat band.
            let bodyInset = max(1.0, t * 0.55)
            let innerBody = outer.insetBy(dx: bodyInset, dy: bodyInset)
            out = roundedRect(innerBody, radius: max(0, outerRadius - bodyInset), color: body)
                .composited(over: out)

            // Dark glass-to-metal inset at the screen edge.
            let insetPad = max(1.2, t * 0.72)
            let inset = outer.insetBy(dx: insetPad, dy: insetPad)
            out = roundedRect(inset, radius: max(0, outerRadius - insetPad), color: edgeDark)
                .composited(over: out)
            let screenWell = outer.insetBy(dx: insetPad + max(0.6, t * 0.18),
                                           dy: insetPad + max(0.6, t * 0.18))
            out = roundedRect(screenWell, radius: max(0, screenRadius), color: body)
                .composited(over: out)
        }

        let filled = aspectFill(phone, into: screen)
        let rounded = roundCorners(filled, radius: screenRadius)
        out = rounded.composited(over: out)

        if showBezel, screen.height > screen.width * 1.2 {
            let pillW = screen.width * 0.30
            let pillH = shortSide * 0.042
            let pill = CGRect(x: screen.midX - pillW / 2,
                              y: screen.maxY - pillH - shortSide * 0.034,
                              width: pillW, height: pillH)
            out = roundedRect(pill, radius: pillH / 2,
                              color: CIColor(red: 0.02, green: 0.02, blue: 0.02))
                .composited(over: out)
        }
        return out
    }

    private func roundedRect(_ rect: CGRect, radius: CGFloat, color: CIColor) -> CIImage {
        let gen = CIFilter.roundedRectangleGenerator()
        gen.extent = rect
        gen.radius = Float(max(0, radius))
        gen.color = color
        return gen.outputImage?.cropped(to: rect) ?? CIImage.empty()
    }

    private func softShadow(rect: CGRect, radius: CGFloat, blur: CGFloat, opacity: CGFloat) -> CIImage {
        let solid = roundedRect(rect, radius: radius,
                                color: CIColor(red: 0, green: 0, blue: 0, alpha: opacity))
        let expanded = rect.insetBy(dx: -blur * 2, dy: -blur * 2)
        let blurred = solid
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur])
            .cropped(to: expanded)
        return blurred
    }

    private func place(camera: CIImage, on frame: CIImage,
                       canvas: CGSize, layout: ExportLayout) -> CIImage {
        let src = camera.extent
        let aspect: CGFloat
        switch layout.cameraShape {
        case .rectangle: aspect = 4 / 5
        case .circle, .square: aspect = 1
        }
        let cropH = min(src.height, src.width / aspect)
        let cropW = cropH * aspect
        let crop = CGRect(x: src.midX - cropW / 2, y: src.midY - cropH / 2,
                          width: cropW, height: cropH)
        var img = camera.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))

        let frac = min(max(layout.bubbleFraction, ExportLayout.bubbleMin), ExportLayout.bubbleMax)
        let dest: CGRect
        let cornerRatio: CGFloat

        switch layout.presenterLayout {
        case .floating:
            let targetH = frac * min(canvas.width, canvas.height)
            let targetW = targetH * aspect
            cornerRatio = layout.cameraShape == .circle ? 0.5 : (layout.cameraShape == .square ? 0.18 : 0.14)
            let cx = layout.bubbleCenter.x * canvas.width
            let cy = (1 - layout.bubbleCenter.y) * canvas.height
            dest = CGRect(x: cx - targetW / 2, y: cy - targetH / 2,
                          width: targetW, height: targetH)

        case .split:
            let zone = flipped(ExportLayout.splitZones(canvas: canvas, layout: layout).camera, in: canvas)
            let fit = min(zone.width / aspect, zone.height)
            let targetH = fit * 0.92
            let targetW = targetH * aspect
            cornerRatio = layout.cameraShape == .circle ? 0.5 : 0.10
            dest = CGRect(x: zone.midX - targetW / 2, y: zone.midY - targetH / 2,
                          width: targetW, height: targetH)
        }

        let scale = dest.height / cropH
        let corner = min(dest.width, dest.height) * cornerRatio
        img = roundCorners(img, radius: min(cropW, cropH) * cornerRatio)

        var out = frame

        let ring = layout.ringRGB
        let rr = ring.count >= 3 ? ring[0] : 1
        let rg = ring.count >= 3 ? ring[1] : 1
        let rb = ring.count >= 3 ? ring[2] : 1
        let ringPad = min(dest.width, dest.height) * (layout.presenterLayout == .split ? 0.010 : 0.016)
        let ringRect = dest.insetBy(dx: -ringPad, dy: -ringPad)
        out = roundedRect(ringRect, radius: corner + ringPad,
                          color: CIColor(red: rr, green: rg, blue: rb, alpha: 0.95))
            .composited(over: out)

        img = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale)
            .translatedBy(x: dest.minX / scale, y: dest.minY / scale))
        return img.composited(over: out)
    }

    /// Applies the track's stored rotation. Track rotation is expressed in
    /// video coordinates (y pointing down); Core Image's y points up, so the
    /// angle flips sign. Origin is re-normalized so layout math stays simple.
    private func upright(_ image: CIImage, angle: CGFloat) -> CIImage {
        guard abs(angle) > 0.001 else { return image }
        let rotated = image.transformed(by: CGAffineTransform(rotationAngle: -angle))
        return rotated.transformed(by: CGAffineTransform(
            translationX: -rotated.extent.minX, y: -rotated.extent.minY))
    }

    private func roundCorners(_ image: CIImage, radius: CGFloat) -> CIImage {
        let mask = CIFilter.roundedRectangleGenerator()
        mask.extent = image.extent
        mask.radius = Float(max(0, radius))
        mask.color = .white
        let blend = CIFilter.blendWithAlphaMask()
        blend.inputImage = image
        blend.backgroundImage = CIImage.empty()
        blend.maskImage = mask.outputImage?.cropped(to: image.extent)
        return blend.outputImage ?? image
    }
}
