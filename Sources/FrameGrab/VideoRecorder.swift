import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import CoreText
import CoreVideo
import QuartzCore
import ScreenCaptureKit

enum VideoRecordingError: LocalizedError {
    case unsupportedSystem
    case noWindow
    case permissionDenied
    case microphoneDenied
    case couldNotStart
    case couldNotProcess

    var errorDescription: String? {
        switch self {
        case .unsupportedSystem:
            "Window recording requires macOS 15 or later."
        case .noWindow:
            "No capturable window was found. Bring the window you want to record to the front and try again."
        case .permissionDenied:
            "Screen Recording permission is required. Enable NiceGrab in System Settings → Privacy & Security → Screen Recording, then relaunch it."
        case .microphoneDenied:
            "Microphone access is required when Include Microphone is enabled. Allow NiceGrab in System Settings → Privacy & Security → Microphone."
        case .couldNotStart:
            "The window recording could not be started."
        case .couldNotProcess:
            "The recording could not be encoded."
        }
    }
}

struct VideoCompositionStyle {
    let background: NSImage?
    let padding: CGFloat
    let canvas: CanvasOption
    let cornerText: String
}

private struct CursorSample: @unchecked Sendable {
    let time: TimeInterval
    let location: CGPoint
    let isInside: Bool
    let cursor: NSCursor?

}

private struct CursorImage {
    let image: CIImage
    let extent: CGRect
    let hotSpot: CGPoint
    let backingScale: CGFloat
}

// All mutable state is confined to VideoRecorder.captureQueue. Only the latest
// ScreenCaptureKit pixel buffer is retained, so memory use does not grow with
// recording duration.
private final class LiveWritingContext: @unchecked Sendable {
    let writer: AVAssetWriter
    let videoInput: AVAssetWriterInput
    let pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor
    let systemAudioInput: AVAssetWriterInput
    let microphoneInput: AVAssetWriterInput?
    let ciContext: CIContext
    let colorSpace: CGColorSpace
    let canvasSize: CGSize
    let canvasExtent: CGRect
    let targetRect: CGRect
    let mask: CIImage
    let shadow: CIImage
    let background: CIImage
    let overlay: CIImage?
    var latestSourcePixelBuffer: CVPixelBuffer?
    var latestSourceRect: CGRect?
    var sessionStartPTS: CMTime?
    var lastVideoFrameIndex: Int64 = -1
    var lastVideoPTS: CMTime?
    var cursorImages: [ObjectIdentifier: CursorImage] = [:]
    var failure: Error?

    init(
        writer: AVAssetWriter,
        videoInput: AVAssetWriterInput,
        pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor,
        systemAudioInput: AVAssetWriterInput,
        microphoneInput: AVAssetWriterInput?,
        ciContext: CIContext,
        colorSpace: CGColorSpace,
        canvasSize: CGSize,
        targetRect: CGRect,
        mask: CIImage,
        shadow: CIImage,
        background: CIImage,
        overlay: CIImage?
    ) {
        self.writer = writer
        self.videoInput = videoInput
        self.pixelBufferAdaptor = pixelBufferAdaptor
        self.systemAudioInput = systemAudioInput
        self.microphoneInput = microphoneInput
        self.ciContext = ciContext
        self.colorSpace = colorSpace
        self.canvasSize = canvasSize
        self.canvasExtent = CGRect(origin: .zero, size: canvasSize)
        self.targetRect = targetRect
        self.mask = mask
        self.shadow = shadow
        self.background = background
        self.overlay = overlay
    }
}

private struct OneEuroFilter {
    private var previousValue: CGFloat?
    private var previousRawValue: CGFloat?
    private var previousDerivative: CGFloat = 0
    private var previousTime: TimeInterval?
    let minimumCutoff: CGFloat
    let beta: CGFloat
    let derivativeCutoff: CGFloat

    init(minimumCutoff: CGFloat, beta: CGFloat, derivativeCutoff: CGFloat) {
        self.minimumCutoff = minimumCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    mutating func filter(_ value: CGFloat, at time: TimeInterval) -> CGFloat {
        guard let previousValue, let previousTime else {
            self.previousValue = value
            self.previousRawValue = value
            self.previousTime = time
            return value
        }
        let delta = max(1.0 / 240.0, time - previousTime)
        let derivative = (value - (previousRawValue ?? value)) / CGFloat(delta)
        let filteredDerivative = lowPass(derivative, previous: previousDerivative, cutoff: derivativeCutoff, delta: delta)
        let cutoff = minimumCutoff + beta * abs(filteredDerivative)
        let filteredValue = lowPass(value, previous: previousValue, cutoff: cutoff, delta: delta)
        self.previousValue = filteredValue
        self.previousRawValue = value
        self.previousDerivative = filteredDerivative
        self.previousTime = time
        return filteredValue
    }

    private func lowPass(_ value: CGFloat, previous: CGFloat, cutoff: CGFloat, delta: TimeInterval) -> CGFloat {
        let timeConstant = 1 / (2 * CGFloat.pi * cutoff)
        let alpha = CGFloat(delta) / (CGFloat(delta) + timeConstant)
        return alpha * value + (1 - alpha) * previous
    }
}

@available(macOS 14.0, *)
private final class CursorTracker {
    private let windowID: CGWindowID
    private var windowFrame: CGRect
    private var lastWindowFrameRefresh: TimeInterval = 0
    private var displayLink: CADisplayLink?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let sampleLock = NSLock()
    private var latestSample: CursorSample?
    private var latestPoint: CGPoint = .zero
    private var latestCursor: NSCursor?
    private var xFilter = OneEuroFilter(minimumCutoff: 1, beta: 0.001, derivativeCutoff: 0.8)
    private var yFilter = OneEuroFilter(minimumCutoff: 1, beta: 0.001, derivativeCutoff: 0.8)

    init(windowID: CGWindowID, windowFrame: CGRect) {
        self.windowID = windowID
        self.windowFrame = windowFrame
    }

    func start() {
        updateActualPosition()
        recordSample()
        let events: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp
        ]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.updateActualPosition()
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            self?.updateActualPosition()
        }
        let displayLink = NSScreen.main?.displayLink(target: self, selector: #selector(displayDidRefresh))
        displayLink?.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    func currentSample() -> CursorSample? {
        sampleLock.lock()
        defer { sampleLock.unlock() }
        return latestSample
    }

    @objc private func displayDidRefresh() {
        recordSample()
    }

    private func updateActualPosition() {
        if let point = CGEvent(source: nil)?.location {
            latestPoint = point
        }
        latestCursor = NSCursor.currentSystem
    }

    private func recordSample() {
        let now = ProcessInfo.processInfo.systemUptime
        refreshWindowFrame(at: now)
        guard windowFrame.width > 0, windowFrame.height > 0 else { return }
        let point = latestPoint
        let localX = point.x - windowFrame.minX
        let localY = point.y - windowFrame.minY
        let sample = CursorSample(
            time: now,
            location: CGPoint(
                x: xFilter.filter(localX, at: now) / windowFrame.width,
                y: yFilter.filter(localY, at: now) / windowFrame.height
            ),
            isInside: windowFrame.contains(point),
            cursor: latestCursor
        )
        sampleLock.lock()
        latestSample = sample
        sampleLock.unlock()
    }

    private func refreshWindowFrame(at time: TimeInterval) {
        guard time - lastWindowFrameRefresh >= 1.0 / 30.0 else { return }
        lastWindowFrameRefresh = time
        guard let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let bounds = windows.first?[kCGWindowBounds as String] as? [String: Any],
              let x = bounds["X"] as? CGFloat,
              let y = bounds["Y"] as? CGFloat,
              let width = bounds["Width"] as? CGFloat,
              let height = bounds["Height"] as? CGFloat,
              width > 0,
              height > 0 else { return }
        windowFrame = CGRect(x: x, y: y, width: width, height: height)
    }
}

@available(macOS 15.0, *)
final class VideoRecorder: NSObject, SCStreamDelegate, SCStreamOutput {
    typealias Completion = (Result<URL, Error>) -> Void

    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private var stream: SCStream?
    private var finalURL: URL?
    private var writingContext: LiveWritingContext?
    private var completion: Completion?
    private var isStopping = false
    private var cursorTracker: CursorTracker?
    private var cursorCaptureScale: CGFloat = 2
    private let captureQueue = DispatchQueue(label: "NiceGrab.LiveComposition", qos: .userInteractive)
    private var frameTimer: DispatchSourceTimer?

    var isRecording: Bool { stream != nil }
    var isFinishing: Bool { isStopping }

    func start(
        includeMicrophone: Bool,
        smoothCursor: Bool,
        style: VideoCompositionStyle,
        completion: @escaping Completion
    ) async throws {
        guard !isRecording else { return }
        if includeMicrophone {
            let microphoneAllowed: Bool
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                microphoneAllowed = true
            case .notDetermined:
                microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
            default:
                microphoneAllowed = false
            }
            guard microphoneAllowed else { throw VideoRecordingError.microphoneDenied }
        }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw VideoRecordingError.permissionDenied
        }
        guard let frontWindowID = frontWindowID() else { throw VideoRecordingError.noWindow }

        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == frontWindowID }) else {
            throw VideoRecordingError.noWindow
        }

        let configuration = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        cursorCaptureScale = scale
        // The live H.264 writer uses 4:2:0 chroma subsampling, which requires
        // even pixel dimensions. Window frames can contain half-point sizes.
        configuration.width = evenPixelDimension(window.frame.width * scale)
        configuration.height = evenPixelDimension(window.frame.height * scale)
        // Preserve fluid pointer and window motion at 60 fps.
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 6
        configuration.showsCursor = !smoothCursor
        // H.264 cannot preserve ScreenCaptureKit's transparent shadow pixels.
        // Capture the full decorated window and rebuild its rounded shadow while compositing.
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreGlobalClipSingleWindow = true
        configuration.shouldBeOpaque = false
        configuration.captureResolution = .best
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.captureMicrophone = includeMicrophone

        let outputURL = try recordingURL()
        let sourceSize = CGSize(width: configuration.width, height: configuration.height)
        let context = try makeLiveWritingContext(
            outputURL: outputURL,
            sourceSize: sourceSize,
            style: style,
            includeMicrophone: includeMicrophone
        )

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
        if includeMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: captureQueue)
        }

        self.stream = stream
        self.finalURL = outputURL
        self.writingContext = context
        self.completion = completion
        self.isStopping = false

        if smoothCursor {
            let tracker = CursorTracker(windowID: window.windowID, windowFrame: window.frame)
            cursorTracker = tracker
            tracker.start()
        }

        do {
            guard context.writer.startWriting() else {
                throw context.writer.error ?? VideoRecordingError.couldNotStart
            }
            try await stream.startCapture()
            startFrameTimer()
        } catch {
            context.writer.cancelWriting()
            reset(removeFiles: true)
            throw error
        }
    }

    func stop() async throws {
        guard let stream, !isStopping else { return }
        isStopping = true
        frameTimer?.cancel()
        frameTimer = nil
        cursorTracker?.stop()
        cursorTracker = nil
        do {
            try await stream.stopCapture()
            try await finishLiveWriting()
            guard let finalURL else { throw VideoRecordingError.couldNotProcess }
            finish(.success(finalURL), removeFiles: false)
        } catch {
            writingContext?.writer.cancelWriting()
            finish(.failure(error))
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard sampleBuffer.isValid, let context = writingContext, context.failure == nil else { return }
        switch outputType {
        case .screen:
            receiveScreenFrame(sampleBuffer, context: context)
        case .audio:
            appendAudio(sampleBuffer, to: context.systemAudioInput, context: context)
        case .microphone:
            guard let microphoneInput = context.microphoneInput else { return }
            appendAudio(sampleBuffer, to: microphoneInput, context: context)
        @unknown default:
            return
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard !isStopping else { return }
        isStopping = true
        frameTimer?.cancel()
        frameTimer = nil
        cursorTracker?.stop()
        cursorTracker = nil
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.writingContext?.writer.cancelWriting()
            self.finish(.failure(error))
        }
    }

    private func finish(_ result: Result<URL, Error>, removeFiles: Bool = true) {
        guard let completion else { return }
        let callback = completion
        reset(removeFiles: removeFiles)
        DispatchQueue.main.async { callback(result) }
    }

    private func reset(removeFiles: Bool) {
        if removeFiles {
            if let finalURL { try? FileManager.default.removeItem(at: finalURL) }
        }
        frameTimer?.cancel()
        frameTimer = nil
        stream = nil
        finalURL = nil
        writingContext = nil
        completion = nil
        isStopping = false
        cursorTracker?.stop()
        cursorTracker = nil
        cursorCaptureScale = 2
    }

    private func recordingURL() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("NiceGrab/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return root.appendingPathComponent("NiceGrab \(formatter.string(from: Date())).mp4")
    }

    private func makeLiveWritingContext(
        outputURL: URL,
        sourceSize: CGSize,
        style: VideoCompositionStyle,
        includeMicrophone: Bool
    ) throws -> LiveWritingContext {
        try? FileManager.default.removeItem(at: outputURL)
        let requestedCanvasSize = style.canvas.size(for: sourceSize, padding: style.padding)
        let canvasSize = CGSize(
            width: ceil(requestedCanvasSize.width / 2) * 2,
            height: ceil(requestedCanvasSize.height / 2) * 2
        )
        let canvasExtent = CGRect(origin: .zero, size: canvasSize)
        let maximumSize = CGSize(
            width: max(2, canvasSize.width - style.padding * 2),
            height: max(2, canvasSize.height - style.padding * 2)
        )
        let scale = min(1, maximumSize.width / sourceSize.width, maximumSize.height / sourceSize.height)
        let targetSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let targetRect = CGRect(
            x: (canvasSize.width - targetSize.width) / 2,
            y: (canvasSize.height - targetSize.height) / 2,
            width: targetSize.width,
            height: targetSize.height
        )
        let radius = min(
            CompositionAppearance.windowCornerRadius,
            targetSize.width / 20,
            targetSize.height / 20
        )

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let width = Int(canvasSize.width.rounded())
        let height = Int(canvasSize.height.rounded())
        let bitsPerSecond = min(
            5_000_000,
            max(500_000, Int(Double(width * height * 60) * 0.008))
        )
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
                ],
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitsPerSecond,
                    AVVideoExpectedSourceFrameRateKey: 60,
                    AVVideoMaxKeyFrameIntervalDurationKey: 10,
                    AVVideoAllowFrameReorderingKey: true,
                    AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
        )
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw VideoRecordingError.couldNotStart }
        writer.add(videoInput)
        let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
        )

        func makeAudioInput() -> AVAssetWriterInput {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 128_000
                ]
            )
            input.expectsMediaDataInRealTime = true
            return input
        }

        let systemAudioInput = makeAudioInput()
        guard writer.canAdd(systemAudioInput) else { throw VideoRecordingError.couldNotStart }
        writer.add(systemAudioInput)
        var microphoneInput: AVAssetWriterInput?
        if includeMicrophone {
            // Keep microphone samples on their own simultaneous track for this
            // prototype, matching QuickScreen's real-time writer architecture.
            let input = makeAudioInput()
            guard writer.canAdd(input) else { throw VideoRecordingError.couldNotStart }
            writer.add(input)
            microphoneInput = input
        }

        return LiveWritingContext(
            writer: writer,
            videoInput: videoInput,
            pixelBufferAdaptor: pixelBufferAdaptor,
            systemAudioInput: systemAudioInput,
            microphoneInput: microphoneInput,
            ciContext: CIContext(),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            canvasSize: canvasSize,
            targetRect: targetRect,
            mask: makeRoundedMask(rect: targetRect, canvasExtent: canvasExtent, radius: radius),
            shadow: makeWindowShadow(rect: targetRect, canvasExtent: canvasExtent, radius: radius),
            background: makeBackground(style.background, extent: canvasExtent),
            overlay: makeCornerText(style.cornerText, extent: canvasExtent)
        )
    }

    private func startFrameTimer() {
        // ScreenCaptureKit can omit source frames while only a separately drawn
        // cursor moves. A writer-owned 60 Hz clock keeps that motion fluid while
        // reusing the latest source buffer for otherwise static content.
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 60.0, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, let context = self.writingContext else { return }
            self.appendLiveVideoFrame(context: context, hostTime: CMClockGetTime(CMClockGetHostTimeClock()))
        }
        frameTimer = timer
        timer.resume()
    }

    private func receiveScreenFrame(_ sampleBuffer: CMSampleBuffer, context: LiveWritingContext) {
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first,
              let statusRawValue = attachments[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRawValue),
              status == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }

        context.latestSourcePixelBuffer = pixelBuffer
        context.latestSourceRect = frameContentRect(from: attachments, pixelBuffer: pixelBuffer)
        if context.sessionStartPTS == nil {
            let startPTS = sampleBuffer.presentationTimeStamp
            context.writer.startSession(atSourceTime: startPTS)
            context.sessionStartPTS = startPTS
            appendLiveVideoFrame(context: context, hostTime: startPTS)
        }
    }

    private func appendLiveVideoFrame(context: LiveWritingContext, hostTime: CMTime) {
        guard context.failure == nil,
              let startPTS = context.sessionStartPTS,
              let sourcePixelBuffer = context.latestSourcePixelBuffer,
              let sourceRect = context.latestSourceRect,
              hostTime >= startPTS else { return }
        let elapsed = CMTimeSubtract(hostTime, startPTS).seconds
        guard elapsed.isFinite else { return }
        let frameIndex = max(0, Int64(floor(elapsed * 60)))
        guard frameIndex > context.lastVideoFrameIndex, context.videoInput.isReadyForMoreMediaData else { return }
        guard let pool = context.pixelBufferAdaptor.pixelBufferPool else {
            context.failure = VideoRecordingError.couldNotProcess
            return
        }
        var destinationPixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destinationPixelBuffer) == kCVReturnSuccess,
              let destinationPixelBuffer else {
            context.failure = VideoRecordingError.couldNotProcess
            return
        }

        let source = CIImage(cvPixelBuffer: sourcePixelBuffer).cropped(to: sourceRect)
        let frameScaleX = context.targetRect.width / sourceRect.width
        let frameScaleY = context.targetRect.height / sourceRect.height
        let transform = CGAffineTransform(
            a: frameScaleX,
            b: 0,
            c: 0,
            d: frameScaleY,
            tx: context.targetRect.minX - sourceRect.minX * frameScaleX,
            ty: context.targetRect.minY - sourceRect.minY * frameScaleY
        )
        var framed = source.transformed(by: transform)
        if let cursor = cursorTracker?.currentSample(),
           cursor.isInside,
           let systemCursor = cursor.cursor {
            let identifier = ObjectIdentifier(systemCursor)
            let cursorImage: CursorImage?
            if let cached = context.cursorImages[identifier] {
                cursorImage = cached
            } else {
                cursorImage = makeCursorImage(systemCursor)
                context.cursorImages[identifier] = cursorImage
            }
            if let cursorImage {
                let cursorScale = min(frameScaleX, frameScaleY) * 2 * cursorCaptureScale / cursorImage.backingScale
                let cursorOrigin = CGPoint(
                    x: context.targetRect.minX + cursor.location.x * context.targetRect.width - cursorImage.hotSpot.x * cursorScale,
                    y: context.targetRect.minY + (1 - cursor.location.y) * context.targetRect.height - (cursorImage.extent.height - cursorImage.hotSpot.y) * cursorScale
                )
                let placedCursor = cursorImage.image
                    .transformed(by: CGAffineTransform(scaleX: cursorScale, y: cursorScale))
                    .transformed(by: CGAffineTransform(translationX: cursorOrigin.x, y: cursorOrigin.y))
                framed = placedCursor.composited(over: framed)
            }
        }

        let transparentCanvas = CIImage(color: .clear).cropped(to: context.canvasExtent)
        let roundedWindow = framed.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: transparentCanvas,
            kCIInputMaskImageKey: context.mask
        ])
        let framedWithShadow = roundedWindow.composited(over: context.shadow)
        var result = framedWithShadow.composited(over: context.background)
        if let overlay = context.overlay { result = overlay.composited(over: result) }
        context.ciContext.render(
            result.cropped(to: context.canvasExtent),
            to: destinationPixelBuffer,
            bounds: context.canvasExtent,
            colorSpace: context.colorSpace
        )

        let presentationTime = CMTimeAdd(startPTS, CMTime(value: frameIndex, timescale: 60))
        guard context.pixelBufferAdaptor.append(destinationPixelBuffer, withPresentationTime: presentationTime) else {
            context.failure = context.writer.error ?? VideoRecordingError.couldNotProcess
            return
        }
        context.lastVideoFrameIndex = frameIndex
        context.lastVideoPTS = presentationTime
    }

    private func appendAudio(
        _ sampleBuffer: CMSampleBuffer,
        to input: AVAssetWriterInput,
        context: LiveWritingContext
    ) {
        guard context.failure == nil,
              let startPTS = context.sessionStartPTS,
              sampleBuffer.presentationTimeStamp >= startPTS,
              input.isReadyForMoreMediaData else { return }
        guard input.append(sampleBuffer) else {
            context.failure = context.writer.error ?? VideoRecordingError.couldNotProcess
            return
        }
    }

    private func finishLiveWriting() async throws {
        guard let context = writingContext else { throw VideoRecordingError.couldNotProcess }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            captureQueue.async {
                if let failure = context.failure {
                    context.writer.cancelWriting()
                    continuation.resume(throwing: failure)
                    return
                }
                guard context.sessionStartPTS != nil, context.lastVideoPTS != nil else {
                    context.writer.cancelWriting()
                    continuation.resume(throwing: VideoRecordingError.couldNotStart)
                    return
                }
                context.videoInput.markAsFinished()
                context.systemAudioInput.markAsFinished()
                context.microphoneInput?.markAsFinished()
                context.writer.finishWriting {
                    if context.writer.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(
                            throwing: context.writer.error ?? VideoRecordingError.couldNotProcess
                        )
                    }
                }
            }
        }
    }

    private func frontWindowID() -> CGWindowID? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? Int, pid != ownPID,
                  let alpha = window[kCGWindowAlpha as String] as? Double, alpha > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? CGFloat,
                  let height = bounds["Height"] as? CGFloat,
                  width > 120,
                  height > 80,
                  let number = window[kCGWindowNumber as String] as? UInt32 else { continue }
            return CGWindowID(number)
        }
        return nil
    }

    private func evenPixelDimension(_ value: CGFloat) -> Int {
        let roundedUp = max(2, Int(ceil(value)))
        return roundedUp + roundedUp % 2
    }

    private func frameContentRect(
        from attachments: [SCStreamFrameInfo: Any],
        pixelBuffer: CVPixelBuffer
    ) -> CGRect {
        let bufferExtent = CGRect(
            x: 0,
            y: 0,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        guard let value = attachments[.contentRect] as? NSDictionary,
              let reportedRect = CGRect(dictionaryRepresentation: value) else {
            return bufferExtent
        }

        // ScreenCaptureKit can leave unused pixels at an output edge when its
        // even-sized IOSurface does not exactly match the window. The metadata
        // rect uses a top-left surface origin; Core Image uses bottom-left.
        let minX = max(bufferExtent.minX, ceil(reportedRect.minX))
        let maxX = min(bufferExtent.maxX, floor(reportedRect.maxX))
        let minYFromTop = max(0, ceil(reportedRect.minY))
        let maxYFromTop = min(bufferExtent.height, floor(reportedRect.maxY))
        guard maxX > minX, maxYFromTop > minYFromTop else { return bufferExtent }
        return CGRect(
            x: minX,
            y: bufferExtent.height - maxYFromTop,
            width: maxX - minX,
            height: maxYFromTop - minYFromTop
        )
    }


    private func makeCursorImage(_ cursor: NSCursor) -> CursorImage? {
        let backingScale: CGFloat = 8
        let pixelWidth = max(1, Int((cursor.image.size.width * backingScale).rounded()))
        let pixelHeight = max(1, Int((cursor.image.size.height * backingScale).rounded()))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: .alphaFirst,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        cursor.image.draw(
            in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = bitmap.cgImage else { return nil }
        let image = CIImage(cgImage: cgImage)
        return CursorImage(
            image: image,
            extent: image.extent,
            hotSpot: CGPoint(x: cursor.hotSpot.x * backingScale, y: cursor.hotSpot.y * backingScale),
            backingScale: backingScale
        )
    }

    private func makeRoundedMask(rect: CGRect, canvasExtent: CGRect, radius: CGFloat) -> CIImage {
        let clear = CIImage(color: .clear).cropped(to: canvasExtent)
        guard let rounded = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: rect),
            "inputRadius": radius,
            "inputColor": CIColor.white
        ])?.outputImage else {
            return CIImage(color: .white).cropped(to: rect).composited(over: clear)
        }
        return rounded.composited(over: clear).cropped(to: canvasExtent)
    }

    private func makeWindowShadow(rect: CGRect, canvasExtent: CGRect, radius: CGFloat) -> CIImage {
        let pixelWidth = max(1, Int(canvasExtent.width.rounded(.up)))
        let pixelHeight = max(1, Int(canvasExtent.height.rounded(.up)))
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return CIImage(color: .clear).cropped(to: canvasExtent)
        }
        context.setShadow(
            offset: CGSize(width: 0, height: CompositionAppearance.shadowOffsetY),
            blur: CompositionAppearance.shadowBlurRadius,
            color: CGColor(gray: 0, alpha: CompositionAppearance.shadowOpacity)
        )
        let windowPath = CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.addPath(windowPath)
        context.fillPath()
        // Keep only the shadow outside the window. A solid backing shape can
        // show through semitransparent capture-edge pixels as a dark band.
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setBlendMode(.clear)
        context.addPath(windowPath)
        context.fillPath()
        guard let image = context.makeImage() else {
            return CIImage(color: .clear).cropped(to: canvasExtent)
        }
        return CIImage(cgImage: image).cropped(to: canvasExtent)
    }

    private func makeBackground(_ image: NSImage?, extent: CGRect) -> CIImage {
        guard let image, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            let gradient = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: extent.minX, y: extent.maxY),
                "inputPoint1": CIVector(x: extent.maxX, y: extent.minY),
                "inputColor0": CIColor(red: 0.18, green: 0.12, blue: 0.42),
                "inputColor1": CIColor(red: 0.91, green: 0.35, blue: 0.46)
            ])?.outputImage
            return (gradient ?? CIImage(color: .black)).cropped(to: extent)
        }
        let source = CIImage(cgImage: cgImage)
        let scale = max(extent.width / source.extent.width, extent.height / source.extent.height)
        let size = CGSize(width: source.extent.width * scale, height: source.extent.height * scale)
        let transform = CGAffineTransform(scaleX: scale, y: scale)
            .translatedBy(x: (extent.width - size.width) / (2 * scale), y: (extent.height - size.height) / (2 * scale))
        return source.transformed(by: transform).cropped(to: extent)
    }

    private func makeCornerText(_ text: String, extent: CGRect) -> CIImage? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let pixelWidth = max(1, Int(extent.width.rounded(.up)))
        let pixelHeight = max(1, Int(extent.height.rounded(.up)))
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let fontSize = max(14, min(24, extent.width / 60))
        let appKitFont = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let font = CTFontCreateWithName(appKitFont.fontName as CFString, fontSize, nil)
        let attributes = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: NSColor.white.cgColor
        ] as CFDictionary
        guard let attributedString = CFAttributedStringCreate(nil, text as CFString, attributes) else { return nil }
        let line = CTLineCreateWithAttributedString(attributedString)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let textSize = CGSize(width: ceil(textWidth), height: ceil(ascent + descent + leading))
        let horizontalInset: CGFloat = 18
        let verticalInset: CGFloat = 10
        let edgeInset = max(24, extent.width / 64)
        let pill = NSRect(
            x: extent.maxX - textSize.width - horizontalInset * 2 - edgeInset,
            y: edgeInset,
            width: textSize.width + horizontalInset * 2,
            height: textSize.height + verticalInset * 2
        )
        context.setFillColor(NSColor.black.withAlphaComponent(0.48).cgColor)
        context.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
        context.fillPath()
        context.textMatrix = .identity
        context.textPosition = CGPoint(
            x: pill.minX + horizontalInset,
            y: pill.minY + verticalInset + descent
        )
        CTLineDraw(line, context)
        guard let cgImage = context.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }
}
