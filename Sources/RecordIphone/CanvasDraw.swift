import AppKit
import SwiftUI

/// Shared canvas math so the editor preview and the export aim at the same spot.
enum CanvasDraw {
    /// Screen hole in SwiftUI coordinates (origin at the top-left).
    static func phoneScreenRect(canvas: CGSize, layout: ExportLayout, phoneAspect: CGFloat) -> CGRect {
        let aspect = max(phoneAspect, 0.3)
        switch layout.presenterLayout {
        case .floating:
            let maxH = canvas.height * layout.phoneScale
            let h = min(maxH, canvas.width * ExportLayout.phoneMaxWidthFraction / aspect)
            let w = h * aspect
            return CGRect(x: (canvas.width - w) / 2, y: (canvas.height - h) / 2,
                          width: w, height: h)
        case .split:
            let zone = ExportLayout.splitZones(canvas: canvas, layout: layout).phone
            let h = min(zone.height, zone.width / aspect)
            let w = h * aspect
            return CGRect(x: zone.midX - w / 2, y: zone.midY - h / 2,
                          width: w, height: h)
        }
    }

    /// Phone-local 0…1 (top-left) → canvas 0…1 (top-left).
    static func canvasUnit(fromPhone center: CGPoint, screen: CGRect, canvas: CGSize) -> CGPoint {
        guard canvas.width > 0.5, canvas.height > 0.5 else { return center }
        return CGPoint(
            x: (screen.minX + center.x * screen.width) / canvas.width,
            y: (screen.minY + center.y * screen.height) / canvas.height
        )
    }

    static func screenRadius(shortSide: CGFloat, showBezel: Bool, screenCorners: Bool) -> CGFloat {
        shortSide * ((showBezel || screenCorners) ? ExportLayout.screenCornerFraction : 0.012)
    }

    static func showsBezel(_ layout: ExportLayout) -> Bool {
        layout.frameStyle.showsBezel || (layout.showBezel && layout.frameStyle != .none)
    }
}

/// Skip clipShape when the radius is 0 so SwiftUI does not build a mask
/// that can receive a NaN position.
struct SafeRoundedClip: ViewModifier {
    var radius: CGFloat
    func body(content: Content) -> some View {
        if radius.isFinite, radius > 0.5 {
            content.clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            content
        }
    }
}

/// Same picture or color the exporter paints behind the phone.
struct CanvasBackdrop: View {
    var customRGB: [CGFloat]?
    var preset: BackgroundPreset
    var wallpaperID: String? = nil

    var body: some View {
        if let id = wallpaperID, let image = WallpaperCatalog.nsImage(id: id) {
            WallpaperFill(image: image)
        } else if let rgb = customRGB, rgb.count >= 3 {
            Color(red: rgb[0], green: rgb[1], blue: rgb[2])
        } else {
            let top = preset.colors.top
            let bottom = preset.colors.bottom
            LinearGradient(
                colors: [
                    Color(red: top.0, green: top.1, blue: top.2),
                    Color(red: bottom.0, green: bottom.1, blue: bottom.2)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

/// Aspect-fill photo that never uses SwiftUI Image or clipShape.
/// Those paths can hand Quartz a NaN layer position and abort the app.
struct WallpaperFill: View {
    let image: NSImage
    var corner: CGFloat = 0

    var body: some View {
        Representable(image: image, corner: corner)
    }

    private struct Representable: NSViewRepresentable {
        let image: NSImage
        let corner: CGFloat

        func makeNSView(context: Context) -> FillImageView {
            let view = FillImageView()
            view.image = image
            view.corner = corner
            return view
        }

        func updateNSView(_ nsView: FillImageView, context: Context) {
            nsView.image = image
            nsView.corner = corner
        }

        func sizeThatFits(_ proposal: ProposedViewSize, nsView: FillImageView, context: Context) -> CGSize? {
            let width = proposal.width ?? 0
            let height = proposal.height ?? 0
            guard width.isFinite, height.isFinite else { return CGSize(width: 1, height: 1) }
            return CGSize(width: max(1, width), height: max(1, height))
        }
    }
}

final class FillImageView: NSView {
    var image: NSImage? {
        didSet { layer?.contents = image }
    }
    var corner: CGFloat = 0 {
        didSet { layer?.cornerRadius = corner }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

/// Metal shell + island drawn around a screen hole. Island sits on top of `content`.
struct FramedPhoneChrome<Content: View>: View {
    var width: CGFloat
    var height: CGFloat
    var style: DeviceFrameStyle
    var showBezel: Bool
    var screenCorners: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shortSide = min(width, height)
        let screenRadius = CanvasDraw.screenRadius(
            shortSide: shortSide, showBezel: showBezel, screenCorners: screenCorners)
        let t = shortSide * ExportLayout.bezelThicknessFraction
        let (br, bgc, bb) = style.rgb
        let (hr, hg, hb) = style.highlightRGB
        let (btnR, btnG, btnB) = style.buttonRGB
        let bodyColor = Color(red: br, green: bgc, blue: bb)
        let highlight = Color(red: hr, green: hg, blue: hb)
        let buttonMetal = Color(red: btnR, green: btnG, blue: btnB)
        let outerW = width + 2 * t
        let outerH = height + 2 * t
        let outerRadius = screenRadius + t
        let portrait = height > width * 1.2
        let btnW = max(2.5, t * 0.72)

        return ZStack {
            if showBezel {
                Group {
                    RoundedRectangle(cornerRadius: btnW * 0.35, style: .continuous)
                        .fill(buttonMetal)
                        .frame(width: btnW, height: shortSide * 0.038)
                        .offset(x: -(outerW / 2) + btnW * 0.15,
                                y: -(outerH / 2) + shortSide * 0.155)
                    RoundedRectangle(cornerRadius: btnW * 0.35, style: .continuous)
                        .fill(buttonMetal)
                        .frame(width: btnW, height: shortSide * 0.075)
                        .offset(x: -(outerW / 2) + btnW * 0.15,
                                y: -(outerH / 2) + shortSide * 0.22)
                    RoundedRectangle(cornerRadius: btnW * 0.35, style: .continuous)
                        .fill(buttonMetal)
                        .frame(width: btnW, height: shortSide * 0.075)
                        .offset(x: -(outerW / 2) + btnW * 0.15,
                                y: -(outerH / 2) + shortSide * 0.32)
                    RoundedRectangle(cornerRadius: btnW * 0.35, style: .continuous)
                        .fill(buttonMetal)
                        .frame(width: btnW, height: shortSide * 0.11)
                        .offset(x: (outerW / 2) - btnW * 0.15,
                                y: -(outerH / 2) + shortSide * 0.28)
                }
                .allowsHitTesting(false)

                RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                highlight.opacity(style == .white ? 0.95 : 0.55),
                                bodyColor,
                                bodyColor.opacity(0.92)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: outerW, height: outerH)
                    .overlay(
                        RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        highlight.opacity(style == .white ? 0.9 : 0.45),
                                        highlight.opacity(0.12),
                                        Color.black.opacity(style == .white ? 0.08 : 0.22)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: max(1, t * 0.35)
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: screenRadius + t * 0.25, style: .continuous)
                            .strokeBorder(Color.black.opacity(style == .white ? 0.10 : 0.35),
                                          lineWidth: max(0.8, t * 0.22))
                            .padding(t * 0.55)
                    )
                    .allowsHitTesting(false)
            }

            content()
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: screenRadius, style: .continuous))

            if showBezel, portrait {
                Capsule(style: .continuous)
                    .fill(Color.black)
                    .frame(width: width * 0.30, height: shortSide * 0.042)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
                    )
                    .offset(y: -(height / 2) + shortSide * 0.055)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: height)
    }
}
