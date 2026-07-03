import SwiftUI
import AVFoundation

struct ContentView: View {
    @EnvironmentObject var engine: CaptureEngine

    var body: some View {
        VStack(spacing: 0) {
            canvas
            controls
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Something went wrong", isPresented: .init(
            get: { engine.errorMessage != nil },
            set: { if !$0 { engine.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(engine.errorMessage ?? "")
        }
    }

    // MARK: - Canvas (matches what the export renders)

    private var canvas: some View {
        GeometryReader { geo in
            ZStack {
                let bg = engine.background.colors
                LinearGradient(
                    colors: [Color(red: bg.top.0, green: bg.top.1, blue: bg.top.2),
                             Color(red: bg.bottom.0, green: bg.bottom.1, blue: bg.bottom.2)],
                    startPoint: .top, endPoint: .bottom)

                if engine.selectedPhone != nil {
                    devicePreview(in: geo.size)
                } else {
                    emptyState
                }

                cameraBubble(in: geo.size)
            }
        }
        .aspectRatio(engine.canvas.size.width / engine.canvas.size.height, contentMode: .fit)
        .frame(minWidth: engine.canvas == .landscape ? 640 : 320,
               minHeight: engine.canvas == .landscape ? 360 : 570)
    }

    private func devicePreview(in size: CGSize) -> some View {
        let maxH = size.height * ExportLayout.phoneHeightFraction
        let h = min(maxH, size.width * 0.88 / engine.phoneAspect)
        let w = h * engine.phoneAspect
        let screenRadius = min(w, h) * 0.10
        let t = min(w, h) * 0.045
        let (br, bgc, bb) = ExportLayout.bezelColor

        return ZStack {
            if engine.showBezel {
                RoundedRectangle(cornerRadius: screenRadius + t)
                    .fill(Color(red: br, green: bgc, blue: bb))
                    .frame(width: w + 2 * t, height: h + 2 * t)
            }
            CaptureLayerView(session: engine.phoneSession, gravity: .resizeAspect)
                .frame(width: w, height: h)
                .clipShape(RoundedRectangle(cornerRadius: screenRadius))
        }
        .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Connect your iPhone or iPad with a cable")
                .font(.title3.weight(.medium))
                .foregroundStyle(.white)
            Text("Unlock it and tap “Trust This Computer” if asked.")
                .foregroundStyle(.secondary)
        }
    }

    private func cameraBubble(in size: CGSize) -> some View {
        let side = engine.bubbleFraction * min(size.width, size.height)
        return CaptureLayerView(session: engine.cameraSession, gravity: .resizeAspectFill)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: side * 0.24))
            .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
            .position(x: engine.bubbleCenter.x * size.width,
                      y: engine.bubbleCenter.y * size.height)
            .gesture(DragGesture().onChanged { value in
                engine.bubbleCenter = CGPoint(
                    x: min(max(value.location.x / size.width, 0.05), 0.95),
                    y: min(max(value.location.y / size.height, 0.05), 0.95))
            })
    }

    // MARK: - Bottom bar

    private var controls: some View {
        HStack(spacing: 14) {
            devicePicker

            Divider().frame(height: 20)

            Picker("Background", selection: $engine.background) {
                ForEach(BackgroundPreset.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 110)
            .help("Background behind the device")

            Picker("Shape", selection: $engine.canvas) {
                ForEach(CanvasPreset.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 110)
            .help("Video shape: widescreen or vertical for socials")

            Toggle(isOn: $engine.showBezel) { Image(systemName: "iphone") }
                .toggleStyle(.button)
                .help("Show a device frame around the screen")

            Toggle(isOn: $engine.pinned) { Image(systemName: "pin") }
                .toggleStyle(.button)
                .help("Keep this window on top of everything")

            Toggle("Hear audio", isOn: $engine.monitorPhoneAudio)
                .toggleStyle(.switch)
                .help("The device's sound is always recorded. This only controls whether you also hear it on the Mac.")

            Picker("Camera size", selection: $engine.bubbleFraction) {
                Text("S").tag(CGFloat(0.22))
                Text("M").tag(CGFloat(0.30))
                Text("L").tag(CGFloat(0.40))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 100)
            .help("Camera bubble size")

            Spacer()

            Button {
                engine.takeScreenshot()
            } label: {
                Image(systemName: "camera")
            }
            .keyboardShortcut("s")
            .disabled(engine.selectedPhone == nil)
            .help("Save a high-resolution screenshot of the device screen")

            recordButton
        }
        .padding(14)
    }

    private var devicePicker: some View {
        Menu {
            ForEach(engine.phones, id: \.uniqueID) { phone in
                Button(phone.localizedName) { engine.select(phone: phone) }
            }
        } label: {
            Label(engine.selectedPhone?.localizedName ?? "Choose device",
                  systemImage: "iphone.gen3")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(engine.phones.isEmpty)
    }

    @ViewBuilder
    private var recordButton: some View {
        switch engine.phase {
        case .idle:
            Button {
                engine.startRecording()
            } label: {
                Label("Record", systemImage: "record.circle.fill")
                    .foregroundStyle(.red)
                    .font(.body.weight(.semibold))
            }
            .keyboardShortcut("r")
            .disabled(engine.selectedPhone == nil)
        case .recording(let startedAt):
            Button {
                engine.stopRecording()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "stop.circle.fill").foregroundStyle(.red)
                    ElapsedTimeText(since: startedAt)
                        .monospacedDigit()
                }
                .font(.body.weight(.semibold))
            }
            .keyboardShortcut("r")
        case .exporting(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress).frame(width: 120)
                Text("Saving… \(Int(progress * 100))%").monospacedDigit()
            }
        }
    }
}

struct ElapsedTimeText: View {
    let since: Date
    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let s = Int(context.date.timeIntervalSince(since))
            Text(String(format: "%d:%02d", s / 60, s % 60))
        }
    }
}

/// Hosts an AVCaptureVideoPreviewLayer inside SwiftUI.
struct CaptureLayerView: NSViewRepresentable {
    let session: AVCaptureSession
    let gravity: AVLayerVideoGravity

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = gravity
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
