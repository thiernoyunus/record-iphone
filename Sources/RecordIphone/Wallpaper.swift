import AppKit
import AVFoundation
import CoreImage
import Foundation

/// Pictures and short silent clips that can sit behind the phone.
/// Solids stay available; picking a wallpaper does not remove them.
enum WallpaperCatalog {
    struct Paper: Identifiable, Equatable, Hashable {
        let id: String
        let name: String
        /// `"jpg"` for a still, `"mp4"` for a looping clip.
        let ext: String
        var isLive: Bool { ext.lowercased() == "mp4" || ext.lowercased() == "mov" }
    }

    static let all: [Paper] = stills + live

    static let live: [Paper] = [
        .init(id: "wispysky", name: "Wispy Sky", ext: "mp4"),
    ]

    static let stills: [Paper] = [
        .init(id: "bluerays", name: "Blue Rays", ext: "jpg"),
        .init(id: "cherrypop", name: "Cherry Pop", ext: "jpg"),
        .init(id: "cityscape", name: "Cityscape", ext: "jpg"),
        .init(id: "energy-17", name: "Energy", ext: "jpg"),
        .init(id: "energy-19", name: "Pulse", ext: "jpg"),
        .init(id: "farmvalley", name: "Farm Valley", ext: "jpg"),
        .init(id: "glassmorphism-3", name: "Glass Light", ext: "jpg"),
        .init(id: "glassmorphism-4", name: "Glass Dark", ext: "jpg"),
        .init(id: "iridescent-9", name: "Iridescent", ext: "jpg"),
        .init(id: "lemonade", name: "Lemonade", ext: "jpg"),
        .init(id: "levels", name: "Levels", ext: "jpg"),
        .init(id: "luisdelrio", name: "Valley Light", ext: "jpg"),
        .init(id: "midnight-8", name: "Midnight Sky", ext: "jpg"),
        .init(id: "ipad-17-dark", name: "iPad 17 Dark", ext: "jpg"),
        .init(id: "ipad-17-light", name: "iPad 17 Light", ext: "jpg"),
        .init(id: "sequoia-blue", name: "Sequoia Blue", ext: "jpg"),
        .init(id: "sequoia-blue-orange", name: "Sequoia Sunset", ext: "jpg"),
        .init(id: "sonoma-clouds", name: "Sonoma Clouds", ext: "jpg"),
        .init(id: "sonoma-dark", name: "Sonoma Dark", ext: "jpg"),
        .init(id: "sonoma-evening", name: "Sonoma Evening", ext: "jpg"),
        .init(id: "sonoma-horizon", name: "Sonoma Horizon", ext: "jpg"),
        .init(id: "sonoma-light", name: "Sonoma Light", ext: "jpg"),
        .init(id: "tahoe-dark", name: "Tahoe Dark", ext: "jpg"),
        .init(id: "tahoe-light", name: "Tahoe Light", ext: "jpg"),
        .init(id: "ventura", name: "Ventura", ext: "jpg"),
        .init(id: "ventura-dark", name: "Ventura Dark", ext: "jpg"),
        .init(id: "mountaintrees", name: "Mountain Trees", ext: "jpg"),
        .init(id: "wallpaper1", name: "Haze", ext: "jpg"),
        .init(id: "wallpaper2", name: "Bloom", ext: "jpg"),
        .init(id: "wallpaper3", name: "Dusk", ext: "jpg"),
        .init(id: "wallpaper4", name: "Glow", ext: "jpg"),
        .init(id: "wallpaper7", name: "Drift", ext: "jpg"),
        .init(id: "wallpaper9", name: "Tide", ext: "jpg"),
        .init(id: "wallpaper10", name: "Ember Sky", ext: "jpg"),
        .init(id: "wallpaper11", name: "Mist", ext: "jpg"),
        .init(id: "wallpaper12", name: "Grain", ext: "jpg"),
        .init(id: "wallpaper13", name: "Field", ext: "jpg"),
        .init(id: "wallpaper15", name: "Still", ext: "jpg"),
    ]

    static func paper(id: String?) -> Paper? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    static func resourceURL(id: String) -> URL? {
        guard let paper = paper(id: id) else { return nil }
        let file = "\(paper.id).\(paper.ext)"
        let candidates: [URL] = [
            Bundle.main.resourceURL?.appendingPathComponent("Wallpapers/\(file)"),
            Bundle.main.url(forResource: paper.id, withExtension: paper.ext, subdirectory: "Wallpapers"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Wallpapers/\(file)"),
            Bundle.main.executableURL?
                .deletingLastPathComponent()
                .appendingPathComponent("RecordIphone_RecordIphone.bundle/Wallpapers/\(file)"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// First-frame still for pickers. Live clips use the opening frame.
    static func nsImage(id: String) -> NSImage? {
        cacheLock.lock()
        if let hit = nsCache[id] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        guard let paper = paper(id: id), let url = resourceURL(id: id) else { return nil }
        let image: NSImage?
        if paper.isLive {
            image = firstFrameImage(url: url)
        } else {
            image = NSImage(contentsOf: url)
        }
        if let image {
            cacheLock.lock()
            nsCache[id] = image
            cacheLock.unlock()
        }
        return image
    }

    /// Frame at `time` seconds into the take. Live clips loop.
    static func ciImage(id: String, at time: Double = 0) -> CIImage? {
        guard let paper = paper(id: id) else { return nil }
        if paper.isLive {
            return liveFrame(id: id, at: time)
        }
        cacheLock.lock()
        if let hit = ciCache[id] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        guard let url = resourceURL(id: id) else { return nil }
        let image = CIImage(contentsOf: url)
        if let image {
            cacheLock.lock()
            ciCache[id] = image
            cacheLock.unlock()
        }
        return image
    }

    static func duration(id: String) -> Double {
        guard let paper = paper(id: id), paper.isLive else { return 0 }
        cacheLock.lock()
        if let hit = durationCache[id] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        guard let url = resourceURL(id: id) else { return 0 }
        let seconds = CMTimeGetSeconds(AVAsset(url: url).duration)
        let value = seconds.isFinite && seconds > 0.05 ? seconds : 0
        cacheLock.lock()
        durationCache[id] = value
        cacheLock.unlock()
        return value
    }

    /// Cover-fit the picture to the canvas, same as the live preview.
    static func fitted(_ image: CIImage, to size: CGSize) -> CIImage {
        let e = image.extent
        guard e.width > 1, e.height > 1, size.width > 1, size.height > 1 else {
            return CIImage(color: .white).cropped(to: CGRect(origin: .zero, size: size))
        }
        let scale = max(size.width / e.width, size.height / e.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let s = scaled.extent
        let dx = (size.width - s.width) / 2 - s.minX
        let dy = (size.height - s.height) / 2 - s.minY
        return scaled
            .transformed(by: CGAffineTransform(translationX: dx, y: dy))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    static func loopedTime(_ time: Double, duration: Double) -> Double {
        guard duration > 0.05, time.isFinite else { return 0 }
        let t = max(0, time)
        return t - floor(t / duration) * duration
    }

    static func logicChecks() -> [(String, Bool)] {
        var rows: [(String, Bool)] = [
            ("wallpapers sit next to solid colors", all.count >= 12),
            ("Apple-named wallpapers are included",
             stills.contains(where: { $0.id == "sonoma-light" })
             && stills.contains(where: { $0.id == "sequoia-blue" })
             && stills.contains(where: { $0.id == "tahoe-light" })
             && stills.contains(where: { $0.id == "ventura" })
             && stills.contains(where: { $0.id == "ipad-17-light" })),
            ("wallpaper ids are unique", Set(all.map(\.id)).count == all.count),
            ("Wispy Sky is the live wallpaper",
             live.contains(where: { $0.id == "wispysky" && $0.isLive })),
            ("looped time wraps inside the clip",
             abs(loopedTime(21, duration: 20) - 1) < 0.001),
        ]
        if resourceURL(id: "wispysky") != nil {
            let a = ciImage(id: "wispysky", at: 0)
            let b = ciImage(id: "wispysky", at: 1.0)
            rows.append(("Wispy Sky file is on disk", true))
            rows.append(("Wispy Sky can be read as a picture", a != nil && b != nil))
            if let a, let b {
                rows.append(("Wispy Sky moves between second 0 and 1", !samePixels(a, b)))
            }
        }
        return rows
    }

    private static func liveFrame(id: String, at time: Double) -> CIImage? {
        guard let url = resourceURL(id: id) else { return nil }
        let duration = duration(id: id)
        let looped = loopedTime(time, duration: duration > 0 ? duration : 20)
        let key = Int((looped * 24).rounded())
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let hit = liveFrameCache[id]?[key] {
            return hit
        }
        let generator: AVAssetImageGenerator
        if let existing = generators[id] {
            generator = existing
        } else {
            let next = AVAssetImageGenerator(asset: AVAsset(url: url))
            next.appliesPreferredTrackTransform = true
            next.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 24)
            next.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 24)
            generators[id] = next
            generator = next
        }
        let requested = CMTime(seconds: looped, preferredTimescale: 600)
        guard let cg = try? generator.copyCGImage(at: requested, actualTime: nil) else {
            return nil
        }
        let image = CIImage(cgImage: cg)
        var bucket = liveFrameCache[id] ?? [:]
        if bucket.count > 48 { bucket.removeAll(keepingCapacity: true) }
        bucket[key] = image
        liveFrameCache[id] = bucket
        return image
    }

    private static func firstFrameImage(url: URL) -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)
        guard let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private static func samePixels(_ a: CIImage, _ b: CIImage) -> Bool {
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let sample = CGRect(x: 8, y: 8, width: 32, height: 32)
        guard let da = context.pngRepresentation(of: a.cropped(to: sample),
                                                 format: .RGBA8,
                                                 colorSpace: CGColorSpaceCreateDeviceRGB()),
              let db = context.pngRepresentation(of: b.cropped(to: sample),
                                                 format: .RGBA8,
                                                 colorSpace: CGColorSpaceCreateDeviceRGB()) else {
            return false
        }
        return da == db
    }

    private static let cacheLock = NSLock()
    private static var nsCache: [String: NSImage] = [:]
    private static var ciCache: [String: CIImage] = [:]
    private static var durationCache: [String: Double] = [:]
    private static var generators: [String: AVAssetImageGenerator] = [:]
    private static var liveFrameCache: [String: [Int: CIImage]] = [:]
}
