@preconcurrency import AVFoundation
import CoreMediaIO
import AppKit
import Combine
import CoreImage

/// Capture + record. Design rules (hard-won):
/// 1. Never reconfigure the phone session on the Record hot path.
/// 2. One video consumer while recording: the sample-writer tap (preferred)
///    or MovieFileOutput. Never both. Stills share the sample tap.
/// 3. Confirm start via didStartRecording / first sample, never isRecording alone.
/// 4. Device disconnect requires multiple empty discovery scans.
/// 5. Never read AVCaptureSession.isRunning on the main thread, and never
///    tear down the preview layer while stopRunning is in flight — that
///    pair deadlocks and Force-Quits on "Connecting…".
/// 6. Never startRunning while SwiftUI is binding the preview layer.
enum PhoneConnectDecision: Equatable {
    case ignore
    case kickStart
    case rebuild
}

enum PhoneSessionStartPolicy {
    enum Action: Equatable {
        case start
        case waitForPreview
    }

    /// startRunning is unsafe until the preview layer is bound.
    static func kick(resumeWhenPreviewAttaches: Bool) -> Action {
        resumeWhenPreviewAttaches ? .waitForPreview : .start
    }

    static func timerMayStart(resumeWhenPreviewAttaches: Bool) -> Bool {
        !resumeWhenPreviewAttaches
    }
}

enum PhoneConnectPolicy {
    static func decide(
        sameDevice: Bool,
        selectInFlight: Bool,
        phoneReady: Bool,
        sessionRunning: Bool,
        phaseIdle: Bool,
        editorOpen: Bool,
        wireless: Bool
    ) -> PhoneConnectDecision {
        guard phaseIdle, !editorOpen, !wireless else { return .ignore }
        if selectInFlight { return .ignore }
        if sameDevice {
            if phoneReady && sessionRunning { return .ignore }
            if phoneReady && !sessionRunning { return .kickStart }
            return .rebuild
        }
        return .rebuild
    }

    static func shouldTimerReconnect(
        selected: Bool,
        phoneReady: Bool,
        phonesPresent: Bool,
        selectInFlight: Bool,
        sessionRunning: Bool
    ) -> PhoneConnectDecision {
        guard selected, !selectInFlight else { return .ignore }
        // After Stop / Home the session is often dead and a kick is not
        // enough — rebuild so the iPhone picture comes back.
        if !sessionRunning { return .rebuild }
        if !phoneReady && phonesPresent { return .rebuild }
        return .ignore
    }
}

@MainActor
final class CaptureEngine: NSObject, ObservableObject {

    enum Phase: Equatable {
        case idle
        case arming
        case recording(startedAt: Date)
        case finishing
    }

    struct RecentProject: Identifiable, Equatable {
        let id: URL
        let name: String
        let date: Date
        let hasExport: Bool
        var dir: URL { id }

        /// Folder names are raw timestamps ("2026-07-18 14.03.22"); show
        /// "Today at 2:03 PM" style instead.
        var displayName: String {
            let parser = DateFormatter()
            parser.dateFormat = "yyyy-MM-dd HH.mm.ss"
            guard let d = parser.date(from: name) else { return name }
            let cal = Calendar.current
            let time = d.formatted(date: .omitted, time: .shortened)
            if cal.isDateInToday(d) { return "Today at \(time)" }
            if cal.isDateInYesterday(d) { return "Yesterday at \(time)" }
            return d.formatted(date: .abbreviated, time: .shortened)
        }
    }

    @Published var phones: [AVCaptureDevice] = []
    @Published var selectedPhone: AVCaptureDevice?
    @Published var phoneReady = false
    @Published var phase: Phase = .idle
    @Published var editor: EditorState?
    @Published var errorMessage: String?
    @Published var recentProjects: [RecentProject] = []
    /// Live speaker/headphones feed of the phone's audio (not the file).
    /// Defaults on so preview/record match Bezel-style monitoring; user can mute.
    @Published var monitorPhoneAudio = true {
        didSet { applyMonitorVolume() }
    }
    @Published var bubbleCenter = CGPoint(x: 0.82, y: 0.78)
    @Published var bubbleFraction: CGFloat = 0.22
    @Published var presenterLayout: PresenterLayout = .floating
    @Published var phoneAspect: CGFloat = 0.462
    @Published var background: BackgroundPreset = .snow
    @Published var canvas: CanvasPreset = .device
    @Published var showBezel = false
    @Published var phoneScale: CGFloat = ExportLayout.phoneHeightFraction
    @Published var cameraEnabled = false
    @Published var cameraShape: CameraShape = .circle
    @Published var ringRGB: [CGFloat] = [1, 1, 1]
    @Published var frameStyle: DeviceFrameStyle = .none
    @Published var screenCorners = true
    @Published var showBorder = false
    @Published var customBackgroundRGB: [CGFloat]? = [1, 1, 1]
    /// Bundled wallpaper id. When set, the picture wins over the solid color.
    @Published var wallpaperID: String? = nil
    @Published var deviceOnLeft = true
    @Published var cameraLeads = false
    @Published var overlapArrangement = false
    @Published var splitBalance: CGFloat = 0.55
    @Published var splitGap: CGFloat = 0.12
    @Published var soundMode: SoundMode = .both
    /// 0…1 — how loud the iPhone’s own sound is (games, videos, speakers).
    @Published var phoneAudioLevel: CGFloat = 1 {
        didSet { applyMonitorVolume() }
    }
    /// 0…1 — how loud the Mac microphone is.
    @Published var micAudioLevel: CGFloat = 1
    @Published var setupOpen = false
    @Published var discardedLastTake = false
    @Published var availableCameras: [AVCaptureDevice] = []
    @Published var availableMics: [AVCaptureDevice] = []
    @Published var selectedCamera: AVCaptureDevice?
    @Published var selectedMic: AVCaptureDevice?
    /// Cable (USB) vs wireless (AirPlay). Wireless is opt-in so a USB
    /// plug-in doesn't yank a Screen Mirroring session.
    enum ConnectionKind: String {
        case none
        case cable
        case wireless
    }
    @Published var connectionKind: ConnectionKind = .none
    @Published var showConnectSheet = false
    let airplay = AirPlayMirror()
    private var airplayWatch: AnyCancellable?
    /// Isolated so the meter can tick without redrawing the live phone preview.
    let micMeter = MicMeterState()
    var micLevelDB: Float { micMeter.db }
    @Published var pinned = false {
        didSet {
            let level: NSWindow.Level = pinned ? .floating : .normal
            NSApp.windows.first { $0.isVisible }?.level = level
        }
    }

    nonisolated(unsafe) let phoneSession = AVCaptureSession()
    nonisolated(unsafe) let cameraSession = AVCaptureSession()

    nonisolated(unsafe) private let phoneOutput = AVCaptureMovieFileOutput()
    nonisolated(unsafe) private let cameraOutput = AVCaptureMovieFileOutput()
    private var audioPreview: AVCaptureAudioPreviewOutput?
    /// Shared with the preview layer. Attaching the layer and startRunning
    /// must never overlap — that pair aborts in AVCaptureSession _setRunning.
    let sessionQueue = DispatchQueue(label: "capture.session")

    /// One video tap for stills and (preferred) sample-writer recording.
    nonisolated(unsafe) private let frameTap = AVCaptureVideoDataOutput()
    private let frameTapQueue = DispatchQueue(label: "capture.frametap")
    nonisolated(unsafe) private let phoneAudioOut = AVCaptureAudioDataOutput()
    private let phoneAudioQueue = DispatchQueue(label: "capture.phone.audio")
    private let phoneSamples = PhoneSampleWriter()
    nonisolated(unsafe) private var phoneUsesSampleWriter = false
    let latestFrame = FrameStore()
    nonisolated(unsafe) private var frameTapAttached = false

    private var startTimes: [URL: CMTime] = [:]
    private var finishedURLs: [URL] = []
    private var phoneFileURL: URL?
    private var cameraFileURL: URL?
    private var phonePartNumber = 1
    private var phoneWriterWatch: Timer?
    private var expectedFinishes = 0
    private var phoneStartedOK = false
    private var cameraStartedOK = false
    /// True once the camera movie writer has closed (success or fail).
    /// We must not stop the camera session until this is true, or camera.mov
    /// is thrown away — that's the "clip didn't save" bug.
    private var cameraWriterClosed = false
    /// Stop hides the live picture so Stop doesn't keep playing the phone.
    @Published var freezeLivePreview = false
    /// After the editor, land on Home (recents + cable/wireless) instead of
    /// jumping straight back to the live camera.
    @Published var showHome = true
    /// True while a take is being prepared for the editor. Keep this on
    /// screen (Home or live) — flipping views mid-open deadlocks the camera.
    @Published private(set) var editorOpening = false
    @Published private(set) var openingStatus: String?
    private var recordGeneration = 0
    private var cancelArming = false
    private var missingDeviceStrikes = 0
    private var phoneSessionGeneration = 0
    private var phoneSelectInFlight = false
    /// Cached on the session queue — never read `phoneSession.isRunning` on main.
    @Published private(set) var phoneSessionRunning = false
    private var cameraSessionRunning = false
    private var phoneMovieArmed = false
    private var resumePhoneWhenPreviewAttaches = false
    private var resumeCameraWhenPreviewAttaches = false
    /// True after SwiftUI bound the phone preview layer (cleared on Home).
    private var phonePreviewAttached = false
    /// Background stitch of phone.mov + camera.mov → Recording.mp4.
    private var combineWorker: Process?
    var combineInFlight: Bool { combineWorker != nil }

    // MARK: - Setup

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
        phoneAudioLevel = CGFloat(AppSettings.shared.defaultPhoneAudio)
        micAudioLevel = CGFloat(AppSettings.shared.defaultMicAudio)
        Self.allowScreenCaptureDevices()
        NotificationCenter.default.addObserver(
            self, selector: #selector(devicesChanged),
            name: AVCaptureDevice.wasConnectedNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(devicesChanged),
            name: AVCaptureDevice.wasDisconnectedNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(portFormatChanged(_:)),
            name: AVCaptureInput.Port.formatDescriptionDidChangeNotification, object: nil)
        phoneSamples.onVideoBegan = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if let url = self.phoneFileURL {
                    self.startTimes[url] = CMClockGetTime(CMClockGetHostTimeClock())
                }
                self.phoneStartedOK = true
                NSLog("[record] phone sample writer started")
                self.promoteToRecordingIfReady()
            }
        }
        phoneSamples.onVideoFailed = { [weak self] in
            DispatchQueue.main.async { self?.handleSampleVideoDied() }
        }
        phoneSamples.onVideoNeedsRestart = { [weak self] in
            DispatchQueue.main.async { self?.handleSampleVideoDied() }
        }

        // Write an index every second so Stop can open the file without
        // waiting for a final header (that wait is what froze the app).
        let fragment = CMTime(seconds: 1, preferredTimescale: 600)
        phoneOutput.movieFragmentInterval = fragment
        cameraOutput.movieFragmentInterval = fragment
        airplayWatch = airplay.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        airplay.onLinkChange = { [weak self] machine in
            guard let self else { return }
            switch machine.link {
            case .live:
                self.noteAirPlayConnected()
            case .locked:
                self.phoneReady = true
                self.showConnectSheet = false
            case .dropped:
                self.phoneReady = true
                self.showConnectSheet = false
                if machine.shouldStopRecording {
                    switch self.phase {
                    case .arming, .recording:
                        self.stopRecording()
                    default:
                        break
                    }
                }
            default:
                break
            }
        }

        Task {
            // Home must not wake the Mac camera or the cable session.
            // Listing cameras (especially Continuity) can turn the green
            // light on. Wait until Cable, Wireless, or Live preview.
            self.refreshRecentProjects()
        }

        // Recover from stuck "Reconnecting…" without stacking select().
        Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard case .idle = self.phase, self.editor == nil,
                      !self.editorOpening, !self.freezeLivePreview else { return }
                if !PhoneSessionStartPolicy.timerMayStart(
                    resumeWhenPreviewAttaches: self.resumePhoneWhenPreviewAttaches
                ) {
                    return
                }
                switch PhoneConnectPolicy.shouldTimerReconnect(
                    selected: self.selectedPhone != nil,
                    phoneReady: self.phoneReady,
                    phonesPresent: !self.phones.isEmpty,
                    selectInFlight: self.phoneSelectInFlight,
                    sessionRunning: self.phoneSessionRunning
                ) {
                case .ignore:
                    break
                case .kickStart:
                    self.kickSessionRunning()
                case .rebuild:
                    self.reconnectIfNeeded()
                }
            }
        }
        // Only publish when the on-screen meter would actually change.
        Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.soundMode != .off else { return }
                guard self.editor == nil, !self.editorOpening,
                      !self.freezeLivePreview, !self.showHome else { return }
                let output = self.cameraOutput
                self.sessionQueue.async {
                    let db = output.connection(with: .audio)?
                        .audioChannels.map(\.averagePowerLevel).max() ?? -160
                    DispatchQueue.main.async { self.micMeter.update(db) }
                }
            }
        }
    }

    @objc private func devicesChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            if self.showHome {
                // Do not list Continuity/Mac cameras on Home — that scan
                // turns the green light on before Cable or Wireless.
                return
            }
            self.refreshPhones()
            self.refreshAVDevices()
        }
    }

    func refreshPhones() {
        let found = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external], mediaType: nil, position: .unspecified
        ).devices.filter { $0.hasMediaType(.muxed) }
        applyDiscoveredPhones(found)
    }

    private func applyDiscoveredPhones(_ found: [AVCaptureDevice]) {
        phones = found
        if let current = selectedPhone, !found.contains(where: { $0.uniqueID == current.uniqueID }) {
            missingDeviceStrikes += 1
            if missingDeviceStrikes >= 3 {
                switch phase {
                case .recording, .arming:
                    abortRecording(reason: "Your device disconnected or locked during the recording. Unlock it, reconnect, and try again.")
                    fallthrough
                case .idle:
                    teardownPhoneSession(clearSelection: true)
                case .finishing:
                    break
                }
                missingDeviceStrikes = 0
            }
        } else {
            missingDeviceStrikes = 0
        }
        if selectedPhone == nil, let first = found.first, case .idle = phase, editor == nil,
           connectionKind != .wireless, !showHome {
            connectionKind = .cable
            select(phone: first)
        }
    }

    @objc private func portFormatChanged(_ notification: Notification) {
        let port = notification.object as? AVCaptureInput.Port
        let audioish = port == nil
            || port?.mediaType == .audio
            || port?.mediaType == .muxed
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let aspect = Self.aspectFromSession(self.phoneSession)
            DispatchQueue.main.async {
                if let aspect { self.phoneAspect = aspect }
                if audioish {
                    switch self.phase {
                    case .arming, .recording:
                        self.phoneSamples.noteAudioFormatChanged()
                    default:
                        break
                    }
                }
            }
        }
    }

    /// Must be called on sessionQueue. Do not read session inputs on main.
    nonisolated private static func aspectFromSession(_ session: AVCaptureSession) -> CGFloat? {
        guard let input = session.inputs.first as? AVCaptureDeviceInput else { return nil }
        for port in input.ports {
            guard let desc = port.formatDescription,
                  CMFormatDescriptionGetMediaType(desc) == kCMMediaType_Video else { continue }
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            if dims.width > 0, dims.height > 0 {
                return CGFloat(dims.width) / CGFloat(dims.height)
            }
        }
        return nil
    }

    /// Call when the window appears or user hits Retry — recovers stuck
    /// "Reconnecting…" when the device is selected but the session died.
    func reconnectIfNeeded() {
        guard case .idle = phase, editor == nil, !showHome else { return }
        guard connectionKind != .wireless else { return }
        refreshPhones()
        // Still try the last selected phone even if discovery is empty —
        // stopping the session after a take often hides it from the list
        // for a second, which used to leave a blank canvas.
        if let phone = selectedPhone {
            select(phone: phone)
            if phones.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                    guard let self, case .idle = self.phase, self.editor == nil else { return }
                    self.refreshPhones()
                    if let again = self.selectedPhone,
                       self.phones.contains(where: { $0.uniqueID == again.uniqueID }) {
                        self.select(phone: again)
                    } else if let first = self.phones.first {
                        self.select(phone: first)
                    }
                }
            }
        } else if let first = phones.first {
            select(phone: first)
        }
    }

    /// Wake the cable phone (and Mac camera) after Home or the editor.
    func ensureLivePreview() {
        guard case .idle = phase, editor == nil else { return }
        freezeLivePreview = false
        if showHome {
            stopMacCamera()
            return
        }
        requestPhoneStartAfterPreview()
        if cameraEnabled || soundMode == .mic || soundMode == .both {
            resumeCameraWhenPreviewAttaches = true
        }
        refreshAVDevices()
        if connectionKind == .wireless { return }
        reconnectIfNeeded()
        if cameraEnabled || soundMode == .mic || soundMode == .both {
            setupCameraSession()
        }
    }

    func stopMacCamera() {
        resumeCameraWhenPreviewAttaches = false
        sessionQueue.async { [self] in
            if cameraSession.isRunning { cameraSession.stopRunning() }
            DispatchQueue.main.async { self.cameraSessionRunning = false }
        }
    }

    var hasLiveDevice: Bool {
        switch connectionKind {
        case .wireless: return airplay.link.holdsPreview || airplay.isConnected
        case .cable, .none: return selectedPhone != nil && phoneReady
        }
    }

    func startWireless() {
        showHome = false
        guard case .idle = phase, editor == nil else { return }
        phoneReady = false
        showConnectSheet = true
        refreshAVDevices()
        if cameraEnabled || soundMode == .mic || soundMode == .both {
            setupCameraSession()
        }
        // Stop the USB session first, then drop the preview. Doing both at
        // once deadlocks (preview dealloc vs stopRunning).
        if selectedPhone != nil || connectionKind == .cable {
            phoneSelectInFlight = false
            phoneSessionGeneration += 1
            let generation = phoneSessionGeneration
            sessionQueue.async { [self] in
                if phoneSession.isRunning { phoneSession.stopRunning() }
                phoneSession.beginConfiguration()
                phoneSession.inputs.forEach { phoneSession.removeInput($0) }
                phoneSession.outputs.forEach { phoneSession.removeOutput($0) }
                phoneSession.commitConfiguration()
                frameTapAttached = false
                phoneUsesSampleWriter = false
                DispatchQueue.main.async {
                    guard generation == self.phoneSessionGeneration else { return }
                    self.phoneSessionRunning = false
                    self.phoneMovieArmed = false
                    self.phonePreviewAttached = false
                    self.audioPreview = nil
                    self.selectedPhone = nil
                    self.connectionKind = .wireless
                    self.airplay.start()
                }
            }
            return
        }
        connectionKind = .wireless
        airplay.start()
    }

    func cancelWireless() {
        airplay.stop()
        if connectionKind == .wireless {
            connectionKind = .none
            phoneReady = false
        }
        showConnectSheet = false
    }

    func preferCable() {
        showHome = false
        airplay.stop()
        connectionKind = .cable
        showConnectSheet = false
        refreshAVDevices()
        reconnectIfNeeded()
        if cameraEnabled || soundMode == .mic || soundMode == .both {
            setupCameraSession()
        }
    }

    func noteAirPlayConnected() {
        guard connectionKind == .wireless else { return }
        phoneReady = true
        phoneAspect = airplay.aspect
        showConnectSheet = false
    }

    func noteAirPlayDisconnected() {
        guard connectionKind == .wireless else { return }
        phoneReady = false
    }

    func select(phone: AVCaptureDevice) {
        guard case .idle = phase, editor == nil else { return }
        if connectionKind == .wireless { airplay.stop() }
        connectionKind = .cable

        let same = selectedPhone?.uniqueID == phone.uniqueID
        switch PhoneConnectPolicy.decide(
            sameDevice: same,
            selectInFlight: phoneSelectInFlight,
            phoneReady: phoneReady,
            sessionRunning: phoneSessionRunning,
            phaseIdle: true,
            editorOpen: editor != nil,
            wireless: false
        ) {
        case .ignore:
            selectedPhone = phone
            return
        case .kickStart:
            selectedPhone = phone
            kickSessionRunning()
            return
        case .rebuild:
            break
        }

        selectedPhone = phone
        if !same { phoneReady = false }
        phoneSelectInFlight = true
        phoneSessionGeneration += 1
        let generation = phoneSessionGeneration
        let name = phone.localizedName
        let phoneID = phone.uniqueID

        sessionQueue.async { [self] in
            let alreadyWired = phoneSession.inputs.contains {
                ($0 as? AVCaptureDeviceInput)?.device.uniqueID == phoneID
            } && (phoneSession.outputs.contains(phoneOutput)
                  || phoneSession.outputs.contains(frameTap))
            let usesSamples = phoneSession.outputs.contains(frameTap)
                && !phoneSession.outputs.contains(phoneOutput)

            if alreadyWired {
                phoneUsesSampleWriter = usesSamples
                let aspect = Self.aspectFromSession(phoneSession)
                DispatchQueue.main.async {
                    guard generation == self.phoneSessionGeneration else { return }
                    self.phoneSelectInFlight = false
                    self.phoneMovieArmed = true
                    if let aspect { self.phoneAspect = aspect }
                    self.phoneReady = true
                    self.requestPhoneStartAfterPreview()
                }
                return
            }

            // Stop first so reconfiguration is clean on flaky USB devices.
            if phoneSession.isRunning { phoneSession.stopRunning() }

            phoneSession.beginConfiguration()
            phoneSession.inputs.forEach { phoneSession.removeInput($0) }
            phoneSession.outputs.forEach { phoneSession.removeOutput($0) }
            frameTapAttached = false
            phoneUsesSampleWriter = false

            var inputOK = false
            var recordOK = false
            var openError: String?
            do {
                let input = try AVCaptureDeviceInput(device: phone)
                if phoneSession.canAddInput(input) {
                    phoneSession.addInput(input)
                    inputOK = true
                } else {
                    openError = "Couldn't attach \(name) as input."
                }

                // Prefer separate video/audio taps so a YouTube/ad format
                // change cannot kill the picture writer.
                frameTap.alwaysDiscardsLateVideoFrames = true
                frameTap.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                frameTap.setSampleBufferDelegate(self, queue: frameTapQueue)
                phoneAudioOut.setSampleBufferDelegate(self, queue: phoneAudioQueue)

                var addedVideoTap = false
                if phoneSession.canAddOutput(frameTap) {
                    phoneSession.addOutput(frameTap)
                    addedVideoTap = true
                }
                if addedVideoTap, phoneSession.canAddOutput(phoneAudioOut) {
                    phoneSession.addOutput(phoneAudioOut)
                }

                if !addedVideoTap {
                    phoneOutput.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
                    if phoneSession.canAddOutput(phoneOutput) {
                        phoneSession.addOutput(phoneOutput)
                        recordOK = true
                    } else {
                        openError = "Couldn't attach the movie recorder for \(name)."
                    }
                }

                // Live monitor only (no video). Stays attached in every phase;
                // volume is toggled so we never rebuild the graph on Record.
                let preview = AVCaptureAudioPreviewOutput()
                preview.volume = 1
                if phoneSession.canAddOutput(preview) {
                    phoneSession.addOutput(preview)
                    DispatchQueue.main.async {
                        guard generation == self.phoneSessionGeneration else { return }
                        self.audioPreview = preview
                        self.applyMonitorVolume()
                    }
                }
            } catch {
                openError = error.localizedDescription
            }
            phoneSession.commitConfiguration()

            if phoneSession.outputs.contains(frameTap),
               !frameTap.connections.isEmpty {
                phoneUsesSampleWriter = true
                frameTapAttached = true
                recordOK = true
                for c in frameTap.connections { c.isEnabled = true }
                // Muxed iPhones sometimes expose .muxed ports, not .audio.
                if phoneSession.outputs.contains(phoneAudioOut),
                   phoneAudioOut.connections.isEmpty {
                    phoneSession.beginConfiguration()
                    phoneSession.removeOutput(phoneAudioOut)
                    phoneSession.commitConfiguration()
                }
            } else if phoneSession.outputs.contains(frameTap) {
                phoneSession.beginConfiguration()
                phoneSession.removeOutput(frameTap)
                if phoneSession.outputs.contains(phoneAudioOut) {
                    phoneSession.removeOutput(phoneAudioOut)
                }
                phoneOutput.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
                if phoneSession.canAddOutput(phoneOutput) {
                    phoneSession.addOutput(phoneOutput)
                    recordOK = true
                }
                frameTap.alwaysDiscardsLateVideoFrames = true
                frameTap.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                frameTap.setSampleBufferDelegate(self, queue: frameTapQueue)
                if phoneSession.canAddOutput(frameTap) {
                    phoneSession.addOutput(frameTap)
                    frameTapAttached = true
                    for c in frameTap.connections { c.isEnabled = true }
                }
                phoneSession.commitConfiguration()
                phoneUsesSampleWriter = false
            }

            if recordOK && !phoneUsesSampleWriter {
                for c in phoneOutput.connections { c.isEnabled = true }
            }
            if recordOK {
                NSLog("[record] phone graph: %@", phoneUsesSampleWriter
                      ? (phoneSession.outputs.contains(phoneAudioOut)
                         ? "sample writer (video+audio taps)"
                         : "sample writer (video tap only; muxed audio tap unavailable)")
                      : "MovieFileOutput fallback")
            }

            let ready = inputOK && recordOK
            let aspect = Self.aspectFromSession(phoneSession)
            DispatchQueue.main.async {
                guard generation == self.phoneSessionGeneration else { return }
                self.phoneSelectInFlight = false
                self.phoneMovieArmed = ready
                if let aspect { self.phoneAspect = aspect }
                self.phoneReady = ready
                if !ready {
                    self.errorMessage = openError
                        ?? "Couldn't connect to \(name). Unlock it, reseat the cable, then tap Retry."
                } else {
                    self.requestPhoneStartAfterPreview()
                }
            }
        }
    }

    /// Fresh connect starts only after the preview layer is bound.
    private func requestPhoneStartAfterPreview() {
        resumePhoneWhenPreviewAttaches = true
        if phonePreviewAttached {
            previewDidAttach(to: phoneSession)
        }
    }

    /// Keep trying to start the session if USB was slow to wake.
    /// No-op while a preview bind is in flight (layer not bound yet).
    private func kickSessionRunning() {
        if PhoneSessionStartPolicy.kick(
            resumeWhenPreviewAttaches: resumePhoneWhenPreviewAttaches
        ) == .waitForPreview {
            return
        }
        sessionQueue.async { [self] in
            if !phoneSession.isRunning {
                phoneSession.startRunning()
            }
            let running = phoneSession.isRunning
            let aspect = Self.aspectFromSession(phoneSession)
            DispatchQueue.main.async { [weak self] in
                guard let self, case .idle = self.phase else { return }
                self.phoneSessionRunning = running
                if let aspect { self.phoneAspect = aspect }
                if running { self.phoneReady = true }
            }
        }
    }

    /// Enable stills tap if it was added in select() (no session rebuild).
    private func attachFrameTapForStills() {
        sessionQueue.async { [self] in
            if frameTapAttached {
                frameTap.setSampleBufferDelegate(self, queue: frameTapQueue)
                for c in frameTap.connections { c.isEnabled = true }
                return
            }
            // Session may have been rebuilt without the tap — add it only when idle.
            guard phoneSession.inputs.isEmpty == false else { return }
            phoneSession.beginConfiguration()
            frameTap.alwaysDiscardsLateVideoFrames = true
            frameTap.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            frameTap.setSampleBufferDelegate(self, queue: frameTapQueue)
            if phoneSession.canAddOutput(frameTap) {
                phoneSession.addOutput(frameTap)
                frameTapAttached = true
                for c in frameTap.connections { c.isEnabled = true }
            }
            phoneSession.commitConfiguration()
        }
    }

    /// Sample-writer path keeps the video tap (it is the recorder). Movie
    /// fallback still drops the tap so MovieFileOutput is the only consumer.
    func prepareForRecording() {
        detachFrameTapForRecording {}
    }

    func abortPrepareForRecording() {
        attachFrameTapForStills()
    }

    private func detachFrameTapForRecording(completion: @escaping () -> Void) {
        sessionQueue.async { [self] in
            if phoneUsesSampleWriter {
                frameTap.setSampleBufferDelegate(self, queue: frameTapQueue)
                for c in frameTap.connections { c.isEnabled = true }
                completion()
                return
            }
            frameTap.setSampleBufferDelegate(nil, queue: nil)
            if phoneSession.outputs.contains(frameTap) {
                phoneSession.beginConfiguration()
                phoneSession.removeOutput(frameTap)
                phoneSession.commitConfiguration()
                frameTapAttached = false
            }
            for c in phoneOutput.connections { c.isEnabled = true }
            completion()
        }
    }

    private func teardownPhoneSession(clearSelection: Bool = false) {
        phoneReady = false
        phoneSelectInFlight = false
        phoneMovieArmed = false
        phoneSessionGeneration += 1
        let generation = phoneSessionGeneration
        sessionQueue.async { [self] in
            if phoneSession.isRunning { phoneSession.stopRunning() }
            phoneSession.beginConfiguration()
            phoneSession.inputs.forEach { phoneSession.removeInput($0) }
            phoneSession.outputs.forEach { phoneSession.removeOutput($0) }
            phoneSession.commitConfiguration()
            frameTapAttached = false
            phoneUsesSampleWriter = false
            DispatchQueue.main.async {
                guard generation == self.phoneSessionGeneration else { return }
                self.phoneSessionRunning = false
                self.phonePreviewAttached = false
                self.audioPreview = nil
                if clearSelection { self.selectedPhone = nil }
            }
        }
    }

    /// Lists selectable cameras and microphones and keeps selections valid.
    func refreshAVDevices() {
        let cams = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video, position: .unspecified).devices
        let mics = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified).devices
        availableCameras = cams
        availableMics = mics
        if let cur = selectedCamera, !cams.contains(where: { $0.uniqueID == cur.uniqueID }) {
            selectedCamera = nil
        }
        if let cur = selectedMic, !mics.contains(where: { $0.uniqueID == cur.uniqueID }) {
            selectedMic = nil
        }
        if selectedMic == nil {
            selectedMic = Self.preferredMicrophone(from: mics)
        }
    }

    /// Do not silently follow the Mac's default input — that jumps to AirPods
    /// whenever they connect. Remember the last pick, and skip headset mics.
    static func preferredMicrophone(from mics: [AVCaptureDevice]) -> AVCaptureDevice? {
        let saved = UserDefaults.standard.string(forKey: "recordiphone.selectedMicID")
        if let saved, let match = mics.first(where: { $0.uniqueID == saved }) {
            return match
        }
        if let shure = mics.first(where: { $0.localizedName.localizedCaseInsensitiveContains("shure") }) {
            return shure
        }
        if let builtin = mics.first(where: {
            $0.localizedName.localizedCaseInsensitiveContains("macbook")
                || $0.localizedName.localizedCaseInsensitiveContains("built-in")
        }) {
            return builtin
        }
        if let wired = mics.first(where: { !isHeadsetMicrophone($0) }) {
            return wired
        }
        return mics.first ?? AVCaptureDevice.default(for: .audio)
    }

    static func isHeadsetMicrophone(_ device: AVCaptureDevice) -> Bool {
        let name = device.localizedName.lowercased()
        return name.contains("airpods") || name.contains("hands-free")
            || name.contains("headset") || name.contains("earbud")
    }

    func select(camera: AVCaptureDevice) {
        guard case .idle = phase else { return }
        let already = cameraEnabled && selectedCamera?.uniqueID == camera.uniqueID && cameraSessionRunning
        selectedCamera = camera
        cameraEnabled = true
        if already { return }
        Task { await ensureCameraPermissionAndStart() }
    }

    func select(mic: AVCaptureDevice) {
        guard case .idle = phase else { return }
        let already = selectedMic?.uniqueID == mic.uniqueID && cameraSessionRunning
        selectedMic = mic
        UserDefaults.standard.set(mic.uniqueID, forKey: "recordiphone.selectedMicID")
        if already { return }
        Task { await ensureMicPermissionAndStart() }
    }

    func setCameraEnabled(_ on: Bool) {
        guard cameraEnabled != on else { return }
        cameraEnabled = on
        if on {
            let nextSound = SoundPolicy.modeWhenTurningCameraOn(current: soundMode)
            if nextSound != soundMode { setSoundMode(nextSound) }
            Task { await ensureCameraPermissionAndStart() }
        } else {
            setupCameraSession()
        }
    }

    func setSoundMode(_ mode: SoundMode) {
        let changed = soundMode != mode
        soundMode = mode
        if mode == .device || mode == .both { monitorPhoneAudio = true }
        applyMonitorVolume()
        guard changed else { return }
        if mode == .mic || mode == .both {
            Task { await ensureMicPermissionAndStart() }
        } else {
            // Drop the mic input only — do not tear down the camera picture.
            setupCameraSession()
        }
    }

    private func ensureCameraPermissionAndStart() async {
        let ok = await AVCaptureDevice.requestAccess(for: .video)
        if !ok {
            errorMessage = "Camera access was denied. Enable it in System Settings → Privacy & Security."
            cameraEnabled = false
            return
        }
        refreshAVDevices()
        setupCameraSession()
    }

    private func ensureMicPermissionAndStart() async {
        let ok = await AVCaptureDevice.requestAccess(for: .audio)
        if !ok {
            errorMessage = "Microphone access was denied. Enable it in System Settings → Privacy & Security."
            soundMode = .off
            return
        }
        refreshAVDevices()
        setupCameraSession()
    }

    /// Updates camera/mic inputs only when the device actually changed.
    /// Tearing the graph down on every Setup tap is what made the bubble blink.
    private func setupCameraSession() {
        let wantCam = cameraEnabled ? (selectedCamera ?? AVCaptureDevice.default(for: .video)) : nil
        let wantMic: AVCaptureDevice? = {
            guard soundMode == .mic || soundMode == .both else { return nil }
            return selectedMic ?? Self.preferredMicrophone(from: availableMics)
                ?? AVCaptureDevice.default(for: .audio)
        }()
        sessionQueue.async { [self] in
            func input(for media: AVMediaType) -> AVCaptureDeviceInput? {
                cameraSession.inputs.compactMap { $0 as? AVCaptureDeviceInput }
                    .first { $0.device.hasMediaType(media) }
            }
            let haveCam = input(for: .video)
            let haveMic = input(for: .audio)
            let camSame = haveCam?.device.uniqueID == wantCam?.uniqueID
            let micSame = haveMic?.device.uniqueID == wantMic?.uniqueID
            if camSame && micSame {
                let shouldRun = wantCam != nil || wantMic != nil
                if shouldRun, !cameraSession.isRunning { cameraSession.startRunning() }
                if !shouldRun, cameraSession.isRunning { cameraSession.stopRunning() }
                let running = cameraSession.isRunning
                DispatchQueue.main.async { self.cameraSessionRunning = running }
                return
            }
            cameraSession.beginConfiguration()
            do {
                if !camSame {
                    if let haveCam { cameraSession.removeInput(haveCam) }
                    if let wantCam {
                        let input = try AVCaptureDeviceInput(device: wantCam)
                        if cameraSession.canAddInput(input) { cameraSession.addInput(input) }
                    }
                }
                if !micSame {
                    if let haveMic { cameraSession.removeInput(haveMic) }
                    if let wantMic {
                        let input = try AVCaptureDeviceInput(device: wantMic)
                        if cameraSession.canAddInput(input) { cameraSession.addInput(input) }
                    }
                }
                if !cameraSession.outputs.contains(cameraOutput),
                   cameraSession.canAddOutput(cameraOutput) {
                    cameraSession.addOutput(cameraOutput)
                    cameraOutput.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Couldn't open the camera or microphone: \(error.localizedDescription)"
                }
            }
            cameraSession.commitConfiguration()
            let shouldRun = wantCam != nil || wantMic != nil
            if shouldRun, !cameraSession.isRunning { cameraSession.startRunning() }
            if !shouldRun, cameraSession.isRunning { cameraSession.stopRunning() }
            for c in cameraOutput.connections { c.isEnabled = true }
            let running = cameraSession.isRunning
            DispatchQueue.main.async { self.cameraSessionRunning = running }
        }
    }

    private func applyMonitorVolume() {
        // Preview output stays attached in every phase — only volume changes —
        // so monitoring during a recording is safe (no graph rebuild on the
        // hot path). Play live only when Sound includes device audio and the
        // user hasn't muted. Headphones avoid echo into a Mac mic take.
        let wantsDevice = soundMode == .device || soundMode == .both
        audioPreview?.volume = (monitorPhoneAudio && wantsDevice) ? Float(phoneAudioLevel) : 0.0
    }

    // MARK: - Recording

    func resetMixToDefaults() {
        phoneAudioLevel = CGFloat(AppSettings.shared.defaultPhoneAudio)
        micAudioLevel = CGFloat(AppSettings.shared.defaultMicAudio)
    }

    func goHome() {
        showHome = true
        setupOpen = false
        phonePreviewAttached = false
        stopMacCamera()
        resetMixToDefaults()
    }

    func enterLive() {
        showHome = false
        resetMixToDefaults()
        refreshAVDevices()
        ensureLivePreview()
    }

    /// Start the mic file during the 3-2-1 count so the first words after
    /// "go" are not lost to camera spin-up.
    func prearmRecording() {
        showHome = false
        guard case .idle = phase, phoneReady, editor == nil else { return }
        beginArming(startPhoneImmediately: false)
    }

    func startRecording() {
        showHome = false
        if case .arming = phase {
            finishArmingPhone()
            return
        }
        guard case .idle = phase, phoneReady, editor == nil else { return }
        beginArming(startPhoneImmediately: true)
    }

    private func beginArming(startPhoneImmediately: Bool) {
        if connectionKind == .wireless {
            startAirPlayRecording(startPhoneImmediately: startPhoneImmediately)
            return
        }
        guard selectedPhone != nil else { return }
        guard phoneSessionRunning, phoneMovieArmed else {
            errorMessage = "Device isn't ready to record. Unlock it and wait for the preview, then try again."
            return
        }
        let needsMic = soundMode == .mic || soundMode == .both
        if cameraEnabled || needsMic {
            guard cameraSessionRunning else {
                errorMessage = cameraEnabled
                    ? "Camera isn't ready. Check camera permissions in System Settings."
                    : "Microphone isn't ready. Check microphone permissions in System Settings."
                return
            }
        }
        if needsMic {
            guard cameraOutput.connection(with: .audio)?.audioChannels.isEmpty == false else {
                errorMessage = "The selected microphone has no audio signal. Choose another microphone and try again."
                return
            }
        }

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
        expectedFinishes = (cameraEnabled || needsMic) ? 2 : 1
        phoneStartedOK = false
        cameraStartedOK = false
        cameraWriterClosed = expectedFinishes < 2
        cancelArming = false
        discardedLastTake = false
        editorOpening = false
        openingStatus = nil
        resetMixToDefaults()
        phonePartNumber = 1
        phoneFileURL = PhoneSegments.url(in: dir, index: 1)
        cameraFileURL = (cameraEnabled || needsMic)
            ? dir.appendingPathComponent("camera.mov")
            : phoneFileURL
        recordGeneration += 1
        let gen = recordGeneration
        writeTakeIntent(in: dir)

        phase = .arming
        applyMonitorVolume()

        // Detach screenshot tap, then start writers on the SAME session
        // queue. startRecording on the main thread throws (SIGABRT) —
        // that is the crash after Stop / simulate-stop.
        detachFrameTapForRecording { [weak self] in
            self?.beginMovieWriters(generation: gen, startPhoneImmediately: startPhoneImmediately)
        }
    }

    private func finishArmingPhone() {
        guard case .arming = phase else { return }
        if connectionKind == .wireless {
            if cameraStartedOK || expectedFinishes < 2 {
                beginWirelessPhoneRecording()
            } else {
                Task { @MainActor in
                    for _ in 0..<40 {
                        if self.cameraStartedOK { break }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    self.beginWirelessPhoneRecording()
                }
            }
            return
        }
        startPhoneOnceCameraIsLive(generation: recordGeneration)
    }

    /// Must run on sessionQueue. Never call MovieFileOutput.startRecording
    /// from the main thread.
    private func beginMovieWriters(generation: Int, startPhoneImmediately: Bool = true) {
        guard recordGeneration == generation, case .arming = phase else { return }
        if !phoneSession.isRunning { phoneSession.startRunning() }
        let sampleReady = phoneUsesSampleWriter
            && phoneSession.outputs.contains(frameTap)
        let movieReady = !phoneUsesSampleWriter
            && phoneSession.outputs.contains(phoneOutput)
        guard phoneSession.isRunning, sampleReady || movieReady else {
            DispatchQueue.main.async { [weak self] in
                self?.abortRecording(reason: "Device isn't ready to record. Unlock it and wait for the preview, then try again.")
            }
            return
        }
        if phoneIsWriting {
            DispatchQueue.main.async { [weak self] in
                self?.abortRecording(reason: "A recording is already in progress. Press Stop, then try again.")
            }
            return
        }
        guard phoneFileURL != nil else { return }
        // Camera writer takes ~1s to actually start. If we start the phone
        // first, the first words after Record are never on the mic file and
        // the export is silent until the camera catches up.
        let writeMicOrCamera = cameraEnabled || soundMode == .mic || soundMode == .both
        if writeMicOrCamera, let camURL = cameraFileURL, camURL != phoneFileURL {
            if !cameraSession.isRunning { cameraSession.startRunning() }
            if cameraOutput.isRecording {
                DispatchQueue.main.async { [weak self] in
                    self?.abortRecording(reason: "Camera is already recording. Press Stop, then try again.")
                }
                return
            }
            for c in cameraOutput.connections { c.isEnabled = true }
            cameraOutput.startRecording(to: camURL, recordingDelegate: self)
            if startPhoneImmediately {
                DispatchQueue.main.async { [weak self] in
                    self?.startPhoneOnceCameraIsLive(generation: generation)
                }
            }
            return
        }
        if startPhoneImmediately {
            startPhoneWriter(generation: generation)
        }
    }

    /// Wait until the camera file is actually writing, then start the phone.
    private func startPhoneOnceCameraIsLive(generation: Int) {
        Task { @MainActor in
            let needsCam = expectedFinishes > 1
            if needsCam {
                for _ in 0..<40 {
                    guard recordGeneration == generation, case .arming = phase else { return }
                    if cameraStartedOK { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                // Encoder warm-up so the first audible sample is not still priming.
                if cameraStartedOK {
                    try? await Task.sleep(for: .milliseconds(280))
                }
            }
            guard recordGeneration == generation, case .arming = phase else { return }
            sessionQueue.async { [weak self] in
                self?.startPhoneWriter(generation: generation)
            }
        }
    }

    private var phoneIsWriting: Bool {
        if phoneUsesSampleWriter { return phoneSamples.isWriting }
        return phoneOutput.isRecording
    }

    private func startPhoneWriter(generation: Int) {
        guard recordGeneration == generation, case .arming = phase else { return }
        guard let phoneURL = phoneFileURL else { return }
        if phoneIsWriting { return }
        if phoneUsesSampleWriter {
            phoneSamples.arm(videoURL: phoneURL)
        } else {
            for c in phoneOutput.connections { c.isEnabled = true }
            phoneOutput.startRecording(to: phoneURL, recordingDelegate: self)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self, self.recordGeneration == generation, case .arming = self.phase else { return }
            if !self.phoneStartedOK {
                self.abortRecording(reason: "Couldn't start recording from the device. Unlock it, reseat the cable, wait for a live preview, then try again.")
            }
        }
    }

    private func startAirPlayRecording(startPhoneImmediately: Bool = true) {
        guard airplay.isConnected else {
            errorMessage = "Wireless mirroring isn’t live yet. On the iPhone, open Control Center → Screen Mirroring → Record iPhone."
            return
        }
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
        let needsMic = soundMode == .mic || soundMode == .both
        expectedFinishes = (cameraEnabled || needsMic) ? 2 : 1
        phoneStartedOK = false
        cameraStartedOK = false
        cameraWriterClosed = expectedFinishes < 2
        cancelArming = false
        discardedLastTake = false
        resetMixToDefaults()
        phonePartNumber = 1
        phoneFileURL = PhoneSegments.url(in: dir, index: 1)
        cameraFileURL = (cameraEnabled || needsMic)
            ? dir.appendingPathComponent("camera.mov")
            : phoneFileURL
        recordGeneration += 1
        writeTakeIntent(in: dir)
        phase = .arming

        if (cameraEnabled || needsMic), let camURL = cameraFileURL, camURL != phoneFileURL {
            sessionQueue.async { [weak self] in
                guard let self else { return }
                if !self.cameraSession.isRunning { self.cameraSession.startRunning() }
                guard self.cameraSession.isRunning else {
                    NSLog("[record] wireless camera session failed to start")
                    return
                }
                guard self.cameraOutput.connection(with: .video) != nil || needsMic else {
                    NSLog("[record] wireless camera has no video connection")
                    return
                }
                guard !self.cameraOutput.isRecording else { return }
                for c in self.cameraOutput.connections { c.isEnabled = true }
                self.cameraOutput.startRecording(to: camURL, recordingDelegate: self)
            }
            if startPhoneImmediately {
                Task { @MainActor in
                    for _ in 0..<40 {
                        if self.cameraStartedOK { break }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    if self.cameraStartedOK {
                        try? await Task.sleep(for: .milliseconds(280))
                    }
                    self.beginWirelessPhoneRecording()
                }
            }
            return
        }
        cameraStartedOK = true
        if startPhoneImmediately {
            beginWirelessPhoneRecording()
        }
    }

    private func beginWirelessPhoneRecording() {
        guard let phone = phoneFileURL else { return }
        do {
            try airplay.beginRecording(to: phone)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        phoneStartedOK = true
        startTimes[phone] = CMClockGetTime(CMClockGetHostTimeClock())
        phase = .recording(startedAt: .now)
    }

    func stopRecording() {
        if connectionKind == .wireless {
            switch phase {
            case .arming, .recording:
                phase = .finishing
                freezeLivePreview = true
                airplay.mutePresentation = true
                let camURL = cameraFileURL
                let phoneKeep = phoneFileURL
                Task.detached { Self.preserveCameraCopy(cameraURL: camURL, phoneURL: phoneKeep) }
                if cameraOutput.isRecording {
                    sessionQueue.async { [weak self] in
                        if self?.cameraOutput.isRecording == true {
                            self?.cameraOutput.stopRecording()
                        }
                    }
                } else if !cameraStartedOK, expectedFinishes > 1 {
                    expectedFinishes = 1
                    cameraWriterClosed = true
                    NSLog("[record] wireless stop: camera never started — opening phone-only")
                }
                Task { @MainActor in
                    if let url = await self.airplay.endRecording(),
                       ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 1024 {
                        if !self.finishedURLs.contains(url) { self.finishedURLs.append(url) }
                    }
                    if case .finishing = self.phase {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                    }
                    if case .finishing = self.phase {
                        if let phone = self.phoneFileURL,
                           ((try? phone.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 1024 {
                            if !self.finishedURLs.contains(phone) {
                                self.finishedURLs.append(phone)
                            }
                        }
                        self.openEditorIfReady()
                    }
                    self.pollFinishAndOpenEditor()
                }
                return
            default:
                return
            }
        }
        switch phase {
        case .arming:
            cancelArming = true
            if phoneStartedOK || cameraStartedOK || phoneIsWriting || cameraOutput.isRecording {
                beginFinishing()
            } else {
                phase = .finishing
                expectedFinishes = 0
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, case .finishing = self.phase, self.expectedFinishes == 0 else { return }
                    self.phase = .idle
                    self.attachFrameTapForStills()
                    self.applyMonitorVolume()
                }
            }
        case .recording:
            beginFinishing()
        default:
            return
        }
    }

    private func beginFinishing() {
        phoneWriterWatch?.invalidate()
        phoneWriterWatch = nil
        phase = .finishing
        freezeLivePreview = true
        airplay.mutePresentation = true
        let phoneWas = phoneIsWriting || phoneStartedOK
        let cameraWas = cameraOutput.isRecording || cameraStartedOK
        expectedFinishes = (phoneWas ? 1 : 0) + (cameraWas ? 1 : 0)
        if expectedFinishes == 0 {
            phase = .idle
            freezeLivePreview = false
            attachFrameTapForStills()
            applyMonitorVolume()
            errorMessage = "Nothing was actually recording — try again with the device unlocked."
            return
        }
        // Copy camera.mov off the main thread. Stopping writers also
        // hops to the session queue so Stop cannot freeze the window.
        let phoneIsRec = phoneOutput.isRecording
        let sampleWas = phoneUsesSampleWriter && (phoneSamples.isWriting || phoneStartedOK)
        let cameraIsRec = cameraOutput.isRecording
        if !phoneIsRec, !sampleWas, phoneStartedOK, let url = phoneFileURL, !finishedURLs.contains(url) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > 1024 { finishedURLs.append(url) }
        }
        if !cameraIsRec, cameraStartedOK, let url = resolvedCameraURL(), !finishedURLs.contains(url) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > 1024 { finishedURLs.append(url) }
        } else if !cameraWas {
            cameraWriterClosed = true
        }
        let camURL = cameraFileURL
        let phoneKeep = phoneFileURL
        Task.detached {
            Self.preserveCameraCopy(cameraURL: camURL, phoneURL: phoneKeep)
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if phoneIsRec, self.phoneOutput.isRecording { self.phoneOutput.stopRecording() }
            if cameraIsRec, self.cameraOutput.isRecording { self.cameraOutput.stopRecording() }
        }
        if sampleWas {
            let writer = phoneSamples
            Task { @MainActor [weak self] in
                await writer.finish(cancel: false)
                guard let self, case .finishing = self.phase else { return }
                if let url = self.phoneFileURL {
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    if size > 1024, !self.finishedURLs.contains(url) {
                        self.finishedURLs.append(url)
                    }
                }
                self.openEditorIfReady()
            }
        }
        openEditorIfReady()
        pollFinishAndOpenEditor()

        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, case .finishing = self.phase, self.editor == nil, !self.editorOpening else { return }
            Task { @MainActor in
                await self.openEditorEvenIfCameraMissing()
            }
        }
    }

    private func abortRecording(reason: String) {
        phoneWriterWatch?.invalidate()
        phoneWriterWatch = nil
        recordGeneration += 1
        cancelArming = true
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.phoneOutput.isRecording { self.phoneOutput.stopRecording() }
            if self.cameraOutput.isRecording { self.cameraOutput.stopRecording() }
        }
        if phoneUsesSampleWriter {
            Task { await self.phoneSamples.finish(cancel: true) }
        }
        if connectionKind == .wireless { airplay.abandonRecording() }
        phase = .idle
        freezeLivePreview = false
        attachFrameTapForStills()
        applyMonitorVolume()
        errorMessage = reason
        finishedURLs = []
        expectedFinishes = 0
        phoneStartedOK = false
        cameraStartedOK = false
        cameraWriterClosed = true
    }

    private func promoteToRecordingIfReady() {
        guard case .arming = phase else { return }
        if cancelArming {
            beginFinishing()
            return
        }
        if phoneStartedOK {
            phase = .recording(startedAt: .now)
            startPhoneWriterWatch()
        }
    }

    private func startPhoneWriterWatch() {
        phoneWriterWatch?.invalidate()
        phoneWriterWatch = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard case .recording = self.phase, self.phoneStartedOK else { return }
                if self.phoneIsWriting { return }
                if self.selectedPhone == nil { return }
                NSLog("[record] watchdog: phone writer idle while still recording — restarting")
                self.restartPhoneWriter()
            }
        }
    }

    /// USB movie writers die when the iPhone hiccups (audio format change,
    /// brief mux stall). If the cable is still in, start the next phone file
    /// instead of ending the take.
    private func restartPhoneWriter() {
        guard case .recording = phase else { return }
        guard selectedPhone != nil else { return }
        guard let dir = phoneFileURL?.deletingLastPathComponent() else { return }
        phonePartNumber += 1
        let next = PhoneSegments.url(in: dir, index: phonePartNumber)
        phoneFileURL = next
        let generation = recordGeneration
        if phoneUsesSampleWriter {
            phoneSamples.restartVideo(at: next)
            NSLog("[record] restarted phone sample writer → %@", next.lastPathComponent)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, self.recordGeneration == generation, case .recording = self.phase else { return }
                if !self.phoneSamples.isWriting {
                    NSLog("[record] phone sample writer restart did not stick")
                    self.errorMessage = "The iPhone picture stopped. Keep the phone unlocked and plugged in."
                    self.beginFinishing()
                }
            }
            return
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.phoneSession.isRunning { self.phoneSession.startRunning() }
            guard self.phoneSession.isRunning else {
                DispatchQueue.main.async {
                    guard case .recording = self.phase else { return }
                    self.errorMessage = "The iPhone picture stopped. Keep the phone unlocked and plugged in."
                    self.beginFinishing()
                }
                return
            }
            if self.phoneOutput.isRecording { return }
            for c in self.phoneOutput.connections { c.isEnabled = true }
            self.phoneOutput.startRecording(to: next, recordingDelegate: self)
            NSLog("[record] restarted phone writer → %@", next.lastPathComponent)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, self.recordGeneration == generation, case .recording = self.phase else { return }
                if !self.phoneOutput.isRecording {
                    NSLog("[record] phone writer restart did not stick")
                    self.errorMessage = "The iPhone picture stopped. Keep the phone unlocked and plugged in."
                    self.beginFinishing()
                }
            }
        }
    }

    private func handleSampleVideoDied() {
        guard case .recording = phase else { return }
        let action = PhoneWriterPolicy.action(
            stillRecording: true,
            phoneWriterStopped: true,
            deviceConnected: selectedPhone != nil,
            sessionRunning: phoneSessionRunning)
        switch action {
        case .restart:
            NSLog("[record] phone sample video died (still plugged in) — starting the next file")
            restartPhoneWriter()
        case .finishTake:
            errorMessage = "The iPhone picture stopped. Keep the phone unlocked and plugged in, then record again."
            beginFinishing()
        case .ignore:
            break
        }
    }

    static func meterBucket(_ db: Float) -> Int {
        if db > -14 { return 5 }
        if db > -22 { return 4 }
        if db > -30 { return 3 }
        if db > -40 { return 2 }
        if db > -50 { return 1 }
        return 0
    }

    func currentLayout() -> ExportLayout {
        let size = min(max(bubbleFraction, ExportLayout.bubbleMin), ExportLayout.bubbleMax)
        return ExportLayout(
            bubbleCenter: bubbleCenter, bubbleFraction: size,
            canvas: canvas.size(phoneAspect: phoneAspect), background: background,
            showBezel: frameStyle.showsBezel,
            presenterLayout: presenterLayout,
            phoneScale: min(max(phoneScale, ExportLayout.phoneScaleMin), ExportLayout.phoneScaleMax),
            cameraShape: cameraShape,
            ringRGB: ringRGB,
            frameStyle: frameStyle,
            screenCorners: screenCorners,
            showBorder: showBorder,
            customBackgroundRGB: customBackgroundRGB,
            wallpaperID: wallpaperID,
            cameraEnabled: cameraEnabled,
            deviceOnLeft: deviceOnLeft,
            cameraLeads: cameraLeads,
            overlapArrangement: overlapArrangement,
            splitBalance: splitBalance,
            splitGap: splitGap)
    }

    func cancelRecording() {
        discardedLastTake = true
        abortRecording(reason: "")
        errorMessage = nil
        if let dir = phoneFileURL?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    func restartRecording() {
        discardedLastTake = true
        let wasReady = selectedPhone != nil && phoneReady
        abortRecording(reason: "")
        errorMessage = nil
        if let dir = phoneFileURL?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: dir)
        }
        guard wasReady else { return }
        DispatchQueue.main.async { [weak self] in
            self?.startRecording()
        }
    }

    func apply(preset: CapturePreset) {
        objectWillChange.send()
        customBackgroundRGB = preset.backgroundRGB
        wallpaperID = preset.wallpaperID
        canvas = preset.canvas
        presenterLayout = preset.presenterLayout
        deviceOnLeft = preset.deviceOnLeft
        cameraLeads = preset.cameraLeads
        phoneScale = preset.phoneScale
        bubbleFraction = preset.bubbleFraction
        bubbleCenter = CGPoint(x: preset.bubbleCenterX, y: preset.bubbleCenterY)
        cameraShape = preset.cameraShape
        ringRGB = preset.ringRGB
        frameStyle = preset.frameStyle
        showBezel = preset.frameStyle.showsBezel
        splitBalance = preset.splitBalance
        splitGap = preset.splitGap
        let camChanged = cameraEnabled != preset.cameraEnabled
        let soundChanged = soundMode != preset.sound
        cameraEnabled = preset.cameraEnabled
        soundMode = preset.sound
        if preset.sound == .device || preset.sound == .both { monitorPhoneAudio = true }
        applyMonitorVolume()
        // One graph update, and only if camera/mic actually changed.
        // Two racing rebuilds here used to blank the iPhone preview.
        if camChanged || soundChanged {
            Task {
                if preset.cameraEnabled {
                    let ok = await AVCaptureDevice.requestAccess(for: .video)
                    if !ok {
                        await MainActor.run {
                            self.errorMessage = "Camera access was denied. Enable it in System Settings → Privacy & Security."
                            self.cameraEnabled = false
                        }
                        return
                    }
                }
                if preset.sound == .mic || preset.sound == .both {
                    let ok = await AVCaptureDevice.requestAccess(for: .audio)
                    if !ok {
                        await MainActor.run {
                            self.errorMessage = "Microphone access was denied. Enable it in System Settings → Privacy & Security."
                            self.soundMode = .off
                        }
                        return
                    }
                }
                await MainActor.run { self.setupCameraSession() }
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard self.editor == nil, case .idle = self.phase else { return }
            if self.selectedPhone != nil, !self.phoneSessionRunning {
                self.ensureLivePreview()
            } else {
                self.requestPhoneStartAfterPreview()
            }
        }
    }

    func snapshotPreset(named name: String) -> CapturePreset {
        CapturePreset(
            name: name,
            backgroundRGB: customBackgroundRGB ?? [1, 1, 1],
            wallpaperID: wallpaperID,
            canvas: canvas,
            presenterLayout: presenterLayout,
            deviceOnLeft: deviceOnLeft,
            cameraLeads: cameraLeads,
            phoneScale: phoneScale,
            bubbleFraction: bubbleFraction,
            bubbleCenterX: bubbleCenter.x,
            bubbleCenterY: bubbleCenter.y,
            cameraShape: cameraShape,
            ringRGB: ringRGB,
            frameStyle: frameStyle,
            cameraEnabled: cameraEnabled,
            sound: soundMode,
            splitBalance: splitBalance,
            splitGap: splitGap)
    }

    /// If the writers already left a real phone.mov on disk, open it even
    /// when a finish-delegate never arrives (common hang after Stop).
    /// Wait until the movie header is actually playable — a file that is
    /// only "big enough" can still freeze AVPlayer.
    private func pollFinishAndOpenEditor() {
        let gen = recordGeneration
        let wantCamera = cameraEnabled
        Task { @MainActor in
            for attempt in 0..<20 {
                guard case .finishing = self.phase, self.recordGeneration == gen else { return }
                let cameraStillOpen = wantCamera && !self.cameraWriterClosed
                    && (self.cameraOutput.isRecording || self.cameraStartedOK)
                if await self.openEditorFromDiskIfPossible(
                    requireCamera: cameraStillOpen && attempt < 12) { return }
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            guard case .finishing = self.phase, self.recordGeneration == gen else { return }
            await self.openEditorEvenIfCameraMissing()
        }
    }

    @discardableResult
    private func openEditorFromDiskIfPossible(requireCamera: Bool) async -> Bool {
        guard let current = phoneFileURL else { return false }
        let dir = current.deletingLastPathComponent()
        let parts = PhoneSegments.urls(in: dir)
        guard let phone = parts.first ?? (FileManager.default.fileExists(atPath: current.path) ? current : nil) else { return false }
        let size = (try? phone.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard FileManager.default.fileExists(atPath: phone.path), size > 50_000 else { return false }
        // Do not ask AVFoundation about the header here — that can stall
        // the window. The editor remuxes off the main thread.
        try? await Task.sleep(for: .milliseconds(250))
        let size2 = (try? phone.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size2 == size, size2 > 50_000 else { return false }
        preserveCameraRecording()
        if let cam = resolvedCameraURL() {
            if !finishedURLs.contains(cam) { finishedURLs.append(cam) }
        } else if requireCamera {
            return false
        }
        if !finishedURLs.contains(phone) { finishedURLs.append(phone) }
        return openEditorIfReady()
    }

    /// Phone file is enough to open. Don't cancel the take just because the
    /// camera writer is slow — that was the "Saving took too long" dialog.
    @discardableResult
    private func openEditorEvenIfCameraMissing() async -> Bool {
        guard case .finishing = phase, editor == nil, !editorOpening else { return editor != nil }
        cameraWriterClosed = true
        if expectedFinishes > 1 { expectedFinishes = 1 }
        if await openEditorFromDiskIfPossible(requireCamera: false) { return true }
        phase = .idle
        freezeLivePreview = false
        attachFrameTapForStills()
        applyMonitorVolume()
        if editor == nil {
            errorMessage = "Couldn't open that take. Use Library — it's in Movies/Record iPhone."
        }
        return false
    }

    @discardableResult
    private func openEditorIfReady() -> Bool {
        if discardedLastTake {
            phase = .idle
            attachFrameTapForStills()
            applyMonitorVolume()
            discardedLastTake = false
            return false
        }
        guard case .finishing = phase, editor == nil, !editorOpening else { return editor != nil }
        guard finishedURLs.count >= expectedFinishes, expectedFinishes > 0,
              let currentPhone = phoneFileURL else { return false }
        let takeDir = currentPhone.deletingLastPathComponent()
        let phoneParts = PhoneSegments.urls(in: takeDir)
        let phoneURL = phoneParts.first ?? currentPhone

        let phoneSize = (try? phoneURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard FileManager.default.fileExists(atPath: phoneURL.path), phoneSize > 1024 else {
            phase = .idle
            attachFrameTapForStills()
            applyMonitorVolume()
            errorMessage = "The device recording is missing or empty. Keep it unlocked for the whole take."
            return false
        }
        let savedCamera = resolvedCameraURL()
        let cameraOK = savedCamera != nil
        let cameraURL = savedCamera ?? phoneURL

        let phoneStart = startTimes[phoneURL] ?? startTimes[currentPhone] ?? .zero
        let camStart = startTimes[cameraFileURL ?? phoneURL] ?? phoneStart
        NSLog("[editor] opening phone=%@ (%d bytes) camera=%@ offset=%.3fs",
              phoneURL.lastPathComponent, phoneSize,
              cameraURL.lastPathComponent, CMTimeSubtract(camStart, phoneStart).seconds)

        let offset = CMTimeSubtract(camStart, phoneStart)
        // Keep the live picture frozen. Unfreezing here remounts the
        // camera layer, then presentEditor stops the session — hang.
        presentEditor(phone: phoneURL, camera: cameraOK ? cameraURL : phoneURL, offset: offset)
        return true
    }

    /// Writes a brand-new take the same way Stop does, then opens review.
    /// Used by `--simulate-stop` so we can test the hang without a phone.
    func simulateStopAndOpen() async {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let dir = Self.recordingsRoot.appendingPathComponent(fmt.string(from: .now), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let phone = dir.appendingPathComponent("phone.mov")
        do {
            try await writeFreshRecording(to: phone, seconds: 2)
        } catch {
            errorMessage = "Simulate stop failed: \(error.localizedDescription)"
            return
        }
        phase = .finishing
        phoneFileURL = phone
        cameraFileURL = phone
        finishedURLs = [phone]
        expectedFinishes = 1
        presentEditor(phone: phone, camera: phone, offset: .zero)
    }

    func openFolder(_ dir: URL) {
        let project = RecentProject(id: dir, name: dir.lastPathComponent,
                                    date: Date(), hasExport: false)
        openProject(project)
    }

    /// Remux off the main thread, then show the editor.
    ///
    /// `pauseLive` is only for Stop → editor. Opening from Home must leave
    /// the live camera alone: flipping to the preview and calling
    /// stopRunning at the same time is the “not responding” deadlock.
    private func presentEditor(phone: URL, camera: URL, offset: CMTime,
                               pauseLive: Bool = true) {
        if editor != nil || editorOpening { return }
        editorOpening = true
        openingStatus = "Opening recording…"
        applyMonitorVolume()
        let dir = phone.deletingLastPathComponent()
        let camToKeep: URL? = pauseLive ? cameraFileURL : nil
        let phoneToKeep = phoneFileURL
        let resume: @MainActor @Sendable () -> Void
        if pauseLive {
            resume = pauseCaptureForExport()
        } else {
            resume = {}
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            if pauseLive {
                Self.preserveCameraCopy(cameraURL: camToKeep, phoneURL: phoneToKeep)
            }
            do {
                let playPhone = try await Exporter.preparePhonePlayback(in: dir)
                var playCam: URL?
                if camera.standardizedFileURL != phone.standardizedFileURL {
                    playCam = try? await Exporter.preparePlaybackCopy(camera)
                }
                let readyCam = playCam ?? playPhone
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.phase = .idle
                    self.editorOpening = false
                    self.openingStatus = nil
                    self.editor = EditorState(
                        dir: dir,
                        phoneURL: phone,
                        cameraURL: camera,
                        playbackPhone: playPhone,
                        playbackCamera: readyCam,
                        cameraOffset: offset,
                        engine: self,
                        onClose: {
                            self.editorOpening = false
                            self.openingStatus = nil
                            self.freezeLivePreview = false
                            self.resetMixToDefaults()
                            self.showHome = true
                            resume()
                            Task { @MainActor in
                                self.freezeLivePreview = false
                                self.applyMonitorVolume()
                                self.refreshRecentProjects()
                                // Let Home tear down the editor first, then
                                // wake the phone so Live preview isn't blank.
                                try? await Task.sleep(for: .milliseconds(350))
                                if self.editor == nil, case .idle = self.phase {
                                    self.ensureLivePreview()
                                }
                            }
                        })
                    self.refreshRecentProjects()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.phase = .idle
                    self.editorOpening = false
                    self.openingStatus = nil
                    self.freezeLivePreview = false
                    resume()
                    if self.editor == nil {
                        self.showHome = true
                        self.errorMessage = Self.openErrorMessage(for: error)
                    }
                    NSLog("[editor] present failed: %@", error.localizedDescription)
                }
            }
        }
    }

    nonisolated private static func preparePlaybackOrThrow(_ url: URL) async throws -> URL {
        try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask {
                try await Exporter.preparePlaybackCopy(url)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(14))
                throw Exporter.ExportError.missingTrack(
                    "this recording took too long to open. It may be incomplete — try another take.")
            }
            let url = try await group.next()!
            group.cancelAll()
            return url
        }
    }

    nonisolated private static func openErrorMessage(for error: Error) -> String {
        let text = error.localizedDescription
        if text.contains("incomplete") || text.contains("too long") || text.contains("empty") {
            return "That take didn’t finish saving, so it can’t be opened. Record again and press Stop, then wait for the editor."
        }
        return "Couldn’t open that take. It’s still in Movies/Record iPhone if you want to try again."
    }

    /// Copy camera.mov → camera.keep.mov off the main thread (90MB+ files
    /// used to beach-ball the window if this ran on tap).
    nonisolated private static func preserveCameraCopy(cameraURL: URL?, phoneURL: URL?) {
        guard let cam = cameraURL, cam != phoneURL else { return }
        let size = (try? cam.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard FileManager.default.fileExists(atPath: cam.path), size > 50_000 else { return }
        let keep = cam.deletingLastPathComponent().appendingPathComponent("camera.keep.mov")
        let keepSize = (try? keep.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > keepSize else { return }
        try? FileManager.default.removeItem(at: keep)
        do {
            try FileManager.default.copyItem(at: cam, to: keep)
            NSLog("[record] preserved camera.mov (%d bytes) -> camera.keep.mov", size)
        } catch {
            NSLog("[record] could not preserve camera.mov: %@", error.localizedDescription)
        }
    }

    /// Snapshot camera.mov so a later session-stop can't delete the only copy.
    @discardableResult
    private func preserveCameraRecording() -> URL? {
        guard let cam = cameraFileURL, cam != phoneFileURL else { return nil }
        let size = (try? cam.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard FileManager.default.fileExists(atPath: cam.path), size > 50_000 else {
            return resolvedCameraURL()
        }
        let keep = cam.deletingLastPathComponent().appendingPathComponent("camera.keep.mov")
        let keepSize = (try? keep.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > keepSize {
            try? FileManager.default.removeItem(at: keep)
            do {
                try FileManager.default.copyItem(at: cam, to: keep)
                NSLog("[record] preserved camera.mov (%d bytes) -> camera.keep.mov", size)
            } catch {
                NSLog("[record] could not preserve camera.mov: %@", error.localizedDescription)
            }
        }
        return resolvedCameraURL()
    }

    /// Prefer the live camera.mov; fall back to the snapshot if Stop deleted it.
    private func resolvedCameraURL() -> URL? {
        guard let cam = cameraFileURL, cam != phoneFileURL else { return nil }
        let keep = cam.deletingLastPathComponent().appendingPathComponent("camera.keep.mov")
        let camSize = (try? cam.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let keepSize = (try? keep.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if FileManager.default.fileExists(atPath: cam.path), camSize > 1024 { return cam }
        if FileManager.default.fileExists(atPath: keep.path), keepSize > 1024 {
            if camSize <= 1024 {
                try? FileManager.default.removeItem(at: cam)
                try? FileManager.default.moveItem(at: keep, to: cam)
                if FileManager.default.fileExists(atPath: cam.path) { return cam }
            }
            return keep
        }
        return nil
    }

    private func cameraFileReady() -> Bool {
        resolvedCameraURL() != nil
    }

    /// Stop capture sessions without parking the UI. Times out so a wedged
    /// USB session cannot put the app in “not responding.”
    private func waitForSessionsToStop(seconds: Double = 1.6) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let lock = NSLock()
            var resumed = false
            func finish() {
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                cont.resume()
            }
            sessionQueue.async {
                if self.phoneSession.isRunning { self.phoneSession.stopRunning() }
                if self.cameraSession.isRunning { self.cameraSession.stopRunning() }
                finish()
            }
            sessionQueue.asyncAfter(deadline: .now() + seconds) {
                finish()
            }
        }
    }

    private func pauseCaptureForExport() -> @MainActor @Sendable () -> Void {
        airplay.mutePresentation = true
        freezeLivePreview = true
        let phoneWasRunning = phoneSessionRunning
        let cameraWasRunning = cameraSessionRunning
        phoneSessionRunning = false
        cameraSessionRunning = false
        // Don't pretend the phone is still live — Home then showed a
        // selected iPhone with a blank white screen.
        phoneReady = false
        phonePreviewAttached = false
        sessionQueue.async {
            if phoneWasRunning { self.phoneSession.stopRunning() }
            if cameraWasRunning { self.cameraSession.stopRunning() }
        }
        return { [weak self] in
            guard let self else { return }
            self.freezeLivePreview = false
            self.airplay.mutePresentation = false
            self.requestPhoneStartAfterPreview()
            self.resumeCameraWhenPreviewAttaches = true
        }
    }

    /// Writes Recording.mp4 in the take folder so Finder has the combined
    /// movie (phone + camera), not just the two raw clips. Runs in a
    /// separate process so a stall can't freeze the app.
    func startSilentCombine(phoneURL: URL, cameraURL: URL, offset: CMTime) {
        let dir = phoneURL.deletingLastPathComponent()
        let outURL = dir.appendingPathComponent("Recording.mp4")
        if FileManager.default.fileExists(atPath: outURL.path) { return }
        if combineWorker != nil { return }
        guard let exe = Bundle.main.executableURL else { return }

        let tempURL = dir.appendingPathComponent("Recording.inprogress.mp4")
        try? FileManager.default.removeItem(at: tempURL)
        let spec = ExportSpec(
            phonePath: phoneURL.path, cameraPath: cameraURL.path,
            cameraOffsetSeconds: offset.seconds,
            layout: currentLayout(), zooms: [],
            trimStart: nil, trimEnd: nil,
            outputPath: tempURL.path,
            phoneAudioLevel: Double(phoneAudioLevel),
            micAudioLevel: Double(micAudioLevel))
        let specURL = dir.appendingPathComponent("combine-spec.json")
        guard let data = try? JSONEncoder().encode(spec),
              (try? data.write(to: specURL, options: .atomic)) != nil else { return }

        let worker = Process()
        worker.executableURL = exe
        worker.arguments = ["--export-json", specURL.path]
        worker.standardOutput = FileHandle.nullDevice
        worker.standardError = FileHandle.nullDevice
        worker.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                try? FileManager.default.removeItem(at: specURL)
                self?.combineWorker = nil
                if proc.terminationStatus == 0,
                   FileManager.default.fileExists(atPath: tempURL.path) {
                    try? FileManager.default.removeItem(at: outURL)
                    try? FileManager.default.moveItem(at: tempURL, to: outURL)
                    NSLog("[combine] wrote %@", outURL.lastPathComponent)
                    self?.refreshRecentProjects()
                } else {
                    try? FileManager.default.removeItem(at: tempURL)
                    NSLog("[combine] failed status=%d", proc.terminationStatus)
                }
            }
        }
        do {
            try worker.run()
            combineWorker = worker
            NSLog("[combine] started pid=%d", worker.processIdentifier)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(90))
                guard let self, let live = self.combineWorker, live === worker, live.isRunning else { return }
                NSLog("[combine] watchdog: silent combine ran 90s — stopping")
                live.terminate()
            }
        } catch {
            NSLog("[combine] could not start: %@", error.localizedDescription)
            try? FileManager.default.removeItem(at: specURL)
        }
    }

    /// Restart only after SwiftUI has put the matching preview layer back.
    /// Starting while AVFoundation is attaching that layer can abort the app.
    func previewDidAttach(to session: AVCaptureSession) {
        if session === phoneSession {
            phonePreviewAttached = true
            if resumePhoneWhenPreviewAttaches {
                resumePhoneWhenPreviewAttaches = false
                attachFrameTapForStills()
                sessionQueue.async { [self] in
                    if !phoneSession.isRunning { phoneSession.startRunning() }
                    let running = phoneSession.isRunning
                    DispatchQueue.main.async { self.phoneSessionRunning = running }
                }
            }
        } else if session === cameraSession, resumeCameraWhenPreviewAttaches {
            resumeCameraWhenPreviewAttaches = false
            sessionQueue.async { [self] in
                if !cameraSession.isRunning { cameraSession.startRunning() }
                let running = cameraSession.isRunning
                DispatchQueue.main.async { self.cameraSessionRunning = running }
            }
        }
    }

    // MARK: - Recent

    static var recordingsRoot: URL {
        FileManager.default
            .urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Record iPhone", isDirectory: true)
    }

    func refreshRecentProjects() {
        let root = Self.recordingsRoot
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            recentProjects = []
            return
        }
        var items: [RecentProject] = []
        for dir in dirs {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            let phone = dir.appendingPathComponent("phone.mov")
            guard FileManager.default.fileExists(atPath: phone.path) else { continue }
            let date = (try? dir.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            // Exports may be "Recording.mp4", "Recording 2.mp4", … — any mp4 counts.
            let hasExport = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .contains { $0.hasSuffix(".mp4") }
            items.append(RecentProject(id: dir, name: dir.lastPathComponent,
                                       date: date, hasExport: hasExport))
        }
        recentProjects = items.sorted { $0.date > $1.date }.prefix(16).map { $0 }
    }

    private func writeTakeIntent(in dir: URL) {
        TakeIntentDoc(wantedCamera: cameraEnabled,
                      cameraEnabled: cameraEnabled,
                      sound: soundMode.rawValue).write(to: dir)
    }

    func openProject(_ project: RecentProject) {
        guard case .idle = phase, editor == nil, !editorOpening else { return }
        // Stay on Home. Leaving Home mounts the live camera while we also
        // stop the session — that is the Force Quit hang.
        showHome = true
        let phoneURL = project.dir.appendingPathComponent("phone.mov")
        var cameraURL = project.dir.appendingPathComponent("camera.mov")
        let keep = project.dir.appendingPathComponent("camera.keep.mov")
        if !FileManager.default.fileExists(atPath: cameraURL.path),
           FileManager.default.fileExists(atPath: keep.path) {
            cameraURL = keep
        }
        guard FileManager.default.fileExists(atPath: phoneURL.path) else {
            errorMessage = "Can't find the phone recording in that folder."
            return
        }
        let phoneSize = (try? phoneURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if phoneSize < 20_000 {
            errorMessage = "That take didn’t finish saving, so it can’t be opened. Record again and press Stop."
            return
        }
        let camExists = FileManager.default.fileExists(atPath: cameraURL.path)
            && ((try? cameraURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 1024
        // Restore the measured phone/camera start offset saved at record time —
        // without it, reopened projects play the camera out of sync.
        struct OffsetPeek: Codable { var cameraOffsetSeconds: Double? }
        var offset = CMTime.zero
        if let data = try? Data(contentsOf: project.dir.appendingPathComponent("project.json")),
           let peek = try? JSONDecoder().decode(OffsetPeek.self, from: data),
           let seconds = peek.cameraOffsetSeconds {
            offset = CMTime(seconds: seconds, preferredTimescale: 600)
        }
        presentEditor(phone: phoneURL, camera: camExists ? cameraURL : phoneURL,
                      offset: offset, pauseLive: false)
    }

    /// Moves a recording folder to the Trash (recoverable, never a hard delete).
    func trashProject(at dir: URL) {
        do {
            try FileManager.default.trashItem(at: dir, resultingItemURL: nil)
        } catch {
            errorMessage = "Couldn't move that recording to the Trash: \(error.localizedDescription)"
        }
        refreshRecentProjects()
    }

    // MARK: - Screenshots

    func takeScreenshot() {
        guard case .idle = phase else {
            errorMessage = "Screenshots are available when you're not recording."
            return
        }
        // Ensure tap is attached.
        if connectionKind == .wireless {
            airplay.captureNextStill = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                self.writeScreenshot(from: self.airplay.latestFrame)
            }
            return
        }
        if !frameTapAttached { attachFrameTapForStills() }
        // Wait a beat for a frame if needed.
        if latestFrame.getImage() == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.writeScreenshot()
            }
            return
        }
        writeScreenshot()
    }

    private func writeScreenshot() {
        writeScreenshot(from: latestFrame)
    }

    private func writeScreenshot(from store: FrameStore) {
        guard let image = store.getImage() else {
            errorMessage = "No picture from the device yet — connect and unlock it first."
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
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

final class FrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var image: CGImage?
    private let context = CIContext(options: [.cacheIntermediates: false])

    func set(_ buffer: CVPixelBuffer) {
        let ci = CIImage(cvPixelBuffer: buffer)
        let cg = context.createCGImage(ci, from: ci.extent)
        lock.lock(); image = cg; lock.unlock()
    }

    func getImage() -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        return image
    }
}

extension CaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        if output === phoneAudioOut {
            phoneSamples.appendAudio(sampleBuffer)
            return
        }
        if let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            latestFrame.set(buffer)
        }
        if output === frameTap {
            phoneSamples.appendVideo(sampleBuffer)
        }
    }
}

extension CaptureEngine: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didStartRecordingTo fileURL: URL,
                                from connections: [AVCaptureConnection]) {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let fileOutput = output
        DispatchQueue.main.async {
            self.startTimes[fileURL] = now
            if fileOutput === self.phoneOutput {
                self.phoneStartedOK = true
                NSLog("[record] phone started")
            } else if fileOutput === self.cameraOutput {
                self.cameraStartedOK = true
                NSLog("[record] camera started")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self else { return }
                    let cam = self.cameraFileURL
                    let phone = self.phoneFileURL
                    Task.detached { Self.preserveCameraCopy(cameraURL: cam, phoneURL: phone) }
                }
            }
            if self.cancelArming {
                self.sessionQueue.async {
                    if fileOutput.isRecording { fileOutput.stopRecording() }
                }
            }
            self.promoteToRecordingIfReady()
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection],
                                error: Error?) {
        DispatchQueue.main.async {
            let size = (try? outputFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if let error {
                NSLog("[record] finish %@ size=%d error=%@", outputFileURL.lastPathComponent, size, error.localizedDescription)
            } else {
                NSLog("[record] finish %@ size=%d", outputFileURL.lastPathComponent, size)
            }
            if outputFileURL.lastPathComponent == "camera.mov" {
                self.cameraWriterClosed = true
            }
            if size > 1024, !self.finishedURLs.contains(outputFileURL) {
                self.finishedURLs.append(outputFileURL)
            } else if size <= 1024, outputFileURL.lastPathComponent == "camera.mov" {
                NSLog("[record] camera.mov finished empty — continuing with the phone screen")
                if self.expectedFinishes > 1 { self.expectedFinishes -= 1 }
            }
            let stillRecording: Bool = {
                switch self.phase {
                case .recording, .arming: return true
                default: return false
                }
            }()
            let phoneStopped = output === self.phoneOutput
                || outputFileURL.lastPathComponent.hasPrefix("phone")
            let action = PhoneWriterPolicy.action(
                stillRecording: stillRecording,
                phoneWriterStopped: phoneStopped,
                deviceConnected: self.selectedPhone != nil,
                sessionRunning: self.phoneSessionRunning || self.phoneSession.isRunning)
            switch action {
            case .restart:
                NSLog("[record] phone writer stopped mid-take (still plugged in) — starting the next file")
                self.restartPhoneWriter()
                return
            case .finishTake:
                NSLog("[record] phone writer stopped and the device is gone — finishing")
                self.errorMessage = "The iPhone picture stopped. Keep the phone unlocked and plugged in, then record again."
                self.beginFinishing()
                return
            case .ignore:
                break
            }
            guard case .finishing = self.phase else { return }
            self.openEditorIfReady()
        }
    }
}
