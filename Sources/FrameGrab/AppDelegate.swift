import AppKit
import Carbon

private final class RecordingProgressWindowController: NSWindowController {
    private let progressIndicator = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "Finalizing the recording…")

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 220),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "Preparing Your Video"
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let explanation = NSTextField(wrappingLabelWithString:
            "NiceGrab is applying your background, layout, corner text, and cursor, then encoding the final MP4. Longer recordings can take a few minutes."
        )
        explanation.textColor = .labelColor

        statusLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor

        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 100

        let note = NSTextField(wrappingLabelWithString:
            "You can keep using your Mac. The finished video will be copied to the clipboard automatically."
        )
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [explanation, statusLabel, progressIndicator, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        panel.contentView = contentView
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24),
            progressIndicator.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        super.init(window: panel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(progress: Double) {
        let percent = max(0, min(100, progress * 100))
        progressIndicator.doubleValue = percent
        if percent < 8 {
            statusLabel.stringValue = "Finalizing the recording…"
        } else if percent < 99 {
            statusLabel.stringValue = "Compositing and encoding… \(Int(percent.rounded()))%"
        } else {
            statusLabel.stringValue = "Finishing the MP4…"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: EventHotKeyRef?
    private var recordingHotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var videoRecorder: AnyObject?
    private var isStartingRecording = false
    private var recordingStatusTimer: Timer?
    private var recordingStartedAt: Date?
    private var processingSpinnerTimer: Timer?
    private var processingSpinnerAngle: CGFloat = 0
    private var recordingProgressWindow: RecordingProgressWindowController?
    private let composer = ScreenshotComposer()
    private let backgroundStore = BackgroundStore()
    private let shortcutSettings = ShortcutSettings()
    private lazy var proStore = ProStore { [weak self] in self?.rebuildMenu() }
    private var effectiveTemplateText: String {
        guard proStore.isPro else { return "Free version of NiceGrab for macOS" }
        return backgroundStore.template == .none ? "" : backgroundStore.templateText
    }
    private var includeMicrophone: Bool {
        get { UserDefaults.standard.bool(forKey: "recording.includeMicrophone") }
        set { UserDefaults.standard.set(newValue, forKey: "recording.includeMicrophone") }
    }
    private var smoothCursor: Bool {
        get {
            let key = "recording.smoothCursor"
            return UserDefaults.standard.object(forKey: key) == nil || UserDefaults.standard.bool(forKey: key)
        }
        set { UserDefaults.standard.set(newValue, forKey: "recording.smoothCursor") }
    }
    private lazy var captureSound: NSSound? = {
        let systemSound = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif")
        return NSSound(contentsOf: systemSound, byReference: true) ?? NSSound(named: NSSound.Name("Tink"))
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeStatusItem()
        _ = proStore
        installHotKeyHandler()
        _ = registerHotKey(shortcutSettings.shortcut)
        _ = registerRecordingHotKey(shortcutSettings.recordingShortcut)
        showWelcome()
    }

    func applicationWillTerminate(_ notification: Notification) {
        recordingStatusTimer?.invalidate()
        processingSpinnerTimer?.invalidate()
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
        let cursor = NSMenuItem(title: "Smooth Cursor", action: #selector(toggleSmoothCursor), keyEquivalent: "")
        cursor.target = self
        cursor.state = smoothCursor ? .on : .off
        cursor.isEnabled = !isRecording
        menu.addItem(cursor)
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
            item.isEnabled = proStore.isPro
            let savedText = proStore.isPro ? backgroundStore.text(for: option) : "Free version of NiceGrab for macOS"
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
        let editText = NSMenuItem(
            title: proStore.isPro ? "Edit Corner Text…" : "Customize Corner Text with Pro…",
            action: #selector(editTemplateText),
            keyEquivalent: ""
        )
        editText.target = self
        editText.isEnabled = !proStore.isPro || backgroundStore.template != .none
        templateMenu.addItem(editText)
        let templates = NSMenuItem(title: "Templates", action: nil, keyEquivalent: "")
        templates.submenu = templateMenu
        menu.addItem(templates)

        menu.addItem(.separator())
        if proStore.isPro {
            let pro = NSMenuItem(title: "NiceGrab Pro ✓", action: nil, keyEquivalent: "")
            pro.isEnabled = false
            menu.addItem(pro)
        } else {
            let purchase = NSMenuItem(title: proStore.purchaseTitle, action: #selector(purchasePro), keyEquivalent: "")
            purchase.target = self
            menu.addItem(purchase)
            let restore = NSMenuItem(title: "Restore Purchases", action: #selector(restorePurchases), keyEquivalent: "")
            restore.target = self
            menu.addItem(restore)
        }

        menu.addItem(.separator())
        let help = NSMenuItem(title: "Help…", action: #selector(showHelp), keyEquivalent: "")
        help.target = self
        menu.addItem(help)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit NiceGrab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        if isProcessingRecording {
            showProcessingStatus()
        } else if isRecording {
            statusItem.menu = nil
            statusItem.button?.target = self
            statusItem.button?.action = #selector(toggleWindowRecording)
            updateRecordingStatus()
        } else {
            stopRecordingStatus()
            statusItem.button?.target = nil
            statusItem.button?.action = nil
            statusItem.button?.image = NSImage(
                systemSymbolName: "macwindow.on.rectangle",
                accessibilityDescription: "NiceGrab"
            )
            statusItem.menu = menu
        }
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

    private var isProcessingRecording: Bool {
        guard #available(macOS 15.0, *), let recorder = videoRecorder as? VideoRecorder else { return false }
        return recorder.isFinishing
    }

    @objc private func toggleMicrophone() {
        includeMicrophone.toggle()
        rebuildMenu()
    }

    @objc private func toggleSmoothCursor() {
        smoothCursor.toggle()
        rebuildMenu()
    }

    @objc private func toggleWindowRecording() {
        guard #available(macOS 15.0, *) else {
            showAlert(VideoRecordingError.unsupportedSystem.localizedDescription)
            return
        }

        if let recorder = videoRecorder as? VideoRecorder, recorder.isRecording {
            showProcessingStatus()
            showRecordingProgress()
            Task {
                do { try await recorder.stop() }
                catch {
                    await MainActor.run {
                        self.hideRecordingProgress()
                        self.rebuildMenu()
                        self.recordingFailed(error)
                    }
                }
            }
            return
        }
        guard !isStartingRecording else { return }

        let recorder = VideoRecorder()
        isStartingRecording = true
        videoRecorder = recorder
        let style = VideoCompositionStyle(
            background: backgroundStore.image,
            padding: backgroundStore.padding.points,
            canvas: backgroundStore.canvas,
            cornerText: effectiveTemplateText
        )
        let useMicrophone = includeMicrophone
        let useSmoothCursor = smoothCursor
        showFeedback(symbol: "record.circle", help: "Recording front window")
        Task {
            do {
                try await recorder.start(
                    includeMicrophone: useMicrophone,
                    smoothCursor: useSmoothCursor,
                    style: style,
                    progress: { [weak self] progress in
                        self?.recordingProgressWindow?.update(progress: progress)
                    }
                ) { [weak self] result in
                    guard let self else { return }
                    self.videoRecorder = nil
                    self.hideRecordingProgress()
                    self.stopRecordingStatus()
                    self.rebuildMenu()
                    switch result {
                    case .success(let url):
                        self.copyVideoToClipboard(url)
                        self.captureSound?.play()
                        self.showFeedback(symbol: "checkmark", help: "Framed MP4 copied")
                    case .failure(let error):
                        if let fallbackError = error as? VideoCompositionFallbackError {
                            self.copyVideoToClipboard(fallbackError.originalURL)
                            self.showAlert(
                                fallbackError.localizedDescription,
                                title: "NiceGrab couldn’t finish the video"
                            )
                        } else {
                            self.recordingFailed(error)
                        }
                    }
                }
                await MainActor.run {
                    self.isStartingRecording = false
                    self.startRecordingStatus()
                    self.rebuildMenu()
                }
            } catch {
                await MainActor.run {
                    self.isStartingRecording = false
                    self.videoRecorder = nil
                    self.hideRecordingProgress()
                    self.stopRecordingStatus()
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

    private func copyVideoToClipboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }

    private func showRecordingProgress() {
        let controller = RecordingProgressWindowController()
        recordingProgressWindow = controller
        controller.present()
    }

    private func hideRecordingProgress() {
        recordingProgressWindow?.close()
        recordingProgressWindow = nil
    }

    @objc private func showHelp() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        let email = "laurent@appblit.com"
        let screenshotShortcut = shortcutSettings.shortcut.displayName
        let recordingShortcut = shortcutSettings.recordingShortcut.displayName

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "NiceGrab Help"
        alert.informativeText = """
        NiceGrab turns ordinary app windows into polished, share-ready screenshots and videos.

        What you can do:
        • Capture or record the frontmost window.
        • Add a background, padding, aspect ratio, and corner text.
        • Record system audio and optional microphone audio.
        • Enable Smooth Cursor for cleaner, fluid pointer movement in recordings.
        • Paste the finished image or MP4 directly into messages, documents, and presentations.

        Bring the window you want to share to the front, then click the NiceGrab icon in the menu bar. You can also press \(screenshotShortcut) for a screenshot or \(recordingShortcut) to start and stop a recording.

        Your media is processed locally on this Mac and is never uploaded by NiceGrab.

        Version \(version) (build \(build))
        Questions, problems, or feedback? \(email)
        """
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "Email Support")
        alert.addButton(withTitle: "Close")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        components.queryItems = [
            URLQueryItem(name: "subject", value: "NiceGrab \(version) (\(build)) feedback")
        ]
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    private func showWelcome() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Welcome to NiceGrab"
        alert.informativeText = """
        Look for the NiceGrab window icon in the menu bar at the top of your screen. Click it to choose a background, adjust the design, capture the front window, or start a recording.

        Bring any window to the front, then use the menu-bar icon—or press \(shortcutSettings.shortcut.displayName) for a screenshot and \(shortcutSettings.recordingShortcut.displayName) to start and stop a recording.
        """
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "Get Started")
        alert.runModal()
    }

    @objc private func captureFrontWindow() {
        do {
            let background = backgroundStore.image
            let result = try composer.captureAndCompose(
                background: background,
                padding: backgroundStore.padding.points,
                canvas: backgroundStore.canvas,
                cornerText: effectiveTemplateText
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
        guard proStore.isPro else { return }
        guard let raw = sender.representedObject as? String, let template = TemplateOption(rawValue: raw) else { return }
        backgroundStore.template = template
        if let canvas = template.preferredCanvas { backgroundStore.canvas = canvas }
        rebuildMenu()
    }

    @objc private func editTemplateText() {
        guard proStore.isPro else {
            showWatermarkUpgradePrompt()
            return
        }
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

    private func showWatermarkUpgradePrompt() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Upgrade to NiceGrab Pro"
        alert.informativeText = "Upgrade to remove the NiceGrab watermark and unlock custom corner text for Work, X / Twitter, LinkedIn, and Presentation exports."
        alert.addButton(withTitle: "Upgrade")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        purchasePro()
    }

    @objc private func purchasePro() {
        Task {
            do {
                try await proStore.purchase()
                if proStore.isPro { showProUnlocked() }
            } catch {
                await MainActor.run { self.showAlert(error.localizedDescription, title: "Couldn’t Purchase NiceGrab Pro") }
            }
        }
    }

    @objc private func restorePurchases() {
        Task {
            do {
                try await proStore.restore()
                await MainActor.run {
                    if self.proStore.isPro {
                        self.showProUnlocked()
                    } else {
                        self.showAlert("No NiceGrab Pro purchase was found for this Apple Account.", title: "No Purchase Found")
                    }
                }
            } catch {
                await MainActor.run { self.showAlert(error.localizedDescription, title: "Couldn’t Restore Purchases") }
            }
        }
    }

    private func showProUnlocked() {
        showAlert("Custom template text is now unlocked on this Mac.", title: "NiceGrab Pro Unlocked")
    }

    private func showFeedback(symbol: String, help: String) {
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            guard self.processingSpinnerTimer == nil else { return }
            if self.isRecording {
                self.statusItem.button?.image = NSImage(
                    systemSymbolName: "record.circle.fill",
                    accessibilityDescription: "Stop window recording"
                )
            } else {
                self.statusItem.button?.image = NSImage(
                    systemSymbolName: "macwindow.on.rectangle",
                    accessibilityDescription: "NiceGrab"
                )
            }
        }
    }

    private func startRecordingStatus() {
        recordingStatusTimer?.invalidate()
        recordingStartedAt = Date()
        updateRecordingStatus()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateRecordingStatus()
        }
        recordingStatusTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopRecordingStatus() {
        recordingStatusTimer?.invalidate()
        recordingStatusTimer = nil
        recordingStartedAt = nil
        processingSpinnerTimer?.invalidate()
        processingSpinnerTimer = nil
        processingSpinnerAngle = 0
        statusItem.length = NSStatusItem.squareLength
        statusItem.button?.title = ""
        statusItem.button?.font = nil
        statusItem.button?.isEnabled = true
    }

    private func updateRecordingStatus() {
        guard let recordingStartedAt else { return }
        let elapsed = max(0, Int(Date().timeIntervalSince(recordingStartedAt)))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        statusItem.length = NSStatusItem.variableLength
        statusItem.button?.image = NSImage(
            systemSymbolName: "record.circle.fill",
            accessibilityDescription: "Stop window recording"
        )
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let timeText = String(format: "%02d:%02d", minutes, seconds)
        statusItem.button?.title = " " + timeText
        statusItem.button?.toolTip = "Recording " + timeText + " — click to stop"
    }

    private func showProcessingStatus() {
        recordingStatusTimer?.invalidate()
        recordingStatusTimer = nil
        recordingStartedAt = nil
        statusItem.menu = nil
        statusItem.length = NSStatusItem.squareLength
        statusItem.button?.target = nil
        statusItem.button?.action = nil
        statusItem.button?.title = ""
        statusItem.button?.image = nil
        statusItem.button?.isEnabled = false
        statusItem.button?.toolTip = "Generating final video…"

        guard processingSpinnerTimer == nil else { return }
        updateProcessingSpinner()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.processingSpinnerAngle += 12
            self.updateProcessingSpinner()
        }
        processingSpinnerTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateProcessingSpinner() {
        guard let symbol = NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath",
            accessibilityDescription: "Generating final video"
        )?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) else { return }
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: rect.midX, yBy: rect.midY)
            transform.rotate(byDegrees: self.processingSpinnerAngle)
            transform.translateX(by: -rect.midX, yBy: -rect.midY)
            transform.concat()
            symbol.draw(in: NSRect(x: 2, y: 2, width: 14, height: 14))
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = true
        statusItem.button?.image = image
    }

    private func showAlert(_ message: String, title: String = "NiceGrab couldn’t capture the window") {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
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
