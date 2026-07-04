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
    /// True once the phone session is actually wired up and running — not
    /// just "a device is selected". Recording is blocked until this is true,
    /// so a mid-reconnect race can't silently record nothing.
    @Published var phoneReady = false
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
    private var lastExportProgressAt = Date.now
    private var startTimes: [URL: CMTime] = [:]
    private var finishedURLs: [URL] = []
    private var phoneFileURL: URL?
    private var cameraFileURL: URL?

    // Bumped every time the phone session is torn down or rebuilt, so a
    // reconfiguration that finishes late can't clobber a newer one's state.
    private var phoneSessionGeneration = 0

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
        if let current = selectedPhone, !found.contains(where: { $0.uniqueID == current.uniqueID }) {
            // The device we were using is really gone (unplugged, locked, or
            // asleep) — not just re-enumerated. Tear down and wait; don't
            // silently keep "recording" from a connection that no longer exists.
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
        phoneReady = false
        phoneSessionGeneration += 1
        let generation = phoneSessionGeneration

        sessionQueue.async { [self] in
            phoneSession.beginConfiguration()
            phoneSession.inputs.forEach { phoneSession.removeInput($0) }
            phoneSession.outputs.forEach { phoneSession.removeOutput($0) }
            var opened = false
            do {
                let input = try AVCaptureDeviceInput(device: phone)
                if phoneSession.canAddInput(input) { phoneSession.addInput(input) }
                if phoneSession.canAddOutput(phoneOutput) { phoneSession.addOutput(phoneOutput) }
                let preview = AVCaptureAudioPreviewOutput()
                preview.volume = 0
                if phoneSession.canAddOutput(preview) {
                    phoneSession.addOutput(preview)
                    DispatchQueue.main.async {
                        guard generation == self.phoneSessionGeneration else { return }
                        self.audioPreview = preview
                        preview.volume = self.monitorPhoneAudio ? 1.0 : 0.0
                    }
                }
                frameTap.alwaysDiscardsLateVideoFrames = true
                frameTap.setSampleBufferDelegate(self, queue: frameTapQueue)
                if phoneSession.canAddOutput(frameTap) { phoneSession.addOutput(frameTap) }
                opened = true
            } catch {
                DispatchQueue.main.async {
                    guard generation == self.phoneSessionGeneration else { return }
                    self.errorMessage = "Couldn't open \(phone.localizedName): \(error.localizedDescription)"
                }
            }
            phoneSession.commitConfiguration()
            if !phoneSession.isRunning { phoneSession.startRunning() }
            DispatchQueue.main.async {
                guard generation == self.phoneSessionGeneration else { return }
                self.updatePhoneAspect()
                self.phoneReady = opened
            }
        }
    }

    private func teardownPhoneSession() {
        phoneReady = false
        phoneSessionGeneration += 1
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
        guard case .idle = phase, selectedPhone != nil, phoneReady else { return }
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

        let generation = phoneSessionGeneration
        phoneOutput.startRecording(to: phoneFileURL!, recordingDelegate: self)
        cameraOutput.startRecording(to: cameraFileURL!, recordingDelegate: self)
        phase = .recording(startedAt: .now)

        // Belt-and-suspenders: if the phone's connection was quietly torn down
        // right as we started (a reconnect/lock race), `startRecording` above
        // is a silent no-op — no file, no delegate callback, ever. Catch that
        // within a couple seconds instead of hanging at "Saving..." forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, generation == self.phoneSessionGeneration,
                  case .recording = self.phase, !self.phoneOutput.isRecording else { return }
            self.errorMessage = "The connection to your iPhone dropped right as recording started. Nothing was saved for this take — reconnect it and try again."
            self.cameraOutput.stopRecording()
            self.phase = .idle
        }
    }

    func stopRecording() {
        guard case .recording = phase else { return }
        phase = .exporting(progress: 0)
        let phoneWasRecording = phoneOutput.isRecording
        phoneOutput.stopRecording()
        cameraOutput.stopRecording()

        // Safety net: if a file never actually started recording (or a finish
        // callback never arrives for any other reason), don't sit at
        // "Saving..." forever — surface it after a generous grace period.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, case .exporting = self.phase, self.finishedURLs.count < 2 else { return }
            self.phase = .idle
            if phoneWasRecording {
                self.errorMessage = "Saving got stuck and was cancelled. Your raw recordings are still on disk in ~/Movies/Record iPhone if you want to recover them by hand."
            } else {
                self.errorMessage = "The iPhone wasn't actually recording during this take (its connection had dropped), so there's no phone video to save. Your camera footage is still on disk in ~/Movies/Record iPhone."
            }
        }
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
        NSLog("[export] starting: phone=%@ camera=%@ offset=%.3fs",
              phoneURL.lastPathComponent, cameraURL.lastPathComponent,
              CMTimeSubtract(camStart, phoneStart).seconds)
        lastExportProgressAt = .now

        // Free the Mac's single hardware video encoder for the export. Leaving
        // the live capture sessions running during a save starves the encoder
        // and can hang the export outright. The preview is just a progress bar
        // while saving anyway, so pausing costs nothing.
        let resumeSessions = pauseCaptureForExport()
        let work = Task {
            do {
                let out = try await Exporter.export(
                    phoneURL: phoneURL, cameraURL: cameraURL,
                    cameraOffset: CMTimeSubtract(camStart, phoneStart),
                    layout: layout,
                    onProgress: { p in
                        Task { @MainActor in
                            self.phase = .exporting(progress: p)
                            self.lastExportProgressAt = .now
                        }
                    })
                NSLog("[export] finished OK: %@", out.path)
                NSWorkspace.shared.activateFileViewerSelecting([out])
            } catch {
                // AVFoundation may surface our watchdog's cancel as its own
                // "cancelled" error rather than CancellationError.
                if error is CancellationError || Task.isCancelled {
                    NSLog("[export] cancelled by watchdog")
                    self.errorMessage = "Saving stalled and was stopped. Your raw recordings are safe in the same folder — the video can be rebuilt from them."
                } else {
                    NSLog("[export] FAILED: %@", String(describing: error))
                    self.errorMessage = "Export failed: \(error.localizedDescription). The raw recordings are saved next to it."
                }
            }
            resumeSessions()
            self.phase = .idle
        }

        // Watchdog: a healthy export reports progress every ~0.3s. If nothing
        // moves for 60s the export is dead (we've seen AVFoundation die
        // without ever throwing) — cancel it and tell the truth instead of
        // showing "Saving…" forever.
        Task {
            while case .exporting = self.phase {
                try? await Task.sleep(for: .seconds(10))
                guard case .exporting = self.phase else { return }
                if Date.now.timeIntervalSince(self.lastExportProgressAt) > 60 {
                    NSLog("[export] watchdog: no progress for 60s, cancelling")
                    work.cancel()
                    return
                }
            }
        }
    }

    /// Stops the live capture sessions and returns a closure that restarts the
    /// ones that were actually running. Runs synchronously so the export starts
    /// with the encoder already free.
    private func pauseCaptureForExport() -> @Sendable () -> Void {
        let phoneWasRunning = phoneSession.isRunning
        let cameraWasRunning = cameraSession.isRunning
        sessionQueue.sync {
            if phoneWasRunning { phoneSession.stopRunning() }
            if cameraWasRunning { cameraSession.stopRunning() }
        }
        return { [weak self] in
            guard let self else { return }
            self.sessionQueue.async {
                if phoneWasRunning, !self.phoneSession.isRunning { self.phoneSession.startRunning() }
                if cameraWasRunning, !self.cameraSession.isRunning { self.cameraSession.startRunning() }
            }
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
