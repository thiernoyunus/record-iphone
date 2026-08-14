import SwiftUI
import AppKit

@MainActor
final class MicMeterState: ObservableObject {
    @Published private(set) var bars = 0
    private(set) var db: Float = -160

    func update(_ db: Float) {
        self.db = db
        let next: Int
        if db > -14 { next = 5 }
        else if db > -22 { next = 4 }
        else if db > -30 { next = 3 }
        else if db > -40 { next = 2 }
        else if db > -50 { next = 1 }
        else { next = 0 }
        if next != bars { bars = next }
    }
}

// MARK: - FrameOS-style chrome

enum Frame {
    static let bg = Color(red: 0.96, green: 0.96, blue: 0.97)
    static let canvas = Color.white
    static let surface = Color.white
    static let hairline = Color.black.opacity(0.08)
    static let label = Color(red: 0.12, green: 0.12, blue: 0.14)
    static let secondary = Color(red: 0.42, green: 0.42, blue: 0.46)
    static let tertiary = Color(red: 0.62, green: 0.62, blue: 0.66)
    static let accent = Color(red: 0.20, green: 0.48, blue: 0.96)
    static let record = Color(red: 0.93, green: 0.32, blue: 0.38)
    static let recordSoft = Color(red: 0.98, green: 0.88, blue: 0.89)
    static let pill = Color(red: 0.96, green: 0.96, blue: 0.97)
    static let pillStroke = Color.black.opacity(0.08)
    static let save = Color(red: 0.18, green: 0.48, blue: 0.96)
    static let export = Color(red: 0.18, green: 0.62, blue: 0.42)
    static let delete = Color(red: 0.86, green: 0.28, blue: 0.32)
    static let panelWidth: CGFloat = 336
    static let timeline = Color(red: 0.16, green: 0.16, blue: 0.18)
    static let timelineRaised = Color(red: 0.22, green: 0.22, blue: 0.24)
    static let timelineText = Color.white.opacity(0.88)
}

enum CameraSourceKind: String, CaseIterable, Identifiable, Codable {
    case off = "Off"
    case mac = "Mac"
    var id: String { rawValue }
}

enum SoundMode: String, CaseIterable, Identifiable, Codable {
    case off = "Audio Off"
    case device = "Device Audio"
    case mic = "Mac Microphone"
    case both = "Device Audio + Mac Mic"
    var id: String { rawValue }
    var subtitle: String {
        switch self {
        case .off: return "Record video only"
        case .device: return "Media sound from your iPhone, when available"
        case .mic: return "Record your voice from this Mac"
        case .both: return "Device media sound plus your voice"
        }
    }
}

enum CameraShape: String, CaseIterable, Identifiable, Codable {
    case circle = "Circle"
    case square = "Square"
    case rectangle = "Rectangle"
    var id: String { rawValue }
    var symbolName: String {
        switch self {
        case .circle: return "circle"
        case .square: return "square"
        case .rectangle: return "rectangle.portrait"
        }
    }
}

enum DeviceFrameStyle: String, CaseIterable, Identifiable, Codable {
    case none = "No frame"
    case black = "iPhone 17 Black"
    case white = "iPhone 17 White"
    case mistBlue = "iPhone 17 Mist Blue"
    case lavender = "iPhone 17 Lavender"
    case sage = "iPhone 17 Sage"
    var id: String { rawValue }
    var showsBezel: Bool { self != .none }

    /// Body metal color (muted, slightly cool — matches FrameOS iPhone 17 frames).
    var rgb: (CGFloat, CGFloat, CGFloat) {
        switch self {
        case .none: return (0.06, 0.06, 0.07)
        case .black: return (0.10, 0.10, 0.11)
        case .white: return (0.93, 0.93, 0.94)
        case .mistBlue: return (0.58, 0.68, 0.74)
        case .lavender: return (0.66, 0.60, 0.72)
        case .sage: return (0.48, 0.54, 0.46)
        }
    }

    /// Soft rim highlight (lighter metal edge).
    var highlightRGB: (CGFloat, CGFloat, CGFloat) {
        let (r, g, b) = rgb
        switch self {
        case .none: return (0.28, 0.28, 0.30)
        case .black: return (0.32, 0.32, 0.34)
        case .white: return (1.0, 1.0, 1.0)
        default:
            return (min(1, r + 0.18), min(1, g + 0.18), min(1, b + 0.16))
        }
    }

    /// Darker metal for side buttons / inset edge.
    var buttonRGB: (CGFloat, CGFloat, CGFloat) {
        let (r, g, b) = rgb
        switch self {
        case .white: return (0.78, 0.78, 0.80)
        case .black: return (0.06, 0.06, 0.07)
        default:
            return (max(0, r * 0.78), max(0, g * 0.78), max(0, b * 0.78))
        }
    }
}

enum SceneKind: String, CaseIterable, Identifiable, Codable {
    case camera = "Camera"
    case both = "Camera + Device"
    case device = "Device"
    var id: String { rawValue }
    var subtitle: String {
        switch self {
        case .camera: return "Show the presenter"
        case .both: return "Use the recorded layout"
        case .device: return "Show the device"
        }
    }
}

struct SceneClip: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var kind: SceneKind
    var start: Double
    var duration: Double
    var end: Double { start + duration }
}

enum CameraSizePreset: String, CaseIterable, Identifiable {
    case s = "S", m = "M", l = "L", xl = "XL"
    var id: String { rawValue }
    var fraction: CGFloat {
        switch self {
        case .s: return 0.18
        case .m: return 0.26
        case .l: return 0.36
        case .xl: return 0.48
        }
    }
    static func matching(_ fraction: CGFloat) -> CameraSizePreset {
        allCases.min(by: { abs($0.fraction - fraction) < abs($1.fraction - fraction) }) ?? .m
    }
}

struct RingSwatch: Identifiable {
    let id: String
    let rgb: (CGFloat, CGFloat, CGFloat)
    static let all: [RingSwatch] = [
        .init(id: "white", rgb: (1, 1, 1)),
        .init(id: "black", rgb: (0.08, 0.08, 0.08)),
        .init(id: "gray", rgb: (0.55, 0.55, 0.55)),
        .init(id: "lime", rgb: (0.55, 0.85, 0.20)),
        .init(id: "cyan", rgb: (0.20, 0.78, 0.88)),
        .init(id: "blue", rgb: (0.20, 0.48, 0.96)),
        .init(id: "yellow", rgb: (0.98, 0.82, 0.18)),
        .init(id: "orange", rgb: (0.98, 0.52, 0.16)),
        .init(id: "red", rgb: (0.92, 0.24, 0.24)),
        .init(id: "pink", rgb: (0.92, 0.32, 0.62)),
        .init(id: "purple", rgb: (0.62, 0.32, 0.88)),
        .init(id: "mint", rgb: (0.45, 0.88, 0.72)),
    ]
}

struct SolidSwatch: Identifiable {
    let id: String
    let name: String
    let rgb: (CGFloat, CGFloat, CGFloat)
    var color: Color { Color(red: rgb.0, green: rgb.1, blue: rgb.2) }

    static let solids: [SolidSwatch] = [
        .init(id: "white", name: "White", rgb: (1, 1, 1)),
        .init(id: "cream", name: "Cream", rgb: (0.98, 0.95, 0.88)),
        .init(id: "black", name: "Black", rgb: (0.06, 0.06, 0.07)),
        .init(id: "charcoal", name: "Charcoal", rgb: (0.16, 0.16, 0.18)),
        .init(id: "slate", name: "Slate", rgb: (0.32, 0.34, 0.38)),
        .init(id: "stone", name: "Stone", rgb: (0.42, 0.40, 0.38)),
        .init(id: "navy", name: "Navy", rgb: (0.12, 0.18, 0.32)),
        .init(id: "blue", name: "Blue", rgb: (0.18, 0.42, 0.86)),
        .init(id: "sky", name: "Sky", rgb: (0.32, 0.58, 0.86)),
        .init(id: "teal", name: "Teal", rgb: (0.14, 0.48, 0.52)),
        .init(id: "forest", name: "Forest", rgb: (0.14, 0.38, 0.28)),
        .init(id: "green", name: "Green", rgb: (0.22, 0.58, 0.32)),
        .init(id: "gold", name: "Gold", rgb: (0.92, 0.72, 0.18)),
        .init(id: "orange", name: "Orange", rgb: (0.92, 0.48, 0.16)),
        .init(id: "coral", name: "Coral", rgb: (0.90, 0.32, 0.22)),
        .init(id: "red", name: "Red", rgb: (0.78, 0.16, 0.18)),
        .init(id: "magenta", name: "Magenta", rgb: (0.72, 0.16, 0.42)),
        .init(id: "purple", name: "Purple", rgb: (0.48, 0.22, 0.72)),
        .init(id: "violet", name: "Violet", rgb: (0.42, 0.28, 0.78)),
        .init(id: "indigo", name: "Indigo", rgb: (0.22, 0.18, 0.58)),
    ]

    /// Short “soft” row — FrameOS-style, not a 13-swatch pastel dump.
    static let pastels: [SolidSwatch] = [
        .init(id: "soft-sky", name: "Sky", rgb: (0.80, 0.88, 0.96)),
        .init(id: "soft-mint", name: "Mint", rgb: (0.80, 0.94, 0.88)),
        .init(id: "soft-sand", name: "Sand", rgb: (0.96, 0.90, 0.78)),
        .init(id: "soft-peach", name: "Peach", rgb: (0.98, 0.84, 0.74)),
        .init(id: "soft-rose", name: "Rose", rgb: (0.96, 0.80, 0.82)),
        .init(id: "soft-lilac", name: "Lilac", rgb: (0.88, 0.82, 0.94)),
    ]

    /// Colors shown in the editor Style menu. Named, not “Pastel / Pastel”.
    private static let styleMenuIDs = [
        "white", "cream", "black", "charcoal",
        "navy", "blue", "teal", "green",
        "gold", "orange", "red", "purple",
    ]
    static let styleMenu: [SolidSwatch] = styleMenuIDs.compactMap { id in
        solids.first { $0.id == id }
    }
}

struct CapturePreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var backgroundRGB: [CGFloat]
    var canvas: CanvasPreset
    var presenterLayout: PresenterLayout
    var deviceOnLeft: Bool
    var cameraLeads: Bool
    var phoneScale: CGFloat
    var bubbleFraction: CGFloat
    var bubbleCenterX: Double
    var bubbleCenterY: Double
    var cameraShape: CameraShape
    var ringRGB: [CGFloat]
    var frameStyle: DeviceFrameStyle
    var cameraEnabled: Bool
    var sound: SoundMode
    var splitBalance: CGFloat
    var splitGap: CGFloat
}

enum PresetStore {
    private static let key = "recordiphone.capturePresets"
    static func load() -> [CapturePreset] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([CapturePreset].self, from: data) else { return [] }
        return list
    }
    static func save(_ list: [CapturePreset]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

func hexString(from rgb: (CGFloat, CGFloat, CGFloat)) -> String {
    String(format: "#%02X%02X%02X",
           Int((rgb.0 * 255).rounded()),
           Int((rgb.1 * 255).rounded()),
           Int((rgb.2 * 255).rounded()))
}

func rgb(fromHex hex: String) -> (CGFloat, CGFloat, CGFloat)? {
    var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let n = UInt32(s, radix: 16) else { return nil }
    return (CGFloat((n >> 16) & 0xFF) / 255,
            CGFloat((n >> 8) & 0xFF) / 255,
            CGFloat(n & 0xFF) / 255)
}
