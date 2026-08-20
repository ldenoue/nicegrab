import AppKit
import AVFoundation
import CoreImage
import CoreMedia
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

@available(macOS 15.0, *)
final class VideoRecorder: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    typealias Completion = (Result<URL, Error>) -> Void

    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var rawURL: URL?
    private var finalURL: URL?
    private var style: VideoCompositionStyle?
    private var completion: Completion?
    private var isStopping = false

    var isRecording: Bool { stream != nil }

    func start(includeMicrophone: Bool, style: VideoCompositionStyle, completion: @escaping Completion) async throws {
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
        configuration.width = max(2, Int(window.frame.width * scale))
        configuration.height = max(2, Int(window.frame.height * scale))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 6
        configuration.showsCursor = true
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

        self.stream = stream
        self.recordingOutput = output
        self.rawURL = urls.raw
        self.finalURL = urls.final
        self.style = style
        self.completion = completion
        self.isStopping = false

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
        try await stream.stopCapture()
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {}

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
                try await compositeRecording(from: rawURL, to: finalURL, style: style)
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

    private func compositeRecording(from sourceURL: URL, to outputURL: URL, style: VideoCompositionStyle) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoRecordingError.couldNotProcess
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let canvasSize = style.canvas.size(for: naturalSize, padding: style.padding)
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

        let composition = AVMutableVideoComposition(asset: asset) { request in
            let source = request.sourceImage.clampedToExtent().cropped(to: request.sourceImage.extent)
            let transform = CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY)
                .scaledBy(x: scale, y: scale)
                .translatedBy(x: targetRect.minX / scale, y: targetRect.minY / scale)
            let framed = source.transformed(by: transform)
            let transparentCanvas = CIImage(color: .clear).cropped(to: canvasExtent)
            let roundedWindow = framed.applyingFilter("CIBlendWithAlphaMask", parameters: [
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

        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw VideoRecordingError.couldNotProcess
        }
        exporter.videoComposition = composition
        try await exporter.export(to: outputURL, as: .mp4)
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
        let image = NSImage(size: extent.size)
        image.lockFocusFlipped(false)
        defer { image.unlockFocus() }
        let fontSize = max(14, min(24, extent.width / 60))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        let horizontalInset: CGFloat = 18
        let verticalInset: CGFloat = 10
        let edgeInset = max(24, extent.width / 64)
        let pill = NSRect(
            x: extent.maxX - textSize.width - horizontalInset * 2 - edgeInset,
            y: edgeInset,
            width: textSize.width + horizontalInset * 2,
            height: textSize.height + verticalInset * 2
        )
        NSColor.black.withAlphaComponent(0.48).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        string.draw(at: NSPoint(x: pill.minX + horizontalInset, y: pill.minY + verticalInset))
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return CIImage(cgImage: cgImage)
    }
}
