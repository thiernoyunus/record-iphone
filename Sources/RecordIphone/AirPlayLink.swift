import Foundation

/// Wireless session state. Keep this a plain value so we can test lock /
/// drop / reconnect without a phone.
enum AirPlayLink: String, Equatable {
    case idle
    case waiting
    case live
    case locked
    case dropped
}

enum AirPlayLinkEvent: String, Equatable {
    case start
    case client
    case frame
    case paused
    case resumed
    case dropped
    case stop
}

struct AirPlayLinkMachine: Equatable {
    var link: AirPlayLink = .idle
    var hadPicture = false
    /// True after a full drop (not a lock) so the recorder can save and stop.
    var shouldStopRecording = false

    var holdsPreview: Bool {
        switch link {
        case .live, .locked: return true
        case .waiting, .dropped: return hadPicture
        case .idle: return false
        }
    }

    mutating func apply(_ event: AirPlayLinkEvent) {
        shouldStopRecording = false
        switch (link, event) {
        case (_, .start):
            link = .waiting
            hadPicture = false
        case (_, .stop):
            link = .idle
            hadPicture = false
        case (_, .frame):
            link = .live
            hadPicture = true
        case (.live, .paused), (.waiting, .paused):
            link = .locked
        case (.locked, .resumed):
            link = .waiting
        case (.live, .dropped), (.locked, .dropped), (.waiting, .dropped):
            if hadPicture {
                link = .dropped
                shouldStopRecording = true
            } else {
                link = .waiting
            }
        case (.dropped, .client), (.dropped, .resumed),
             (.idle, .client), (.waiting, .client):
            link = .waiting
        default:
            break
        }
    }
}

enum AirPlayLinkTests {
    static func run() -> (Bool, String) {
        var fails: [String] = []
        func check(_ name: String, _ ok: Bool) {
            if !ok { fails.append(name) }
        }

        // 1. Happy path: wait → picture.
        var m = AirPlayLinkMachine()
        m.apply(.start)
        check("start waits", m.link == .waiting && !m.holdsPreview)
        m.apply(.client)
        m.apply(.frame)
        check("frame is live", m.link == .live && m.holdsPreview && !m.shouldStopRecording)

        // 2. Lock then unlock: keep last frame, then go live again.
        m.apply(.paused)
        check("lock keeps preview", m.link == .locked && m.holdsPreview && !m.shouldStopRecording)
        m.apply(.resumed)
        check("unlock waits for picture", m.link == .waiting && m.holdsPreview)
        m.apply(.frame)
        check("unlock lives", m.link == .live)

        // 3. Stop mirroring while live: keep last frame, tell recorder to stop.
        m.apply(.dropped)
        check("drop stops recording", m.link == .dropped && m.holdsPreview && m.shouldStopRecording)
        m.apply(.client)
        m.apply(.frame)
        check("reconnect lives", m.link == .live && !m.shouldStopRecording)

        // 4. Drop before any picture: stay waiting, don't stop a recording.
        m = AirPlayLinkMachine()
        m.apply(.start)
        m.apply(.dropped)
        check("early drop stays waiting", m.link == .waiting && !m.shouldStopRecording && !m.holdsPreview)

        let ok = fails.isEmpty
        let detail = ok ? "OK \(4) airplay edge cases" : "FAIL \(fails.joined(separator: ", "))"
        return (ok, detail)
    }
}
