import AppKit
import Carbon

struct KeyboardShortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let defaultShortcut = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(controlKey | shiftKey))
    static let defaultRecordingShortcut = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(controlKey | shiftKey))

    var displayName: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        result += Self.keyNames[keyCode] ?? "Key \(keyCode)"
        return result
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbonFlags: UInt32 = 0
        if flags.contains(.command) { carbonFlags |= UInt32(cmdKey) }
        if flags.contains(.option) { carbonFlags |= UInt32(optionKey) }
        if flags.contains(.control) { carbonFlags |= UInt32(controlKey) }
        if flags.contains(.shift) { carbonFlags |= UInt32(shiftKey) }
        modifiers = carbonFlags
    }

    private static let keyNames: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9", UInt32(kVK_Space): "Space", UInt32(kVK_Return): "Return",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12"
    ]
}

final class ShortcutSettings {
    private let defaults = UserDefaults.standard
    private let keyCodeKey = "shortcut.keyCode"
    private let modifiersKey = "shortcut.modifiers"
    private let recordingKeyCodeKey = "recordingShortcut.keyCode"
    private let recordingModifiersKey = "recordingShortcut.modifiers"

    var shortcut: KeyboardShortcut {
        get {
            guard defaults.object(forKey: keyCodeKey) != nil else { return .defaultShortcut }
            return KeyboardShortcut(
                keyCode: UInt32(defaults.integer(forKey: keyCodeKey)),
                modifiers: UInt32(defaults.integer(forKey: modifiersKey))
            )
        }
        set {
            defaults.set(Int(newValue.keyCode), forKey: keyCodeKey)
            defaults.set(Int(newValue.modifiers), forKey: modifiersKey)
        }
    }

    var recordingShortcut: KeyboardShortcut {
        get {
            guard defaults.object(forKey: recordingKeyCodeKey) != nil else { return .defaultRecordingShortcut }
            return KeyboardShortcut(
                keyCode: UInt32(defaults.integer(forKey: recordingKeyCodeKey)),
                modifiers: UInt32(defaults.integer(forKey: recordingModifiersKey))
            )
        }
        set {
            defaults.set(Int(newValue.keyCode), forKey: recordingKeyCodeKey)
            defaults.set(Int(newValue.modifiers), forKey: recordingModifiersKey)
        }
    }
}

final class ShortcutRecorderView: NSView {
    private let label = NSTextField(labelWithString: "Press a shortcut")
    var shortcut: KeyboardShortcut? {
        didSet { label.stringValue = shortcut?.displayName ?? "Press a shortcut" }
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 2
        label.font = .systemFont(ofSize: 22, weight: .medium)
        label.alignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: 8, dy: 14)
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    override func keyDown(with event: NSEvent) {
        let candidate = KeyboardShortcut(event: event)
        guard candidate.modifiers != 0 else {
            NSSound.beep()
            return
        }
        shortcut = candidate
    }
}
