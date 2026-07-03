import AVFoundation
import CoreMediaIO
import AppKit

/// Owns all capture: the iPhone (screen video + device audio, arriving as one
/// "muxed" AVCaptureDevice once the CoreMediaIO switch is flipped), the Mac
/// camera, and the microphone. Records each source to its own .mov, then hands
/// both files to the Exporter.
@MainActor
final class CaptureEngine: NSObject, ObservableObject {

    enum Phase: Equatable {
        case idle
        case recording(startedAt: Date)
        case exporting(progress: Double)
    }

    @Published var phones: [AVCaptureDevice] = []
    @Published var selectedPhone: AVCaptureDevice?
    @Published var phase: Phase = .idle
    @Published var errorMessage: String?
    @Published var monitorPhoneAudio = false {
        didSet { audioPreview?.volume = monitorPhoneAudio ? 1.0 : 0.0 }
    }
    /// Camera bubble placement, normalized 0...1 in top-left coordinates.
    @Published var bubbleCenter = CGPoint(x: 0.82, y: 0.76)
    @Published var bubbleFraction: CGFloat = 0.30   // bubble side / canvas height
    /// Width/height of the connected device's stream (iPhone portrait vs iPad
    /// landscape look completely different). Updated from the live stream.
    @Published var phoneAspect: CGFloat = 0.462
    @Published var background: BackgroundPreset = .midnight
    @Published var canvas: CanvasPreset = .landscape
    @Published var showBezel = true
    @Published var pinned = false {
        didSet {
            let level: NSWindow.Level = pinned ? .floating : .normal
            NSApp.windows.first { $0.isVisible }?.level = level
        }
    }

    let phoneSession = AVCaptureSession()
    let cameraSession = AVCaptureSession()

    private let phoneOutput = AVCaptureMovieFileOutput()
    private let cameraOutput = AVCaptureMovieFileOutput()
    private var audioPreview: AVCaptureAudioPreviewOutput?
    private let sessionQueue = DispatchQueue(label: "capture.session")

    // Keeps the newest device frame around so screenshots are instant and at
    // the stream's native resolution.
    private let frameTap = AVCaptureVideoDataOutput()
    private let frameTapQueue = DispatchQueue(label: "capture.frametap")
    let latestFrame = FrameStore()

    // Per-recording bookkeeping (touched from delegate callbacks).
    private var startTimes: [URL: CMTime] = [:]
    private var finishedURLs: [URL] = []
    private var phoneFileURL: URL?
    private var cameraFileURL: URL?

    // MARK: - Setup

    /// The QuickTime trick: tell CoreMediaIO that screen-capture devices
    /// (USB-connected iPhones/iPads) may appear as capture devices.
    static func allowScreenCaptureDevices() {
        var prop = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &prop, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &allow)
    }

    func start() {
        Self.allowScreenCaptureDevices()

        NotificationCenter.default.addObserver(
            self, selector: #selector(devicesChanged),
            name: AVCaptureDevice.wasConnectedNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(devicesChanged),
            name: AVCaptureDevice.wasDisconnectedNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(portFormatChanged),
            name: .AVCaptureInputPortFormatDescriptionDidChange, object: nil)

        Task {
            let cam = await AVCaptureDevice.requestAccess(for: .video)
            let mic = await AVCaptureDevice.requestAccess(for: .audio)
            if !cam || !mic {
                self.errorMessage = "Camera or microphone access was denied. Enable both in System Settings → Privacy & Security."
            }
            self.setupCameraSession()
            self.refreshPhones()
        }
    }

    @objc private func devicesChanged() {
        // Devices enumerate a beat after connect/disconnect.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshPhones()
        }
    }

    private func refreshPhones() {
        // iPhones over USB show up as external devices carrying "muxed"
        // (video+audio in one stream) media — that's how we tell them apart
        // from webcams and Continuity Camera.
        let found = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external], mediaType: nil, position: .unspecified
        ).devices.filter { $0.hasMediaType(.muxed) }

        phones = found
        if let current = selectedPhone, !found.contains(current) {
            selectedPhone = nil
            teardownPhoneSession()
        }
        if selectedPhone == nil, let first = found.first {
            select(phone: first)
        }
    }

    @objc private func portFormatChanged() {
        DispatchQueue.main.async { [weak self] in self?.updatePhoneAspect() }
    }

    private func updatePhoneAspect() {
        guard let input = phoneSession.inputs.first as? AVCaptureDeviceInput else { return }
        for port in input.ports {
            guard let desc = port.formatDescription,
                  CMFormatDescriptionGetMediaType(desc) == kCMMediaType_Video else { continue }
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            if dims.width > 0, dims.height > 0 {
                phoneAspect = CGFloat(dims.width) / CGFloat(dims.height)
            }
        }
    }

    func select(phone: AVCaptureDevice) {
        selectedPhone = phone
        sessionQueue.async { [self] in
            phoneSession.beginConfiguration()
            phoneSession.inputs.forEach { phoneSession.removeInput($0) }
            phoneSession.outputs.forEach { phoneSession.removeOutput($0) }
            do {
                let input = try AVCaptureDeviceInput(device: phone)
                if phoneSession.canAddInput(input) { phoneSession.addInput(input) }
                if phoneSession.canAddOutput(phoneOutput) { phoneSession.addOutput(phoneOutput) }
                let preview = AVCaptureAudioPreviewOutput()
                preview.volume = 0
                if phoneSession.canAddOutput(preview) {
                    phoneSession.addOutput(preview)
                    DispatchQueue.main.async {
                        self.audioPreview = preview
                        preview.volume = self.monitorPhoneAudio ? 1.0 : 0.0
                    }
                }
                frameTap.alwaysDiscardsLateVideoFrames = true
                frameTap.setSampleBufferDelegate(self, queue: frameTapQueue)
                if phoneSession.canAddOutput(frameTap) { phoneSession.addOutput(frameTap) }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Couldn't open \(phone.localizedName): \(error.localizedDescription)"
                }
            }
            phoneSession.commitConfiguration()
            if !phoneSession.isRunning { phoneSession.startRunning() }
            DispatchQueue.main.async { self.updatePhoneAspect() }
        }
    }

    private func teardownPhoneSession() {
        sessionQueue.async { [self] in
            phoneSession.beginConfiguration()
            phoneSession.inputs.forEach { phoneSession.removeInput($0) }
            phoneSession.outputs.forEach { phoneSession.removeOutput($0) }
            phoneSession.commitConfiguration()
            if phoneSession.isRunning { phoneSession.stopRunning() }
        }
        audioPreview = nil
    }

    private func setupCameraSession() {
        sessionQueue.async { [self] in
            cameraSession.beginConfiguration()
            do {
                if let cam = AVCaptureDevice.default(for: .video) {
                    let input = try AVCaptureDeviceInput(device: cam)
                    if cameraSession.canAddInput(input) { cameraSession.addInput(input) }
                }
                if let mic = AVCaptureDevice.default(for: .audio) {
                    let input = try AVCaptureDeviceInput(device: mic)
                    if cameraSession.canAddInput(input) { cameraSession.addInput(input) }
                }
                if cameraSession.canAddOutput(cameraOutput) { cameraSession.addOutput(cameraOutput) }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Couldn't open the camera or microphone: \(error.localizedDescription)"
                }
            }
            cameraSession.commitConfiguration()
            if !cameraSession.isRunning { cameraSession.startRunning() }
        }
    }

    // MARK: - Recording

    func startRecording() {
        guard case .idle = phase, selectedPhone != nil else { return }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let dir = FileManager.default
            .urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Record iPhone/\(fmt.string(from: .now))", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Couldn't create the recording folder: \(error.localizedDescription)"
            return
        }

        startTimes = [:]
        finishedURLs = []
        phoneFileURL = dir.appendingPathComponent("phone.mov")
        cameraFileURL = dir.appendingPathComponent("camera.mov")

        phoneOutput.startRecording(to: phoneFileURL!, recordingDelegate: self)
        cameraOutput.startRecording(to: cameraFileURL!, recordingDelegate: self)
        phase = .recording(startedAt: .now)
    }

    func stopRecording() {
        guard case .recording = phase else { return }
        phase = .exporting(progress: 0)
        phoneOutput.stopRecording()
        cameraOutput.stopRecording()
    }

    private func exportIfBothFinished() {
        guard finishedURLs.count == 2,
              let phoneURL = phoneFileURL, let cameraURL = cameraFileURL else { return }
        // Align the two files: whichever started later gets shifted by the gap.
        let phoneStart = startTimes[phoneURL] ?? .zero
        let camStart = startTimes[cameraURL] ?? .zero
        let layout = ExportLayout(bubbleCenter: bubbleCenter, bubbleFraction: bubbleFraction,
                                  canvas: canvas.size, background: background,
                                  showBezel: showBezel)
        Task {
            do {
                let out = try await Exporter.export(
                    phoneURL: phoneURL, cameraURL: cameraURL,
                    cameraOffset: CMTimeSubtract(camStart, phoneStart),
                    layout: layout,
                    onProgress: { p in
                        Task { @MainActor in self.phase = .exporting(progress: p) }
                    })
                NSWorkspace.shared.activateFileViewerSelecting([out])
            } catch {
                self.errorMessage = "Export failed: \(error.localizedDescription). The raw recordings are saved next to it."
            }
            self.phase = .idle
        }
    }

    // MARK: - Screenshots

    /// Saves the device's current screen at native resolution as a PNG.
    func takeScreenshot() {
        guard let buffer = latestFrame.get() else {
            errorMessage = "No picture from the device yet — connect and unlock it first."
            return
        }
        let rep = NSBitmapImageRep(ciImage: CIImage(cvPixelBuffer: buffer))
        guard let png = rep.representation(using: .png, properties: [:]) else {
            errorMessage = "Couldn't turn the current frame into an image."
            return
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let dir = FileManager.default
            .urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Record iPhone", isDirectory: true)
        let url = dir.appendingPathComponent("Screenshot \(fmt.string(from: .now)).png")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try png.write(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            errorMessage = "Couldn't save the screenshot: \(error.localizedDescription)"
        }
    }
}

/// Thread-safe holder for the most recent video frame.
final class FrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    func set(_ new: CVPixelBuffer) { lock.lock(); buffer = new; lock.unlock() }
    func get() -> CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return buffer }
}

extension CaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        if let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            latestFrame.set(buffer)
        }
    }
}

extension CaptureEngine: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didStartRecordingTo fileURL: URL,
                                from connections: [AVCaptureConnection]) {
        // ponytail: host-clock-at-callback ≈ first frame time (±30ms). If lip
        // sync between phone and camera ever looks off, switch to reading the
        // first sample timestamp from each file instead.
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        Task { @MainActor in self.startTimes[fileURL] = now }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection],
                                error: Error?) {
        Task { @MainActor in
            if let error, !FileManager.default.fileExists(atPath: outputFileURL.path) {
                self.errorMessage = "Recording failed: \(error.localizedDescription)"
                self.phase = .idle
                return
            }
            self.finishedURLs.append(outputFileURL)
            self.exportIfBothFinished()
        }
    }
}
