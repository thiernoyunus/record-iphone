import AVFoundation
import CoreMedia
import Foundation

/// Device sound next to phone.mov.
/// First file is phone-audio.m4a; a YouTube/ad format change makes
/// phone-audio-2.m4a, phone-audio-3.m4a, … and must not stop the picture.
/// Export should mix these later the same way PhoneSegments glues phone-N.mov.
enum PhoneAudioSegments {
    static func fileName(index: Int) -> String {
        index <= 1 ? "phone-audio.m4a" : "phone-audio-\(index).m4a"
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
            guard FileManager.default.fileExists(atPath: u.path), size > 256 else { break }
            parts.append(u)
            i += 1
        }
        return parts
    }
}

enum PhoneAudioRollPolicy {
    /// New m4a only. The video writer must keep running.
    static func shouldRollAudio(formatChanged: Bool, audioWriterFailed: Bool) -> Bool {
        formatChanged || audioWriterFailed
    }

    static func shouldStopVideoForAudioFormatChange() -> Bool { false }
}

/// USB phone picture + device sound as two writers.
/// Video stays in phone.mov even when the phone's audio format jumps.
final class PhoneSampleWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var dir: URL?
    private var videoURL: URL?
    private var audioPart = 1
    private var audioURLs: [URL] = []

    private var videoWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var videoAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var videoStarted = false
    private var videoSize = CGSize.zero

    private var audioWriter: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var audioStarted = false
    private var lastAudioFormat: CMFormatDescription?
    private var audioFormatDirty = false
    private var epoch = 0

    var onVideoBegan: (() -> Void)?
    var onVideoFailed: (() -> Void)?
    var onVideoNeedsRestart: (() -> Void)?

    var isWriting: Bool {
        lock.lock(); defer { lock.unlock() }
        return armed && (videoStarted || videoWriter?.status == .writing)
    }

    var currentVideoURL: URL? {
        lock.lock(); defer { lock.unlock() }
        return videoURL
    }

    func arm(videoURL: URL) {
        lock.lock()
        epoch += 1
        let leftoverVideo = videoWriter
        let leftoverVideoIn = videoInput
        let leftoverAudio = audioWriter
        let leftoverAudioIn = audioInput
        resetLocked()
        armed = true
        dir = videoURL.deletingLastPathComponent()
        self.videoURL = videoURL
        audioPart = 1
        audioURLs = []
        lock.unlock()
        Self.finishInBackground(writer: leftoverVideo, input: leftoverVideoIn)
        Self.finishInBackground(writer: leftoverAudio, input: leftoverAudioIn)
    }

    func noteAudioFormatChanged() {
        lock.lock()
        audioFormatDirty = true
        lock.unlock()
    }

    func restartVideo(at url: URL) {
        lock.lock()
        let oldWriter = videoWriter
        let oldInput = videoInput
        videoWriter = nil
        videoInput = nil
        videoAdaptor = nil
        videoStarted = false
        videoSize = .zero
        videoURL = url
        lock.unlock()
        Self.finishInBackground(writer: oldWriter, input: oldInput)
    }

    func appendVideo(_ sample: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isValid else { return }
        lock.lock()
        guard armed else { lock.unlock(); return }
        if let size = Self.videoSize(from: sample), videoStarted,
           videoSize.width > 8,
           (abs(size.width - videoSize.width) > 2
            || abs(size.height - videoSize.height) > 2) {
            lock.unlock()
            onVideoNeedsRestart?()
            return
        }
        if videoWriter == nil {
            guard startVideoWriterLocked(from: sample) else {
                lock.unlock()
                return
            }
        }
        guard let startedWriter = videoWriter, videoInput != nil else {
            lock.unlock()
            return
        }
        if startedWriter.status == .failed {
            lock.unlock()
            onVideoFailed?()
            return
        }
        if !videoStarted {
            guard startedWriter.status == .unknown || startedWriter.status == .writing else {
                lock.unlock()
                onVideoFailed?()
                return
            }
            if startedWriter.status == .unknown, !startedWriter.startWriting() {
                lock.unlock()
                onVideoFailed?()
                return
            }
            startedWriter.startSession(atSourceTime: pts)
            videoStarted = true
            let began = onVideoBegan
            lock.unlock()
            began?()
            lock.lock()
        }
        // The callback may have reset, re-armed, or restarted the writer.
        guard armed,
              let writer = videoWriter,
              let input = videoInput,
              writer.status == .writing,
              input.isReadyForMoreMediaData else {
            lock.unlock()
            return
        }
        var ok = false
        if let adaptor = videoAdaptor, let pixel = CMSampleBufferGetImageBuffer(sample) {
            ok = adaptor.append(pixel, withPresentationTime: pts)
        } else {
            ok = input.append(sample)
        }
        let failed = !ok && writer.status == .failed
        lock.unlock()
        if failed { onVideoFailed?() }
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isValid else { return }
        lock.lock()
        guard armed else { lock.unlock(); return }
        let desc = CMSampleBufferGetFormatDescription(sample)
        let formatChanged = audioFormatDirty || Self.formatChanged(last: lastAudioFormat, next: desc)
        let audioFailed = audioWriter?.status == .failed
        if PhoneAudioRollPolicy.shouldRollAudio(
            formatChanged: formatChanged && (audioWriter != nil || audioStarted),
            audioWriterFailed: audioFailed
        ) {
            rollAudioLocked()
        }
        audioFormatDirty = false
        if let desc { lastAudioFormat = desc }
        if audioWriter == nil {
            guard startAudioWriterLocked(from: sample) else {
                lock.unlock()
                return
            }
        }
        guard let writer = audioWriter, let input = audioInput else {
            lock.unlock()
            return
        }
        if writer.status == .failed {
            rollAudioLocked()
            lock.unlock()
            return
        }
        if !audioStarted {
            if writer.status == .unknown, !writer.startWriting() {
                lock.unlock()
                return
            }
            writer.startSession(atSourceTime: pts)
            audioStarted = true
        }
        if writer.status == .writing, input.isReadyForMoreMediaData {
            _ = input.append(sample)
        }
        lock.unlock()
    }

    func finish(cancel: Bool) async {
        let snapshot = takeFinishSnapshot()
        snapshot.videoInput?.markAsFinished()
        snapshot.audioInput?.markAsFinished()
        await Self.finishWriter(snapshot.videoWriter)
        await Self.finishWriter(snapshot.audioWriter)
        if cancel, sameEpoch(snapshot.epoch) {
            if let url = snapshot.videoURL { try? FileManager.default.removeItem(at: url) }
            for url in snapshot.audioURLs { try? FileManager.default.removeItem(at: url) }
        }
    }

    private struct FinishSnapshot {
        let epoch: Int
        let videoWriter: AVAssetWriter?
        let videoInput: AVAssetWriterInput?
        let audioWriter: AVAssetWriter?
        let audioInput: AVAssetWriterInput?
        let videoURL: URL?
        let audioURLs: [URL]
    }

    private func takeFinishSnapshot() -> FinishSnapshot {
        lock.lock()
        let snap = FinishSnapshot(
            epoch: epoch,
            videoWriter: videoWriter,
            videoInput: videoInput,
            audioWriter: audioWriter,
            audioInput: audioInput,
            videoURL: videoURL,
            audioURLs: audioURLs)
        resetLocked()
        lock.unlock()
        return snap
    }

    private func sameEpoch(_ value: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return epoch == value
    }

    private func resetLocked() {
        videoWriter = nil
        videoInput = nil
        videoAdaptor = nil
        videoStarted = false
        videoSize = .zero
        audioWriter = nil
        audioInput = nil
        audioStarted = false
        lastAudioFormat = nil
        audioFormatDirty = false
        videoURL = nil
        dir = nil
        audioPart = 1
        audioURLs = []
        armed = false
    }

    private func rollAudioLocked() {
        let oldWriter = audioWriter
        let oldInput = audioInput
        audioWriter = nil
        audioInput = nil
        audioStarted = false
        lastAudioFormat = nil
        if oldWriter != nil { audioPart += 1 }
        Self.finishInBackground(writer: oldWriter, input: oldInput)
    }

    private func startVideoWriterLocked(from sample: CMSampleBuffer) -> Bool {
        guard let url = videoURL, let size = Self.videoSize(from: sample) else { return false }
        let width = max(2, Int(size.width) & ~1)
        let height = max(2, Int(size.height) & ~1)
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(url: url, fileType: .mov) else { return false }
        writer.shouldOptimizeForNetworkUse = true
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ])
        videoWriter = writer
        videoInput = input
        videoAdaptor = adaptor
        videoSize = CGSize(width: width, height: height)
        return true
    }

    private func startAudioWriterLocked(from sample: CMSampleBuffer) -> Bool {
        guard let dir else { return false }
        guard let settings = Self.audioOutputSettings(from: sample) else { return false }
        let url = PhoneAudioSegments.url(in: dir, index: audioPart)
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(url: url, fileType: .m4a) else { return false }
        writer.shouldOptimizeForNetworkUse = true
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        audioWriter = writer
        audioInput = input
        audioURLs.append(url)
        NSLog("[record] phone audio writer → %@", url.lastPathComponent)
        return true
    }

    private static func videoSize(from sample: CMSampleBuffer) -> CGSize? {
        if let pixel = CMSampleBufferGetImageBuffer(sample) {
            let width = CVPixelBufferGetWidth(pixel)
            let height = CVPixelBufferGetHeight(pixel)
            if width > 8, height > 8 { return CGSize(width: width, height: height) }
        }
        guard let format = CMSampleBufferGetFormatDescription(sample) else { return nil }
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        if dims.width > 8, dims.height > 8 {
            return CGSize(width: Int(dims.width), height: Int(dims.height))
        }
        return nil
    }

    private static func audioOutputSettings(from sample: CMSampleBuffer) -> [String: Any]? {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
            return nil
        }
        let channels = max(1, min(2, Int(asbd.mChannelsPerFrame)))
        let rate = asbd.mSampleRate >= 8000 ? asbd.mSampleRate : 44_100
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: channels,
            AVSampleRateKey: rate,
            AVEncoderBitRateKey: channels > 1 ? 160_000 : 96_000
        ]
    }

    private static func formatChanged(last: CMFormatDescription?, next: CMFormatDescription?) -> Bool {
        guard let last, let next else { return false }
        return CMFormatDescriptionEqual(last, otherFormatDescription: next) == false
    }

    private static func finishInBackground(writer: AVAssetWriter?, input: AVAssetWriterInput?) {
        guard writer != nil || input != nil else { return }
        DispatchQueue.global(qos: .utility).async {
            input?.markAsFinished()
            if let writer, writer.status == .writing {
                writer.finishWriting {}
            }
        }
    }

    private static func finishWriter(_ writer: AVAssetWriter?) async {
        guard let writer else { return }
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
    }
}
