import SwiftUI
import CoreMedia

@main
struct RecordIphoneApp: App {
    @StateObject private var engine = CaptureEngine()

    init() {
        runExportTestIfRequested()
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

/// Headless self-check: `"Record iPhone" --export-test phone.mov camera.mov`
/// runs the export pipeline on existing recordings, prints progress and
/// timing, and exits. Lets us verify and time exports without the UI.
private func runExportTestIfRequested() {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--export-test"), args.count > i + 2 else { return }
    let phoneURL = URL(fileURLWithPath: args[i + 1])
    let cameraURL = URL(fileURLWithPath: args[i + 2])
    let started = Date()
    let done = DispatchSemaphore(value: 0)

    // RECORD_TEST_ZOOMS=1 adds a zoom at 3s–7s so the zoom path gets exercised.
    let zooms: [ZoomSegment] = ProcessInfo.processInfo.environment["RECORD_TEST_ZOOMS"] == "1"
        ? [ZoomSegment(start: 3, duration: 4, center: CGPoint(x: 0.5, y: 0.45), level: 2.2)]
        : []
    Task {
        do {
            let out = try await Exporter.export(
                phoneURL: phoneURL, cameraURL: cameraURL,
                cameraOffset: .zero,
                layout: ExportLayout(bubbleCenter: CGPoint(x: 0.82, y: 0.76), bubbleFraction: 0.30,
                                     canvas: CanvasPreset.landscape.size,
                                     background: .midnight, showBezel: true),
                zooms: zooms,
                onProgress: { p in print(String(format: "progress %3.0f%%", p * 100)) })
            print(String(format: "OK %@ in %.1fs", out.path, Date().timeIntervalSince(started)))
        } catch {
            print("FAIL: \(error)")
        }
        done.signal()
    }
    if done.wait(timeout: .now() + 300) == .timedOut {
        print(String(format: "TIMEOUT: export still not finished after 300s"))
        exit(2)
    }
    exit(0)
}
