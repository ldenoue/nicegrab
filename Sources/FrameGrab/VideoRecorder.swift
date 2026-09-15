import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import CoreText
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
            "The finished recording could not be composited."
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

    static func sample(at time: TimeInterval, in samples: [CursorSample]) -> CursorSample? {
        guard !samples.isEmpty else { return nil }
        var low = 0
        var high = samples.count
        while low < high {
            let middle = (low + high) / 2
            if samples[middle].time < time { low = middle + 1 } else { high = middle }
        }
        if low == 0 { return samples[0] }
        if low == samples.count { return samples[samples.count - 1] }
        let before = samples[low - 1]
        let after = samples[low]
        let duration = after.time - before.time
        guard duration > 0 else { return after }
        let amount = CGFloat((time - before.time) / duration)
        return CursorSample(
            time: time,
            location: CGPoint(
                x: before.location.x + (after.location.x - before.location.x) * amount,
                y: before.location.y + (after.location.y - before.location.y) * amount
            ),
            isInside: amount < 0.5 ? before.isInside : after.isInside,
            cursor: amount < 0.5 ? before.cursor : after.cursor
        )
    }
}

private struct CursorImage {
    let image: CIImage
    let extent: CGRect
    let hotSpot: CGPoint
    let backingScale: CGFloat
}

private final class MP4WritingContext: @unchecked Sendable {
    let reader: AVAssetReader
    let writer: AVAssetWriter
    let videoOutput: AVAssetReaderVideoCompositionOutput
    let videoInput: AVAssetWriterInput
    let audioOutput: AVAssetReaderAudioMixOutput?
    let audioInput: AVAssetWriterInput?

    init(
        reader: AVAssetReader,
        writer: AVAssetWriter,
        videoOutput: AVAssetReaderVideoCompositionOutput,
        videoInput: AVAssetWriterInput,
        audioOutput: AVAssetReaderAudioMixOutput?,
        audioInput: AVAssetWriterInput?
    ) {
        self.reader = reader
        self.writer = writer
        self.videoOutput = videoOutput
        self.videoInput = videoInput
        self.audioOutput = audioOutput
        self.audioInput = audioInput
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
    private let windowFrame: CGRect
    private var displayLink: CADisplayLink?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var samples: [CursorSample] = []
    private var latestPoint: CGPoint = .zero
    private var latestCursor: NSCursor?
    private var xFilter = OneEuroFilter(minimumCutoff: 1, beta: 0.001, derivativeCutoff: 0.8)
    private var yFilter = OneEuroFilter(minimumCutoff: 1, beta: 0.001, derivativeCutoff: 0.8)

    init(windowFrame: CGRect) {
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

    @discardableResult
    func stop() -> [CursorSample] {
        displayLink?.invalidate()
        displayLink = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        return samples
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
        guard windowFrame.width > 0, windowFrame.height > 0 else { return }
        let point = latestPoint
        let now = ProcessInfo.processInfo.systemUptime
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
        samples.append(sample)
    }
}

@available(macOS 15.0, *)
final class VideoRecorder: NSObject, SCRecordingOutputDelegate, SCStreamDelegate, SCStreamOutput {
    typealias Completion = (Result<URL, Error>) -> Void

    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var rawURL: URL?
    private var finalURL: URL?
    private var style: VideoCompositionStyle?
    private var completion: Completion?
    private var isStopping = false
    private var cursorTracker: CursorTracker?
    private var cursorSamples: [CursorSample] = []
    private var cursorCaptureScale: CGFloat = 2
    private let frameTimingQueue = DispatchQueue(label: "NiceGrab.FrameTiming", qos: .userInteractive)
    private let audioSinkQueue = DispatchQueue(label: "NiceGrab.AudioSink", qos: .userInitiated)
    private let microphoneSinkQueue = DispatchQueue(label: "NiceGrab.MicrophoneSink", qos: .userInitiated)
    private let frameTimingLock = NSLock()
    private var firstFramePTS: TimeInterval?
    private var minimumHostMinusPTS: TimeInterval?

    var isRecording: Bool { stream != nil }
    var isFinishing: Bool { isStopping }

    func start(includeMicrophone: Bool, smoothCursor: Bool, style: VideoCompositionStyle, completion: @escaping Completion) async throws {
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
        configuration.width = max(2, Int(window.frame.width * scale))
        configuration.height = max(2, Int(window.frame.height * scale))
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

        let urls = try recordingURLs()
        let outputConfiguration = SCRecordingOutputConfiguration()
        outputConfiguration.outputURL = urls.raw
        outputConfiguration.outputFileType = .mp4
        outputConfiguration.videoCodecType = .h264

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        let output = SCRecordingOutput(configuration: outputConfiguration, delegate: self)
        try stream.addRecordingOutput(output)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameTimingQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioSinkQueue)
        if includeMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: microphoneSinkQueue)
        }

        self.stream = stream
        self.recordingOutput = output
        self.rawURL = urls.raw
        self.finalURL = urls.final
        self.style = style
        self.completion = completion
        self.isStopping = false

        if smoothCursor {
            let tracker = CursorTracker(windowFrame: window.frame)
            cursorTracker = tracker
            tracker.start()
        }

        do {
            try await stream.startCapture()
        } catch {
            reset(removeFiles: true)
            throw error
        }
    }

    func stop() async throws {
        guard let stream, !isStopping else { return }
        isStopping = true
        cursorSamples = cursorTracker?.stop() ?? []
        cursorTracker = nil
        try await stream.stopCapture()
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {}

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid else { return }
        let pts = sampleBuffer.presentationTimeStamp.seconds
        guard pts.isFinite else { return }
        let hostTime = ProcessInfo.processInfo.systemUptime
        frameTimingLock.lock()
        if firstFramePTS == nil { firstFramePTS = pts }
        let hostMinusPTS = hostTime - pts
        minimumHostMinusPTS = min(minimumHostMinusPTS ?? hostMinusPTS, hostMinusPTS)
        frameTimingLock.unlock()
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        finish(.failure(error))
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        guard let rawURL, let finalURL, let style else {
            finish(.failure(VideoRecordingError.couldNotProcess))
            return
        }
        Task {
            do {
                let samples = cursorTracker?.stop() ?? cursorSamples
                cursorTracker = nil
                let videoTimedSamples = cursorSamplesOnVideoTimeline(samples)
                try await compositeRecording(
                    from: rawURL,
                    to: finalURL,
                    style: style,
                    cursorSamples: videoTimedSamples,
                    cursorCaptureScale: cursorCaptureScale
                )
                try? FileManager.default.removeItem(at: rawURL)
                finish(.success(finalURL), removeFiles: false)
            } catch {
                finish(.failure(error))
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<URL, Error>, removeFiles: Bool = true) {
        guard let completion else { return }
        let callback = completion
        reset(removeFiles: removeFiles)
        DispatchQueue.main.async { callback(result) }
    }

    private func reset(removeFiles: Bool) {
        if removeFiles {
            if let rawURL { try? FileManager.default.removeItem(at: rawURL) }
            if let finalURL { try? FileManager.default.removeItem(at: finalURL) }
        }
        stream = nil
        recordingOutput = nil
        rawURL = nil
        finalURL = nil
        style = nil
        completion = nil
        isStopping = false
        cursorTracker?.stop()
        cursorTracker = nil
        cursorSamples = []
        cursorCaptureScale = 2
        frameTimingLock.lock()
        firstFramePTS = nil
        minimumHostMinusPTS = nil
        frameTimingLock.unlock()
    }

    private func cursorSamplesOnVideoTimeline(_ samples: [CursorSample]) -> [CursorSample] {
        guard !samples.isEmpty else { return [] }
        frameTimingLock.lock()
        let firstPTS = firstFramePTS
        let hostMinusPTS = minimumHostMinusPTS
        frameTimingLock.unlock()

        let firstVideoFrameHostTime: TimeInterval
        if let firstPTS, let hostMinusPTS {
            firstVideoFrameHostTime = firstPTS + hostMinusPTS
        } else {
            firstVideoFrameHostTime = samples[0].time
        }
        return samples.map {
            CursorSample(
                time: $0.time - firstVideoFrameHostTime,
                location: $0.location,
                isInside: $0.isInside,
                cursor: $0.cursor
            )
        }
    }

    private func frontWindowID() -> CGWindowID? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? Int, pid != ownPID,
                  let alpha = window[kCGWindowAlpha as String] as? Double, alpha > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? CGFloat, let height = bounds["Height"] as? CGFloat,
                  width > 120, height > 80,
                  let number = window[kCGWindowNumber as String] as? UInt32 else { continue }
            return CGWindowID(number)
        }
        return nil
    }

    private func recordingURLs() throws -> (raw: URL, final: URL) {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("NiceGrab/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "NiceGrab \(formatter.string(from: Date()))"
        return (
            root.appendingPathComponent(".\(name)-raw.mp4"),
            root.appendingPathComponent("\(name).mp4")
        )
    }

    private func compositeRecording(
        from sourceURL: URL,
        to outputURL: URL,
        style: VideoCompositionStyle,
        cursorSamples: [CursorSample],
        cursorCaptureScale: CGFloat
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoRecordingError.couldNotProcess
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let requestedCanvasSize = style.canvas.size(for: naturalSize, padding: style.padding)
        // 4:2:0 H.264 needs even dimensions. Adaptive canvases inherit the
        // captured window's pixel size, which can occasionally be odd.
        let canvasSize = CGSize(
            width: ceil(requestedCanvasSize.width / 2) * 2,
            height: ceil(requestedCanvasSize.height / 2) * 2
        )
        let canvasExtent = CGRect(origin: .zero, size: canvasSize)
        let background = makeBackground(style.background, extent: canvasExtent)
        let overlay = makeCornerText(style.cornerText, extent: canvasExtent)

        let maximumSize = CGSize(
            width: canvasSize.width - style.padding * 2,
            height: canvasSize.height - style.padding * 2
        )
        let scale = min(1, maximumSize.width / naturalSize.width, maximumSize.height / naturalSize.height)
        let targetSize = CGSize(width: naturalSize.width * scale, height: naturalSize.height * scale)
        let targetRect = CGRect(
            x: (canvasSize.width - targetSize.width) / 2,
            y: (canvasSize.height - targetSize.height) / 2,
            width: targetSize.width,
            height: targetSize.height
        )
        let radius = min(14, targetSize.width / 20, targetSize.height / 20)
        let mask = makeRoundedMask(rect: targetRect, canvasExtent: canvasExtent, radius: radius)
        var cursorImages: [ObjectIdentifier: CursorImage] = [:]
        for sample in cursorSamples {
            guard let cursor = sample.cursor else { continue }
            let identifier = ObjectIdentifier(cursor)
            if cursorImages[identifier] == nil {
                cursorImages[identifier] = makeCursorImage(cursor)
            }
        }

        let composition = AVMutableVideoComposition(asset: asset) { request in
            let source = request.sourceImage.clampedToExtent().cropped(to: request.sourceImage.extent)
            let transform = CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY)
                .scaledBy(x: scale, y: scale)
                .translatedBy(x: targetRect.minX / scale, y: targetRect.minY / scale)
            let framed = source.transformed(by: transform)
            var framedWithCursor = framed
            if let cursor = CursorSample.sample(at: request.compositionTime.seconds, in: cursorSamples),
               cursor.isInside,
               let systemCursor = cursor.cursor,
               let cursorImage = cursorImages[ObjectIdentifier(systemCursor)] {
                let sourcePoint = CGPoint(
                    x: cursor.location.x * naturalSize.width,
                    y: (1 - cursor.location.y) * naturalSize.height
                )
                // The cursor is rasterized at 8x to keep the requested 2x display
                // size crisp, even after the window is scaled into the canvas.
                let cursorScale = scale * 2 * cursorCaptureScale / cursorImage.backingScale
                let cursorOrigin = CGPoint(
                    x: targetRect.minX + sourcePoint.x * scale - cursorImage.hotSpot.x * cursorScale,
                    y: targetRect.minY + sourcePoint.y * scale - (cursorImage.extent.height - cursorImage.hotSpot.y) * cursorScale
                )
                let placedCursor = cursorImage.image
                    .transformed(by: CGAffineTransform(scaleX: cursorScale, y: cursorScale))
                    .transformed(by: CGAffineTransform(translationX: cursorOrigin.x, y: cursorOrigin.y))
                framedWithCursor = placedCursor.composited(over: framed)
            }
            let transparentCanvas = CIImage(color: .clear).cropped(to: canvasExtent)
            let roundedWindow = framedWithCursor.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: transparentCanvas,
                kCIInputMaskImageKey: mask
            ])
            let shadowSource = roundedWindow
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
                ])

            // A broad ambient shadow separates the window from textured backgrounds;
            // the tighter key shadow matches the screenshot compositing treatment.
            let ambientShadow = shadowSource
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.30)
                ])
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 54])
                .transformed(by: CGAffineTransform(translationX: 0, y: -6))
                .cropped(to: canvasExtent)

            let keyShadow = shadowSource
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.48)
                ])
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 24])
                .transformed(by: CGAffineTransform(translationX: 0, y: -12))
                .cropped(to: canvasExtent)

            let combinedShadow = keyShadow.composited(over: ambientShadow)
            let framedWithShadow = roundedWindow.composited(over: combinedShadow)
            var result = framedWithShadow.composited(over: background)
            if let overlay { result = overlay.composited(over: result) }
            request.finish(with: result.cropped(to: canvasExtent), context: nil)
        }
        composition.renderSize = canvasSize
        composition.frameDuration = CMTime(value: 1, timescale: 60)
        if !cursorSamples.isEmpty {
            // ScreenCaptureKit may encode a variable-frame-rate track and omit
            // samples while only the separately monitored cursor is moving.
            // Synthetic-cursor recordings therefore need an independent 60-fps
            // output clock. Native-cursor recordings can preserve sparse source
            // timing, avoiding needless frame rendering and a slower export.
            composition.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        }

        try await writeCompatibleMP4(
            asset: asset,
            videoTrack: videoTrack,
            videoComposition: composition,
            canvasSize: canvasSize,
            outputURL: outputURL
        )
    }

    private func writeCompatibleMP4(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        videoComposition: AVVideoComposition,
        canvasSize: CGSize,
        outputURL: URL
    ) async throws {
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [videoTrack],
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        videoOutput.videoComposition = videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw VideoRecordingError.couldNotProcess }
        reader.add(videoOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        // Put the movie index before media data so chat clients can inspect and
        // generate a preview without first downloading the whole recording.
        writer.shouldOptimizeForNetworkUse = true

        let width = Int(canvasSize.width.rounded())
        let height = Int(canvasSize.height.rounded())
        // Screen recordings compress well. This targets about 4 Mbps at
        // 1080p60, scaling with pixel count while retaining crisp UI text.
        let bitsPerSecond = min(
            8_000_000,
            max(1_000_000, Int(Double(width * height * 60) * 0.032))
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
                    AVVideoMaxKeyFrameIntervalKey: 120,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
        )
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw VideoRecordingError.couldNotProcess }
        // Adding video first makes it track 1. Some chat preview pipelines do
        // not reliably discover video when an audio track comes first.
        writer.add(videoInput)

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var audioOutput: AVAssetReaderAudioMixOutput?
        var audioInput: AVAssetWriterInput?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(
                audioTracks: audioTracks,
                audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM]
            )
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 128_000
                ]
            )
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(output), writer.canAdd(input) else {
                throw VideoRecordingError.couldNotProcess
            }
            reader.add(output)
            writer.add(input)
            audioOutput = output
            audioInput = input
        }

        guard writer.startWriting() else {
            throw writer.error ?? VideoRecordingError.couldNotProcess
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            writer.cancelWriting()
            throw reader.error ?? VideoRecordingError.couldNotProcess
        }

        let context = MP4WritingContext(
            reader: reader,
            writer: writer,
            videoOutput: videoOutput,
            videoInput: videoInput,
            audioOutput: audioOutput,
            audioInput: audioInput
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let group = DispatchGroup()
            let videoQueue = DispatchQueue(label: "NiceGrab.VideoEncoder", qos: .userInitiated)
            group.enter()
            context.videoInput.requestMediaDataWhenReady(on: videoQueue) {
                while context.videoInput.isReadyForMoreMediaData {
                    guard let sample = context.videoOutput.copyNextSampleBuffer() else {
                        context.videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                    guard context.videoInput.append(sample) else {
                        context.reader.cancelReading()
                        context.videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }

            if let audioInput = context.audioInput {
                let audioQueue = DispatchQueue(label: "NiceGrab.AudioEncoder", qos: .userInitiated)
                group.enter()
                audioInput.requestMediaDataWhenReady(on: audioQueue) {
                    guard let contextAudioInput = context.audioInput,
                          let contextAudioOutput = context.audioOutput else {
                        group.leave()
                        return
                    }
                    while contextAudioInput.isReadyForMoreMediaData {
                        guard let sample = contextAudioOutput.copyNextSampleBuffer() else {
                            contextAudioInput.markAsFinished()
                            group.leave()
                            return
                        }
                        guard contextAudioInput.append(sample) else {
                            context.reader.cancelReading()
                            contextAudioInput.markAsFinished()
                            group.leave()
                            return
                        }
                    }
                }
            }

            group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
                context.writer.finishWriting {
                    if context.writer.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(
                            throwing: context.writer.error ?? context.reader.error ?? VideoRecordingError.couldNotProcess
                        )
                    }
                }
            }
        }
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
