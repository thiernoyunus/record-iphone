import AppKit
import CoreImage
import Foundation

/// Still pictures that can sit behind the phone instead of a flat color.
/// Solids stay available; picking a wallpaper does not remove them.
enum WallpaperCatalog {
    struct Paper: Identifiable, Equatable, Hashable {
        let id: String
        let name: String
    }

    static let all: [Paper] = [
        .init(id: "bluerays", name: "Blue Rays"),
        .init(id: "cherrypop", name: "Cherry Pop"),
        .init(id: "cityscape", name: "Cityscape"),
        .init(id: "energy-17", name: "Energy"),
        .init(id: "energy-19", name: "Pulse"),
        .init(id: "farmvalley", name: "Farm Valley"),
        .init(id: "glassmorphism-3", name: "Glass Light"),
        .init(id: "glassmorphism-4", name: "Glass Dark"),
        .init(id: "iridescent-9", name: "Iridescent"),
        .init(id: "lemonade", name: "Lemonade"),
        .init(id: "levels", name: "Levels"),
        .init(id: "luisdelrio", name: "Valley Light"),
        .init(id: "midnight-8", name: "Midnight Sky"),
        .init(id: "ipad-17-dark", name: "iPad 17 Dark"),
        .init(id: "ipad-17-light", name: "iPad 17 Light"),
        .init(id: "sequoia-blue", name: "Sequoia Blue"),
        .init(id: "sequoia-blue-orange", name: "Sequoia Sunset"),
        .init(id: "sonoma-clouds", name: "Sonoma Clouds"),
        .init(id: "sonoma-dark", name: "Sonoma Dark"),
        .init(id: "sonoma-evening", name: "Sonoma Evening"),
        .init(id: "sonoma-horizon", name: "Sonoma Horizon"),
        .init(id: "sonoma-light", name: "Sonoma Light"),
        .init(id: "tahoe-dark", name: "Tahoe Dark"),
        .init(id: "tahoe-light", name: "Tahoe Light"),
        .init(id: "ventura", name: "Ventura"),
        .init(id: "ventura-dark", name: "Ventura Dark"),
        .init(id: "mountaintrees", name: "Mountain Trees"),
        .init(id: "wallpaper1", name: "Haze"),
        .init(id: "wallpaper2", name: "Bloom"),
        .init(id: "wallpaper3", name: "Dusk"),
        .init(id: "wallpaper4", name: "Glow"),
        .init(id: "wallpaper7", name: "Drift"),
        .init(id: "wallpaper9", name: "Tide"),
        .init(id: "wallpaper10", name: "Ember Sky"),
        .init(id: "wallpaper11", name: "Mist"),
        .init(id: "wallpaper12", name: "Grain"),
        .init(id: "wallpaper13", name: "Field"),
        .init(id: "wallpaper15", name: "Still"),
    ]

    static func paper(id: String?) -> Paper? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    static func nsImage(id: String) -> NSImage? {
        cacheLock.lock()
        if let hit = nsCache[id] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        guard let url = resourceURL(id) else { return nil }
        let image = NSImage(contentsOf: url)
        if let image {
            cacheLock.lock()
            nsCache[id] = image
            cacheLock.unlock()
        }
        return image
    }

    static func ciImage(id: String) -> CIImage? {
        cacheLock.lock()
        if let hit = ciCache[id] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        guard let url = resourceURL(id) else { return nil }
        let image = CIImage(contentsOf: url)
        if let image {
            cacheLock.lock()
            ciCache[id] = image
            cacheLock.unlock()
        }
        return image
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

    private static func resourceURL(_ id: String) -> URL? {
        let file = "\(id).jpg"
        let candidates: [URL] = [
            Bundle.main.resourceURL?.appendingPathComponent("Wallpapers/\(file)"),
            Bundle.main.url(forResource: id, withExtension: "jpg", subdirectory: "Wallpapers"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Wallpapers/\(file)"),
            Bundle.main.executableURL?
                .deletingLastPathComponent()
                .appendingPathComponent("RecordIphone_RecordIphone.bundle/Wallpapers/\(file)"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static let cacheLock = NSLock()
    private static var nsCache: [String: NSImage] = [:]
    private static var ciCache: [String: CIImage] = [:]
}
