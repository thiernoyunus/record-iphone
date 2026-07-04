import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Look settings shared by the live preview and the export, in normalized
/// units so they map from the on-screen canvas to the export canvas.
struct ExportLayout {
    var bubbleCenter: CGPoint     // 0...1, top-left origin (SwiftUI style)
    var bubbleFraction: CGFloat   // bubble side / min canvas dimension
    var canvas: CGSize
    var background: BackgroundPreset
    var showBezel: Bool

    static let phoneHeightFraction: CGFloat = 0.86
    static let bezelColor: (CGFloat, CGFloat, CGFloat) = (0.07, 0.07, 0.08)
}

enum BackgroundPreset: String, CaseIterable, Identifiable {
    case midnight = "Midnight"
    case graphite = "Graphite"
    case ocean = "Ocean"
    case sunset = "Sunset"
    case forest = "Forest"
    case black = "Black"

    var id: String { rawValue }

    /// (top, bottom) gradient colors as RGB 0–1.
    var colors: (top: (CGFloat, CGFloat, CGFloat), bottom: (CGFloat, CGFloat, CGFloat)) {
        switch self {
        case .midnight: return ((0.17, 0.17, 0.21), (0.09, 0.09, 0.11))
        case .graphite: return ((0.36, 0.36, 0.40), (0.14, 0.14, 0.16))
        case .ocean:    return ((0.12, 0.30, 0.52), (0.03, 0.07, 0.18))
        case .sunset:   return ((0.93, 0.44, 0.30), (0.38, 0.10, 0.32))
        case .forest:   return ((0.13, 0.36, 0.26), (0.03, 0.10, 0.08))
        case .black:    return ((0.02, 0.02, 0.02), (0.0, 0.0, 0.0))
        }
    }
}

enum CanvasPreset: String, CaseIterable, Identifiable {
    case landscape = "16:9"
    case portrait = "9:16"
    var id: String { rawValue }
    var size: CGSize {
        self == .landscape ? CGSize(width: 1920, height: 1080)
                           : CGSize(width: 1080, height: 1920)
    }
}

/// Combines phone.mov (screen video + device audio) and camera.mov (camera +
/// mic) into one polished MP4: gradient background, rounded phone in the
/// middle, rounded camera bubble where the user dragged it. Audio tracks are
/// added side by side and the exporter mixes them into the output.
enum Exporter {

    static func export(phoneURL: URL, cameraURL: URL,
                       cameraOffset: CMTime, layout: ExportLayout,
                       onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let phoneAsset = AVURLAsset(url: phoneURL)
        let cameraAsset = AVURLAsset(url: cameraURL)

        let composition = AVMutableComposition()

        // Later-starting source gets shifted so the timelines line up.
        let phoneAt = cameraOffset.seconds < 0 ? (CMTime.zero - cameraOffset) : .zero
        let cameraAt = cameraOffset.seconds > 0 ? cameraOffset : .zero

        guard let phoneVideo = try await addTrack(from: phoneAsset, type: .video,
                                                  to: composition, at: phoneAt) else {
            throw ExportError.missingTrack("the iPhone recording has no video")
        }
        let cameraVideo = try await addTrack(from: cameraAsset, type: .video,
                                             to: composition, at: cameraAt)
        _ = try await addTrack(from: phoneAsset, type: .audio, to: composition, at: phoneAt)
        _ = try await addTrack(from: cameraAsset, type: .audio, to: composition, at: cameraAt)

        let instruction = CanvasInstruction(
            timeRange: CMTimeRange(start: .zero, duration: try await composition.load(.duration)),
            phoneTrackID: phoneVideo.trackID,
            cameraTrackID: cameraVideo?.trackID ?? kCMPersistentTrackID_Invalid,
            phoneRotation: try await rotationAngle(of: phoneAsset),
            cameraRotation: try await rotationAngle(of: cameraAsset),
            layout: layout)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = CanvasCompositor.self
        videoComposition.renderSize = layout.canvas
        videoComposition.frameDuration = CMTime(value: 1, timescale: 60)
        videoComposition.instructions = [instruction]

        NSLog("[export] composition ready: duration=%.2fs canvas=%.0fx%.0f",
              instruction.timeRange.duration.seconds, layout.canvas.width, layout.canvas.height)

        guard let session = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.exportSetup
        }
        session.videoComposition = videoComposition

        let outURL = phoneURL.deletingLastPathComponent().appendingPathComponent("Recording.mp4")
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
        return outURL
    }

    /// Rotation stored as track metadata (radians). The pixels themselves are
    /// not rotated in the file, so the compositor must apply this.
    private static func rotationAngle(of asset: AVURLAsset) async throws -> CGFloat {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return 0 }
        let t = try await track.load(.preferredTransform)
        return atan2(t.b, t.a)
    }

    private static func addTrack(from asset: AVURLAsset, type: AVMediaType,
                                 to composition: AVMutableComposition,
                                 at offset: CMTime) async throws -> AVMutableCompositionTrack? {
        guard let source = try await asset.loadTracks(withMediaType: type).first else { return nil }
        let range = try await source.load(.timeRange)
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
            case .missingTrack(let what): return "Can't export: \(what)."
            case .exportSetup: return "Couldn't set up the video exporter."
            }
        }
    }
}

// MARK: - Composition instruction

final class CanvasInstruction: NSObject, AVVideoCompositionInstructionProtocol {
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

    init(timeRange: CMTimeRange, phoneTrackID: CMPersistentTrackID,
         cameraTrackID: CMPersistentTrackID,
         phoneRotation: CGFloat, cameraRotation: CGFloat, layout: ExportLayout) {
        self.timeRange = timeRange
        self.phoneTrackID = phoneTrackID
        self.cameraTrackID = cameraTrackID
        self.phoneRotation = phoneRotation
        self.cameraRotation = cameraRotation
        self.layout = layout
        var ids = [NSNumber(value: phoneTrackID)]
        if cameraTrackID != kCMPersistentTrackID_Invalid {
            ids.append(NSNumber(value: cameraTrackID))
        }
        self.requiredSourceTrackIDs = ids
    }
}

// MARK: - Core Image compositor

/// Draws each output frame: gradient background, phone scaled to 86% of the
/// canvas height with rounded corners, camera center-cropped to a rounded
/// square at the user's chosen spot. Coordinates here are Core Image style
/// (origin bottom-left), so the bubble's y is flipped from the UI value.
final class CanvasCompositor: NSObject, AVVideoCompositing {
    private static let context = CIContext()

    let sourcePixelBufferAttributes: [String: Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_32BGRA,
        ]
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: Any] = [
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
        var frame = background(size: size, preset: instruction.layout.background)

        if let phoneBuffer = request.sourceFrame(byTrackID: instruction.phoneTrackID) {
            let phone = upright(CIImage(cvPixelBuffer: phoneBuffer), angle: instruction.phoneRotation)
            frame = place(phone: phone, on: frame, canvas: size,
                          showBezel: instruction.layout.showBezel)
        }
        if instruction.cameraTrackID != kCMPersistentTrackID_Invalid,
           let camBuffer = request.sourceFrame(byTrackID: instruction.cameraTrackID) {
            let cam = upright(CIImage(cvPixelBuffer: camBuffer), angle: instruction.cameraRotation)
            frame = place(bubble: cam, on: frame, canvas: size, layout: instruction.layout)
        }

        Self.context.render(frame.cropped(to: CGRect(origin: .zero, size: size)),
                            to: output,
                            bounds: CGRect(origin: .zero, size: size),
                            colorSpace: CGColorSpaceCreateDeviceRGB())
        request.finish(withComposedVideoFrame: output)
    }

    private func background(size: CGSize, preset: BackgroundPreset) -> CIImage {
        let (top, bottom) = preset.colors
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: 0, y: size.height)
        gradient.point1 = .zero
        gradient.color0 = CIColor(red: top.0, green: top.1, blue: top.2)
        gradient.color1 = CIColor(red: bottom.0, green: bottom.1, blue: bottom.2)
        return gradient.outputImage!.cropped(to: CGRect(origin: .zero, size: size))
    }

    private func place(phone: CIImage, on frame: CIImage, canvas: CGSize,
                       showBezel: Bool) -> CIImage {
        let src = phone.extent
        // Fit by height, but never let a wide (landscape iPad) source spill
        // past the canvas edges.
        let scale = min((canvas.height * ExportLayout.phoneHeightFraction) / src.height,
                        (canvas.width * 0.88) / src.width)
        let w = src.width * scale
        let h = src.height * scale
        let x = (canvas.width - w) / 2
        let y = (canvas.height - h) / 2
        let screenRadius = min(w, h) * 0.10

        var out = frame
        if showBezel {
            let t = min(w, h) * 0.045
            let (r, g, b) = ExportLayout.bezelColor
            out = roundedRect(CGRect(x: x - t, y: y - t, width: w + 2 * t, height: h + 2 * t),
                              radius: screenRadius + t,
                              color: CIColor(red: r, green: g, blue: b))
                .composited(over: out)
        }

        let rounded = roundCorners(phone, radius: min(src.width, src.height) * 0.10)
        let placed = rounded.transformed(by: CGAffineTransform(scaleX: scale, y: scale)
            .translatedBy(x: x / scale - src.minX, y: y / scale - src.minY))
        return placed.composited(over: out)
    }

    private func roundedRect(_ rect: CGRect, radius: CGFloat, color: CIColor) -> CIImage {
        let gen = CIFilter.roundedRectangleGenerator()
        gen.extent = rect
        gen.radius = Float(radius)
        gen.color = color
        return gen.outputImage?.cropped(to: rect) ?? CIImage.empty()
    }

    private func place(bubble camera: CIImage, on frame: CIImage,
                       canvas: CGSize, layout: ExportLayout) -> CIImage {
        let src = camera.extent
        let side = min(src.width, src.height)
        let crop = CGRect(x: src.midX - side / 2, y: src.midY - side / 2, width: side, height: side)
        var img = camera.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        img = roundCorners(img, radius: side * 0.24)

        let targetSide = layout.bubbleFraction * min(canvas.width, canvas.height)
        let scale = targetSide / side
        let cx = layout.bubbleCenter.x * canvas.width
        let cy = (1 - layout.bubbleCenter.y) * canvas.height   // flip UI y → CI y
        img = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale)
            .translatedBy(x: (cx - targetSide / 2) / scale, y: (cy - targetSide / 2) / scale))
        return img.composited(over: frame)
    }

    /// Applies the track's stored rotation. Track rotation is expressed in
    /// video coordinates (y pointing down); Core Image's y points up, so the
    /// angle flips sign. Origin is re-normalized so layout math stays simple.
    private func upright(_ image: CIImage, angle: CGFloat) -> CIImage {
        guard angle != 0 else { return image }
        let rotated = image.transformed(by: CGAffineTransform(rotationAngle: -angle))
        return rotated.transformed(by: CGAffineTransform(
            translationX: -rotated.extent.minX, y: -rotated.extent.minY))
    }

    private func roundCorners(_ image: CIImage, radius: CGFloat) -> CIImage {
        let mask = CIFilter.roundedRectangleGenerator()
        mask.extent = image.extent
        mask.radius = Float(radius)
        mask.color = .white
        let blend = CIFilter.blendWithAlphaMask()
        blend.inputImage = image
        blend.backgroundImage = CIImage.empty()
        blend.maskImage = mask.outputImage?.cropped(to: image.extent)
        return blend.outputImage ?? image
    }
}
