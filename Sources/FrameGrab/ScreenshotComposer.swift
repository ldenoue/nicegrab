import AppKit
import CoreGraphics

enum CaptureError: LocalizedError {
    case noWindow
    case permissionDenied
    case renderingFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .noWindow: "No capturable window was found. Bring the window you want to capture to the front and try again."
        case .permissionDenied: "Screen Recording permission is required. Enable NiceGrab in System Settings → Privacy & Security → Screen Recording, then relaunch it."
        case .renderingFailed: "The framed image could not be rendered."
        case .encodingFailed: "The framed screenshot could not be saved as a PNG."
        }
    }
}

final class ScreenshotComposer {
    func captureAndCompose(background: NSImage?, padding: CGFloat, canvas: CanvasOption, cornerText: String) throws -> NSImage {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
        }
        guard let windowID = frontWindowID() else { throw CaptureError.noWindow }
        guard let cgImage = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .bestResolution]) else {
            throw CaptureError.permissionDenied
        }
        return try compose(window: NSImage(cgImage: cgImage, size: .zero), background: background, padding: padding, canvas: canvas, cornerText: cornerText)
    }

    func copyToClipboard(_ image: NSImage) throws {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw CaptureError.encodingFailed
        }

        let fileURL = try screenshotURL()
        try pngData.write(to: fileURL, options: .atomic)

        // Finder needs a file URL in order to paste onto the Desktop, while apps
        // such as Preview and messaging clients prefer image data. Advertising
        // both representations on one item supports both kinds of destination.
        let item = NSPasteboardItem()
        item.setData(pngData, forType: .png)
        item.setData(tiffData, forType: .tiff)
        item.setString(fileURL.absoluteString, forType: .fileURL)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    private func screenshotURL() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("NiceGrab/Screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
        return root.appendingPathComponent("NiceGrab \(formatter.string(from: Date())).png")
    }

    private func frontWindowID() -> CGWindowID? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
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

    private func compose(window: NSImage, background: NSImage?, padding: CGFloat, canvas: CanvasOption, cornerText: String) throws -> NSImage {
        let windowSize = window.size
        let canvasSize = canvas.size(for: windowSize, padding: padding)
        let image = NSImage(size: canvasSize)
        image.lockFocusFlipped(false)
        defer { image.unlockFocus() }

        let canvas = NSRect(origin: .zero, size: canvasSize)
        if let background {
            drawAspectFill(background, in: canvas)
        } else {
            let gradient = NSGradient(colors: [
                NSColor(calibratedRed: 0.18, green: 0.12, blue: 0.42, alpha: 1),
                NSColor(calibratedRed: 0.91, green: 0.35, blue: 0.46, alpha: 1)
            ])
            gradient?.draw(in: canvas, angle: -35)
        }

        let maximumSize = NSSize(width: canvasSize.width - padding * 2, height: canvasSize.height - padding * 2)
        let scale = min(1, maximumSize.width / windowSize.width, maximumSize.height / windowSize.height)
        let targetSize = NSSize(width: windowSize.width * scale, height: windowSize.height * scale)
        let target = NSRect(
            x: (canvasSize.width - targetSize.width) / 2,
            y: (canvasSize.height - targetSize.height) / 2,
            width: targetSize.width,
            height: targetSize.height
        )
        let path = NSBezierPath(roundedRect: target, xRadius: 12, yRadius: 12)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.42)
        shadow.shadowBlurRadius = 28
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.set()
        NSColor.black.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        window.draw(in: target, from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        drawCornerText(cornerText, in: canvas)
        return image
    }

    private func drawCornerText(_ text: String, in canvas: NSRect) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let fontSize = max(14, min(24, canvas.width / 60))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        let horizontalInset: CGFloat = 18
        let verticalInset: CGFloat = 10
        let edgeInset = max(24, canvas.width / 64)
        let pill = NSRect(
            x: canvas.maxX - textSize.width - horizontalInset * 2 - edgeInset,
            y: edgeInset,
            width: textSize.width + horizontalInset * 2,
            height: textSize.height + verticalInset * 2
        )
        NSColor.black.withAlphaComponent(0.48).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        string.draw(at: NSPoint(x: pill.minX + horizontalInset, y: pill.minY + verticalInset))
    }

    private func drawAspectFill(_ image: NSImage, in rect: NSRect) {
        let source = image.size
        guard source.width > 0, source.height > 0 else { return }
        let scale = max(rect.width / source.width, rect.height / source.height)
        let size = NSSize(width: source.width * scale, height: source.height * scale)
        let target = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        image.draw(in: target, from: .zero, operation: .copy, fraction: 1)
    }
}
