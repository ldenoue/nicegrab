import AppKit

enum PaddingOption: String, CaseIterable {
    case compact, comfortable, spacious

    var title: String { rawValue.capitalized }
    var points: CGFloat {
        switch self {
        case .compact: 32
        case .comfortable: 120
        case .spacious: 180
        }
    }
}

enum CanvasOption: String, CaseIterable {
    case adaptive, widescreen, standard, square

    var title: String {
        switch self {
        case .adaptive: "Adaptive (Match Window)"
        case .widescreen: "16:9 (1920 × 1080)"
        case .standard: "4:3 (1440 × 1080)"
        case .square: "1:1 (1080 × 1080)"
        }
    }

    func size(for window: NSSize, padding: CGFloat) -> NSSize {
        switch self {
        case .adaptive: NSSize(width: window.width + padding * 2, height: window.height + padding * 2)
        case .widescreen: NSSize(width: 1920, height: 1080)
        case .standard: NSSize(width: 1440, height: 1080)
        case .square: NSSize(width: 1080, height: 1080)
        }
    }
}

enum TemplateOption: String, CaseIterable {
    case none, work, twitter, linkedIn, presentation

    var title: String {
        switch self {
        case .none: "None"
        case .work: "Work"
        case .twitter: "X / Twitter"
        case .linkedIn: "LinkedIn"
        case .presentation: "Presentation"
        }
    }

    var defaultText: String {
        switch self {
        case .none: ""
        case .work: "CONFIDENTIAL • WORK"
        case .twitter: "@yourhandle"
        case .linkedIn: "Your Name"
        case .presentation: "Company • 2026"
        }
    }

    var preferredCanvas: CanvasOption? {
        switch self {
        case .none: nil
        case .linkedIn: .square
        case .work, .twitter, .presentation: .widescreen
        }
    }
}

final class BackgroundStore {
    private let defaults = UserDefaults.standard
    private let bookmarkKey = "backgroundBookmark"
    private let storedFileKey = "backgroundStoredFile"
    private let nameKey = "backgroundName"
    private let paddingKey = "padding"
    private let canvasKey = "canvas"
    private let templateKey = "template"

    var displayName: String? { defaults.string(forKey: nameKey) }
    var hasCustomBackground: Bool {
        defaults.string(forKey: storedFileKey) != nil || defaults.data(forKey: bookmarkKey) != nil
    }

    var padding: PaddingOption {
        get { PaddingOption(rawValue: defaults.string(forKey: paddingKey) ?? "comfortable") ?? .comfortable }
        set { defaults.set(newValue.rawValue, forKey: paddingKey) }
    }

    var canvas: CanvasOption {
        get { CanvasOption(rawValue: defaults.string(forKey: canvasKey) ?? "widescreen") ?? .widescreen }
        set { defaults.set(newValue.rawValue, forKey: canvasKey) }
    }

    var template: TemplateOption {
        get { TemplateOption(rawValue: defaults.string(forKey: templateKey) ?? "none") ?? .none }
        set { defaults.set(newValue.rawValue, forKey: templateKey) }
    }

    var templateText: String {
        get { text(for: template) }
        set {
            guard template != .none else { return }
            defaults.set(newValue, forKey: "templateText.\(template.rawValue)")
        }
    }

    func text(for template: TemplateOption) -> String {
        guard template != .none else { return "" }
        return defaults.string(forKey: "templateText.\(template.rawValue)") ?? template.defaultText
    }

    var image: NSImage? {
        if let url = storedBackgroundURL(), let image = NSImage(contentsOf: url) {
            return image
        }
        guard let data = defaults.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return NSImage(contentsOf: url)
    }

    func setBackground(from url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard NSImage(contentsOf: url) != nil else { throw CocoaError(.fileReadCorruptFile) }

        let directory = try backgroundDirectory()
        let pathExtension = url.pathExtension.isEmpty ? "image" : url.pathExtension.lowercased()
        let storedName = "Background-\(UUID().uuidString).\(pathExtension)"
        let destination = directory.appendingPathComponent(storedName)
        let previousURL = storedBackgroundURL()
        let data = try Data(contentsOf: url)
        try data.write(to: destination, options: .atomic)
        guard NSImage(contentsOf: destination) != nil else {
            try? FileManager.default.removeItem(at: destination)
            throw CocoaError(.fileReadCorruptFile)
        }

        defaults.set(storedName, forKey: storedFileKey)
        defaults.set(url.lastPathComponent, forKey: nameKey)
        defaults.removeObject(forKey: bookmarkKey)
        if let previousURL, previousURL != destination {
            try? FileManager.default.removeItem(at: previousURL)
        }
    }

    func clearBackground() {
        if let url = storedBackgroundURL() {
            try? FileManager.default.removeItem(at: url)
        }
        defaults.removeObject(forKey: bookmarkKey)
        defaults.removeObject(forKey: storedFileKey)
        defaults.removeObject(forKey: nameKey)
    }

    private func backgroundDirectory() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("NiceGrab/Backgrounds", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func storedBackgroundURL() -> URL? {
        guard let storedName = defaults.string(forKey: storedFileKey),
              let directory = try? backgroundDirectory() else { return nil }
        return directory.appendingPathComponent(storedName)
    }
}
