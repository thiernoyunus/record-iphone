import Foundation
import CoreGraphics

/// Pure editor rules. Kept off SwiftUI / AVFoundation so we can test them
/// from `--editor-logic-check` without opening a window.
enum CameraClipStatus: Equatable {
    case hasPicture
    case micOnly
    case wantedButMissing
    case phoneOnly

    static func resolve(wantedCamera: Bool, cameraFileExists: Bool, hasVideoTrack: Bool) -> CameraClipStatus {
        if cameraFileExists, hasVideoTrack { return .hasPicture }
        if cameraFileExists { return .micOnly }
        if wantedCamera { return .wantedButMissing }
        return .phoneOnly
    }

    var hasPicture: Bool { self == .hasPicture }
    var hasMicFile: Bool { self == .hasPicture || self == .micOnly }

    /// Shown in Look → Layout when there is no camera picture.
    var layoutMessage: String {
        switch self {
        case .hasPicture:
            return ""
        case .micOnly:
            return "This take recorded your voice, but not a camera picture. Layout stays phone-only."
        case .wantedButMissing:
            return "The camera was on, but that clip didn't save. The phone screen is here. Record again and leave the camera on until you press Stop."
        case .phoneOnly:
            return "This take is phone-screen only. Turn the Mac camera on before Record if you want your face in the picture."
        }
    }
}

enum SceneTiming {
    static let minDuration = 0.4

    static func move(start: Double, duration: Double, delta: Double, timeline: Double) -> (start: Double, duration: Double) {
        let dur = max(minDuration, duration)
        let maxStart = max(0, timeline - dur)
        return (min(max(start + delta, 0), maxStart), dur)
    }

    /// Stretch a scene from the left or right edge.
    static func resize(start: Double, duration: Double, delta: Double, leading: Bool, timeline: Double) -> (start: Double, duration: Double) {
        if leading {
            let newStart = min(max(start + delta, 0), start + duration - minDuration)
            return (newStart, start + duration - newStart)
        }
        let newDur = min(max(duration + delta, minDuration), max(minDuration, timeline - start))
        return (start, newDur)
    }
}

enum TimelineLayout {
    /// The portion of the take that remains after trimming.
    struct KeepWindow: Equatable {
        var viewStart: Double
        var viewEnd: Double
        var duration: Double
        var trackWidth: CGFloat

        var viewDur: Double { max(viewEnd - viewStart, 0.1) }
        var pps: CGFloat { trackWidth / CGFloat(viewDur) }
        var fullWidth: CGFloat { CGFloat(max(duration, 0.1)) * pps }
        var shift: CGFloat { -CGFloat(viewStart) * pps }

        func x(for time: Double) -> CGFloat {
            CGFloat((time - viewStart) / viewDur) * trackWidth
        }

        func time(at x: CGFloat) -> Double {
            let t = viewStart + Double(x / max(trackWidth, 1)) * viewDur
            return min(max(t, 0), max(duration, 0))
        }

        func intersects(start: Double, duration span: Double) -> Bool {
            start < viewEnd && (start + span) > viewStart
        }
    }

    static func keepWindow(trimStart: Double, trimEnd: Double,
                           duration: Double, trackWidth: CGFloat) -> KeepWindow {
        let dur = max(duration, 0.1)
        let end = min(max(trimEnd, 0.05), dur)
        let start = min(max(trimStart, 0), max(0, end - 0.05))
        return KeepWindow(
            viewStart: start,
            viewEnd: max(end, start + 0.05),
            duration: dur,
            trackWidth: max(trackWidth, 1))
    }

    /// X of the playhead needle inside the timeline card.
    /// `time == 0` is the left edge of the tracks, not the middle.
    static func playheadX(time: Double, duration: Double, trackWidth: CGFloat, labelWidth: CGFloat) -> CGFloat {
        let dur = max(duration, 0.1)
        let t = min(max(time, 0), dur)
        return labelWidth + CGFloat(t / dur) * trackWidth
    }

    static func playheadX(time: Double, window: KeepWindow, labelWidth: CGFloat) -> CGFloat {
        labelWidth + window.x(for: time)
    }

    /// Where a clip that lasts `span` seconds, starting at `start`, sits on a track.
    /// Do not stretch a short file across the leftover timeline.
    static func clipFrame(start: Double, span: Double, timeline: Double, trackWidth: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let t = max(timeline, 0.1)
        let x = CGFloat(max(0, start) / t) * trackWidth
        let w = CGFloat(max(0.05, span) / t) * trackWidth
        return (x, min(max(w, 2), max(2, trackWidth - x)))
    }
}

/// Where phone.mov and camera.mov sit on the finished movie.
///
/// `cameraOffset` is (camera start − phone start). A positive value means the
/// mic file started later — if we put it there, the export is silent at the
/// start and the first words feel cut off. Timeline 0 is always the mic /
/// camera start so speech is at the beginning.
enum ClipAlignment {
    struct Times: Equatable {
        var phoneAt: Double
        var cameraAt: Double
        var phoneSkip: Double
        var cameraSkip: Double
    }

    static func startAtMic(cameraOffsetSeconds offset: Double) -> Times {
        if offset > 0.02 {
            return Times(phoneAt: 0, cameraAt: 0, phoneSkip: offset, cameraSkip: 0)
        }
        if offset < -0.02 {
            return Times(phoneAt: -offset, cameraAt: 0, phoneSkip: 0, cameraSkip: 0)
        }
        return Times(phoneAt: 0, cameraAt: 0, phoneSkip: 0, cameraSkip: 0)
    }

    /// File times (and whether that player should be rolling) for a playhead
    /// on the same timeline the export uses.
    struct SourceTimes: Equatable {
        var phone: Double
        var camera: Double
        var phonePlaying: Bool
        var cameraPlaying: Bool
    }

    static func sourceTimes(timeline: Double, cameraOffsetSeconds offset: Double,
                            phoneDuration: Double = .infinity,
                            cameraDuration: Double = .infinity) -> SourceTimes {
        let a = startAtMic(cameraOffsetSeconds: offset)
        let phoneRaw = timeline - a.phoneAt + a.phoneSkip
        let camRaw = timeline - a.cameraAt + a.cameraSkip
        let phoneCap = phoneDuration.isFinite ? max(0, phoneDuration - 0.001) : .greatestFiniteMagnitude
        let camCap = cameraDuration.isFinite ? max(0, cameraDuration - 0.001) : .greatestFiniteMagnitude
        return SourceTimes(
            phone: min(max(0, phoneRaw), phoneCap),
            camera: min(max(0, camRaw), camCap),
            phonePlaying: phoneRaw >= -0.01 && phoneRaw < phoneDuration - 0.02,
            cameraPlaying: camRaw >= -0.01 && camRaw < cameraDuration - 0.02)
    }

    /// Where a source file sits on the shared timeline (after skip / delay).
    static func clipWindow(fileDuration: Double, at: Double, skip: Double) -> (start: Double, end: Double) {
        (at, at + max(0, fileDuration - skip))
    }

    static func timelineDuration(phone: Double, camera: Double, cameraOffsetSeconds offset: Double) -> Double {
        let a = startAtMic(cameraOffsetSeconds: offset)
        let phoneEnd = a.phoneAt + max(0, phone - a.phoneSkip)
        let camEnd = a.cameraAt + max(0, camera - a.cameraSkip)
        return max(phoneEnd, camEnd, 0.1)
    }

    /// When the iPhone writer dies mid-take the camera file keeps going.
    /// With no mic on that camera file the leftover is a frozen phone
    /// picture and silence — do not keep it as the movie length.
    static func usefulEnd(phone: Double, camera: Double,
                          cameraOffsetSeconds offset: Double,
                          cameraHasMic: Bool) -> Double {
        let full = timelineDuration(phone: phone, camera: camera, cameraOffsetSeconds: offset)
        let a = startAtMic(cameraOffsetSeconds: offset)
        let phoneEnd = a.phoneAt + max(0, phone - a.phoneSkip)
        if cameraHasMic { return full }
        if full > phoneEnd + 1.2 { return max(phoneEnd, 0.1) }
        return full
    }

    /// Phone loudness for this take (0…1).
    /// A value saved in project.json is kept, even if it is quiet.
    /// If there is no saved mix and no mic, leftover quiet values (~16%)
    /// become full volume so an old Instagram mix does not mute the take.
    static func audiblePhoneLevel(saved: Double?, hasMic: Bool, explicitSaved: Bool = false) -> Double {
        guard let saved else { return 1 }
        let level = min(max(saved, 0), 1)
        if explicitSaved { return level }
        if hasMic { return level }
        if saved < 0.30 { return 1 }
        return level
    }

    /// True when the camera file is the playhead clock (mic started first).
    static func cameraIsClock(cameraOffsetSeconds offset: Double) -> Bool {
        offset < -0.02
    }
}

enum PhoneWriterPolicy {
    enum Action: Equatable {
        case ignore
        case restart
        case finishTake
    }

    /// If the iPhone movie writer dies but the cable is still live, start a
    /// new phone file. Only end the take when the device is actually gone.
    static func action(stillRecording: Bool, phoneWriterStopped: Bool,
                       deviceConnected: Bool, sessionRunning: Bool) -> Action {
        guard stillRecording, phoneWriterStopped else { return .ignore }
        if deviceConnected && sessionRunning { return .restart }
        return .finishTake
    }
}

/// How to treat rolled `phone-audio.m4a` + `phone-audio-2.m4a` when a glue
/// step fails. Never keep only the first file if later files exist.
enum AudioJoinPolicy {
    enum Fallback: Equatable {
        case singleFile
        case refusePartial
    }

    static func fallback(partCount: Int) -> Fallback {
        partCount > 1 ? .refusePartial : .singleFile
    }

    static func nextStart(current: Double, duration: Double, skip: Double) -> Double {
        current + max(0, duration - max(0, skip))
    }
}

enum PhoneSegments {
    static func fileName(index: Int) -> String {
        index <= 1 ? "phone.mov" : "phone-\(index).mov"
    }

    static func url(in dir: URL, index: Int) -> URL {
        dir.appendingPathComponent(fileName(index: index))
    }

    static func urls(in dir: URL) -> [URL] {
        var parts: [URL] = []
        var i = 1
        while true {
            let u = url(in: dir, index: i)
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard FileManager.default.fileExists(atPath: u.path), size > 1024 else { break }
            parts.append(u)
            i += 1
        }
        return parts
    }
}

enum SoundPolicy {
    /// Turning the Mac camera on should also record your voice, unless you
    /// already picked Mic only or Both.
    static func modeWhenTurningCameraOn(current: SoundMode) -> SoundMode {
        if current == .off || current == .device { return .both }
        return current
    }
}

enum FilmstripBudget {
    /// More stills when the ruler is stretched, so zoomed thumbs stay sharp.
    static func count(zoom: Double) -> Int {
        min(96, max(16, Int((16 * max(zoom, 1)).rounded())))
    }

    static func cameraCount(zoom: Double) -> Int {
        min(48, max(8, count(zoom: zoom) / 2))
    }

    static func maxHeight(zoom: Double) -> Double {
        160 * min(max(zoom, 1), 2.5)
    }

    static func cameraHeight(zoom: Double) -> Double {
        96 * min(max(zoom, 1), 2.0)
    }

    /// How sloppy the still-grabber can be. Tighter when zoomed so
    /// neighboring frames don't look like the same picture.
    static func timeTolerance(zoom: Double) -> Double {
        max(zoom, 1) > 1.05 ? 0.06 : 0.5
    }

    static func timeTolerance(count: Int) -> Double {
        count > 20 ? 0.06 : 0.5
    }
}

enum ZoomTiming {
    static let minDuration = 0.5

    static func resize(start: Double, duration: Double, delta: Double, leading: Bool, timeline: Double) -> (start: Double, duration: Double) {
        if leading {
            let newStart = min(max(start + delta, 0), start + duration - minDuration)
            return (newStart, start + duration - newStart)
        }
        let newDur = min(max(duration + delta, minDuration), max(minDuration, timeline - start))
        return (start, newDur)
    }
}

/// Zoom chips stick to quarter-seconds, or to the playhead if you are close.
enum ZoomSnap {
    static let step = 0.25
    static let playheadTolerance = 0.15

    static func snap(_ time: Double, playhead: Double?, timeline: Double) -> Double {
        let hi = max(timeline, 0)
        let raw: Double
        if let playhead, abs(time - playhead) < playheadTolerance {
            raw = playhead
        } else {
            raw = (time / step).rounded() * step
        }
        return min(max(raw, 0), hi)
    }

    static func nearPlayhead(_ time: Double, playhead: Double) -> Bool {
        abs(time - playhead) < playheadTolerance
    }

    static func chipLabel(level: Double, duration: Double) -> String {
        String(format: "%.1f× · %.1fs", level, duration)
    }

    static func covers(start: Double, duration: Double, time: Double) -> Bool {
        time >= start && time <= start + duration
    }
}

struct TakeIntentDoc: Codable, Equatable {
    var wantedCamera: Bool
    var cameraEnabled: Bool
    var sound: String

    static func load(from dir: URL) -> TakeIntentDoc? {
        let url = dir.appendingPathComponent("take-intent.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TakeIntentDoc.self, from: data)
    }

    func write(to dir: URL) {
        let url = dir.appendingPathComponent("take-intent.json")
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

enum RecordingSourceRules {
    static func hasPhoneSource(phoneURL: URL, phoneSegments: [URL]) -> Bool {
        phoneSegments.contains { $0.standardizedFileURL == phoneURL.standardizedFileURL }
    }
}

enum RecordingFinishPolicy {
    static func expectedFinishes(hasPhoneSource: Bool, phoneActive: Bool, cameraActive: Bool) -> Int {
        (hasPhoneSource && phoneActive ? 1 : 0) + (cameraActive ? 1 : 0)
    }
}

enum ProjectMediaSelection {
    static func candidates(in dir: URL) -> [URL] {
        [
            dir.appendingPathComponent("phone.mov"),
            dir.appendingPathComponent("camera.mov"),
            dir.appendingPathComponent("camera.keep.mov"),
        ]
    }
}

enum EditorLogicTests {
    static func run() -> (Bool, String) {
        var lines: [String] = []
        var failed = 0
        func expect(_ name: String, _ cond: Bool) {
            if cond { lines.append("OK \(name)") }
            else { lines.append("FAIL \(name)"); failed += 1 }
        }

        let splitLook = ExportLayout(
            bubbleCenter: CGPoint(x: 0.82, y: 0.78), bubbleFraction: 0.22,
            canvas: CGSize(width: 1920, height: 1080), background: .snow, showBezel: false,
            presenterLayout: .split, deviceOnLeft: true)
        let phoneOnly = splitLook.soloCentered(showPhone: true, showCamera: false)
        expect("phone-only leaves the side-by-side layout and sits in the middle",
               phoneOnly.presenterLayout == .floating)
        let both = splitLook.soloCentered(showPhone: true, showCamera: true)
        expect("phone plus camera keep the left/right layout",
               both.presenterLayout == .split && both.deviceOnLeft)
        let camOnly = splitLook.soloCentered(showPhone: false, showCamera: true)
        expect("camera-only sits in the middle of the canvas",
               camOnly.presenterLayout == .floating
               && abs(camOnly.bubbleCenter.x - 0.5) < 0.001
               && abs(camOnly.bubbleCenter.y - 0.5) < 0.001)
        var noPhone = splitLook
        noPhone.hasPhoneSource = false
        noPhone.cameraEnabled = true
        expect("a take with no phone defaults to the camera scene",
               noPhone.scene(at: 1) == .camera)
        expect("scene appearance is 0 at the cut and 1 after a beat",
               ExportLayout.appearanceProgress(at: 2.0, layout: {
                   var l = splitLook
                   l.scenes = [SceneClip(kind: .camera, start: 2, duration: 4)]
                   return l
               }()) < 0.01
               && ExportLayout.appearanceProgress(at: 2.5, layout: {
                   var l = splitLook
                   l.scenes = [SceneClip(kind: .camera, start: 2, duration: 4)]
                   return l
               }()) > 0.99)

        expect("wanted + missing file is a lost camera clip",
               CameraClipStatus.resolve(wantedCamera: true, cameraFileExists: false, hasVideoTrack: false) == .wantedButMissing)
        expect("no camera on + no file is phone-only",
               CameraClipStatus.resolve(wantedCamera: false, cameraFileExists: false, hasVideoTrack: false) == .phoneOnly)
        expect("file with picture is present",
               CameraClipStatus.resolve(wantedCamera: true, cameraFileExists: true, hasVideoTrack: true) == .hasPicture)
        expect("file without picture is mic-only",
               CameraClipStatus.resolve(wantedCamera: false, cameraFileExists: true, hasVideoTrack: false) == .micOnly)
        expect("lost-clip message mentions save failure",
               CameraClipStatus.wantedButMissing.layoutMessage.contains("didn't save"))
        expect("phone-only message does not claim a failed save",
               !CameraClipStatus.phoneOnly.layoutMessage.contains("didn't save"))
        let takeDir = URL(fileURLWithPath: "/tmp/record-iphone-take")
        let phoneURL = takeDir.appendingPathComponent("phone.mov")
        let cameraURL = takeDir.appendingPathComponent("camera.mov")
        expect("phone-only source stays a phone source",
               RecordingSourceRules.hasPhoneSource(phoneURL: phoneURL, phoneSegments: [phoneURL]))
        expect("camera-only source is not mistaken for a phone source",
               !RecordingSourceRules.hasPhoneSource(phoneURL: cameraURL, phoneSegments: [phoneURL]))
        expect("camera-only finish counts only the camera writer",
               RecordingFinishPolicy.expectedFinishes(hasPhoneSource: false, phoneActive: true, cameraActive: true) == 1)
        expect("phone and camera finish count both writers",
               RecordingFinishPolicy.expectedFinishes(hasPhoneSource: true, phoneActive: true, cameraActive: true) == 2)
        expect("thumbnail candidates prefer phone then camera snapshot",
               ProjectMediaSelection.candidates(in: takeDir).map(\.lastPathComponent)
                == ["phone.mov", "camera.mov", "camera.keep.mov"])

        let stretched = SceneTiming.resize(start: 2, duration: 4, delta: 6, leading: false, timeline: 26)
        expect("device scene can stretch longer", abs(stretched.duration - 10) < 0.001 && abs(stretched.start - 2) < 0.001)
        let fill = SceneTiming.resize(start: 2, duration: 4, delta: 40, leading: false, timeline: 26)
        expect("device scene can fill the leftover timeline", abs(fill.duration - 24) < 0.001)
        let shrink = SceneTiming.resize(start: 2, duration: 4, delta: -10, leading: false, timeline: 26)
        expect("scene cannot shrink below the minimum", abs(shrink.duration - SceneTiming.minDuration) < 0.001)
        let lead = SceneTiming.resize(start: 4, duration: 4, delta: -2, leading: true, timeline: 26)
        expect("leading handle grows the scene backward", abs(lead.start - 2) < 0.001 && abs(lead.duration - 6) < 0.001)
        let moved = SceneTiming.move(start: 2, duration: 4, delta: 30, timeline: 26)
        expect("move stays on the timeline", abs(moved.start - 22) < 0.001)

        let zoomGrow = ZoomTiming.resize(start: 0, duration: 2.4, delta: 4, leading: false, timeline: 26)
        expect("zoom handle can grow", abs(zoomGrow.duration - 6.4) < 0.001)

        let x0 = TimelineLayout.playheadX(time: 0, duration: 29, trackWidth: 800, labelWidth: 56)
        expect("playhead at 0 sits at the start of the tracks", abs(x0 - 56) < 0.01)
        let xEnd = TimelineLayout.playheadX(time: 29, duration: 29, trackWidth: 800, labelWidth: 56)
        expect("playhead at the end sits at the right of the tracks", abs(xEnd - 856) < 0.01)
        let xMid = TimelineLayout.playheadX(time: 14.5, duration: 29, trackWidth: 800, labelWidth: 56)
        expect("playhead in the middle is actually the middle", abs(xMid - 456) < 0.5)

        let keep = TimelineLayout.keepWindow(trimStart: 2, trimEnd: 12, duration: 20, trackWidth: 1000)
        expect("kept start sits on the left edge", abs(keep.x(for: 2)) < 0.01)
        expect("kept end sits on the right edge", abs(keep.x(for: 12) - 1000) < 0.01)
        expect("cut-away head is off the left of the track", keep.x(for: 0) < -1)
        expect("cut-away tail is off the right of the track", keep.x(for: 20) > 1001)
        expect("clicking the left edge lands on the kept start",
               abs(keep.time(at: 0) - 2) < 0.001)
        expect("an entirely trimmed clip does not overlap the keep",
               !keep.intersects(start: 0, duration: 1.5))
        let uncut = TimelineLayout.keepWindow(trimStart: 0, trimEnd: 20, duration: 20, trackWidth: 1000)
        expect("an untrimmed take keeps its full timeline",
               abs(uncut.x(for: 0)) < 0.01 && abs(uncut.x(for: 20) - 1000) < 0.01
                && abs(uncut.shift) < 0.01 && abs(uncut.fullWidth - 1000) < 0.01)

        expect("style menu is named colors, not a pastel dump",
               SolidSwatch.styleMenu.allSatisfy { !$0.name.lowercased().contains("pastel") })
        expect("style menu has a useful set of colors",
               SolidSwatch.styleMenu.count >= 8 && SolidSwatch.styleMenu.count <= 16)
        expect("soft colors stay a short row",
               SolidSwatch.pastels.count <= 6)
        expect("soft colors are uniquely named",
               Set(SolidSwatch.pastels.map(\.name)).count == SolidSwatch.pastels.count)

        let lateMic = ClipAlignment.startAtMic(cameraOffsetSeconds: 0.944)
        expect("late mic starts the movie at the first spoken word",
               abs(lateMic.cameraAt) < 0.001 && abs(lateMic.phoneSkip - 0.944) < 0.001 && abs(lateMic.phoneAt) < 0.001)
        let earlyMic = ClipAlignment.startAtMic(cameraOffsetSeconds: -0.80)
        expect("early mic keeps the first words and delays the phone picture",
               abs(earlyMic.cameraAt) < 0.001 && abs(earlyMic.phoneAt - 0.80) < 0.001 && abs(earlyMic.phoneSkip) < 0.001)
        let together = ClipAlignment.startAtMic(cameraOffsetSeconds: 0.004)
        expect("tiny offsets stay lined up",
               abs(together.phoneAt) < 0.001 && abs(together.cameraAt) < 0.001 && abs(together.phoneSkip) < 0.001)

        // Real take 18.22.09: camera started 2.072s first. Preview used to
        // show the face 2s ahead of the phone; export started both at mic t=0.
        let t0 = ClipAlignment.sourceTimes(timeline: 0, cameraOffsetSeconds: -2.072)
        expect("early-mic preview starts the face at file 0, not 2s in",
               abs(t0.camera) < 0.001 && t0.cameraPlaying && !t0.phonePlaying && abs(t0.phone) < 0.001)
        let tGo = ClipAlignment.sourceTimes(timeline: 2.072, cameraOffsetSeconds: -2.072)
        expect("early-mic preview starts the phone when the camera has played the wait",
               abs(tGo.phone) < 0.001 && tGo.phonePlaying && abs(tGo.camera - 2.072) < 0.001)
        let late0 = ClipAlignment.sourceTimes(timeline: 0, cameraOffsetSeconds: 0.944)
        expect("late-mic preview skips the silent phone preroll",
               abs(late0.phone - 0.944) < 0.001 && abs(late0.camera) < 0.001 && late0.phonePlaying && late0.cameraPlaying)
        // Old editor formula would have been camera = timeline - offset.
        let oldWrong = max(0, 0 - (-2.072))
        expect("old preview formula is the 2s-ahead bug", abs(oldWrong - 2.072) < 0.001)
        let dur = ClipAlignment.timelineDuration(phone: 20.33, camera: 27.71, cameraOffsetSeconds: -2.072)
        expect("timeline is long enough for the longer camera file", abs(dur - 27.71) < 0.02)

        // 18.45.54: 18.8s of iPhone sound on a 37.9s timeline must not be
        // stretched to the end — that put the wave ~2× too far right.
        let wave = TimelineLayout.clipFrame(start: 1.89, span: 18.77, timeline: 37.92, trackWidth: 1000)
        expect("short phone audio only fills its own seconds",
               abs(wave.x - 49.8) < 2 && abs(wave.width - 495) < 8)
        expect("short phone audio does not fill the leftover timeline",
               wave.width < 700)

        let afterPhone = ClipAlignment.sourceTimes(
            timeline: 23, cameraOffsetSeconds: -1.893,
            phoneDuration: 18.67, cameraDuration: 37.89)
        expect("after the phone file ends, preview keeps the last phone frame",
               abs(afterPhone.phone - 18.669) < 0.01 && !afterPhone.phonePlaying)
        expect("after the phone file ends, the camera keeps rolling",
               abs(afterPhone.camera - 23) < 0.01 && afterPhone.cameraPlaying)
        let phoneWin = ClipAlignment.clipWindow(fileDuration: 18.67, at: 1.893, skip: 0)
        expect("phone picture ends when the phone file ends, not the leftover camera",
               abs(phoneWin.start - 1.893) < 0.001 && abs(phoneWin.end - 20.563) < 0.01)
        expect("zoomed timeline asks for more filmstrip stills",
               FilmstripBudget.count(zoom: 1) == 16 && FilmstripBudget.count(zoom: 2) == 32)
        expect("zoomed stills are taller so they stay sharp",
               FilmstripBudget.maxHeight(zoom: 2) > FilmstripBudget.maxHeight(zoom: 1))
        expect("zoomed stills grab a tighter moment in the take",
               FilmstripBudget.timeTolerance(zoom: 2) < FilmstripBudget.timeTolerance(zoom: 1))
        expect("more stills also mean a tighter grab",
               FilmstripBudget.timeTolerance(count: 32) < FilmstripBudget.timeTolerance(count: 16))
        expect("camera stills grow when the ruler is stretched",
               FilmstripBudget.cameraHeight(zoom: 2) > FilmstripBudget.cameraHeight(zoom: 1))

        for (name, ok) in WallpaperCatalog.logicChecks() {
            expect(name, ok)
        }

        expect("zoom start snaps to quarter seconds",
               abs(ZoomSnap.snap(1.12, playhead: nil, timeline: 20) - 1.0) < 0.001)
        expect("zoom start snaps to the playhead when close",
               abs(ZoomSnap.snap(5.08, playhead: 5.0, timeline: 20) - 5.0) < 0.001)
        expect("zoom start stays on the quarter grid when the playhead is far",
               abs(ZoomSnap.snap(5.20, playhead: 8.0, timeline: 20) - 5.25) < 0.001)
        expect("playhead snap wins over the quarter grid",
               abs(ZoomSnap.snap(3.12, playhead: 3.20, timeline: 20) - 3.20) < 0.001)
        expect("snap cannot leave the timeline",
               abs(ZoomSnap.snap(99, playhead: nil, timeline: 10) - 10) < 0.001)
        expect("a playhead already on the grid stays put",
               abs(ZoomSnap.snap(2.0, playhead: 2.0, timeline: 10) - 2.0) < 0.001)
        expect("zoom chip names the level and how long it lasts",
               ZoomSnap.chipLabel(level: 1.5, duration: 2.4) == "1.5× · 2.4s")
        expect("hover plus hides when that time already has a zoom",
               ZoomSnap.covers(start: 2, duration: 2.4, time: 3.1)
                && !ZoomSnap.covers(start: 2, duration: 2.4, time: 5))

        // Recording12 / 19.25.56: phone died at ~31s, camera ran to 69s,
        // no mic. The leftover is freeze + silence.
        let rec12 = ClipAlignment.usefulEnd(
            phone: 31.31, camera: 69.24,
            cameraOffsetSeconds: -1.277, cameraHasMic: false)
        expect("no-mic camera tail is cut so the movie is not frozen silence",
               abs(rec12 - 32.587) < 0.05)
        let rec12mic = ClipAlignment.usefulEnd(
            phone: 31.31, camera: 69.24,
            cameraOffsetSeconds: -1.277, cameraHasMic: true)
        expect("a real mic take keeps the camera tail",
               abs(rec12mic - 69.24) < 0.05)
        expect("16% iPhone slider with no mic is treated as leftover mix",
               abs(ClipAlignment.audiblePhoneLevel(saved: 0.160, hasMic: false) - 1) < 0.001)
        expect("a real mic mix keeps the saved iPhone slider",
               abs(ClipAlignment.audiblePhoneLevel(saved: 0.160, hasMic: true) - 0.160) < 0.001)
        expect("saved 0.16 with mic stays 0.16",
               abs(ClipAlignment.audiblePhoneLevel(saved: 0.160, hasMic: true, explicitSaved: true) - 0.160) < 0.001)
        expect("saved 0.16 with no mic stays 0.16 when the take saved a mix",
               abs(ClipAlignment.audiblePhoneLevel(saved: 0.160, hasMic: false, explicitSaved: true) - 0.160) < 0.001)
        expect("missing mix with no mic is full phone sound",
               abs(ClipAlignment.audiblePhoneLevel(saved: nil, hasMic: false) - 1) < 0.001)
        expect("phone writer death while still plugged in restarts the file",
               PhoneWriterPolicy.action(stillRecording: true, phoneWriterStopped: true,
                                       deviceConnected: true, sessionRunning: true) == .restart)
        expect("phone writer death after unplug finishes the take",
               PhoneWriterPolicy.action(stillRecording: true, phoneWriterStopped: true,
                                       deviceConnected: false, sessionRunning: false) == .finishTake)
        expect("a normal Stop is not treated as a mid-take death",
               PhoneWriterPolicy.action(stillRecording: false, phoneWriterStopped: true,
                                       deviceConnected: true, sessionRunning: true) == .ignore)
        expect("first phone part is phone.mov", PhoneSegments.fileName(index: 1) == "phone.mov")
        expect("second phone part is phone-2.mov", PhoneSegments.fileName(index: 2) == "phone-2.mov")
        expect("one audio file can be used as-is",
               AudioJoinPolicy.fallback(partCount: 1) == .singleFile)
        expect("two audio files must not fall back to only the first",
               AudioJoinPolicy.fallback(partCount: 2) == .refusePartial)
        expect("second audio piece starts after the first minus skip",
               abs(AudioJoinPolicy.nextStart(current: 1.0, duration: 10, skip: 0.5) - 10.5) < 0.001)
        expect("turning the camera on also records your voice",
               SoundPolicy.modeWhenTurningCameraOn(current: .device) == .both)

        let report = lines.joined(separator: "\n")
        return (failed == 0, failed == 0 ? report + "\nOK editor-logic-check" : report + "\nFAIL editor-logic-check (\(failed))")
    }
}
