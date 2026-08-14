import SwiftUI
import AVFoundation

struct ContentView: View {
    @EnvironmentObject var engine: CaptureEngine
    @State private var countdown: Int? = nil
    @State private var hexDraft = "#FFFFFF"
    @State private var savedPresets: [CapturePreset] = PresetStore.load()
    @State private var presetName = ""
    @State private var askPresetName = false
    @State private var setupSection: SetupSection = .sources
    @State private var countdownTask: Task<Void, Never>?
    @State private var dragBubble: CGPoint?
    @State private var connectChoice: ConnectChoice?

    enum SetupSection: String, CaseIterable {
        case sources = "Sources"
        case layout = "Layout"
        case canvas = "Canvas"
        case appearance = "Appearance"
    }

    var body: some View {
        Group {
            if let editor = engine.editor {
                EditorView(editor: editor)
            } else if engine.showHome {
                HomeLandingView()
            } else {
                captureShell
            }
        }
        .background(Frame.bg)
        .preferredColorScheme(.light)
        .overlay {
            if engine.editorOpening, engine.editor == nil {
                ZStack {
                    Color.white.opacity(0.78)
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text(engine.openingStatus ?? "Opening recording…")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Frame.label)
                        Text("This stays on screen so the app doesn’t freeze.")
                            .font(.system(size: 12))
                            .foregroundStyle(Frame.secondary)
                    }
                    .padding(28)
                    .background(Frame.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Frame.hairline))
                    .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
                }
                .allowsHitTesting(true)
            }
        }
        .onAppear {
            if !engine.showHome { engine.reconnectIfNeeded() }
        }
        .onChange(of: engine.airplay.sourceSize) { _, _ in
            if engine.connectionKind == .wireless {
                engine.phoneAspect = engine.airplay.aspect
            }
        }
        .onChange(of: engine.airplay.status) { _, status in
            switch status {
            case .connected:
                engine.noteAirPlayConnected()
            case .failed(let message):
                engine.errorMessage = message
            default:
                break
            }
        }
        .sheet(item: $connectChoice) { choice in
            ConnectSheet(choice: choice, engine: engine) { connectChoice = nil }
        }
        .sheet(isPresented: $engine.showConnectSheet) {
            WirelessWaitSheet(engine: engine)
        }
        .alert("Something went wrong", isPresented: .init(
            get: { engine.errorMessage != nil },
            set: { if !$0 { engine.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(engine.errorMessage ?? "")
        }
        .alert("Save preset", isPresented: $askPresetName) {
            TextField("Name", text: $presetName)
            Button("Save") { saveCurrentPreset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Give this look a name so you can apply it again later.")
        }
    }

    private var captureShell: some View {
        ZStack(alignment: .bottom) {
            Frame.bg.ignoresSafeArea()
            HStack(spacing: 0) {
                canvas
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 78)
                if engine.setupOpen {
                    Color.clear.frame(width: Frame.panelWidth)
                }
            }

            if case .recording = engine.phase {
                recordingBar
                    .padding(.bottom, 16)
            } else if case .arming = engine.phase, countdown == nil {
                recordingBar
                    .padding(.bottom, 16)
            } else if case .finishing = engine.phase {
                finishingBar
                    .padding(.bottom, 16)
            } else {
                captureBar
                    .padding(.bottom, 16)
            }
        }
        .overlay(alignment: .trailing) {
            if engine.setupOpen {
                setupPanel
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: engine.setupOpen)
        .overlay {
            if let n = countdown { countdownOverlay(n) }
        }
        .frame(minWidth: 1060, minHeight: 700)
    }

    private var isFinishing: Bool {
        if case .finishing = engine.phase { return true }
        return false
    }

    /// Phone picture is actually on screen — not the empty Connect card.
    private var showsLiveDevice: Bool {
        if engine.connectionKind == .wireless { return engine.hasLiveDevice }
        return engine.selectedPhone != nil
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { geo in
            let layout = engine.presenterLayout == .split ? engine.currentLayout() : nil
            ZStack {
                canvasFill
                if engine.connectionKind == .wireless {
                    if engine.hasLiveDevice {
                        devicePreview(in: geo.size, layout: layout)
                        if let message = engine.airplay.overlayMessage {
                            wirelessOverlay(message)
                        }
                    } else if engine.airplay.isLive || engine.showConnectSheet {
                        wirelessWaitState
                    } else {
                        emptyState
                    }
                } else if engine.selectedPhone != nil {
                    // Keep the preview view mounted the whole time a cable
                    // phone is selected. Swapping it for the spinner is what
                    // froze the window on "Connecting…".
                    devicePreview(in: geo.size, layout: layout)
                    if !engine.phoneReady || !engine.phoneSessionRunning {
                        reconnectingState
                    }
                } else {
                    emptyState
                }
                // Never draw the camera on the Connect card — that's the
                // "bubble while I'm not recording" bug.
                if engine.cameraEnabled, showsLiveDevice, !engine.freezeLivePreview {
                    cameraBubble(in: geo.size, layout: layout)
                }
                if engine.freezeLivePreview || isFinishing {
                    canvasFill.opacity(0.92)
                        .overlay(
                            VStack(spacing: 10) {
                                ProgressView().controlSize(.large)
                                Text("Saving recording…")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Frame.label)
                            }
                        )
                        .allowsHitTesting(true)
                }
            }
        }
        .modifier(CanvasShape(preset: engine.canvas, phoneAspect: engine.phoneAspect))
        .background(canvasFill)
        .clipShape(RoundedRectangle(cornerRadius: engine.canvas == .device ? 0 : 18, style: .continuous))
        .shadow(color: .black.opacity(engine.canvas == .device ? 0 : 0.08), radius: 18, y: 6)
    }

    private var canvasFill: Color {
        if let rgb = engine.customBackgroundRGB, rgb.count >= 3 {
            return Color(red: rgb[0], green: rgb[1], blue: rgb[2])
        }
        let c = engine.background.colors.top
        return Color(red: c.0, green: c.1, blue: c.2)
    }

    @ViewBuilder
    private var phoneLiveView: some View {
        if engine.connectionKind == .wireless {
            AirPlayPreviewView(mirror: engine.airplay)
        } else {
            CaptureLayerView(session: engine.phoneSession,
                             sessionQueue: engine.sessionQueue,
                             gravity: .resizeAspect) {
                engine.previewDidAttach(to: engine.phoneSession)
            }
            .id("phone-preview")
        }
    }

    private func devicePreview(in size: CGSize, layout: ExportLayout?) -> some View {
        let (frame, w, h) = phoneFrame(in: size, layout: layout)
        return FramedPhoneChrome(
            width: w,
            height: h,
            style: engine.frameStyle,
            showBezel: engine.frameStyle.showsBezel,
            screenCorners: engine.screenCorners
        ) {
            phoneLiveView
                .overlay {
                    if let freeze = frozenPhoneImage {
                        ZStack {
                            Image(decorative: freeze, scale: 1)
                                .resizable()
                                .scaledToFill()
                            Color.black.opacity(0.22)
                            VStack(spacing: 5) {
                                Text("Last picture")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white)
                                Text("Unlock the phone and this will update")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.88))
                            }
                            .multilineTextAlignment(.center)
                            .padding(10)
                        }
                    }
                }
        }
        .position(x: frame.midX, y: frame.midY)
    }

    private func phoneFrame(in size: CGSize, layout: ExportLayout?) -> (CGRect, CGFloat, CGFloat) {
        let r = CanvasDraw.phoneScreenRect(
            canvas: size,
            layout: layout ?? engine.currentLayout(),
            phoneAspect: engine.phoneAspect)
        return (r, r.width, r.height)
    }

    private func cameraBubble(in size: CGSize, layout: ExportLayout?) -> some View {
        let busy: Bool = {
            switch engine.phase {
            case .idle: return false
            default: return true
            }
        }()
        let frac = min(max(engine.bubbleFraction, ExportLayout.bubbleMin), ExportLayout.bubbleMax)
        let aspect: CGFloat = engine.cameraShape == .rectangle ? 4 / 5 : 1
        let (w, h, center, corner): (CGFloat, CGFloat, CGPoint, CGFloat) = {
            switch engine.presenterLayout {
            case .floating:
                let s = frac * min(size.width, size.height)
                let hh = s
                let ww = s * aspect
                let cr: CGFloat = engine.cameraShape == .circle ? 0.5
                    : (engine.cameraShape == .square ? 0.18 : 0.14)
                return (ww, hh, dragBubble ?? engine.bubbleCenter, cr)
            case .split:
                let zone = ExportLayout.splitZones(canvas: size, layout: layout ?? engine.currentLayout()).camera
                let fit = min(zone.width / aspect, zone.height) * 0.92
                let cr: CGFloat = engine.cameraShape == .circle ? 0.5 : 0.10
                return (fit * aspect, fit,
                        CGPoint(x: zone.midX / size.width, y: zone.midY / size.height), cr)
            }
        }()
        let ring = engine.ringRGB
        let ringColor = Color(red: ring[safe: 0] ?? 1, green: ring[safe: 1] ?? 1, blue: ring[safe: 2] ?? 1)

        return CaptureLayerView(session: engine.cameraSession,
                                sessionQueue: engine.sessionQueue,
                                gravity: .resizeAspectFill) {
            engine.previewDidAttach(to: engine.cameraSession)
        }
        .id("camera-preview")
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: min(w, h) * corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: min(w, h) * corner, style: .continuous)
                .strokeBorder(ringColor, lineWidth: max(2, min(w, h) * 0.018))
        )
        .background {
            RoundedRectangle(cornerRadius: min(w, h) * corner, style: .continuous)
                .fill(Color.black.opacity(0.001))
        }
        .position(x: center.x * size.width, y: center.y * size.height)
        .gesture(DragGesture().onChanged { value in
            guard !busy, engine.presenterLayout == .floating else { return }
            dragBubble = CGPoint(
                x: min(max(value.location.x / size.width, 0.08), 0.92),
                y: min(max(value.location.y / size.height, 0.08), 0.92))
        }.onEnded { value in
            guard engine.presenterLayout == .floating else { return }
            engine.bubbleCenter = CGPoint(
                x: min(max(value.location.x / size.width, 0.08), 0.92),
                y: min(max(value.location.y / size.height, 0.08), 0.92))
            dragBubble = nil
        })
        .help(engine.presenterLayout == .floating ? "Drag to reposition camera" : "Camera")
    }

    private var reconnectingState: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("Looking for \(engine.selectedPhone?.localizedName ?? "your iPhone")…")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Frame.label)
            Text("The cable is fine — we’re waking the picture after the last take. Unlock the phone and keep the screen on.")
                .font(.system(size: 13))
                .foregroundStyle(Frame.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Retry connection") { engine.ensureLivePreview() }
                .buttonStyle(.borderedProminent)
                .tint(Frame.accent)
        }
        .padding(28)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Frame.tertiary)
            Text("Connect your iPhone")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Frame.label)
            Text("Plug in a cable, or use Screen Mirroring over Wi‑Fi.")
                .font(.system(size: 13))
                .foregroundStyle(Frame.secondary)
            HStack(spacing: 10) {
                connectCard(title: "Cable",
                            subtitle: "Plug in · unlock · Trust",
                            icon: "cable.connector",
                            action: {
                    engine.preferCable()
                    connectChoice = .cable
                })
                connectCard(title: "Wireless",
                            subtitle: "Wi-Fi · no cable",
                            icon: "airplayvideo",
                            action: { engine.startWireless() })
            }
            if !engine.recentProjects.isEmpty {
                Divider().frame(width: 140).padding(.top, 6)
                Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(Frame.tertiary)
                VStack(spacing: 6) {
                    ForEach(engine.recentProjects.prefix(5)) { project in
                        Button { engine.openProject(project) } label: {
                            HStack(spacing: 10) {
                                ProjectThumb(dir: project.dir)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(project.displayName).lineLimit(1)
                                    Text(project.hasExport ? "Exported" : "Not exported yet")
                                        .font(.caption2).foregroundStyle(Frame.tertiary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption2).opacity(0.4)
                            }
                            .foregroundStyle(Frame.label)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.black.opacity(0.04),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: 320)
                    }
                }
            }
        }
    }

    private func connectCard(title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Frame.accent)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Frame.label)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Frame.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minWidth: 176, maxWidth: 200, alignment: .leading)
            .padding(14)
            .background(Frame.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Frame.pillStroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// Keep the last phone picture on screen when the device locks or sleeps.
    private var frozenPhoneImage: CGImage? {
        if engine.connectionKind == .wireless {
            switch engine.airplay.link.link {
            case .live: return nil
            default: return engine.airplay.latestFrame.getImage()
            }
        }
        if !engine.phoneReady {
            return engine.latestFrame.getImage()
        }
        return nil
    }

    private func wirelessOverlay(_ message: String) -> some View {
        VStack(spacing: 8) {
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(Frame.label)
        }
        .padding(16)
        .frame(maxWidth: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .allowsHitTesting(false)
    }

    private var wirelessWaitState: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Waiting for Screen Mirroring")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Frame.label)
            VStack(alignment: .leading, spacing: 6) {
                Text("1. On the iPhone, swipe to Control Center")
                Text("2. Tap Screen Mirroring")
                Text("3. Tap Record iPhone")
            }
            .font(.system(size: 13))
            .foregroundStyle(Frame.secondary)
            Text("The phone stays unlocked. The picture shows up in this window — not full-screen.")
                .font(.system(size: 12))
                .foregroundStyle(Frame.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if let pin = engine.airplay.pinCode {
                Text("If the phone asks for a code, enter \(pin)")
                    .font(.system(size: 13, weight: .semibold))
            }
            Button("Cancel wireless") { engine.cancelWireless() }
                .buttonStyle(.bordered)
        }
        .padding(28)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Bottom bars

    private var captureBar: some View {
        HStack(spacing: 10) {
            Button { engine.goHome() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "house")
                    Text("Home").font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(Frame.label)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Frame.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Frame.pillStroke, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Back to your clips")
            recentsChip
            deviceChip
            if engine.soundMode != .off { MicMeterView(meter: engine.micMeter) }
            recordChip
            snapshotChip
            setupChip
        }
        .padding(.horizontal, 8)
    }

    private var recordingBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Frame.record).frame(width: 8, height: 8)
                Text("RECORDING")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.6)
                if case .recording(let started) = engine.phase {
                    ElapsedTimeText(since: started).monospacedDigit()
                } else {
                    Text("0:00").monospacedDigit()
                }
            }
            .foregroundStyle(Frame.record)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Frame.recordSoft, in: Capsule())
            .overlay(Capsule().strokeBorder(Frame.record.opacity(0.25), lineWidth: 1))

            if engine.soundMode != .off { MicMeterView(meter: engine.micMeter) }

            pillButton("Cancel", icon: nil) { engine.cancelRecording() }
            pillButton("Restart", icon: "arrow.counterclockwise") { engine.restartRecording() }

            Button { engine.stopRecording() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "stop.fill")
                    Text("Stop")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(Frame.record, in: Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r")
        }
    }

    private var finishingBar: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Saving recording…").font(.system(size: 13, weight: .medium)).foregroundStyle(Frame.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Frame.surface, in: Capsule())
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }

    private var recentsChip: some View {
        Menu {
            if engine.recentProjects.isEmpty {
                Text("No recordings yet")
            } else {
                ForEach(engine.recentProjects) { project in
                    Button {
                        engine.openProject(project)
                    } label: {
                        Label(project.displayName,
                              systemImage: project.hasExport ? "film" : "waveform")
                    }
                }
                Divider()
                Button("Show in Finder") {
                    NSWorkspace.shared.open(CaptureEngine.recordingsRoot)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                Text("Library")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(engine.recentProjects.isEmpty ? Frame.tertiary : Frame.label)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Frame.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Frame.pillStroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(engine.recentProjects.isEmpty)
        .help("Open a previous recording")
        .accessibilityLabel("Library")
    }

    private var deviceChip: some View {
        Menu {
            Button {
                engine.startWireless()
            } label: {
                if engine.connectionKind == .wireless {
                    Label("Wireless (Screen Mirroring)", systemImage: "checkmark")
                } else {
                    Label("Wireless (Screen Mirroring)", systemImage: "airplayvideo")
                }
            }
            if engine.phones.isEmpty {
                Text("No cable connected")
            } else {
                ForEach(engine.phones, id: \.uniqueID) { phone in
                    Button { engine.select(phone: phone) } label: {
                        if engine.connectionKind == .cable,
                           engine.selectedPhone?.uniqueID == phone.uniqueID {
                            Label(phone.localizedName, systemImage: "checkmark")
                        } else { Text(phone.localizedName) }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(engine.hasLiveDevice ? Color(red: 0.22, green: 0.78, blue: 0.38) : Color.orange)
                    .frame(width: 8, height: 8)
                Text(deviceChipTitle)
                    .font(.system(size: 13, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(Frame.label)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Frame.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Frame.pillStroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var deviceChipTitle: String {
        if engine.connectionKind == .wireless {
            if engine.airplay.link.link == .locked { return "\(engine.airplay.deviceName) · locked" }
            if engine.airplay.link.link == .dropped { return "\(engine.airplay.deviceName) · reconnect" }
            if engine.airplay.isConnected { return engine.airplay.deviceName }
            return "Wireless…"
        }
        return engine.selectedPhone?.localizedName ?? "No device"
    }



    private var recordChip: some View {
        Button { beginCountdown() } label: {
            HStack(spacing: 8) {
                Circle().fill(Frame.record).frame(width: 10, height: 10)
                Text("Record").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Frame.label)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(Frame.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Frame.pillStroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("r")
        .disabled(!engine.phoneReady)
        .opacity(engine.phoneReady ? 1 : 0.45)
        .help("Start recording (⌘R)")
        .accessibilityIdentifier("recordButton")
    }

    private var snapshotChip: some View {
        Button { engine.takeScreenshot() } label: {
            HStack(spacing: 7) {
                Image(systemName: "camera")
                Text("Snapshot").font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(Frame.label)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Frame.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Frame.pillStroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("s")
        .disabled(!engine.phoneReady)
        .help("Screenshot (⌘S)")
        .accessibilityLabel("Snapshot")
    }

    private var setupChip: some View {
        Button { engine.setupOpen.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: "slider.horizontal.3")
                VStack(alignment: .leading, spacing: 0) {
                    Text("Setup").font(.system(size: 13, weight: .medium))
                    Text(setupSubtitle)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Frame.tertiary)
                }
            }
            .foregroundStyle(engine.setupOpen ? Frame.accent : Frame.label)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Frame.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(
                engine.setupOpen ? Frame.accent.opacity(0.45) : Frame.pillStroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Setup")
    }

    private var setupSubtitle: String {
        var bits: [String] = ["Device"]
        switch engine.soundMode {
        case .off: bits.append("No audio")
        case .device: bits.append("Device")
        case .mic: bits.append("Mic")
        case .both: bits.append("Mic / Mac")
        }
        if engine.cameraEnabled { bits.append("Mac") }
        return bits.joined(separator: " / ")
    }

    private func pillButton(_ title: String, icon: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Frame.label)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Frame.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Frame.pillStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Countdown

    private func beginCountdown() {
        guard engine.phoneReady else { return }
        engine.setupOpen = false
        engine.prepareForRecording()
        countdownTask?.cancel()
        let beats = AppSettings.shared.countdownSeconds
        if beats <= 0 {
            engine.startRecording()
            return
        }
        engine.prearmRecording()
        countdown = beats
        countdownTask = Task { @MainActor in
            var n = beats
            while n > 0 {
                countdown = n
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                n -= 1
            }
            countdown = nil
            engine.startRecording()
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
        if case .arming = engine.phase {
            engine.cancelRecording()
        } else {
            engine.abortPrepareForRecording()
        }
    }

    private func countdownOverlay(_ n: Int) -> some View {
        ZStack {
            Color.black.opacity(0.18)
            VStack(spacing: 10) {
                Text("\(n)")
                    .font(.system(size: 92, weight: .bold, design: .rounded))
                    .foregroundStyle(Frame.label)
                Text("Click to cancel")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Frame.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { cancelCountdown() }
        .overlay(alignment: .bottom) {
            Button("Cancel", action: cancelCountdown)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Frame.label)
                .padding(.horizontal, 18).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 48)
        }
    }

    // MARK: - Setup panel

    private var setupPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Scene").font(.system(size: 16, weight: .semibold)).foregroundStyle(Frame.label)
                Text(engine.selectedPhone?.localizedName ?? "No device")
                    .font(.system(size: 12))
                    .foregroundStyle(Frame.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.black.opacity(0.05), in: Capsule())
                Spacer()
                Button("Reset") { resetLook() }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Frame.secondary)
                    .buttonStyle(.plain)
                Button { engine.setupOpen = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Frame.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color.black.opacity(0.05), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            HStack {
                Menu {
                    Button("Current look") {}
                    if !savedPresets.isEmpty { Divider() }
                    ForEach(savedPresets) { p in
                        Button(p.name) { engine.apply(preset: p) }
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                    Text("Capture presets")
                    Text("Save and reuse this setup")
                        .font(.system(size: 10))
                        .foregroundStyle(Frame.tertiary)
                }
                        Spacer()
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Frame.label)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.black.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .menuStyle(.borderlessButton)
                Button("+ Save") {
                    presetName = ""
                    askPresetName = true
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Frame.save, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            HStack(spacing: 0) {
                ForEach(SetupSection.allCases, id: \.self) { section in
                    Button { setupSection = section } label: {
                        Text(section.rawValue)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(setupSection == section ? Frame.accent : Frame.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(setupSection == section ? Frame.accent : Color.clear)
                                    .frame(height: 2)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(section.rawValue)
                }
            }
            Divider().overlay(Frame.hairline)

            ScrollView {
                Group {
                    switch setupSection {
                    case .sources: sourcesBody
                    case .layout:
                        LookControls(engine: engine, section: .layout, showsCamera: true)
                    case .canvas:
                        LookControls(engine: engine, section: .canvas)
                    case .appearance:
                        LookControls(engine: engine, section: .appearance)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: Frame.panelWidth)
        .background(Frame.surface)
        .overlay(Rectangle().fill(Frame.hairline).frame(width: 1), alignment: .leading)
        .shadow(color: .black.opacity(0.10), radius: 18, x: -4, y: 0)
    }

    // MARK: Sources

    private var sourcesBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Camera source").font(.system(size: 11, weight: .semibold)).foregroundStyle(Frame.secondary)
                Spacer()
                Text(engine.cameraEnabled ? "Mac Camera" : "Off")
                    .font(.system(size: 11)).foregroundStyle(Frame.tertiary)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                sourceCard(title: "Off", subtitle: "Screen only",
                           icon: "iphone.slash", selected: !engine.cameraEnabled) {
                    engine.setCameraEnabled(false)
                }
                sourceCard(title: "Mac",
                           subtitle: (engine.selectedCamera ?? AVCaptureDevice.default(for: .video))?.localizedName ?? "FaceTime HD Camera",
                           icon: "web.camera", selected: engine.cameraEnabled) {
                    if let cam = AVCaptureDevice.default(for: .video) ?? engine.availableCameras.first {
                        engine.select(camera: cam)
                    } else {
                        engine.setCameraEnabled(true)
                    }
                }
                sourceCard(title: "Continuity Camera",
                           subtitle: continuityName,
                           icon: "iphone",
                           selected: engine.cameraEnabled && isContinuity(engine.selectedCamera)) {
                    if let cam = engine.availableCameras.first(where: { isContinuity($0) }) {
                        engine.select(camera: cam)
                    }
                }
                sourceCard(title: "External",
                           subtitle: externalName,
                           icon: "rectangle.connected.to.line.below",
                           selected: engine.cameraEnabled && isExternal(engine.selectedCamera)) {
                    if let cam = engine.availableCameras.first(where: { $0.deviceType == .external }) {
                        engine.select(camera: cam)
                    }
                }
            }

            HStack {
                Text("Sound").font(.system(size: 11, weight: .semibold)).foregroundStyle(Frame.secondary)
                Spacer()
                Text(engine.soundMode.rawValue).font(.system(size: 11)).foregroundStyle(Frame.tertiary)
            }
            VStack(spacing: 6) {
                ForEach(SoundMode.allCases) { mode in
                    Button { engine.setSoundMode(mode) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: soundIcon(mode))
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(mode.rawValue).font(.system(size: 12, weight: .semibold))
                                Text(mode.subtitle).font(.system(size: 10)).foregroundStyle(Frame.tertiary)
                            }
                            Spacer()
                            if engine.soundMode == mode {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Frame.accent)
                            }
                        }
                        .foregroundStyle(Frame.label)
                        .padding(10)
                        .background(engine.soundMode == mode ? Frame.accent.opacity(0.08) : Color.black.opacity(0.03),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
                            engine.soundMode == mode ? Frame.accent.opacity(0.45) : Color.clear, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("RECORDING STATUS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Frame.tertiary)
                Text(engine.soundMode == .off
                     ? "Recording without audio\nOnly video will be recorded"
                     : (engine.monitorPhoneAudio
                        ? "Recording with audio\nYou’ll hear the iPhone on this Mac"
                        : "Recording with audio\nLive speaker is muted"))
                    .font(.system(size: 11))
                    .foregroundStyle(Frame.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if engine.soundMode == .device || engine.soundMode == .both {
                Toggle("Play phone audio on this Mac", isOn: $engine.monitorPhoneAudio)
                    .font(.system(size: 12))
                    .toggleStyle(.switch)
                    .help("Hear your iPhone through the Mac while you preview or record. Wear headphones if you also record the Mac mic.")
                Text("Phone sound").font(.system(size: 11, weight: .semibold)).foregroundStyle(Frame.secondary)
                Slider(value: $engine.phoneAudioLevel, in: 0...1)
                    .tint(Frame.accent)
            }
            if engine.soundMode == .mic || engine.soundMode == .both {
                Text("Microphone").font(.system(size: 11, weight: .semibold)).foregroundStyle(Frame.secondary)
                microphonePicker
                Text("Your voice").font(.system(size: 11, weight: .semibold)).foregroundStyle(Frame.secondary)
                Slider(value: $engine.micAudioLevel, in: 0...1)
                    .tint(Frame.accent)
            }
        }
    }

    private var microphonePicker: some View {
        let current = engine.selectedMic
            ?? CaptureEngine.preferredMicrophone(from: engine.availableMics)
        return Menu {
            if engine.availableMics.isEmpty {
                Text("No microphones found")
            } else {
                ForEach(engine.availableMics, id: \.uniqueID) { mic in
                    Button {
                        engine.select(mic: mic)
                    } label: {
                        HStack {
                            Text(mic.localizedName)
                            if current?.uniqueID == mic.uniqueID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            HStack {
                Image(systemName: "mic")
                Text(current?.localizedName ?? "Choose a microphone")
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Frame.label)
            .padding(10)
            .background(Color.black.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .help("Which microphone records your voice")
    }

    private var continuityName: String {
        engine.availableCameras.first(where: { isContinuity($0) })?.localizedName ?? "iPhone Camera"
    }
    private var externalName: String {
        engine.availableCameras.first(where: { isExternal($0) })?.localizedName ?? "USB or virtual camera"
    }
    private func isContinuity(_ cam: AVCaptureDevice?) -> Bool {
        guard let cam else { return false }
        return cam.deviceType == .continuityCamera || cam.localizedName.localizedCaseInsensitiveContains("iphone")
    }
    private func isExternal(_ cam: AVCaptureDevice?) -> Bool {
        cam?.deviceType == .external
    }

    private func soundIcon(_ mode: SoundMode) -> String {
        switch mode {
        case .off: return "speaker.slash"
        case .device: return "iphone.and.arrow.forward"
        case .mic: return "mic"
        case .both: return "person.wave.2"
        }
    }

    private func sourceCard(title: String, subtitle: String, icon: String,
                            selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Frame.accent) }
                }
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(Frame.tertiary).lineLimit(2)
            }
            .foregroundStyle(Frame.label)
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
            .background(selected ? Frame.accent.opacity(0.08) : Color.black.opacity(0.03),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
                selected ? Frame.accent : Color.black.opacity(0.08), lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }

    private func resetLook() {
        engine.background = .snow
        engine.customBackgroundRGB = [1, 1, 1]
        engine.canvas = .device
        engine.presenterLayout = .floating
        engine.deviceOnLeft = true
        engine.cameraLeads = false
        engine.phoneScale = ExportLayout.phoneHeightFraction
        engine.bubbleFraction = 0.22
        engine.bubbleCenter = CGPoint(x: 0.82, y: 0.78)
        engine.cameraShape = .circle
        engine.ringRGB = [1, 1, 1]
        engine.frameStyle = .none
        engine.showBezel = false
        engine.setCameraEnabled(false)
        engine.setSoundMode(.off)
        engine.splitBalance = 0.55
        engine.splitGap = 0.12
        hexDraft = "#FFFFFF"
    }

    private func saveCurrentPreset() {
        let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        savedPresets.append(engine.snapshotPreset(named: name))
        PresetStore.save(savedPresets)
    }
}

private struct CanvasShape: ViewModifier {
    let preset: CanvasPreset
    let phoneAspect: CGFloat
    func body(content: Content) -> some View {
        if preset == .device {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let size = preset.size(phoneAspect: phoneAspect)
            content.aspectRatio(size.width / size.height, contentMode: .fit)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private struct MicMeterView: View {
    @ObservedObject var meter: MicMeterState
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(i < meter.bars ? Color(red: 0.18, green: 0.72, blue: 0.36) : Color.black.opacity(0.12))
                    .frame(width: 4, height: CGFloat(8 + i * 3))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Frame.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Frame.pillStroke, lineWidth: 1))
        .help("Microphone level")
        .animation(.easeOut(duration: 0.08), value: meter.bars)
    }
}

/// After a take, land here instead of the live camera.
struct HomeLandingView: View {
    @EnvironmentObject var engine: CaptureEngine
    @State private var connectChoice: ConnectChoice?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Record iPhone")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Frame.label)
                Spacer()
                if engine.phoneReady || engine.hasLiveDevice {
                    Button("Live preview") { engine.enterLive() }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Frame.accent)
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 8)

            HStack(spacing: 12) {
                homeCard(title: "Cable",
                         subtitle: "Plug in · unlock · Trust",
                         icon: "cable.connector") {
                    engine.preferCable()
                    connectChoice = .cable
                }
                .disabled(engine.editorOpening)
                homeCard(title: "Wireless",
                         subtitle: "Wi-Fi · no cable",
                         icon: "airplayvideo") {
                    engine.startWireless()
                }
                .disabled(engine.editorOpening)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)

            HStack {
                Text("Recent recordings")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Frame.secondary)
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 8)

            if engine.recentProjects.isEmpty {
                Text("Your takes will show up here after you record.")
                    .font(.system(size: 13))
                    .foregroundStyle(Frame.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(engine.recentProjects) { project in
                            Button { engine.openProject(project) } label: {
                                HStack(spacing: 12) {
                                    ProjectThumb(dir: project.dir)
                                        .frame(width: 72, height: 48)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(project.displayName)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(Frame.label)
                                        Text(project.hasExport ? "Exported" : "Not exported yet")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Frame.tertiary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(Frame.tertiary)
                                }
                                .padding(10)
                                .background(Color.white,
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(Frame.hairline))
                            }
                            .buttonStyle(.plain)
                            .disabled(engine.editorOpening)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Frame.bg)
        .onAppear { engine.refreshRecentProjects() }
        .sheet(item: $connectChoice) { choice in
            ConnectSheet(choice: choice, engine: engine) { connectChoice = nil }
        }
    }

    private func homeCard(title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Frame.accent)
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Frame.label)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Frame.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Frame.hairline))
        }
        .buttonStyle(.plain)
    }
}

struct ElapsedTimeText: View {
    let since: Date
    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let s = Int(context.date.timeIntervalSince(since))
            Text(String(format: "%02d:%02d", s / 60, s % 60))
        }
    }
}

struct ProjectThumb: View {
    let dir: URL
    @State private var image: CGImage?
    private static let cache = NSCache<NSURL, CGImage>()

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.black.opacity(0.06)
            }
        }
        .frame(width: 42, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .task {
            let url = dir.appendingPathComponent("phone.mov")
            if let cached = Self.cache.object(forKey: url as NSURL) {
                image = cached
                return
            }
            let grabbed = await Task.detached(priority: .utility) { () -> CGImage? in
                await withTaskGroup(of: CGImage?.self) { group in
                    group.addTask {
                        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                        gen.appliesPreferredTrackTransform = true
                        gen.maximumSize = CGSize(width: 160, height: 0)
                        gen.requestedTimeToleranceBefore = .positiveInfinity
                        gen.requestedTimeToleranceAfter = .positiveInfinity
                        return try? await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
                    }
                    group.addTask {
                        try? await Task.sleep(for: .seconds(2))
                        return nil
                    }
                    let first = await group.next() ?? nil
                    group.cancelAll()
                    return first
                }
            }.value
            if let img = grabbed {
                Self.cache.setObject(img, forKey: url as NSURL)
                image = img
            }
        }
    }
}

enum ConnectChoice: String, Identifiable {
    case cable
    var id: String { rawValue }
}

private struct ConnectSheet: View {
    let choice: ConnectChoice
    @ObservedObject var engine: CaptureEngine
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect with a cable")
                .font(.system(size: 20, weight: .semibold))
            Text("Plug the iPhone into this Mac with a USB cable. Unlock it and tap Trust This Computer if asked. The screen shows up in the phone frame — not full-screen.")
                .font(.system(size: 13))
                .foregroundStyle(Frame.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !engine.phones.isEmpty {
                Text("Found: \(engine.phones.map(\.localizedName).joined(separator: ", "))")
                    .font(.system(size: 13, weight: .medium))
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("I’ve plugged it in") {
                    engine.preferCable()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Frame.accent)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

private struct WirelessWaitSheet: View {
    @ObservedObject var engine: CaptureEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Mirror without a cable")
                .font(.system(size: 20, weight: .semibold))
            Text("This Mac now shows up as Record iPhone in your iPhone’s Screen Mirroring list. The phone stays unlocked, and the picture lands in this app — not across the whole Mac screen.")
                .font(.system(size: 13))
                .foregroundStyle(Frame.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                step(1, "On the iPhone, swipe down from the top-right for Control Center")
                step(2, "Tap Screen Mirroring")
                step(3, "Tap Record iPhone")
            }
            Text("If macOS asks to allow incoming connections or local network access, choose Allow.")
                .font(.system(size: 12))
                .foregroundStyle(Frame.tertiary)
            if let pin = engine.airplay.pinCode {
                Text("If the phone asks for a code, type \(pin)")
                    .font(.system(size: 14, weight: .semibold))
            }
            switch engine.airplay.status {
            case .connected:
                Label("Phone is mirrored", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color(red: 0.18, green: 0.62, blue: 0.42))
            case .connecting:
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("iPhone found. Starting the picture…")
                            .foregroundStyle(Frame.secondary)
                    }
                    Text("Keep the phone unlocked and the screen on.")
                        .font(.system(size: 12))
                        .foregroundStyle(Frame.tertiary)
                }
            case .failed(let message):
                Text(message).foregroundStyle(Frame.delete).font(.system(size: 13))
            default:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Waiting for the iPhone…")
                        .foregroundStyle(Frame.secondary)
                }
            }
            HStack {
                Button("Use a cable instead") {
                    engine.preferCable()
                }
                Spacer()
                Button("Cancel") { engine.cancelWireless() }
                if engine.airplay.isConnected {
                    Button("Done") { engine.showConnectSheet = false }
                        .buttonStyle(.borderedProminent)
                        .tint(Frame.accent)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Frame.accent, in: Circle())
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Frame.label)
        }
    }
}

struct CaptureLayerView: NSViewRepresentable {
    let session: AVCaptureSession
    let sessionQueue: DispatchQueue
    let gravity: AVLayerVideoGravity
    let onAttached: () -> Void

    func makeNSView(context: Context) -> CapturePreviewNSView {
        let view = CapturePreviewNSView()
        view.sessionQueue = sessionQueue
        view.previewLayer.videoGravity = gravity
        view.bind(session: session, then: onAttached)
        return view
    }

    func updateNSView(_ nsView: CapturePreviewNSView, context: Context) {
        nsView.sessionQueue = sessionQueue
        if nsView.previewLayer.session !== session {
            nsView.bind(session: session, then: onAttached)
        }
        if nsView.previewLayer.videoGravity != gravity {
            nsView.previewLayer.videoGravity = gravity
        }
    }

    static func dismantleNSView(_ nsView: CapturePreviewNSView, coordinator: ()) {
        nsView.detachSessionOffMain()
    }
}

final class CapturePreviewNSView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    var sessionQueue: DispatchQueue?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor
        previewLayer.videoGravity = .resizeAspect
        layer?.addSublayer(previewLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Must run on `sessionQueue`. Setting the session on the main thread
    /// while startRunning is in flight aborts in `_setRunning`.
    func bind(session: AVCaptureSession, then onAttached: @escaping () -> Void) {
        let layer = previewLayer
        let queue = sessionQueue ?? DispatchQueue.global(qos: .userInitiated)
        queue.async {
            if layer.session !== session {
                layer.session = session
            }
            DispatchQueue.main.async(execute: onAttached)
        }
    }

    /// Clear the session on the capture queue. Doing `setSession:` from
    /// dealloc during a Core Animation commit deadlocks with stopRunning.
    func detachSessionOffMain() {
        previewLayer.removeFromSuperlayer()
        let layer = previewLayer
        let queue = sessionQueue ?? DispatchQueue.global(qos: .utility)
        queue.async {
            layer.session = nil
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }
}
