import SwiftUI

/// Screen / camera / audio lanes + a full-height playhead, like a regular editor.
struct TimelineStrip: View {
    @ObservedObject var editor: EditorState
    @State private var zoomStartBase: [UUID: Double] = [:]
    @State private var zoomDurationBase: [UUID: Double] = [:]
    @State private var trimStartBase: Double?
    @State private var trimEndBase: Double?
    @State private var trimDragPPS: CGFloat?
    @State private var playheadBase: Double?
    @State private var hoverZoomX: CGFloat?
    @State private var snapGuideX: CGFloat?
    @State private var isEditingZoom = false
    @State private var isScrubbing = false

    private let labelW: CGFloat = 64

    var body: some View {
        GeometryReader { geo in
            let trackW = max(geo.size.width - labelW, 1)
            let view = layoutWindow(trackWidth: trackW)
            let needleX = TimelineLayout.playheadX(
                time: editor.currentTime,
                window: view,
                labelWidth: labelW)

            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    timeRuler(view: view)
                        .padding(.leading, labelW)
                    track(label: "Screen", height: 52) {
                        filmstrip(view: view)
                    }
                    track(label: "Camera", height: 32) {
                        cameraLane(view: view)
                    }
                    audioTrack(label: "iPhone",
                               muted: editor.phoneMuted,
                               onMute: { editor.togglePhoneMute() }) {
                        audioLane(samples: editor.phoneWaveform,
                                  tint: Frame.accent,
                                  delay: ClipAlignment.startAtMic(
                                    cameraOffsetSeconds: editor.cameraOffset.seconds).phoneAt,
                                  span: editor.phoneAudioDuration,
                                  empty: "No iPhone sound on this take",
                                  view: view)
                    }
                    audioTrack(label: "Mic",
                               muted: editor.micMuted,
                               onMute: { editor.toggleMicMute() }) {
                        audioLane(samples: editor.micWaveform,
                                  tint: Color(red: 0.18, green: 0.62, blue: 0.42),
                                  delay: ClipAlignment.startAtMic(
                                    cameraOffsetSeconds: editor.cameraOffset.seconds).cameraAt,
                                  span: editor.micAudioDuration,
                                  empty: "No Mac mic — Sound was iPhone only",
                                  view: view)
                    }
                    track(label: "Zoom", height: 28) {
                        zoomLane(view: view)
                    }
                }

                if let gx = snapGuideX {
                    Rectangle()
                        .fill(Frame.accent)
                        .frame(width: 1, height: max(20, geo.size.height - 4))
                        .offset(x: labelW + gx, y: 2)
                        .allowsHitTesting(false)
                }

                // Needle sits on top so you can grab it. Trim / zoom use their
                // own drags — this card does not steal those.
                playheadNeedle(x: needleX, height: geo.size.height, view: view)
            }
        }
        .padding(10)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Frame.hairline))
        .onAppear {
            if editor.currentTime > editor.trimStart + 0.05 {
                editor.seek(to: editor.trimStart)
            }
        }
        .contextMenu {
            Button("Trim start here") {
                editor.trimStart = min(editor.currentTime, editor.trimEnd - 0.5)
                editor.applyTrimToPlayback()
            }
            Button("Trim end here") {
                editor.trimEnd = max(editor.currentTime, editor.trimStart + 0.5)
                editor.applyTrimToPlayback()
            }
            Button("Add zoom here") { editor.addZoom(at: editor.currentTime) }
        }
    }

    /// Keep the old window while a trim handle is moving so the handle can
    /// follow the pointer. At rest, only the kept range fills the timeline.
    private func layoutWindow(trackWidth: CGFloat) -> TimelineLayout.KeepWindow {
        let start = min(editor.trimStart, trimStartBase ?? editor.trimStart)
        let end = max(editor.trimEnd, trimEndBase ?? editor.trimEnd)
        return TimelineLayout.keepWindow(
            trimStart: start,
            trimEnd: end,
            duration: editor.duration,
            trackWidth: trackWidth)
    }

    /// Draw the full take, then move the kept range into the visible track.
    private func keepLane<V: View>(view: TimelineLayout.KeepWindow, height: CGFloat,
                                   @ViewBuilder content: () -> V) -> some View {
        content()
            .frame(width: max(1, view.fullWidth), height: height, alignment: .leading)
            .offset(x: view.shift)
            .frame(width: view.trackWidth, height: height, alignment: .leading)
            .compositingGroup()
            .clipped()
            .contentShape(Rectangle())
    }

    private var playheadClock: String {
        let t = max(0, editor.currentTime - editor.trimStart)
        return String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
    }

    private func playheadNeedle(x: CGFloat, height: CGFloat,
                                view: TimelineLayout.KeepWindow) -> some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                TimelineDiamond()
                    .fill(Frame.accent)
                    .frame(width: 11, height: 9)
                Rectangle()
                    .fill(Frame.accent)
                    .frame(width: 2, height: max(20, height - 9))
            }
            if isScrubbing {
                Text(playheadClock)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Frame.accent, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .offset(x: 22, y: -1)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: 20, height: height, alignment: .top)
        .contentShape(Rectangle())
        .offset(x: x - 10)
        .highPriorityGesture(DragGesture(minimumDistance: 0).onChanged { value in
            if playheadBase == nil {
                playheadBase = editor.currentTime
                isScrubbing = true
            }
            let dt = Double(value.translation.width) / Double(max(view.trackWidth, 1)) * view.viewDur
            editor.seek(to: (playheadBase ?? 0) + dt)
        }.onEnded { _ in
            playheadBase = nil
            isScrubbing = false
        })
    }

    private func track<V: View>(label: String, height: CGFloat, @ViewBuilder content: () -> V) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Frame.secondary)
                .frame(width: labelW - 6, alignment: .trailing)
            content()
        }
        .frame(height: height)
    }

    private func audioTrack<V: View>(label: String, muted: Bool, onMute: @escaping () -> Void,
                                     @ViewBuilder content: () -> V) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Button(action: onMute) {
                HStack(spacing: 3) {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text(label)
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(muted ? Frame.tertiary : Frame.secondary)
                .frame(width: labelW - 6, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .help(muted ? "Unmute \(label)" : "Mute \(label)")
            content()
                .opacity(muted ? 0.35 : 1)
        }
        .frame(height: 28)
    }

    private func timeRuler(view: TimelineLayout.KeepWindow) -> some View {
        let step: Double = view.viewDur > 40 ? 5 : 2
        let marks = stride(from: 0.0, through: view.viewDur, by: step).map { $0 }
        return ZStack(alignment: .topLeading) {
            ForEach(marks, id: \.self) { t in
                Text("\(Int(t))s")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Frame.tertiary)
                    .offset(x: max(0, t * view.pps - (t == 0 ? 0 : 8)))
            }
        }
        .frame(width: view.trackWidth, height: 12, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            isScrubbing = true
            editor.seek(to: view.time(at: value.location.x))
        }.onEnded { _ in
            isScrubbing = false
        })
    }

    private func filmstrip(view: TimelineLayout.KeepWindow) -> some View {
        let align = ClipAlignment.startAtMic(cameraOffsetSeconds: editor.cameraOffset.seconds)
        let span = max(0.05, editor.phoneFileDuration - align.phoneSkip)
        let placed = TimelineLayout.clipFrame(
            start: align.phoneAt, span: span,
            timeline: editor.duration, trackWidth: view.fullWidth)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.04))
            keepLane(view: view, height: 52) {
                EquatableView(content: FilmstripView(
                    thumbnails: editor.thumbnails,
                    clipX: placed.x,
                    clipWidth: placed.width
                ))
            }
            trimHandle(view: view, edge: .start)
            trimHandle(view: view, edge: .end)
        }
        .frame(width: view.trackWidth, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Frame.hairline))
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { point in
            editor.seek(to: view.time(at: point.x))
        }
    }

    private func trimHandle(view: TimelineLayout.KeepWindow,
                            edge: FilmstripView.TrimEdge) -> some View {
        let time = edge == .start ? editor.trimStart : editor.trimEnd
        let x = min(max(view.x(for: time), 5), max(5, view.trackWidth - 5))
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color.white)
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.black.opacity(0.2)))
            .frame(width: 7, height: 52)
            .offset(x: x - 3.5)
            .highPriorityGesture(DragGesture(minimumDistance: 1).onChanged { value in
                if trimDragPPS == nil { trimDragPPS = view.pps }
                let dx = Double(value.translation.width) / Double(trimDragPPS ?? view.pps)
                switch edge {
                case .start:
                    if trimStartBase == nil { trimStartBase = editor.trimStart }
                    editor.trimStart = min(max(0, (trimStartBase ?? 0) + dx), editor.trimEnd - 0.5)
                case .end:
                    if trimEndBase == nil { trimEndBase = editor.trimEnd }
                    editor.trimEnd = max(min(editor.duration, (trimEndBase ?? editor.duration) + dx),
                                         editor.trimStart + 0.5)
                }
            }.onEnded { _ in
                trimStartBase = nil
                trimEndBase = nil
                trimDragPPS = nil
                editor.applyTrimToPlayback()
            })
    }

    private func cameraLane(view: TimelineLayout.KeepWindow) -> some View {
        let align = ClipAlignment.startAtMic(cameraOffsetSeconds: editor.cameraOffset.seconds)
        let span = max(0.05, editor.cameraFileDuration - align.cameraSkip)
        let placed = TimelineLayout.clipFrame(
            start: align.cameraAt, span: span,
            timeline: editor.duration, trackWidth: view.fullWidth)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.04))
            if editor.hasCamera {
                keepLane(view: view, height: 32) {
                    if !editor.cameraThumbnails.isEmpty {
                        HStack(spacing: 0) {
                            ForEach(editor.cameraThumbnails.indices, id: \.self) { i in
                                Image(decorative: editor.cameraThumbnails[i], scale: 1)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: max(6, placed.width / CGFloat(max(editor.cameraThumbnails.count, 1))),
                                           height: 32)
                                    .clipped()
                            }
                        }
                        .frame(width: placed.width, height: 32)
                        .offset(x: placed.x)
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Frame.accent.opacity(0.16))
                            .overlay(Text("Camera").font(.system(size: 11, weight: .semibold)).foregroundStyle(Frame.accent))
                            .frame(width: placed.width, height: 32)
                            .offset(x: placed.x)
                    }
                }
            } else {
                Text(editor.cameraClipStatus == .wantedButMissing
                     ? "Camera was on — clip didn’t save"
                     : "No camera clip recorded")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Frame.secondary)
                    .padding(.horizontal, 8)
            }
        }
        .frame(width: view.trackWidth, height: 32)
        .onTapGesture(coordinateSpace: .local) { point in
            editor.seek(to: view.time(at: point.x))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: editor.hasCamera ? [] : [4, 3]))
                .foregroundStyle(Frame.hairline)
        )
    }

    private func audioLane(samples: [Float], tint: Color, delay: Double,
                           span: Double, empty: String,
                           view: TimelineLayout.KeepWindow) -> some View {
        let placed = TimelineLayout.clipFrame(
            start: delay, span: max(span, 0.05),
            timeline: editor.duration, trackWidth: view.fullWidth)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.black.opacity(0.04))
            if samples.contains(where: { $0 > 0.02 }) {
                keepLane(view: view, height: 28) {
                    WaveformOverlay(samples: samples, color: tint.opacity(0.9))
                        .frame(width: placed.width)
                        .offset(x: placed.x)
                }
            } else {
                Text(empty)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Frame.secondary)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: view.trackWidth, height: 28)
        .clipped()
        .onTapGesture(coordinateSpace: .local) { point in
            editor.seek(to: view.time(at: point.x))
        }
    }

    private func zoomLane(view: TimelineLayout.KeepWindow) -> some View {
        let hoverTime = hoverZoomX.map { view.time(at: $0) }
        let hoverOverChip = hoverTime.map { t in
            editor.zooms.contains { ZoomSnap.covers(start: $0.start, duration: $0.duration, time: t) }
        } ?? false
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.black.opacity(0.04))
                .frame(width: view.trackWidth, height: 28)
            keepLane(view: view, height: 28) {
                ForEach(editor.zooms.filter { view.intersects(start: $0.start, duration: $0.duration) }) { zoom in
                    zoomChip(zoom, view: view)
                }
            }
            if !isEditingZoom, !hoverOverChip, let hx = hoverZoomX {
                Button {
                    let snapped = ZoomSnap.snap(
                        view.time(at: hx),
                        playhead: editor.currentTime,
                        timeline: editor.duration)
                    editor.addZoom(at: snapped)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Frame.accent)
                        .background(Circle().fill(Color.white))
                }
                .buttonStyle(.plain)
                .help("Add a zoom here")
                .position(x: hx, y: 14)
            }
        }
        .frame(width: view.trackWidth, height: 28)
        .clipped()
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                hoverZoomX = min(max(p.x, 0), view.trackWidth)
            case .ended:
                hoverZoomX = nil
            }
        }
    }

    private func zoomChip(_ zoom: ZoomSegment, view: TimelineLayout.KeepWindow) -> some View {
        let pps = view.pps
        let on = editor.selectedZoomID == zoom.id
        let width = max(44, zoom.duration * pps)
        return ZStack {
            Capsule().fill(Frame.accent.opacity(on ? 0.96 : 0.7))
            Text(ZoomSnap.chipLabel(level: Double(zoom.level), duration: zoom.duration))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 10)
            HStack {
                Capsule().fill(Color.white.opacity(0.9)).frame(width: 3, height: 12)
                Spacer()
                Capsule().fill(Color.white.opacity(0.9)).frame(width: 3, height: 12)
            }
            .padding(.horizontal, 4)
        }
        .frame(width: width, height: 22)
        .offset(x: zoom.start * pps)
        .onTapGesture {
            editor.selectedZoomID = zoom.id
            editor.seek(to: zoom.start + 0.15)
        }
        .gesture(DragGesture(minimumDistance: 3).onChanged { value in
            if zoomStartBase[zoom.id] == nil {
                zoomStartBase[zoom.id] = zoom.start
                isEditingZoom = true
            }
            var z = zoom
            z.start = (zoomStartBase[zoom.id] ?? z.start) + Double(value.translation.width) / Double(pps)
            editor.update(z, rebuild: false)
            showSnapGuide(for: z.start, view: view)
        }.onEnded { _ in
            if var current = editor.zooms.first(where: { $0.id == zoom.id }) {
                current.start = clampedZoomStart(
                    ZoomSnap.snap(current.start, playhead: editor.currentTime, timeline: editor.duration),
                    duration: current.duration)
                editor.update(current, rebuild: true)
            }
            zoomStartBase[zoom.id] = nil
            finishZoomEdit()
        })
        .overlay(alignment: .leading) {
            Color.clear.frame(width: 11, height: 22).contentShape(Rectangle())
                .highPriorityGesture(resize(zoom: zoom, view: view, leading: true))
        }
        .overlay(alignment: .trailing) {
            Color.clear.frame(width: 11, height: 22).contentShape(Rectangle())
                .highPriorityGesture(resize(zoom: zoom, view: view, leading: false))
        }
        .help("Drag the middle to move. Drag either end to make the zoom longer.")
    }

    private func resize(zoom: ZoomSegment, view: TimelineLayout.KeepWindow,
                        leading: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1).onChanged { value in
            if zoomStartBase[zoom.id] == nil {
                zoomStartBase[zoom.id] = zoom.start
                zoomDurationBase[zoom.id] = zoom.duration
                isEditingZoom = true
            }
            let sized = ZoomTiming.resize(start: zoomStartBase[zoom.id] ?? zoom.start,
                                          duration: zoomDurationBase[zoom.id] ?? zoom.duration,
                                          delta: Double(value.translation.width) / Double(view.pps),
                                          leading: leading,
                                          timeline: editor.duration)
            var z = zoom
            z.start = sized.start
            z.duration = sized.duration
            editor.update(z, rebuild: false)
            showSnapGuide(for: leading ? z.start : z.end, view: view)
        }.onEnded { _ in
            if var current = editor.zooms.first(where: { $0.id == zoom.id }) {
                current = snappedZoom(current, leading: leading)
                editor.update(current, rebuild: true)
            }
            zoomStartBase[zoom.id] = nil
            zoomDurationBase[zoom.id] = nil
            finishZoomEdit()
        }
    }

    private func showSnapGuide(for time: Double, view: TimelineLayout.KeepWindow) {
        if ZoomSnap.nearPlayhead(time, playhead: editor.currentTime) {
            snapGuideX = view.x(for: editor.currentTime)
        } else {
            snapGuideX = nil
        }
    }

    private func finishZoomEdit() {
        isEditingZoom = false
        snapGuideX = nil
    }

    private func clampedZoomStart(_ start: Double, duration: Double) -> Double {
        min(max(start, 0), max(0, editor.duration - duration))
    }

    private func snappedZoom(_ zoom: ZoomSegment, leading: Bool) -> ZoomSegment {
        var z = zoom
        if leading {
            let end = z.end
            z.start = min(
                max(ZoomSnap.snap(z.start, playhead: editor.currentTime, timeline: editor.duration), 0),
                end - ZoomTiming.minDuration)
            z.duration = end - z.start
        } else {
            let snappedEnd = ZoomSnap.snap(z.end, playhead: editor.currentTime, timeline: editor.duration)
            z.duration = min(max(snappedEnd - z.start, ZoomTiming.minDuration), editor.duration - z.start)
        }
        return z
    }
}

private struct FilmstripView: View, Equatable {
    let thumbnails: [CGImage]
    let clipX: CGFloat
    let clipWidth: CGFloat

    enum TrimEdge { case start, end }

    static func == (lhs: FilmstripView, rhs: FilmstripView) -> Bool {
        lhs.clipX == rhs.clipX
            && lhs.clipWidth == rhs.clipWidth
            && lhs.thumbnails.count == rhs.thumbnails.count
            && lhs.thumbnails.first === rhs.thumbnails.first
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(thumbnails.indices, id: \.self) { i in
                Image(decorative: thumbnails[i], scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: max(8, clipWidth / CGFloat(max(thumbnails.count, 1))), height: 52)
                    .clipped()
            }
        }
        .frame(width: clipWidth, height: 52, alignment: .leading)
        .offset(x: clipX)
        .clipped()
    }
}

private struct TimelineDiamond: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        p.closeSubpath()
        return p
    }
}

private struct WaveformOverlay: View {
    let samples: [Float]
    var color: Color = Color.white.opacity(0.88)
    var body: some View {
        Canvas { ctx, size in
            let n = max(samples.count, 1)
            let barW = size.width / CGFloat(n)
            for (i, s) in samples.enumerated() {
                let h = max(2, CGFloat(s) * size.height * 0.88)
                let rect = CGRect(x: CGFloat(i) * barW,
                                  y: (size.height - h) / 2,
                                  width: max(1, barW - 0.35),
                                  height: h)
                ctx.fill(Path(rect), with: .color(color))
            }
        }
    }
}

struct ZoomInspector: View {
    @ObservedObject var editor: EditorState

    var body: some View {
        if let zoom = editor.selectedZoom {
            HStack(spacing: 12) {
                Text("Zoom")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Frame.secondary)
                Text(String(format: "%.1f×", zoom.level))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Frame.label)
                    .frame(width: 36, alignment: .leading)
                Slider(value: Binding(
                    get: { Double(zoom.level) },
                    set: { v in
                        var z = zoom
                        z.level = CGFloat(v)
                        editor.update(z, rebuild: false)
                    }
                ), in: 1.25...3.5, step: 0.05) { editing in
                    if !editing, let current = editor.zooms.first(where: { $0.id == zoom.id }) {
                        editor.update(current, rebuild: true)
                    }
                }
                .frame(maxWidth: 200)
                Text("Click the phone picture to aim")
                    .font(.system(size: 11))
                    .foregroundStyle(Frame.tertiary)
                Button("Remove") { editor.deleteSelectedZoom() }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Frame.delete)
                    .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.03))
        }
    }
}
