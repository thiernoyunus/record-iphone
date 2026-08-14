import AppKit
import AVFoundation
import CoreMedia
import Darwin
import Foundation
import SwiftUI
import VideoToolbox

/// Bezel-style wireless path: our helper advertises this Mac as
/// "Record iPhone" in Control Center → Screen Mirroring. The phone
/// stays unlocked; the picture lands in our window, not full-screen.
@MainActor
final class AirPlayMirror: ObservableObject {
    enum Status: Equatable {
        case off
        case advertising
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var link = AirPlayLinkMachine()
    @Published private(set) var deviceName = "iPhone"
    @Published private(set) var deviceModel = ""
    @Published var pinCode: String?
    @Published private(set) var sourceSize = CGSize(width: 1170, height: 2532)

    let displayLayer = AVSampleBufferDisplayLayer()
    let latestFrame = FrameStore()

    var isConnected: Bool { link.link == .live }

    var isLive: Bool {
        switch link.link {
        case .waiting, .live, .locked, .dropped: return true
        default: return false
        }
    }

    var overlayMessage: String? {
        switch link.link {
        case .locked:
            return "Phone locked. Unlock it — the picture will come back."
        case .dropped:
            return "Mirroring stopped. On the iPhone, tap Screen Mirroring → Record iPhone."
        case .waiting where link.hadPicture:
            return "Waiting for the picture again. Keep the phone unlocked."
        default:
            return nil
        }
    }

    var aspect: CGFloat {
        guard sourceSize.height > 1 else { return 0.462 }
        return sourceSize.width / sourceSize.height
    }

    nonisolated(unsafe) private var process: Process?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var videoHandle: FileHandle?
    nonisolated(unsafe) private var videoSource: DispatchSourceRead?
    nonisolated(unsafe) private var listenSource: DispatchSourceRead?
    nonisolated(unsafe) private var videoFD: Int32 = -1
    private var listenFD: Int32 = -1
    private var sockPath = ""
    private let ioQueue = DispatchQueue(label: "airplay.io")
    private let decodeQueue = DispatchQueue(label: "airplay.decode")
    /// When the review screen is open we skip drawing live frames so they
    /// don't fight the player on the main thread.
    nonisolated(unsafe) var mutePresentation = false
    /// Screenshot asks for one still; we do not copy every live frame.
    nonisolated(unsafe) var captureNextStill = false
    nonisolated(unsafe) private var leftover = Data()
    nonisolated(unsafe) private var videoLeftover = Data()
    nonisolated(unsafe) private var decoder = H264Decoder()
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var writerAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var writerStarted = false
    private var firstPTS: CMTime?
    private var helperFirstPTSNanos: UInt64?
    private var pendingRecordURL: URL?
    private var lastFrameAt = Date.distantPast
    private var watchTimer: Timer?
    var onLinkChange: ((AirPlayLinkMachine) -> Void)?

    func start() {
        stop()
        pinCode = nil
        decoder = H264Decoder()
        leftover = Data()
        videoLeftover = Data()
        applyLink(.start)

        guard let url = Self.helperURL() else {
            status = .failed("Wireless mirroring isn’t bundled in this build. Rebuild the app with ./build.sh.")
            return
        }

        guard let path = startVideoListener() else {
            status = .failed("Couldn’t open the wireless picture pipe.")
            return
        }

        let proc = Process()
        proc.executableURL = url
        proc.arguments = ["--name", "Record iPhone", "--video-sock", path]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.process === p {
                    if case .failed = self.status { return }
                    if self.status != .off {
                        self.status = .failed("Wireless mirroring stopped unexpectedly.")
                    }
                    self.process = nil
                }
            }
        }

        do {
            try proc.run()
        } catch {
            status = .failed("Couldn’t start wireless mirroring: \(error.localizedDescription)")
            return
        }

        process = proc
        stdoutHandle = out.fileHandleForReading
        stderrHandle = err.fileHandleForReading
        status = .advertising
        startWatch()
        readEvents(out.fileHandleForReading)
        readStderr(err.fileHandleForReading)
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        videoHandle?.readabilityHandler = nil
        videoSource?.cancel()
        videoSource = nil
        listenSource?.cancel()
        listenSource = nil
        videoFD = -1
        stdoutHandle = nil
        stderrHandle = nil
        videoHandle = nil
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        if !sockPath.isEmpty { unlink(sockPath) }
        leftover = Data()
        videoLeftover = Data()
        watchTimer?.invalidate()
        watchTimer = nil
        Task { await finishWriter(cancel: true) }
        applyLink(.stop)
        if status != .off { status = .off }
        pinCode = nil
    }

    func beginRecording(to url: URL) throws {
        let staleWriter = writer
        let staleInput = writerInput
        let staleURL = pendingRecordURL
        writer = nil
        writerInput = nil
        writerAdaptor = nil
        writerStarted = false
        firstPTS = nil
        helperFirstPTSNanos = nil
        pendingRecordURL = nil
        if staleWriter != nil || staleInput != nil {
            Task.detached(priority: .utility) {
                staleInput?.markAsFinished()
                if let staleWriter, staleWriter.status == .writing {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        staleWriter.finishWriting { cont.resume() }
                    }
                }
                if let staleURL { try? FileManager.default.removeItem(at: staleURL) }
            }
        }
        let size = sourceSize.width > 8 && sourceSize.height > 8
            ? sourceSize : CGSize(width: 1170, height: 2532)
        let writer = try AVAssetWriter(url: url, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = true
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ])
        guard writer.canAdd(input) else {
            throw NSError(domain: "AirPlay", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn’t prepare wireless recording."])
        }
        writer.add(input)
        self.writer = writer
        writerInput = input
        writerAdaptor = adaptor
        writerStarted = false
        firstPTS = nil
        helperFirstPTSNanos = nil
        pendingRecordURL = url
    }

    func endRecording() async -> URL? {
        let url = pendingRecordURL
        await finishWriter(cancel: false)
        return url
    }

    func abandonRecording() {
        Task { await finishWriter(cancel: true) }
    }

    private func finishWriter(cancel: Bool) async {
        guard let writer else { return }
        let input = writerInput
        let savedURL = pendingRecordURL
        writerInput = nil
        writerAdaptor = nil
        self.writer = nil
        writerStarted = false
        firstPTS = nil
        helperFirstPTSNanos = nil
        pendingRecordURL = nil
        input?.markAsFinished()
        if writer.status == .writing {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        writer.finishWriting { cont.resume() }
                    }
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
                await group.next()
                group.cancelAll()
            }
        }
        if cancel, let savedURL {
            try? FileManager.default.removeItem(at: savedURL)
        }
    }

    private func applyLink(_ event: AirPlayLinkEvent) {
        var next = link
        next.apply(event)
        if event == .frame { lastFrameAt = Date() }
        guard next != link else { return }
        let before = link
        link = next
        // Keep the last decoder across lock/unlock. Wiping it here
        // drops the VPS/SPS that just arrived, so unlock stays frozen.
        if event == .dropped || event == .start {
            decoder = H264Decoder()
        }
        if before.link == .locked, event == .frame {
            displayLayer.flush()
        }
        if link.link == .live { status = .connected }
        else if link.link == .waiting || link.link == .dropped { status = .advertising }
        else if link.link == .locked { status = .connected }
        onLinkChange?(link)
    }

    private func startWatch() {
        watchTimer?.invalidate()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let silence = Date().timeIntervalSince(self.lastFrameAt)
                if self.mutePresentation { return }
                if self.link.link == .live, silence > 2.5 {
                    self.applyLink(.paused)
                }
            }
        }
    }

    private func handleFrame(data: Data, ptsNanos: UInt64, isHEVC: Bool) {
        applyLink(.frame)
        decodeQueue.async { [weak self] in
            self?.decoder.decode(annexB: data, hevc: isHEVC) { sample, pixel in
                Task { @MainActor in
                    self?.present(sample: sample, pixel: pixel, ptsNanos: ptsNanos)
                }
            }
        }
    }

    private func present(sample: CMSampleBuffer?, pixel: CVPixelBuffer?, ptsNanos: UInt64) {
        if let sample {
            if displayLayer.status == .failed {
                displayLayer.flush()
            }
            displayLayer.enqueue(sample)
        }
        if let pixel {
            if captureNextStill {
                latestFrame.set(pixel)
                captureNextStill = false
            }
            let w = CVPixelBufferGetWidth(pixel)
            let h = CVPixelBufferGetHeight(pixel)
            if w > 0, h > 0 {
                let size = CGSize(width: w, height: h)
                if size != sourceSize { sourceSize = size }
            }
            appendRecord(pixel: pixel, ptsNanos: ptsNanos)
        }
        if status == .advertising || status == .connecting {
            status = .connected
        }
    }

    private func appendRecord(pixel: CVPixelBuffer, ptsNanos: UInt64) {
        guard let writer, let input = writerInput, let adaptor = writerAdaptor else { return }
        guard writer.status != .failed else { return }
        let stamp: CMTime
        if ptsNanos > 0 {
            let origin = helperFirstPTSNanos ?? ptsNanos
            if helperFirstPTSNanos == nil { helperFirstPTSNanos = ptsNanos }
            let delta = ptsNanos >= origin ? ptsNanos - origin : 0
            stamp = CMTime(value: Int64(delta), timescale: 1_000_000_000)
        } else if helperFirstPTSNanos != nil {
            // Already committed to helper timestamps; drop a packet with none.
            return
        } else if let firstPTS {
            stamp = CMTimeMaximum(firstPTS, CMClockGetTime(CMClockGetHostTimeClock()))
        } else {
            stamp = CMClockGetTime(CMClockGetHostTimeClock())
        }
        if !writerStarted {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: stamp)
            writerStarted = true
            firstPTS = stamp
        }
        guard let firstPTS, stamp >= firstPTS else { return }
        if input.isReadyForMoreMediaData {
            if !adaptor.append(pixel, withPresentationTime: stamp) {
                NSLog("[airplay] record append failed: %@",
                      writer.error?.localizedDescription ?? "unknown")
            }
        }
    }

    private func handleEvent(_ json: [String: Any]) {
        let type = json["type"] as? String ?? ""
        switch type {
        case "ready":
            if status == .off || status == .advertising { status = .advertising }
        case "connecting":
            if status == .advertising { status = .connecting }
            applyLink(.client)
        case "client":
            if let n = json["name"] as? String, !n.isEmpty { deviceName = n }
            if let m = json["model"] as? String { deviceModel = m }
            if status == .advertising || status == .connecting { status = .connecting }
            applyLink(.client)
        case "size":
            let w = (json["sourceWidth"] as? Double) ?? (json["width"] as? Double) ?? 0
            let h = (json["sourceHeight"] as? Double) ?? (json["height"] as? Double) ?? 0
            if w > 8, h > 8 { sourceSize = CGSize(width: w, height: h) }
            if status == .advertising || status == .connecting { status = .connecting }
        case "paused":
            applyLink(.paused)
        case "resumed":
            applyLink(.resumed)
        case "disconnect", "reset":
            applyLink(.dropped)
        case "pin":
            pinCode = json["pin"] as? String
        case "error":
            status = .failed(json["message"] as? String ?? "Wireless mirroring failed.")
        default:
            break
        }
    }

    private func startVideoListener() -> String? {
        let path = NSTemporaryDirectory() + "record-iphone-airplay.sock"
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        guard var addr = Self.unixSockaddr(path: path) else {
            close(fd)
            return nil
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            close(fd)
            return nil
        }
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        listenFD = fd
        sockPath = path
        let queue = ioQueue
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { break }
                    break
                }
                self.attachVideoClient(client, queue: queue)
            }
        }
        listenSource = src
        src.resume()
        return path
    }

    nonisolated private func attachVideoClient(_ client: Int32, queue: DispatchQueue) {
        videoSource?.cancel()
        videoSource = nil
        let flags = fcntl(client, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(client, F_SETFL, flags | O_NONBLOCK) }
        let src = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
        src.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 256 * 1024)
            while true {
                let n = buf.withUnsafeMutableBytes { raw in
                    read(client, raw.baseAddress, raw.count)
                }
                if n > 0 {
                    self?.consumeVideo(Data(buf.prefix(n)))
                } else if n == 0 {
                    src.cancel()
                    break
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    break
                } else {
                    src.cancel()
                    break
                }
            }
        }
        src.setCancelHandler { close(client) }
        videoFD = client
        videoSource = src
        src.resume()
    }

    private static func unixSockaddr(path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < capacity else { return nil }
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            path.withCString { strlcpy(ptr, $0, capacity) }
        }
        return addr
    }

    private func readEvents(_ handle: FileHandle) {
        handle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                return
            }
            self?.consumeEvents(data)
        }
    }

    private func readStderr(_ handle: FileHandle) {
        handle.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                return
            }
            if let line = String(data: data, encoding: .utf8), !line.isEmpty {
                NSLog("[airplay-helper] %@", line.trimmingCharacters(in: .newlines))
            }
        }
    }

    nonisolated private func consumeEvents(_ chunk: Data) {
        leftover.append(chunk)
        drain(&leftover, video: false)
    }

    nonisolated private func consumeVideo(_ chunk: Data) {
        videoLeftover.append(chunk)
        drain(&videoLeftover, video: true)
    }

    nonisolated private func drain(_ buffer: inout Data, video: Bool) {
        while buffer.count >= 5 {
            let bytes = [UInt8](buffer.prefix(5))
            let type = bytes[0]
            let len = UInt32(bytes[1]) << 24 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 8 | UInt32(bytes[4])
            let total = 5 + Int(len)
            guard buffer.count >= total else { return }
            let payload = buffer.subdata(in: buffer.startIndex + 5 ..< buffer.startIndex + total)
            buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + total)
            if type == UInt8(ascii: "E"), !video {
                if let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                    Task { @MainActor in self.handleEvent(obj) }
                }
            } else if type == UInt8(ascii: "V"), payload.count >= 13 {
                var pts: UInt64 = 0
                for i in 0..<8 { pts = (pts << 8) | UInt64(payload[payload.startIndex + i]) }
                let captured = pts
                let isHEVC = payload[payload.startIndex + 12] != 0
                let annex = payload.subdata(in: payload.startIndex + 13 ..< payload.endIndex)
                if self.mutePresentation { continue }
                Task { @MainActor in self.handleFrame(data: annex, ptsNanos: captured, isHEVC: isHEVC) }
            }
        }
    }

    /// Writes one fake video packet through the same socket the helper uses.
    /// Returns true if this app actually received it.
    func runSocketSelfTest() async -> Bool {
        status = .advertising
        guard let path = startVideoListener() else { return false }
        try? await Task.sleep(nanoseconds: 150_000_000)
        print("selftest listen \(path)")
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { print("selftest socket fail"); return false }
        guard var addr = Self.unixSockaddr(path: path) else {
            print("selftest path too long"); close(fd); return false
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard ok else { print("selftest connect fail errno=\(errno)"); close(fd); return false }
        print("selftest connected")
        var payload = Data(count: 13 + 8)
        payload[12] = 1 // hevc flag
        var packet = Data([UInt8(ascii: "V")])
        let len = UInt32(payload.count).bigEndian
        packet.append(contentsOf: withUnsafeBytes(of: len, Array.init))
        packet.append(payload)
        let wrote = packet.withUnsafeBytes { write(fd, $0.baseAddress, packet.count) }
        print("selftest wrote \(wrote) status=\(status)")
        try? await Task.sleep(nanoseconds: 500_000_000)
        close(fd)
        print("selftest final status=\(status)")
        return status == .connected
    }

    static func helperURL() -> URL? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/airplay-helper")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build-airplay/airplay-helper")
        if FileManager.default.isExecutableFile(atPath: dev.path) { return dev }
        return nil
    }
}

struct AirPlayPreviewView: NSViewRepresentable {
    let mirror: AirPlayMirror

    func makeNSView(context: Context) -> AirPlayPreviewNSView {
        let view = AirPlayPreviewNSView()
        view.attach(mirror.displayLayer)
        return view
    }

    func updateNSView(_ nsView: AirPlayPreviewNSView, context: Context) {
        nsView.attach(mirror.displayLayer)
    }
}

final class AirPlayPreviewNSView: NSView {
    private weak var hosted: AVSampleBufferDisplayLayer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func attach(_ display: AVSampleBufferDisplayLayer) {
        if hosted === display { return }
        hosted?.removeFromSuperlayer()
        display.videoGravity = .resizeAspect
        display.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(display)
        hosted = display
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hosted?.frame = bounds
        CATransaction.commit()
    }
}

/// Turns AirPlay Annex-B H.264 / HEVC into displayable samples + pixel buffers.
final class H264Decoder: @unchecked Sendable {
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var vps: Data?
    private var sps: Data?
    private var pps: Data?
    private var hevc = false
    private let lock = NSLock()

    func decode(annexB: Data, hevc: Bool, deliver: @escaping (CMSampleBuffer?, CVPixelBuffer?) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if hevc != self.hevc {
            self.hevc = hevc
            format = nil
            session = nil
            vps = nil
            sps = nil
            pps = nil
        }
        let nals = Self.splitNAL(annexB)
        var picture = Data()
        var isIDR = false
        for nal in nals {
            guard !nal.isEmpty else { continue }
            if hevc {
                let t = Int((nal[nal.startIndex] >> 1) & 0x3F)
                if t == 32 { vps = Data(nal); rebuildFormat() }
                else if t == 33 { sps = Data(nal); rebuildFormat() }
                else if t == 34 { pps = Data(nal); rebuildFormat() }
                else if t == 19 || t == 20 || t == 21 { isIDR = true; picture.append(Self.avcc(nal)) }
                else if t < 32 { picture.append(Self.avcc(nal)) }
            } else {
                let t = Int(nal[nal.startIndex] & 0x1F)
                if t == 7 { sps = Data(nal); rebuildFormat() }
                else if t == 8 { pps = Data(nal); rebuildFormat() }
                else if t == 5 || t == 1 {
                    if t == 5 { isIDR = true }
                    picture.append(Self.avcc(nal))
                }
            }
        }
        guard !picture.isEmpty, let format else { return }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        var block: CMBlockBuffer?
        let bytes = [UInt8](picture)
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: bytes.count,
            flags: 0,
            blockBufferOut: &block) == noErr,
              let block else { return }
        _ = bytes.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!,
                                          blockBuffer: block,
                                          offsetIntoDestination: 0,
                                          dataLength: bytes.count)
        }
        var sample: CMSampleBuffer?
        var size = bytes.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample) == noErr,
              let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(isIDR ? kCFBooleanFalse : kCFBooleanTrue).toOpaque())
        }
        var pixel: CVPixelBuffer?
        if let session {
            var flagsOut = VTDecodeInfoFlags()
            VTDecompressionSessionDecodeFrame(
                session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression],
                infoFlagsOut: &flagsOut) { _, _, image, _, _ in
                    pixel = image
                }
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }
        deliver(sample, pixel)
    }

    private func rebuildFormat() {
        if hevc {
            guard let vps, let sps, let pps else { return }
            let blobs = [Array(vps), Array(sps), Array(pps)]
            createFormat(blobs, hevc: true)
        } else {
            guard let sps, let pps else { return }
            createFormat([Array(sps), Array(pps)], hevc: false)
        }
    }

    private func createFormat(_ blobs: [[UInt8]], hevc: Bool) {
        var sizes = blobs.map(\.count)
        var desc: CMVideoFormatDescription?
        let err: OSStatus = blobs[0].withUnsafeBufferPointer { b0 in
            blobs[1].withUnsafeBufferPointer { b1 in
                if hevc {
                    return blobs[2].withUnsafeBufferPointer { b2 in
                        let ptrs: [UnsafePointer<UInt8>] = [
                            b0.baseAddress!, b1.baseAddress!, b2.baseAddress!
                        ]
                        return ptrs.withUnsafeBufferPointer { pbuf in
                            sizes.withUnsafeBufferPointer { sbuf in
                                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                                    allocator: kCFAllocatorDefault,
                                    parameterSetCount: 3,
                                    parameterSetPointers: pbuf.baseAddress!,
                                    parameterSetSizes: sbuf.baseAddress!,
                                    nalUnitHeaderLength: 4,
                                    extensions: nil,
                                    formatDescriptionOut: &desc)
                            }
                        }
                    }
                } else {
                    let ptrs: [UnsafePointer<UInt8>] = [b0.baseAddress!, b1.baseAddress!]
                    return ptrs.withUnsafeBufferPointer { pbuf in
                        sizes.withUnsafeBufferPointer { sbuf in
                            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                                allocator: kCFAllocatorDefault,
                                parameterSetCount: 2,
                                parameterSetPointers: pbuf.baseAddress!,
                                parameterSetSizes: sbuf.baseAddress!,
                                nalUnitHeaderLength: 4,
                                formatDescriptionOut: &desc)
                        }
                    }
                }
            }
        }
        if err == noErr, let desc {
            format = desc
            let d = CMVideoFormatDescriptionGetDimensions(desc)
            NSLog("[airplay] format ok hevc=%d %dx%d", hevc, d.width, d.height)
            makeSession(desc)
        } else {
            NSLog("[airplay] format create failed %d hevc=%d", err, hevc)
        }
    }

    private func makeSession(_ format: CMVideoFormatDescription) {
        if let session {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
        var session: VTDecompressionSession?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA
        ]
        let err = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session)
        if err == noErr { self.session = session }
    }

    private static func splitNAL(_ data: Data) -> [Data] {
        var out: [Data] = []
        var i = data.startIndex
        func start(at idx: Data.Index) -> (Data.Index, Int)? {
            var j = idx
            while j + 3 <= data.endIndex {
                if data[j] == 0, data[j + 1] == 0 {
                    if data[j + 2] == 1 { return (j, 3) }
                    if j + 4 <= data.endIndex, data[j + 2] == 0, data[j + 3] == 1 { return (j, 4) }
                }
                j = data.index(after: j)
            }
            return nil
        }
        guard var cur = start(at: i) else { return out }
        while true {
            let nalStart = data.index(cur.0, offsetBy: cur.1)
            let next = start(at: nalStart)
            let nalEnd = next?.0 ?? data.endIndex
            if nalStart < nalEnd { out.append(data[nalStart..<nalEnd]) }
            guard let next else { break }
            cur = next
            i = next.0
        }
        return out
    }

    private static func avcc(_ nal: Data) -> Data {
        var out = Data(count: 4 + nal.count)
        let n = UInt32(nal.count).bigEndian
        out.replaceSubrange(0..<4, with: withUnsafeBytes(of: n, Array.init))
        out.replaceSubrange(4..<(4 + nal.count), with: nal)
        return out
    }
}
