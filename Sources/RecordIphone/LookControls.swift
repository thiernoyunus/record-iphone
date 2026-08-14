import SwiftUI

enum LookSection: String, CaseIterable {
    case layout = "Layout"
    case canvas = "Canvas"
    case appearance = "Appearance"
    case sound = "Sound"
}

/// Shared look controls for live Setup and the after-record editor.
/// Changing these must update the preview immediately and persist via `onChange`.
struct LookControls: View {
    @ObservedObject var engine: CaptureEngine
    var section: LookSection
    var showsCamera: Bool = true
    var showsMic: Bool = true
    var cameraStatus: CameraClipStatus = .phoneOnly
    var phoneMix: Binding<CGFloat>? = nil
    var micMix: Binding<CGFloat>? = nil
    var onChange: () -> Void = {}

    @State private var hexDraft = "#FFFFFF"
    @State private var liveBalance: CGFloat?
    @State private var liveGap: CGFloat?
    @State private var livePadding: CGFloat?

    var body: some View {
        Group {
            switch section {
            case .layout: layoutBody
            case .canvas: canvasBody
            case .appearance: appearanceBody
            case .sound: soundBody
            }
        }
        .onAppear { syncHex() }
    }

    // MARK: Layout

    private var layoutBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsCamera {
                HStack(spacing: 8) {
                    layoutChoice("Camera bubble", selected: engine.presenterLayout == .floating) {
                        engine.presenterLayout = .floating
                        onChange()
                    }
                    layoutChoice("Device left", selected: engine.presenterLayout == .split && engine.deviceOnLeft) {
                        engine.presenterLayout = .split
                        engine.deviceOnLeft = true
                        onChange()
                    }
                    layoutChoice("Device right", selected: engine.presenterLayout == .split && !engine.deviceOnLeft) {
                        engine.presenterLayout = .split
                        engine.deviceOnLeft = false
                        onChange()
                    }
                }
            }

            if showsCamera, engine.presenterLayout == .floating {
                Text("Position").font(.system(size: 11, weight: .semibold)).foregroundStyle(Frame.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(0..<9, id: \.self) { i in
                        let x = [0.16, 0.5, 0.84][i % 3]
                        let y = [0.18, 0.5, 0.82][i / 3]
                        let on = abs(engine.bubbleCenter.x - x) < 0.12
                            && abs(engine.bubbleCenter.y - y) < 0.12
                        Button {
                            engine.bubbleCenter = CGPoint(x: x, y: y)
                            onChange()
                        } label: {
                            Circle().fill(on ? Frame.accent : Color.black.opacity(0.18))
                                .frame(width: 8, height: 8)
                                .frame(maxWidth: .infinity, minHeight: 26)
                                .background(Color.black.opacity(0.04),
                                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Self.cameraPositionName(x: x, y: y))
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }

                Text("Camera shape").font(.system(size: 11, weight: .semibold)).foregroundStyle(Frame.secondary)
                HStack(spacing: 6) {
                    ForEach(CameraShape.allCases) { shape in
                        Button {
                            engine.cameraShape = shape
                            onChange()
                        } label: {
                            Text(shape.rawValue)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(engine.cameraShape == shape ? .white : Frame.label)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .background(engine.cameraShape == shape ? Frame.accent : Color.black.opacity(0.05),
                                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("Ring color").font(.system(size: 11, weight: .semibold)).foregroundStyle(Frame.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 6) {
                    ForEach(RingSwatch.all) { swatch in
                        let on = abs((engine.ringRGB[safe: 0] ?? 1) - swatch.rgb.0) < 0.05
                            && abs((engine.ringRGB[safe: 1] ?? 1) - swatch.rgb.1) < 0.05
                        Button {
                            engine.ringRGB = [swatch.rgb.0, swatch.rgb.1, swatch.rgb.2]
                            onChange()
                        } label: {
                            Circle()
                                .fill(Color(red: swatch.rgb.0, green: swatch.rgb.1, blue: swatch.rgb.2))
                                .overlay(Circle().strokeBorder(on ? Frame.accent : Color.black.opacity(0.12),
                                                               lineWidth: on ? 2 : 1))
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("Camera size").font(.system(size: 11, weight: .semibold)).foregroundStyle(Frame.secondary)
                HStack(spacing: 6) {
                    ForEach(CameraSizePreset.allCases) { size in
                        let on = CameraSizePreset.matching(engine.bubbleFraction) == size
                        Button {
                            engine.bubbleFraction = size.fraction
                            onChange()
                        } label: {
                            Text(size.rawValue)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(on ? .white : Frame.label)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .background(on ? Frame.accent : Color.black.opacity(0.05),
                                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if showsCamera {
                Text("Focus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Frame.secondary)
                HStack(spacing: 6) {
                    layoutChoice("Device leads", selected: !engine.cameraLeads) {
                        engine.cameraLeads = false
                        onChange()
                    }
                    layoutChoice("Camera leads", selected: engine.cameraLeads) {
                        engine.cameraLeads = true
                        onChange()
                    }
                }
                Text("Arrangement").font(.system(size: 11, weight: .semibold)).foregroundStyle(Frame.secondary)
                HStack(spacing: 6) {
                    layoutChoice("Side by side", selected: !engine.overlapArrangement) {
                        engine.overlapArrangement = false
                        onChange()
                    }
                    layoutChoice("Overlap", selected: engine.overlapArrangement) {
                        engine.overlapArrangement = true
                        onChange()
                    }
                }
                labeledSlider("Balance",
                              value: Binding(
                                get: { liveBalance ?? engine.splitBalance },
                                set: { liveBalance = $0; engine.splitBalance = $0 }
                              ),
                              range: 0.28...0.72)
                labeledSlider("Gap",
                              value: Binding(
                                get: { liveGap ?? engine.splitGap },
                                set: { liveGap = $0; engine.splitGap = $0 }
                              ),
                              range: 0.02...0.22)
            } else {
                Text(cameraStatus.layoutMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Frame.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Canvas

    private var canvasBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recommended").font(.system(size: 11, weight: .semibold)).foregroundStyle(Frame.secondary)
            HStack(spacing: 8) {
                canvasCard(.device)
                canvasCard(.landscape)
                canvasCard(.square)
            }
            Text("More formats").font(.system(size: 11, weight: .semibold)).foregroundStyle(Frame.secondary)
            canvasRow(.macbook)
            canvasRow(.photo)
            canvasRow(.ipad)
            canvasRow(.fiveFour)
            canvasRow(.portrait)
            labeledSlider("Padding", value: Binding(
                get: { livePadding ?? (ExportLayout.phoneScaleMax - engine.phoneScale + ExportLayout.phoneScaleMin) },
                set: {
                    livePadding = $0
                    engine.phoneScale = ExportLayout.phoneScaleMax - $0 + ExportLayout.phoneScaleMin
                }
            ), range: ExportLayout.phoneScaleMin...ExportLayout.phoneScaleMax)

            Text("Background").font(.system(size: 11, weight: .semibold)).foregroundStyle(Frame.secondary)
            colorGrid(SolidSwatch.solids)
            Text("Soft").font(.system(size: 11, weight: .semibold)).foregroundStyle(Frame.secondary)
            colorGrid(SolidSwatch.pastels)
            HStack {
                Text("Hex").font(.system(size: 11, weight: .semibold)).foregroundStyle(Frame.secondary)
                TextField("#FFFFFF", text: $hexDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { applyHex() }
                Button("Apply") { applyHex() }
                    .font(.system(size: 11, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Frame.accent)
            }
        }
    }

    // MARK: Sound

    private var phoneLevel: Binding<CGFloat> {
        Binding(
            get: { phoneMix?.wrappedValue ?? engine.phoneAudioLevel },
            set: { newValue in
                if let phoneMix {
                    phoneMix.wrappedValue = newValue
                } else {
                    engine.phoneAudioLevel = newValue
                }
            })
    }

    private var micLevel: Binding<CGFloat> {
        Binding(
            get: { micMix?.wrappedValue ?? engine.micAudioLevel },
            set: { newValue in
                if let micMix {
                    micMix.wrappedValue = newValue
                } else {
                    engine.micAudioLevel = newValue
                }
            })
    }

    private var soundBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("These sliders only change how loud each source is. They do not re-record anything.")
                .font(.system(size: 12))
                .foregroundStyle(Frame.secondary)

            Text("iPhone sound").font(.system(size: 11, weight: .semibold)).foregroundStyle(Frame.secondary)
            Slider(value: phoneLevel, in: 0...1) { _ in
                onChange()
            }
            .tint(Frame.accent)
            Text(phoneLevel.wrappedValue <= 0.001 ? "Muted" : "\(Int(phoneLevel.wrappedValue * 100))%")
                .font(.system(size: 11))
                .foregroundStyle(Frame.tertiary)

            if showsMic {
                Text("Your voice (Mac mic)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Frame.secondary)
                Slider(value: micLevel, in: 0...1) { _ in
                    onChange()
                }
                .tint(Frame.accent)
                Text(micLevel.wrappedValue <= 0.001 ? "Muted" : "\(Int(micLevel.wrappedValue * 100))%")
                    .font(.system(size: 11))
                    .foregroundStyle(Frame.tertiary)
            } else {
                Text("This take has no Mac mic. In Setup, pick Device Audio + Mac Mic before Record if you want your voice.")
                    .font(.system(size: 12))
                    .foregroundStyle(Frame.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Appearance

    private var appearanceBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Device frame").font(.system(size: 11, weight: .semibold)).foregroundStyle(Frame.secondary)
            ForEach(DeviceFrameStyle.allCases) { style in
                Button {
                    engine.frameStyle = style
                    engine.showBezel = style.showsBezel
                    onChange()
                } label: {
                    HStack {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color(red: style.rgb.0, green: style.rgb.1, blue: style.rgb.2))
                            .frame(width: 22, height: 16)
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.black.opacity(0.12)))
                        Text(style.rawValue)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Frame.label)
                        Spacer()
                        if engine.frameStyle == style {
                            Image(systemName: "checkmark").foregroundStyle(Frame.accent).font(.system(size: 11, weight: .bold))
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(engine.frameStyle == style ? Frame.accent.opacity(0.08) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Toggle("Screen corners", isOn: $engine.screenCorners)
                .font(.system(size: 12, weight: .medium))
                .onChange(of: engine.screenCorners) { _, _ in onChange() }
            Toggle("Border", isOn: $engine.showBorder)
                .font(.system(size: 12, weight: .medium))
                .onChange(of: engine.showBorder) { _, _ in onChange() }
        }
    }

    // MARK: pieces

    private func canvasCard(_ preset: CanvasPreset) -> some View {
        let on = engine.canvas == preset
        let size = preset.size(phoneAspect: engine.phoneAspect)
        let ratio = size.width / max(size.height, 1)
        return Button {
            engine.canvas = preset
            onChange()
        } label: {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(on ? Frame.accent : Color.black.opacity(0.2), lineWidth: on ? 2 : 1)
                    .aspectRatio(ratio, contentMode: .fit)
                    .frame(height: 36)
                Text(preset.displayTitle).font(.system(size: 10, weight: .semibold)).foregroundStyle(Frame.label)
                Text(preset.subtitle).font(.system(size: 9)).foregroundStyle(Frame.tertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(8)
            .background(on ? Frame.accent.opacity(0.08) : Color.black.opacity(0.03),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func canvasRow(_ preset: CanvasPreset) -> some View {
        let on = engine.canvas == preset
        return Button {
            engine.canvas = preset
            onChange()
        } label: {
            HStack {
                Text(preset.displayTitle).font(.system(size: 12, weight: .semibold)).foregroundStyle(Frame.label)
                Text(preset.subtitle).font(.system(size: 11)).foregroundStyle(Frame.tertiary)
                Spacer()
                if on { Image(systemName: "checkmark").foregroundStyle(Frame.accent).font(.system(size: 11, weight: .bold)) }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(on ? Frame.accent.opacity(0.08) : Color.black.opacity(0.03),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func colorGrid(_ swatches: [SolidSwatch]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 6) {
            ForEach(swatches) { swatch in
                let on = matchesBackground(swatch.rgb)
                Button { setBackground(swatch.rgb) } label: {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(swatch.color)
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(on ? Frame.accent : Color.black.opacity(0.12),
                                          lineWidth: on ? 2 : 1))
                        .frame(height: 22)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func layoutChoice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? .white : Frame.label)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(selected ? Frame.accent : Color.black.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func labeledSlider(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Frame.secondary)
            Slider(value: value, in: range) { editing in
                if !editing {
                    liveBalance = nil
                    liveGap = nil
                    livePadding = nil
                    onChange()
                }
            }
            .tint(Frame.accent)
        }
    }

    private func setBackground(_ rgb: (CGFloat, CGFloat, CGFloat)) {
        engine.customBackgroundRGB = [rgb.0, rgb.1, rgb.2]
        hexDraft = hexString(from: rgb)
        let isNearBlack = rgb.0 < 0.1 && rgb.1 < 0.1 && rgb.2 < 0.1
        engine.background = isNearBlack ? .black : .snow
        onChange()
    }

    private static func cameraPositionName(x: CGFloat, y: CGFloat) -> String {
        let horizontal = x < 0.3 ? "left" : x > 0.7 ? "right" : "center"
        let vertical = y < 0.3 ? "Top" : y > 0.7 ? "Bottom" : "Middle"
        return "\(vertical) \(horizontal) camera position"
    }

    private func matchesBackground(_ rgb: (CGFloat, CGFloat, CGFloat)) -> Bool {
        guard let cur = engine.customBackgroundRGB, cur.count >= 3 else { return false }
        return abs(cur[0] - rgb.0) < 0.04 && abs(cur[1] - rgb.1) < 0.04 && abs(cur[2] - rgb.2) < 0.04
    }

    private func applyHex() {
        if let rgb = rgb(fromHex: hexDraft) { setBackground(rgb) }
    }

    private func syncHex() {
        hexDraft = hexString(from: (
            engine.customBackgroundRGB?[safe: 0] ?? 1,
            engine.customBackgroundRGB?[safe: 1] ?? 1,
            engine.customBackgroundRGB?[safe: 2] ?? 1
        ))
    }
}

struct LookPanel: View {
    @ObservedObject var engine: CaptureEngine
    var showsCamera: Bool = true
    var showsMic: Bool = true
    var cameraStatus: CameraClipStatus = .phoneOnly
    var phoneMix: Binding<CGFloat>? = nil
    var micMix: Binding<CGFloat>? = nil
    var onChange: () -> Void = {}
    var onClose: () -> Void

    @State private var section: LookSection = .layout

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Look").font(.system(size: 16, weight: .semibold)).foregroundStyle(Frame.label)
                Text("Same as Setup")
                    .font(.system(size: 12))
                    .foregroundStyle(Frame.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.black.opacity(0.05), in: Capsule())
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Frame.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color.black.opacity(0.05), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            HStack(spacing: 0) {
                ForEach(LookSection.allCases, id: \.self) { item in
                    Button { section = item } label: {
                        Text(item.rawValue)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(section == item ? Frame.accent : Frame.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(section == item ? Frame.accent : Color.clear)
                                    .frame(height: 2)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider().overlay(Frame.hairline)

            ScrollView {
                LookControls(engine: engine, section: section, showsCamera: showsCamera, showsMic: showsMic, cameraStatus: cameraStatus, phoneMix: phoneMix, micMix: micMix, onChange: onChange)
                    .padding(16)
            }
        }
        .frame(width: Frame.panelWidth)
        .background(Frame.surface)
        .overlay(Rectangle().fill(Frame.hairline).frame(width: 1), alignment: .leading)
        .shadow(color: .black.opacity(0.10), radius: 18, x: -4, y: 0)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
