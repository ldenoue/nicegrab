import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: EventHotKeyRef?
    private var recordingHotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var videoRecorder: AnyObject?
    private let composer = ScreenshotComposer()
    private let backgroundStore = BackgroundStore()
    private let shortcutSettings = ShortcutSettings()
    private var includeMicrophone: Bool {
        get { UserDefaults.standard.bool(forKey: "recording.includeMicrophone") }
        set { UserDefaults.standard.set(newValue, forKey: "recording.includeMicrophone") }
    }
    private lazy var captureSound: NSSound? = {
        let systemSound = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif")
        return NSSound(contentsOf: systemSound, byReference: true) ?? NSSound(named: NSSound.Name("Tink"))
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeStatusItem()
        installHotKeyHandler()
        _ = registerHotKey(shortcutSettings.shortcut)
        _ = registerRecordingHotKey(shortcutSettings.recordingShortcut)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let recordingHotKey { UnregisterEventHotKey(recordingHotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
    }

    private func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "NiceGrab")
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let capture = NSMenuItem(title: "Capture Front Window", action: #selector(captureFrontWindow), keyEquivalent: "")
        capture.target = self
        menu.addItem(capture)
        let shortcut = NSMenuItem(title: "Keyboard Shortcut: \(shortcutSettings.shortcut.displayName)…", action: #selector(changeKeyboardShortcut), keyEquivalent: "")
        shortcut.target = self
        menu.addItem(shortcut)

        let recording = NSMenuItem(
            title: isRecording ? "Stop Window Recording" : "Record Front Window",
            action: #selector(toggleWindowRecording),
            keyEquivalent: ""
        )
        recording.target = self
        menu.addItem(recording)
        let recordingShortcut = NSMenuItem(title: "Recording Shortcut: \(shortcutSettings.recordingShortcut.displayName)…", action: #selector(changeRecordingShortcut), keyEquivalent: "")
        recordingShortcut.target = self
        recordingShortcut.isEnabled = !isRecording
        menu.addItem(recordingShortcut)
        let microphone = NSMenuItem(title: "Include Microphone", action: #selector(toggleMicrophone), keyEquivalent: "")
        microphone.target = self
        microphone.state = includeMicrophone ? .on : .off
        microphone.isEnabled = !isRecording
        menu.addItem(microphone)
        menu.addItem(.separator())

        let backgroundTitle = backgroundStore.displayName.map { "Background: \($0)" } ?? "Background: Default Gradient"
        let current = NSMenuItem(title: backgroundTitle, action: nil, keyEquivalent: "")
        current.isEnabled = false
        menu.addItem(current)

        let choose = NSMenuItem(title: "Choose Background Image…", action: #selector(chooseBackground), keyEquivalent: "")
        choose.target = self
        menu.addItem(choose)

        if backgroundStore.hasCustomBackground {
            let clear = NSMenuItem(title: "Use Default Gradient", action: #selector(clearBackground), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }

        menu.addItem(.separator())
        let paddingMenu = NSMenu()
        for option in PaddingOption.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(selectPadding(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = backgroundStore.padding == option ? .on : .off
            paddingMenu.addItem(item)
        }
        let padding = NSMenuItem(title: "Canvas Padding", action: nil, keyEquivalent: "")
        padding.submenu = paddingMenu
        menu.addItem(padding)

        let canvasMenu = NSMenu()
        for option in CanvasOption.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(selectCanvas(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = backgroundStore.canvas == option ? .on : .off
            canvasMenu.addItem(item)
        }
        let canvas = NSMenuItem(title: "Output Aspect Ratio", action: nil, keyEquivalent: "")
        canvas.submenu = canvasMenu
        menu.addItem(canvas)

        let templateMenu = NSMenu()
        for option in TemplateOption.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(selectTemplate(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = backgroundStore.template == option ? .on : .off
            let savedText = backgroundStore.text(for: option)
            if !savedText.isEmpty {
                let title = NSMutableAttributedString(
                    string: option.title,
                    attributes: [.foregroundColor: NSColor.labelColor]
                )
                title.append(NSAttributedString(
                    string: "  —  \(savedText)",
                    attributes: [.foregroundColor: NSColor.secondaryLabelColor]
                ))
                item.attributedTitle = title
            }
            templateMenu.addItem(item)
        }
        templateMenu.addItem(.separator())
        let editText = NSMenuItem(title: "Edit Corner Text…", action: #selector(editTemplateText), keyEquivalent: "")
        editText.target = self
        editText.isEnabled = backgroundStore.template != .none
        templateMenu.addItem(editText)
        let templates = NSMenuItem(title: "Templates", action: nil, keyEquivalent: "")
        templates.submenu = templateMenu
        menu.addItem(templates)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit NiceGrab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func installHotKeyHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var identifier = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout.size(ofValue: identifier), nil, &identifier)
            if identifier.id == 1 {
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { delegate.captureFrontWindow() }
            } else if identifier.id == 2 {
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { delegate.toggleWindowRecording() }
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)

    }

    @discardableResult
    private func registerHotKey(_ shortcut: KeyboardShortcut) -> Bool {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        let identifier = EventHotKeyID(signature: OSType(0x4E475242), id: 1) // NGRB
        return RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, identifier, GetApplicationEventTarget(), 0, &hotKey) == noErr
    }

    @discardableResult
    private func registerRecordingHotKey(_ shortcut: KeyboardShortcut) -> Bool {
        if let recordingHotKey { UnregisterEventHotKey(recordingHotKey) }
        recordingHotKey = nil
        let identifier = EventHotKeyID(signature: OSType(0x4E475242), id: 2) // NGRB
        return RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, identifier, GetApplicationEventTarget(), 0, &recordingHotKey) == noErr
    }

    @objc private func changeKeyboardShortcut() {
        NSApp.activate(ignoringOtherApps: true)
        let recorder = ShortcutRecorderView(frame: NSRect(x: 0, y: 0, width: 300, height: 68))
        recorder.shortcut = shortcutSettings.shortcut
        let alert = NSAlert()
        alert.messageText = "Choose a keyboard shortcut"
        alert.informativeText = "Click the field, then press a key with Command, Option, Control, or Shift."
        alert.accessoryView = recorder
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = recorder
        guard alert.runModal() == .alertFirstButtonReturn, let candidate = recorder.shortcut else { return }

        let previous = shortcutSettings.shortcut
        if registerHotKey(candidate) {
            shortcutSettings.shortcut = candidate
            rebuildMenu()
        } else {
            _ = registerHotKey(previous)
            showAlert("That shortcut is already used by macOS or another app. Please choose a different combination.")
        }
    }

    @objc private func changeRecordingShortcut() {
        NSApp.activate(ignoringOtherApps: true)
        let recorder = ShortcutRecorderView(frame: NSRect(x: 0, y: 0, width: 300, height: 68))
        recorder.shortcut = shortcutSettings.recordingShortcut
        let alert = NSAlert()
        alert.messageText = "Choose a recording shortcut"
        alert.informativeText = "Use this shortcut once to start recording the front window and again to stop."
        alert.accessoryView = recorder
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = recorder
        guard alert.runModal() == .alertFirstButtonReturn, let candidate = recorder.shortcut else { return }

        let previous = shortcutSettings.recordingShortcut
        if registerRecordingHotKey(candidate) {
            shortcutSettings.recordingShortcut = candidate
            rebuildMenu()
        } else {
            _ = registerRecordingHotKey(previous)
            showAlert("That shortcut is already used by macOS or another app. Please choose a different combination.")
        }
    }

    private var isRecording: Bool {
        guard #available(macOS 15.0, *), let recorder = videoRecorder as? VideoRecorder else { return false }
        return recorder.isRecording
    }

    @objc private func toggleMicrophone() {
        includeMicrophone.toggle()
        rebuildMenu()
    }

    @objc private func toggleWindowRecording() {
        guard #available(macOS 15.0, *) else {
            showAlert(VideoRecordingError.unsupportedSystem.localizedDescription)
            return
        }

        if let recorder = videoRecorder as? VideoRecorder, recorder.isRecording {
            showFeedback(symbol: "ellipsis", help: "Finishing recording")
            Task {
                do { try await recorder.stop() }
                catch { await MainActor.run { self.recordingFailed(error) } }
            }
            return
        }

        let recorder = VideoRecorder()
        videoRecorder = recorder
        let style = VideoCompositionStyle(
            background: backgroundStore.image,
            padding: backgroundStore.padding.points,
            canvas: backgroundStore.canvas,
            cornerText: backgroundStore.templateText
        )
        let useMicrophone = includeMicrophone
        showFeedback(symbol: "record.circle", help: "Recording front window")
        Task {
            do {
                try await recorder.start(includeMicrophone: useMicrophone, style: style) { [weak self] result in
                    guard let self else { return }
                    self.videoRecorder = nil
                    self.rebuildMenu()
                    switch result {
                    case .success(let url):
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.writeObjects([url as NSURL])
                        self.captureSound?.play()
                        self.showFeedback(symbol: "checkmark", help: "Framed MP4 copied")
                    case .failure(let error):
                        self.recordingFailed(error)
                    }
                }
                await MainActor.run { self.rebuildMenu() }
            } catch {
                await MainActor.run {
                    self.videoRecorder = nil
                    self.rebuildMenu()
                    self.recordingFailed(error)
                }
            }
        }
    }

    private func recordingFailed(_ error: Error) {
        if let recordingError = error as? VideoRecordingError, recordingError == .permissionDenied {
            showScreenRecordingPermissionAlert()
        } else {
            showAlert(error.localizedDescription)
        }
    }

    @objc private func captureFrontWindow() {
        do {
            let background = backgroundStore.image
            let result = try composer.captureAndCompose(
                background: background,
                padding: backgroundStore.padding.points,
                canvas: backgroundStore.canvas,
                cornerText: backgroundStore.templateText
            )
            try composer.copyToClipboard(result)
            captureSound?.play()
            showFeedback(symbol: "checkmark", help: "Framed screenshot copied")
        } catch CaptureError.permissionDenied {
            showScreenRecordingPermissionAlert()
        } catch {
            showAlert(error.localizedDescription)
        }
    }

    @objc private func chooseBackground() {
        let panel = NSOpenPanel()
        panel.title = "Choose a background image"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try backgroundStore.setBackground(from: url)
            rebuildMenu()
        } catch {
            showAlert("Could not use that image: \(error.localizedDescription)")
        }
    }

    @objc private func clearBackground() {
        backgroundStore.clearBackground()
        rebuildMenu()
    }

    @objc private func selectPadding(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let padding = PaddingOption(rawValue: raw) else { return }
        backgroundStore.padding = padding
        rebuildMenu()
    }

    @objc private func selectCanvas(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let canvas = CanvasOption(rawValue: raw) else { return }
        backgroundStore.canvas = canvas
        rebuildMenu()
    }

    @objc private func selectTemplate(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let template = TemplateOption(rawValue: raw) else { return }
        backgroundStore.template = template
        if let canvas = template.preferredCanvas { backgroundStore.canvas = canvas }
        rebuildMenu()
    }

    @objc private func editTemplateText() {
        guard backgroundStore.template != .none else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Edit \(backgroundStore.template.title) corner text"
        alert.informativeText = "This text is saved separately for each template."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: backgroundStore.templateText)
        field.placeholderString = backgroundStore.template.defaultText
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            backgroundStore.templateText = field.stringValue
        }
    }

    private func showFeedback(symbol: String, help: String) {
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.statusItem.button?.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "NiceGrab")
        }
    }

    private func showAlert(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "NiceGrab couldn’t capture the window"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showScreenRecordingPermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission is required"
        alert.informativeText = "Allow NiceGrab to record the screen, then quit and reopen the app before capturing again."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
