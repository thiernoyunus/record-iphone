import AppKit
import SwiftUI

/// App-wide preferences (Settings window + Export).
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    enum ExportPlace: String, CaseIterable, Identifiable {
        case ask = "ask"
        case recordingFolder = "recording"
        case customFolder = "custom"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .ask: return "Ask me where to save"
            case .recordingFolder: return "Save in the recording folder"
            case .customFolder: return "Always save to a folder I pick"
            }
        }
        var detail: String {
            switch self {
            case .ask: return "Opens the Mac save window each time. Starts in your last folder."
            case .recordingFolder: return "Puts the movie next to phone.mov in Movies/Record iPhone."
            case .customFolder: return "Always writes to the folder you choose below."
            }
        }
    }

    @Published var exportPlace: ExportPlace {
        didSet { UserDefaults.standard.set(exportPlace.rawValue, forKey: Keys.exportPlace) }
    }
    @Published var customExportPath: String {
        didSet { UserDefaults.standard.set(customExportPath, forKey: Keys.customExportPath) }
    }
    /// 0 = start recording immediately. 3 or 5 = countdown.
    @Published var countdownSeconds: Int {
        didSet { UserDefaults.standard.set(countdownSeconds, forKey: Keys.countdownSeconds) }
    }
    @Published var defaultPhoneAudio: Double {
        didSet { UserDefaults.standard.set(defaultPhoneAudio, forKey: Keys.defaultPhoneAudio) }
    }
    @Published var defaultMicAudio: Double {
        didSet { UserDefaults.standard.set(defaultMicAudio, forKey: Keys.defaultMicAudio) }
    }

    private enum Keys {
        static let exportPlace = "recordiphone.exportPlace"
        static let customExportPath = "recordiphone.customExportPath"
        static let lastExportDirectory = "recordiphone.lastExportDirectory"
        static let countdownSeconds = "recordiphone.countdownSeconds"
        static let defaultPhoneAudio = "recordiphone.defaultPhoneAudio"
        static let defaultMicAudio = "recordiphone.defaultMicAudio"
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Keys.exportPlace) ?? ExportPlace.ask.rawValue
        exportPlace = ExportPlace(rawValue: raw) ?? .ask
        customExportPath = UserDefaults.standard.string(forKey: Keys.customExportPath) ?? ""
        let cd = UserDefaults.standard.object(forKey: Keys.countdownSeconds) as? Int
        countdownSeconds = cd ?? 3
        let phone = UserDefaults.standard.object(forKey: Keys.defaultPhoneAudio) as? Double
        defaultPhoneAudio = phone ?? 1
        let mic = UserDefaults.standard.object(forKey: Keys.defaultMicAudio) as? Double
        defaultMicAudio = mic ?? 1
    }

    var lastExportDirectory: URL {
        if let path = UserDefaults.standard.string(forKey: Keys.lastExportDirectory),
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return CaptureEngine.recordingsRoot
    }

    func rememberExportDirectory(_ url: URL) {
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: Keys.lastExportDirectory)
    }

    func pickCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Exported movies will go in this folder."
        if let current = customFolderURL { panel.directoryURL = current }
        if panel.runModal() == .OK, let url = panel.url {
            customExportPath = url.path
        }
    }

    var customFolderURL: URL? {
        let path = customExportPath
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Export") {
                Picker("When I export", selection: $settings.exportPlace) {
                    ForEach(AppSettings.ExportPlace.allCases) { place in
                        Text(place.title).tag(place)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(settings.exportPlace.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if settings.exportPlace == .customFolder {
                    HStack {
                        Text(settings.customExportPath.isEmpty
                             ? "No folder chosen yet"
                             : settings.customExportPath)
                            .lineLimit(2)
                            .foregroundStyle(settings.customExportPath.isEmpty ? .secondary : .primary)
                        Spacer()
                        Button("Choose Folder…") { settings.pickCustomFolder() }
                    }
                }

                Button("Show recordings folder") {
                    NSWorkspace.shared.open(CaptureEngine.recordingsRoot)
                }
            }

            Section("Recording") {
                Picker("Countdown", selection: $settings.countdownSeconds) {
                    Text("None — start immediately").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                }
            }

            Section("Default sound levels") {
                Text("Used for new recordings. You can still change levels on each take.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text("Phone sound")
                    Slider(value: $settings.defaultPhoneAudio, in: 0...1)
                }
                VStack(alignment: .leading) {
                    Text("Your voice (Mac mic)")
                    Slider(value: $settings.defaultMicAudio, in: 0...1)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 520)
        .padding()
    }
}
