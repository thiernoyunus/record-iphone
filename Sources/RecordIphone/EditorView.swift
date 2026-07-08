import SwiftUI
import AVKit

private let accent = Color(red: 0.47, green: 0.40, blue: 0.95)
private let chrome = Color(red: 0.075, green: 0.075, blue: 0.09)
private let panel = Color(red: 0.125, green: 0.125, blue: 0.15)

struct EditorView: View {
    @ObservedObject var editor: EditorState
    @EnvironmentObject var engine: CaptureEngine

    var body: some View {
        VStack(spacing: 0) {
            topBar
            preview
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            transport
                .padding(.horizontal, 24)
            TimelineStrip(editor: editor)
                .frame(height: 96)
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 18)
        }
        .background(chrome)
        .overlay { if let p = editor.exportProgress { exportOverlay(p) } }
        .frame(minWidth: 860, minHeight: 620)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 14) {
            Button {
                editor.close()
            } label: {
                Label("Done", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Text(editor.dir.lastPathComponent)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)

            Spacer()

            Picker("", selection: $engine.background) {
                ForEach(BackgroundPreset.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 105)

            Toggle(isOn: $engine.showBezel) { Image(systemName: "iphone") }
                .toggleStyle(.button)
                .help("Device frame")

            Picker("", selection: $engine.bubbleFraction) {
                Text("S").tag(CGFloat(0.22)); Text("M").tag(CGFloat(0.30)); Text("L").tag(CGFloat(0.40))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 96)
            .help("Camera bubble size")

            Button {
                editor.export()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
            .keyboardShortcut("e")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(panel)
        .onChange(of: engine.background) { editor.refreshPreview() }
        .onChange(of: engine.showBezel) { editor.refreshPreview() }
        .onChange(of: engine.bubbleFraction) { editor.refreshPreview() }
    }

    // MARK: - Preview + zoom reticle

    private var preview: some View {
        GeometryReader { geo in
            ZStack {
                PlayerContainerView(player: editor.player)
                if let zoom = editor.selectedZoom,
                   editor.currentTime >= zoom.start - 0.2, editor.currentTime <= zoom.end + 0.2 {
                    reticle(for: zoom, in: geo.size)
                }
                if let failure = editor.loadFailed {
                    Text(failure).foregroundStyle(.white).padding()
                }
            }
        }
        .aspectRatio(engine.canvas.size.width / engine.canvas.size.height, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
    }

    private func reticle(for zoom: ZoomSegment, in size: CGSize) -> some View {
        ZStack {
            Circle().stroke(accent, lineWidth: 2).frame(width: 56, height: 56)
            Circle().fill(accent.opacity(0.25)).frame(width: 56, height: 56)
            Image(systemName: "plus").font(.system(size: 13, weight: .bold)).foregroundStyle(accent)
        }
        .position(x: zoom.center.x * size.width, y: zoom.center.y * size.height)
        .gesture(DragGesture(minimumDistance: 1).onChanged { value in
            var z = zoom
            z.center = CGPoint(x: min(max(value.location.x / size.width, 0.05), 0.95),
                               y: min(max(value.location.y / size.height, 0.05), 0.95))
            editor.update(z)
        })
        .help("Drag to aim the zoom")
    }

    // MARK: - Transport row

    private var transport: some View {
        HStack(spacing: 14) {
            Button {
                editor.togglePlay()
            } label: {
                Image(systemName: editor.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 34, height: 30)
            }
            .keyboardShortcut(.space, modifiers: [])

            Text("\(timeString(editor.currentTime)) / \(timeString(editor.duration))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            if let zoom = editor.selectedZoom {
                HStack(spacing: 10) {
                    Text("Zoom \(String(format: "%.1f×", zoom.level))")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(accent)
                    Slider(value: Binding(
                        get: { zoom.level },
                        set: { var z = zoom; z.level = $0; editor.update(z) }
                    ), in: 1.2...3.5)
                    .frame(width: 140)
                    Button(role: .destructive) {
                        editor.deleteSelectedZoom()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .keyboardShortcut(.delete, modifiers: [])
                    .help("Remove this zoom")
                }
            }

            Button {
                editor.addZoom()
            } label: {
                Label("Add Zoom", systemImage: "plus.magnifyingglass")
                    .font(.body.weight(.medium))
            }
            .buttonStyle(.bordered)
            .tint(accent)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .help("Drop a smooth zoom-in at the playhead, then drag the circle on the preview to aim it")
        }
    }

    private func exportOverlay(_ progress: Double) -> some View {
        ZStack {
            Color.black.opacity(0.6)
            VStack(spacing: 14) {
                ProgressView(value: progress).frame(width: 260)
                Text("Exporting… \(Int(progress * 100))%")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.white)
            }
            .padding(28)
            .background(RoundedRectangle(cornerRadius: 14).fill(panel))
        }
    }
}

private func timeString(_ s: Double) -> String {
    let t = max(0, Int(s.rounded()))
    return String(format: "%d:%02d", t / 60, t % 60)
}

// MARK: - Timeline

private struct TimelineStrip: View {
    @ObservedObject var editor: EditorState
    @State private var dragBaseStart: [UUID: Double] = [:]
    @State private var dragBaseDuration: [UUID: Double] = [:]
    @State private var trimBase: [String: Double] = [:]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let pps = w / max(editor.duration, 0.1)   // pixels per second

            ZStack(alignment: .leading) {
                // Film strip
                RoundedRectangle(cornerRadius: 10).fill(panel)
                HStack(spacing: 0) {
                    ForEach(Array(editor.thumbnails.enumerated()), id: \.offset) { _, img in
                        Image(decorative: img, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: w / CGFloat(max(editor.thumbnails.count, 1)),
                                   height: geo.size.height)
                            .clipped()
                    }
                }
                .opacity(0.5)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                // Dim the trimmed-away ends
                Rectangle().fill(.black.opacity(0.62))
                    .frame(width: max(0, editor.trimStart * pps))
                Rectangle().fill(.black.opacity(0.62))
                    .frame(width: max(0, (editor.duration - editor.trimEnd) * pps))
                    .offset(x: editor.trimEnd * pps)

                // Zoom chips
                ForEach(editor.zooms) { zoom in
                    zoomChip(zoom, pps: pps, height: geo.size.height)
                }

                // Trim handles — drag by relative motion (the handle's own
                // coordinate space is only 7pt wide, so absolute positions lie)
                trimHandle(x: editor.trimStart * pps, height: geo.size.height,
                           key: "start", current: editor.trimStart, pps: pps) { seconds in
                    editor.trimStart = min(max(0, seconds), editor.trimEnd - 1)
                    editor.applyTrimToPlayback()
                }
                trimHandle(x: editor.trimEnd * pps, height: geo.size.height,
                           key: "end", current: editor.trimEnd, pps: pps) { seconds in
                    editor.trimEnd = max(min(editor.duration, seconds), editor.trimStart + 1)
                    editor.applyTrimToPlayback()
                }

                // Playhead
                RoundedRectangle(cornerRadius: 1)
                    .fill(.white)
                    .frame(width: 2, height: geo.size.height + 8)
                    .offset(x: editor.currentTime * pps - 1, y: -4)
                    .shadow(radius: 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                editor.seek(to: value.location.x / pps)
                editor.selectedZoomID = nil
            })
        }
    }

    private func zoomChip(_ zoom: ZoomSegment, pps: CGFloat, height: CGFloat) -> some View {
        let selected = editor.selectedZoomID == zoom.id
        return HStack(spacing: 4) {
            Image(systemName: "plus.magnifyingglass").font(.system(size: 10, weight: .bold))
            Text(String(format: "%.1f×", zoom.level)).font(.caption2.weight(.semibold).monospacedDigit())
            Spacer(minLength: 0)
            // Right-edge grip: drag to change the zoom's length
            RoundedRectangle(cornerRadius: 2)
                .fill(.white.opacity(selected ? 0.9 : 0.4))
                .frame(width: 5, height: 26)
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragBaseDuration[zoom.id] == nil { dragBaseDuration[zoom.id] = zoom.duration }
                        var z = zoom
                        z.duration = (dragBaseDuration[zoom.id] ?? z.duration) + value.translation.width / pps
                        editor.update(z)
                    }
                    .onEnded { _ in dragBaseDuration[zoom.id] = nil })
        }
        .padding(.horizontal, 6)
        .foregroundStyle(.white)
        .frame(width: max(34, zoom.duration * pps), height: 34)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: [accent, accent.opacity(0.75)],
                                     startPoint: .top, endPoint: .bottom))
        )
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(.white, lineWidth: selected ? 2 : 0))
        .offset(x: zoom.start * pps)
        .onTapGesture { editor.selectedZoomID = zoom.id; editor.seek(to: zoom.start + 0.7) }
        .gesture(DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragBaseStart[zoom.id] == nil { dragBaseStart[zoom.id] = zoom.start }
                var z = zoom
                z.start = (dragBaseStart[zoom.id] ?? z.start) + value.translation.width / pps
                editor.update(z)
                editor.selectedZoomID = zoom.id
            }
            .onEnded { _ in dragBaseStart[zoom.id] = nil })
        .help("Drag to move the zoom; drag the grip to change its length")
    }

    private func trimHandle(x: CGFloat, height: CGFloat, key: String,
                            current: Double, pps: CGFloat,
                            onDrag: @escaping (Double) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(.white)
            .frame(width: 7, height: height + 6)
            .overlay(RoundedRectangle(cornerRadius: 1).fill(.black.opacity(0.35)).frame(width: 1.5, height: 18))
            .offset(x: x - 3.5, y: -3)
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if trimBase[key] == nil { trimBase[key] = current }
                    onDrag((trimBase[key] ?? current) + value.translation.width / pps)
                }
                .onEnded { _ in trimBase[key] = nil })
            .help("Drag to trim")
    }
}

/// AVPlayerView without its own controls — the editor supplies transport UI.
private struct PlayerContainerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        return v
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}
