import AppKit
import AVFoundation
import CoreImage

/// Captures camera + mic, plays the AI video, composites both into one frame 30 times a second,
/// shows that frame in the preview and, while recording, writes it with the mic audio to an MP4.
///
/// All mutable state below the `queue` marker is only touched on `queue`.
final class RecorderEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    enum EngineError: LocalizedError {
        case cannotAddInputs
        case cannotStart(Error?)
        var errorDescription: String? {
            switch self {
            case .cannotAddInputs: "The recorder couldn't be set up."
            case .cannotStart(let e): e?.localizedDescription ?? "The recorder couldn't start."
            }
        }
    }

    let captureSession = AVCaptureSession()
    let displayLayer = AVSampleBufferDisplayLayer()
    let player = AVPlayer()

    /// Called on the main thread with the mic level in dB.
    var onMicLevel: ((Float) -> Void)?
    /// Called on the engine queue with every mic buffer (feeds speech recognition).
    var onAudioSample: ((CMSampleBuffer) -> Void)?

    private let queue = DispatchQueue(label: "VideoFilmer.engine", qos: .userInteractive)
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let audioDataOutput = AVCaptureAudioDataOutput()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let hostClock = CMClockGetHostTimeClock()

    // queue
    private var settings = RenderSettings()
    private var latestCamera: CVPixelBuffer?
    private var latestVideo: CVPixelBuffer?
    private var poster: CIImage?
    private var itemOutput: AVPlayerItemVideoOutput?
    private var pool: CVPixelBufferPool?
    private var poolSize: CGSize = .zero
    private var timer: DispatchSourceTimer?
    private var writer: AVAssetWriter?
    private var writerVideo: AVAssetWriterInput?
    private var writerAudio: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordStart: CMTime = .invalid
    private var sessionStarted = false
    private var lastVideoPTS: CMTime = .invalid
    // Optional second file: the clean camera at its own resolution, for editing elsewhere.
    private var cameraWriter: AVAssetWriter?
    private var cameraVideo: AVAssetWriterInput?
    private var cameraAudio: AVAssetWriterInput?
    private var cameraAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var cameraLastPTS: CMTime = .invalid
    private var levelCounter = 0
    private var lastFrame: CVPixelBuffer?

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        player.actionAtItemEnd = .pause
        configureOutputs()
        startRenderLoop()
    }

    // MARK: - Devices

    static func cameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    static func microphones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                         mediaType: .audio, position: .unspecified).devices
    }

    private func configureOutputs() {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .high
        videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.setSampleBufferDelegate(self, queue: queue)
        if captureSession.canAddOutput(videoDataOutput) { captureSession.addOutput(videoDataOutput) }
        audioDataOutput.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        audioDataOutput.setSampleBufferDelegate(self, queue: queue)
        if captureSession.canAddOutput(audioDataOutput) { captureSession.addOutput(audioDataOutput) }
        captureSession.commitConfiguration()
    }

    /// The sharpest landscape format (16:9 preferred, up to 4K) that still does ~30 fps.
    /// The default preset often picks 720p even when a camera can do 1080p.
    static func bestFormat(of device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let candidates = device.formats.compactMap { format -> (AVCaptureDevice.Format, Int32, Int32)? in
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let fps = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            guard d.width >= d.height, d.width <= 3840, fps >= 29 else { return nil }
            return (format, d.width, d.height)
        }
        let isWide = { (w: Int32, h: Int32) in abs(Double(w) / Double(h) - 16.0 / 9.0) < 0.05 }
        return candidates.max { a, b in
            let (aw, bw) = (isWide(a.1, a.2), isWide(b.1, b.2))
            if aw != bw { return !aw }
            return Int(a.1) * Int(a.2) < Int(b.1) * Int(b.2)
        }?.0
    }

    /// Switches to the given devices (nil = system default) and starts capturing.
    func useDevices(cameraID: String?, micID: String?) {
        queue.async { [self] in
            captureSession.beginConfiguration()
            for input in captureSession.inputs { captureSession.removeInput(input) }
            let cam = cameraID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .video)
            let mic = micID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .audio)
            for device in [cam, mic].compactMap({ $0 }) {
                if let input = try? AVCaptureDeviceInput(device: device), captureSession.canAddInput(input) {
                    captureSession.addInput(input)
                }
            }
            if let cam, let best = Self.bestFormat(of: cam), cam.activeFormat != best, (try? cam.lockForConfiguration()) != nil {
                cam.activeFormat = best
                cam.unlockForConfiguration()
            }
            captureSession.commitConfiguration()
            latestCamera = nil
            if !captureSession.isRunning { captureSession.startRunning() }
        }
    }

    // MARK: - Settings & AI video

    func update(_ s: RenderSettings) {
        queue.async { self.settings = s }
    }

    func loadVideo(url: URL) {
        let item = AVPlayerItem(url: url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        player.replaceCurrentItem(with: item)
        queue.async {
            self.itemOutput = output
            self.latestVideo = nil
            self.poster = nil
        }
        // A still of the first frame, shown until the video starts playing.
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.appliesPreferredTrackTransform = true
        generator.generateCGImageAsynchronously(for: .zero) { [weak self] image, _, _ in
            guard let self, let image else { return }
            self.queue.async { self.poster = CIImage(cgImage: image) }
        }
    }

    // MARK: - Rendering

    private func startRenderLoop() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .nanoseconds(33_333_333), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.renderFrame() }
        t.resume()
        timer = t
    }

    private func renderFrame() {
        let now = CMClockGetTime(hostClock)
        if let output = itemOutput {
            let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
            if output.hasNewPixelBuffer(forItemTime: itemTime),
               let pb = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
                latestVideo = pb
            }
        }

        let size = settings.aspect.size
        guard let buffer = makeBuffer(size: size) else { return }
        let video = latestVideo.map { CIImage(cvPixelBuffer: $0) } ?? poster
        let image = Compositor.compose(cam: latestCamera.map { CIImage(cvPixelBuffer: $0) }, video: video,
                                       settings: settings, size: size)
        ciContext.render(image, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)

        if let writer, let input = writerVideo, let adaptor {
            if !sessionStarted {
                writer.startSession(atSourceTime: recordStart)
                sessionStarted = true
            }
            if writer.status == .writing, input.isReadyForMoreMediaData, !lastVideoPTS.isValid || now > lastVideoPTS {
                if adaptor.append(buffer, withPresentationTime: now) { lastVideoPTS = now }
            }
        }
        showPreview(buffer, at: now)
        lastFrame = buffer
    }

    /// Whether camera frames are arriving.
    var isCameraLive: Bool { queue.sync { latestCamera != nil } }

    /// PNG of the latest composited frame (what is being recorded).
    func snapshotPNG(maxDimension: CGFloat = 960) async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let frame = lastFrame else { continuation.resume(returning: nil); return }
                var image = CIImage(cvPixelBuffer: frame)
                let k = min(1, maxDimension / max(image.extent.width, image.extent.height))
                image = image.transformed(by: CGAffineTransform(scaleX: k, y: k))
                guard let cg = ciContext.createCGImage(image, from: image.extent) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
            }
        }
    }

    /// PNG of the frame at `time` seconds in any video file.
    static func framePNG(of url: URL, at time: Double, maxDimension: CGFloat = 960) async throws -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (cg, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    private func makeBuffer(size: CGSize) -> CVPixelBuffer? {
        if pool == nil || poolSize != size {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &newPool)
            pool = newPool
            poolSize = size
            displayLayer.sampleBufferRenderer.flush()
        }
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
        return pb
    }

    private func showPreview(_ buffer: CVPixelBuffer, at pts: CMTime) {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                 formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }

    // MARK: - Capture callbacks

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoDataOutput {
            latestCamera = CMSampleBufferGetImageBuffer(sampleBuffer)
            if let w = cameraWriter, w.status == .writing, let input = cameraVideo, input.isReadyForMoreMediaData,
               let adaptor = cameraAdaptor, let frame = latestCamera {
                let pts = hostPTS(of: sampleBuffer)
                if pts >= recordStart, !cameraLastPTS.isValid || pts > cameraLastPTS,
                   adaptor.append(frame, withPresentationTime: pts) {
                    cameraLastPTS = pts
                }
            }
            return
        }

        levelCounter += 1
        if levelCounter % 4 == 0, let channel = connection.audioChannels.first {
            let db = channel.averagePowerLevel
            DispatchQueue.main.async { self.onMicLevel?(db) }
        }
        onAudioSample?(sampleBuffer)

        guard writer != nil || cameraWriter != nil else { return }
        let sample = onHostClock(sampleBuffer)
        guard CMSampleBufferGetPresentationTimeStamp(sample) >= recordStart else { return }
        if let writer, sessionStarted, writer.status == .writing, let input = writerAudio, input.isReadyForMoreMediaData {
            input.append(sample)
        }
        if let w = cameraWriter, w.status == .writing, let input = cameraAudio, input.isReadyForMoreMediaData {
            input.append(sample)
        }
    }

    private func hostPTS(of sample: CMSampleBuffer) -> CMTime {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard let clock = captureSession.synchronizationClock, clock !== hostClock else { return pts }
        return CMSyncConvertTime(pts, from: clock, to: hostClock)
    }

    /// Video frames are stamped with host time, so mic buffers must be too.
    private func onHostClock(_ sample: CMSampleBuffer) -> CMSampleBuffer {
        guard let clock = captureSession.synchronizationClock, clock !== hostClock else { return sample }
        let pts = CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sample), from: clock, to: hostClock)
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sample), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                                              sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &out)
        return out ?? sample
    }

    // MARK: - Recording

    private static func audioInput() -> AVAssetWriterInput {
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ])
        audio.expectsMediaDataInRealTime = true
        return audio
    }

    /// Starts writing the composite to `url` and, if given, the clean camera to `cameraURL`.
    /// Returns the host time the recording starts at.
    func beginRecording(to url: URL, cameraURL: URL? = nil) throws -> CMTime {
        try queue.sync {
            let size = settings.aspect.size
            let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 12_000_000,
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
            ])
            video.expectsMediaDataInRealTime = true
            let audio = Self.audioInput()
            guard w.canAdd(video), w.canAdd(audio) else { throw EngineError.cannotAddInputs }
            w.add(video)
            w.add(audio)
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
            guard w.startWriting() else { throw EngineError.cannotStart(w.error) }

            writer = w
            writerVideo = video
            writerAudio = audio
            self.adaptor = adaptor
            recordStart = CMClockGetTime(hostClock)
            sessionStarted = false
            lastVideoPTS = .invalid
            if let cameraURL { try beginCameraFile(at: cameraURL) }
            return recordStart
        }
    }

    /// Clean camera at its native size, high bitrate, same clock as the composite.
    private func beginCameraFile(at url: URL) throws {
        let width = latestCamera.map(CVPixelBufferGetWidth) ?? 1920
        let height = latestCamera.map(CVPixelBufferGetHeight) ?? 1080
        let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(10_000_000, width * height * 8),
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        let audio = Self.audioInput()
        guard w.canAdd(video), w.canAdd(audio) else { throw EngineError.cannotAddInputs }
        w.add(video)
        w.add(audio)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
        guard w.startWriting() else { throw EngineError.cannotStart(w.error) }
        w.startSession(atSourceTime: recordStart)
        cameraWriter = w
        cameraVideo = video
        cameraAudio = audio
        cameraAdaptor = adaptor
        cameraLastPTS = .invalid
    }

    /// Finishes the camera-only file, if one is being written. Runs on `queue`.
    private func finishCameraFile(end: CMTime, completion: @escaping (URL?) -> Void) {
        guard let w = cameraWriter else { completion(nil); return }
        let video = cameraVideo, audio = cameraAudio
        cameraWriter = nil
        cameraVideo = nil
        cameraAudio = nil
        cameraAdaptor = nil
        guard cameraLastPTS.isValid, end.isValid else {
            w.cancelWriting()
            completion(nil)
            return
        }
        video?.markAsFinished()
        audio?.markAsFinished()
        w.endSession(atSourceTime: end)
        w.finishWriting { completion(w.status == .completed ? w.outputURL : nil) }
    }

    /// Finishes the file(s). Returns the composite's URL and duration (nil if nothing was recorded)
    /// and the camera-only file if one was written.
    func finishRecording() async -> (url: URL, duration: Double, cameraURL: URL?)? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let w = writer, let video = writerVideo, let audio = writerAudio else {
                    finishCameraFile(end: .invalid) { _ in }
                    continuation.resume(returning: nil)
                    return
                }
                let end = lastVideoPTS
                let start = recordStart
                writer = nil
                writerVideo = nil
                writerAudio = nil
                adaptor = nil
                guard sessionStarted, end.isValid else {
                    w.cancelWriting()
                    finishCameraFile(end: .invalid) { _ in }
                    continuation.resume(returning: nil)
                    return
                }
                video.markAsFinished()
                audio.markAsFinished()
                w.endSession(atSourceTime: end)
                // Same end time for both files, so they line up in an editor.
                finishCameraFile(end: end) { cameraURL in
                    w.finishWriting {
                        continuation.resume(returning: w.status == .completed ? (w.outputURL, (end - start).seconds, cameraURL) : nil)
                    }
                }
            }
        }
    }
}
