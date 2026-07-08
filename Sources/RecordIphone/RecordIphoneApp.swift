import SwiftUI
import CoreMedia

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
                .onAppear { engine.start() }
        }
        .windowResizability(.contentSize)
    }
}

/// Headless modes (no UI, print progress, exit):
///   --export-json <spec.json>       full export driven by an ExportSpec —
///                                   this is how the app's own exports run,
///                                   in a clean worker process.
///   --export-test <phone> <camera>  quick default-look export for testing.
private func runHeadlessModeIfRequested() {
    let args = CommandLine.arguments
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
            layout: spec.layout, zooms: spec.zooms, trim: trim)
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

private func runHeadlessExport(phoneURL: URL, cameraURL: URL, offset: CMTime,
                               layout: ExportLayout, zooms: [ZoomSegment],
                               trim: CMTimeRange?) {
    setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered so the parent sees progress live
    let started = Date()
    let done = DispatchSemaphore(value: 0)

    Task {
        do {
            let out = try await Exporter.export(
                phoneURL: phoneURL, cameraURL: cameraURL, cameraOffset: offset,
                layout: layout, zooms: zooms, trim: trim,
                onProgress: { p in print(String(format: "progress %.4f", p)) })
            print(String(format: "OK %@ in %.1fs", out.path, Date().timeIntervalSince(started)))
        } catch {
            print("FAIL: \(error)")
        }
        done.signal()
    }
    if done.wait(timeout: .now() + 600) == .timedOut {
        print("TIMEOUT: export still not finished after 600s")
        exit(2)
    }
    exit(0)
}
