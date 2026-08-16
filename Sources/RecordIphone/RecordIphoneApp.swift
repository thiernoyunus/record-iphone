import SwiftUI
import CoreMedia
import AVFoundation
import AppKit

enum LaunchIntent {
    static var openDir: URL?
    static var simulateStop = false
}

@main
struct RecordIphoneApp: App {
    @StateObject private var engine = CaptureEngine()

    init() {
        runHeadlessModeIfRequested()
    }

    var body: some Scene {
        WindowGroup("Record iPhone") {
            ContentView()
                .environmentObject(engine)
                .onAppear {
                    engine.start()
                    if LaunchIntent.simulateStop {
                        LaunchIntent.simulateStop = false
                        Task { await engine.simulateStopAndOpen() }
                    } else if let dir = LaunchIntent.openDir {
                        LaunchIntent.openDir = nil
                        engine.openFolder(dir)
                    }
                    if let win = NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first {
                        // Only shrink a restored full-screen frame. Don't yank a
                        // window the user already sized.
                        if win.frame.width > 1500 || win.frame.height > 980 {
                            win.setFrame(NSRect(x: 0, y: 0, width: 1120, height: 760), display: true)
                            win.center()
                        }
                    }
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1120, height: 740)
        .windowStyle(.titleBar)
        Settings {
            SettingsView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { engine.editor?.undo() }
                    .keyboardShortcut("z", modifiers: [.command])
                    .disabled(!(engine.editor?.canUndo ?? false))
                Button("Redo") { engine.editor?.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!(engine.editor?.canRedo ?? false))
            }
            CommandGroup(after: .undoRedo) {
                Button("Remove Zoom") { engine.editor?.deleteSelectedZoom() }
                    .keyboardShortcut(.delete)
                    .disabled(engine.editor?.selectedZoomID == nil)
            }
            CommandMenu("Recording") {
                Button("Connect Wirelessly…") {
                    engine.startWireless()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                Divider()
                Menu("Open Recent") {
                    if engine.recentProjects.isEmpty {
                        Text("No recordings yet")
                    } else {
                        ForEach(engine.recentProjects) { project in
                            Button(project.displayName) {
                                engine.openProject(project)
                            }
                        }
                    }
                }
                Button("Show Recordings in Finder") {
                    NSWorkspace.shared.open(CaptureEngine.recordingsRoot)
                }
                Divider()
                Button("Settings…") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                .keyboardShortcut(",", modifiers: [.command])
                Button("Refresh Recent") {
                    engine.refreshRecentProjects()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
    }
}

/// Headless modes (no UI, print progress, exit):
///   --export-json <spec.json>       full export driven by an ExportSpec —
///                                   this is how the app's own exports run,
///                                   in a clean worker process.
///   --export-test <phone> <camera>  quick default-look export for testing.
///   --preview-audio-check <phone> <camera>
///                                   asserts the editor receives one stable
///                                   audio track instead of swapping tracks.
///   --editor-open-check <phone> <camera>
///                                   times the exact work the review screen
///                                   does after Stop (compose + player item).
///                                   Fails if that work takes more than 8 seconds.
///                                   A 20-second outer timeout covers a hang.
///   --connect-safety-check          USB connect policy + preview detach order.
///                                   Fails (exit 3) if the main thread hangs.
private func runHeadlessModeIfRequested() {
    let args = CommandLine.arguments
    if args.contains("--connect-safety-check") {
        runConnectSafetyCheck()
    }
    if args.contains("--airplay-edge-test") {
        let result = AirPlayLinkTests.run()
        print(result.1)
        exit(result.0 ? 0 : 1)
    }
    if args.contains("--editor-logic-check") {
        let result = EditorLogicTests.run()
        print(result.1)
        exit(result.0 ? 0 : 1)
    }
    if args.contains("--airplay-selftest") {
        var ok = false
        var finished = false
        Task { @MainActor in
            let mirror = AirPlayMirror()
            ok = await mirror.runSocketSelfTest()
            print(ok ? "OK airplay socket read" : "FAIL airplay socket read")
            finished = true
            CFRunLoopStop(CFRunLoopGetMain())
        }
        let deadline = Date().addingTimeInterval(5)
        while !finished, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        exit(ok ? 0 : 1)
    }
    if let i = args.firstIndex(of: "--export-json"), args.count > i + 1 {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: args[i + 1])),
              let spec = try? JSONDecoder().decode(ExportSpec.self, from: data) else {
            print("FAIL could not read export spec"); exit(1)
        }
        var trim: CMTimeRange?
        if spec.trimStart != nil || spec.trimEnd != nil {
            let start = CMTime(seconds: spec.trimStart ?? 0, preferredTimescale: 600)
            let end = CMTime(seconds: spec.trimEnd ?? .greatestFiniteMagnitude,
                             preferredTimescale: 600)
            trim = CMTimeRange(start: start, end: end)
        }
        runHeadlessExport(
            phoneURL: URL(fileURLWithPath: spec.phonePath),
            cameraURL: URL(fileURLWithPath: spec.cameraPath),
            offset: CMTime(seconds: spec.cameraOffsetSeconds, preferredTimescale: 600),
            layout: spec.layout, zooms: spec.zooms, trim: trim,
            outputURL: spec.outputPath.map { URL(fileURLWithPath: $0) },
            phoneAudioLevel: spec.phoneAudioLevel ?? 1,
            micAudioLevel: spec.micAudioLevel ?? 1)
    } else if let i = args.firstIndex(of: "--preview-audio-check"), args.count > i + 2 {
        runHeadlessPreviewAudioCheck(
            phoneURL: URL(fileURLWithPath: args[i + 1]),
            cameraURL: URL(fileURLWithPath: args[i + 2]))
    } else if let i = args.firstIndex(of: "--editor-open-check"), args.count > i + 2 {
        runHeadlessEditorOpenCheck(
            phoneURL: URL(fileURLWithPath: args[i + 1]),
            cameraURL: URL(fileURLWithPath: args[i + 2]))
    } else if args.contains("--repro-stop-open") {
        runReproStopOpen()
    } else if args.contains("--simulate-stop") {
        LaunchIntent.simulateStop = true
    } else if let i = args.firstIndex(of: "--open-project"), args.count > i + 1 {
        LaunchIntent.openDir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
    } else if let i = args.firstIndex(of: "--export-test"), args.count > i + 2 {
        let zooms: [ZoomSegment] = ProcessInfo.processInfo.environment["RECORD_TEST_ZOOMS"] == "1"
            ? [ZoomSegment(start: 3, duration: 4, center: CGPoint(x: 0.5, y: 0.45), level: 2.2)]
            : []
        runHeadlessExport(
            phoneURL: URL(fileURLWithPath: args[i + 1]),
            cameraURL: URL(fileURLWithPath: args[i + 2]),
            offset: .zero,
            layout: ExportLayout(bubbleCenter: CGPoint(x: 0.82, y: 0.76), bubbleFraction: 0.30,
                                 canvas: CanvasPreset.landscape.size,
                                 background: .midnight, showBezel: true),
            zooms: zooms, trim: nil)
    }
}

/// Policy + detach-order + reconnect-spam. Exits 3 if main hangs.
private func runConnectSafetyCheck() {
    setvbuf(stdout, nil, _IOLBF, 0)
    var failures = 0
    func expect(_ name: String, _ cond: Bool) {
        if cond { print("OK \(name)") }
        else { print("FAIL \(name)"); failures += 1 }
    }

    expect("ignore while in flight",
           PhoneConnectPolicy.decide(
            sameDevice: true, selectInFlight: true, phoneReady: false,
            sessionRunning: false, phaseIdle: true, editorOpen: false,
            wireless: false) == .ignore)
    expect("ignore when already live",
           PhoneConnectPolicy.decide(
            sameDevice: true, selectInFlight: false, phoneReady: true,
            sessionRunning: true, phaseIdle: true, editorOpen: false,
            wireless: false) == .ignore)
    expect("kick when ready but stopped",
           PhoneConnectPolicy.decide(
            sameDevice: true, selectInFlight: false, phoneReady: true,
            sessionRunning: false, phaseIdle: true, editorOpen: false,
            wireless: false) == .kickStart)
    expect("rebuild a new device",
           PhoneConnectPolicy.decide(
            sameDevice: false, selectInFlight: false, phoneReady: false,
            sessionRunning: false, phaseIdle: true, editorOpen: false,
            wireless: false) == .rebuild)
    expect("ignore during editor",
           PhoneConnectPolicy.decide(
            sameDevice: false, selectInFlight: false, phoneReady: false,
            sessionRunning: false, phaseIdle: true, editorOpen: true,
            wireless: false) == .ignore)
    expect("timer ignores in-flight select",
           PhoneConnectPolicy.shouldTimerReconnect(
            selected: true, phoneReady: false, phonesPresent: true,
            selectInFlight: true, sessionRunning: false) == .ignore)
    expect("timer rebuilds while connecting",
           PhoneConnectPolicy.shouldTimerReconnect(
            selected: true, phoneReady: false, phonesPresent: true,
            selectInFlight: false, sessionRunning: false) == .rebuild)
    expect("timer rebuilds a dead live session",
           PhoneConnectPolicy.shouldTimerReconnect(
            selected: true, phoneReady: true, phonesPresent: true,
            selectInFlight: false, sessionRunning: false) == .rebuild)
    expect("kick waits while preview bind is in flight",
           PhoneSessionStartPolicy.kick(resumeWhenPreviewAttaches: true) == .waitForPreview)
    expect("kick starts after preview is bound",
           PhoneSessionStartPolicy.kick(resumeWhenPreviewAttaches: false) == .start)
    expect("timer does not startRunning during preview bind",
           PhoneSessionStartPolicy.timerMayStart(resumeWhenPreviewAttaches: true) == false)
    expect("timer may startRunning once preview is bound",
           PhoneSessionStartPolicy.timerMayStart(resumeWhenPreviewAttaches: false))
    expect("audio format change rolls audio only",
           PhoneAudioRollPolicy.shouldRollAudio(formatChanged: true, audioWriterFailed: false)
           && !PhoneAudioRollPolicy.shouldStopVideoForAudioFormatChange())
    expect("dead audio writer rolls a new m4a",
           PhoneAudioRollPolicy.shouldRollAudio(formatChanged: false, audioWriterFailed: true))
    expect("first device-audio file is phone-audio.m4a",
           PhoneAudioSegments.fileName(index: 1) == "phone-audio.m4a")
    expect("second device-audio file is phone-audio-2.m4a",
           PhoneAudioSegments.fileName(index: 2) == "phone-audio-2.m4a")

    // Safe order: stop the session, then detach the preview layer.
    // The launch SIGABRT was the opposite race: addVideoPreviewLayer on
    // main while startRunning ran on capture.session.
    let session = AVCaptureSession()
    let output = AVCaptureMovieFileOutput()
    session.beginConfiguration()
    if session.canAddOutput(output) { session.addOutput(output) }
    session.commitConfiguration()
    session.startRunning()
    let layer = AVCaptureVideoPreviewLayer(session: session)
    layer.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    let t0 = Date()
    session.stopRunning()
    layer.session = nil
    let safe = Date().timeIntervalSince(t0)
    print(String(format: "step detach-after-stop %.3fs", safe))
    expect("detach after stop under 2s", safe < 2)

    var engineOK = false
    DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
        if !engineOK {
            print("FAIL HANG CaptureEngine start/reconnect")
            exit(3)
        }
    }
    Task { @MainActor in
        let engine = CaptureEngine()
        engine.start()
        for _ in 0..<20 {
            engine.reconnectIfNeeded()
            engine.refreshPhones()
        }
        engineOK = true
        print("OK engine reconnect spam")
        CFRunLoopStop(CFRunLoopGetMain())
    }
    let deadline = Date().addingTimeInterval(8)
    while !engineOK, Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }
    if !engineOK {
        print("TIMEOUT engine reconnect spam")
        exit(2)
    }
    if failures > 0 {
        print("FAIL connect-safety-check (\(failures) checks)")
        exit(1)
    }
    print("OK connect-safety-check")
    exit(0)
}

/// Writes a movie the way Stop does, then opens it the way the review
/// screen does. Exits 3 if the main thread hangs — that is the Force Quit.
private func runReproStopOpen() {
    setvbuf(stdout, nil, _IOLBF, 0)
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("record-iphone-repro-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let raw = dir.appendingPathComponent("phone.mov")

    let written = DispatchSemaphore(value: 0)
    var writeError: String?
    Task.detached {
        do {
            try await writeFreshRecording(to: raw, seconds: 2)
            print(String(format: "step wrote-fresh %.0f bytes",
                         Double((try? raw.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)))
        } catch {
            writeError = error.localizedDescription
        }
        written.signal()
    }
    if written.wait(timeout: .now() + 20) == .timedOut {
        print("FAIL could not write a test recording")
        exit(1)
    }
    if let writeError {
        print("FAIL write: \(writeError)")
        exit(1)
    }

    // Watchdog: if main is stuck opening the fresh file, die with a clear code.
    let openedOK = OnceFlag()
    DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
        if !openedOK.isSet {
            print("FAIL HANG opening just-finished recording on the main thread")
            exit(3)
        }
    }

    let opened = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 1
    DispatchQueue.main.async {
        let t0 = Date()
        do {
            let play = try awaitBlocking { try await Exporter.preparePlaybackCopy(raw) }
            print(String(format: "step remux %.2fs -> %@",
                         Date().timeIntervalSince(t0), play.lastPathComponent))
            let t1 = Date()
            let item = AVPlayerItem(url: play)
            let player = AVPlayer(playerItem: item)
            print(String(format: "step player-on-copy %.3fs", Date().timeIntervalSince(t1)))
            let t2 = Date()
            for _ in 0..<100 {
                if item.status == .readyToPlay || item.status == .failed { break }
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
            if item.status == .readyToPlay {
                print(String(format: "step ready %.2fs", Date().timeIntervalSince(t2)))
                print("OK repro-stop-open")
                exitCode = 0
            } else {
                print("FAIL player status=\(item.status.rawValue) \(item.error?.localizedDescription ?? "")")
            }
            _ = player
        } catch {
            print("FAIL remux/open: \(error)")
        }
        openedOK.mark()
        opened.signal()
    }
    let deadline = Date().addingTimeInterval(15)
    while opened.wait(timeout: .now() + 0.05) == .timedOut {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        if Date() > deadline {
            print("TIMEOUT repro-stop-open")
            exit(2)
        }
    }
    try? FileManager.default.removeItem(at: dir)
    exit(exitCode)
}

/// Tiny sync bridge so the repro can stay on the main run loop.
private func awaitBlocking<T>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
    let box = BlockingBox<T>()
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.value = .success(try await work()) }
        catch { box.value = .failure(error) }
        sem.signal()
    }
    while sem.wait(timeout: .now() + 0.05) == .timedOut {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }
    switch box.value {
    case .success(let v): return v
    case .failure(let e): throw e
    case .none: throw NSError(domain: "repro", code: 1)
    }
}

private final class BlockingBox<T>: @unchecked Sendable {
    var value: Result<T, Error>?
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func mark() {
        lock.lock()
        done = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return done
    }
}

func writeFreshRecording(to url: URL, seconds: Double) async throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(url: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 720,
        AVVideoHeightKey: 1280
    ])
    input.expectsMediaDataInRealTime = true
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 720,
            kCVPixelBufferHeightKey as String: 1280
        ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    let frames = Int(seconds * 30)
    for i in 0..<frames {
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(for: .milliseconds(4))
        }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 720, 1280,
                            kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer else { continue }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, Int32(40 + (i * 3) % 180), CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
    }
    input.markAsFinished()
    await writer.finishWriting()
    if writer.status != .completed {
        throw writer.error ?? NSError(domain: "repro", code: 2)
    }
}

/// Reproduces the review-screen open path: two plain file players.
/// Must finish quickly. A hang here is the same hang that made macOS
/// show "Application Not Responding".
private func runHeadlessEditorOpenCheck(phoneURL: URL, cameraURL: URL) {
    setvbuf(stdout, nil, _IOLBF, 0)
    let done = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 1
    Task { @MainActor in
        let total = Date()
        let t0 = Date()
        let phoneItem = AVPlayerItem(url: phoneURL)
        phoneItem.preferredForwardBufferDuration = 1
        let phonePlayer = AVPlayer(playerItem: phoneItem)
        print(String(format: "step phone-item %.3fs", Date().timeIntervalSince(t0)))

        let t1 = Date()
        let camExists = cameraURL.standardizedFileURL != phoneURL.standardizedFileURL
            && FileManager.default.fileExists(atPath: cameraURL.path)
        var camItem: AVPlayerItem?
        var camPlayer: AVPlayer?
        if camExists {
            let item = AVPlayerItem(url: cameraURL)
            item.preferredForwardBufferDuration = 1
            camItem = item
            camPlayer = AVPlayer(playerItem: item)
        }
        print(String(format: "step camera-item %.3fs present=%d",
                     Date().timeIntervalSince(t1), camExists ? 1 : 0))

        let t2 = Date()
        for _ in 0..<80 {
            if phoneItem.status == .readyToPlay { break }
            if phoneItem.status == .failed {
                print("FAIL phone item: \(phoneItem.error?.localizedDescription ?? "unknown")")
                done.signal()
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if phoneItem.status != .readyToPlay {
            print("FAIL phone item never became ready (status=\(phoneItem.status.rawValue))")
            done.signal()
            return
        }
        print(String(format: "step phone-ready %.2fs", Date().timeIntervalSince(t2)))

        if let camItem {
            for _ in 0..<80 {
                if camItem.status == .readyToPlay || camItem.status == .failed { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            print(String(format: "step camera-status %d", camItem.status.rawValue))
        }

        _ = phonePlayer
        _ = camPlayer
        let elapsed = Date().timeIntervalSince(total)
        if elapsed > 8 {
            print(String(format: "FAIL editor-open-check too slow (%.2fs)", elapsed))
        } else {
            print(String(format: "OK editor-open-check in %.2fs", elapsed))
            exitCode = 0
        }
        done.signal()
    }
    let deadline = Date().addingTimeInterval(20)
    while done.wait(timeout: .now() + 0.05) == .timedOut {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        if Date() > deadline {
            print("TIMEOUT editor-open-check")
            exit(2)
        }
    }
    exit(exitCode)
}

private func runHeadlessPreviewAudioCheck(phoneURL: URL, cameraURL: URL) {
    setvbuf(stdout, nil, _IOLBF, 0)
    let done = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 1
    Task {
        do {
            let preview = try await Exporter.makePreview(
                phoneURL: phoneURL, cameraURL: cameraURL, cameraOffset: .zero)
            let tracks = try await preview.composition.loadTracks(withMediaType: .audio)
            if tracks.count == 1 {
                print(String(format: "OK one preview audio track, %.2fs", preview.duration))
                exitCode = 0
            } else {
                print("FAIL preview has \(tracks.count) audio tracks; playback can drop one")
            }
        } catch {
            print("FAIL preview audio check: \(error)")
        }
        done.signal()
    }
    if done.wait(timeout: .now() + 60) == .timedOut {
        print("TIMEOUT preview audio check")
        exit(2)
    }
    exit(exitCode)
}

private func runHeadlessExport(phoneURL: URL, cameraURL: URL, offset: CMTime,
                               layout: ExportLayout, zooms: [ZoomSegment],
                               trim: CMTimeRange?, outputURL: URL? = nil,
                               phoneAudioLevel: Double = 1,
                               micAudioLevel: Double = 1) {
    setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered so the parent sees progress live
    let started = Date()
    let done = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 1

    Task {
        do {
            let out = try await Exporter.export(
                phoneURL: phoneURL, cameraURL: cameraURL, cameraOffset: offset,
                layout: layout, zooms: zooms, trim: trim, outputURL: outputURL,
                phoneAudioLevel: phoneAudioLevel, micAudioLevel: micAudioLevel,
                onProgress: { p in print(String(format: "progress %.4f", p)) })
            print(String(format: "OK %@ in %.1fs", out.path, Date().timeIntervalSince(started)))
            exitCode = 0
        } catch {
            print("FAIL: \(error)")
            exitCode = 1
        }
        done.signal()
    }
    if done.wait(timeout: .now() + 600) == .timedOut {
        print("TIMEOUT: export still not finished after 600s")
        exit(2)
    }
    exit(exitCode)
}
