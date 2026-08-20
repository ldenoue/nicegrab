# NiceGrab

NiceGrab is a tiny native macOS menu-bar app for turning ordinary window screenshots and recordings into polished, share-ready media.

Press a global keyboard shortcut and NiceGrab captures the frontmost window, centers it on your chosen background, adds optional template text, and puts the finished image or MP4 file directly on the clipboard.

## Download

[Download NiceGrab from the Mac App Store](https://apps.apple.com/app/id6798733469) — no Xcode required.

The App Store link will become available as soon as Apple publishes the app.

![A browser window captured by NiceGrab and centered over an illustrated landscape](docs/images/nicegrab-example.png)

## What it does

- Captures the frontmost macOS window with one global shortcut
- Saves the composed PNG locally and copies both its image data and file to the clipboard, including support for pasting onto the Desktop
- Records the frontmost window with its cursor and system audio on macOS 15+
- Optionally includes microphone audio in recordings
- Composites recordings over the same background, canvas, and template as screenshots
- Saves the finished MP4 locally and copies its file to the clipboard
- Uses any image as the background, or a built-in purple-to-coral gradient
- Produces adaptive, 16:9, 4:3, or square output
- Offers compact, comfortable, and spacious canvas padding
- Includes Work, X/Twitter, LinkedIn, and Presentation templates
- Saves custom corner text separately for every template
- Lets you configure the global keyboard shortcut
- Plays the familiar macOS camera sound after a successful capture
- Lives entirely in the menu bar—there is no Dock icon or main window

![NiceGrab menu showing backgrounds, canvas options, and templates](docs/images/nicegrab-menu.png)

## Requirements

- macOS 13 or newer for screenshots; macOS 15 or newer for window recordings
- Screen Recording permission, used only to capture the selected window
- Xcode 16 or newer when building from source

NiceGrab guides you directly to **System Settings → Privacy & Security → Screen Recording** when permission is missing.

## Build and run with Xcode

1. Clone the repository:

   ```sh
   git clone https://github.com/ldenoue/nicegrab.git
   cd nicegrab
   ```

2. Open `FrameGrab.xcodeproj` in Xcode.
3. Select the **FrameGrab** scheme and your Mac as the run destination.
4. Choose your development team under **Signing & Capabilities** if needed.
5. Press **Run**.

The built product and executable are named **NiceGrab** and use the bundle identifier `com.appblit.nicegrab`.

## Build from Terminal

To create a locally signed app in `dist/NiceGrab.app`:

```sh
./scripts/build-app.sh
open dist/NiceGrab.app
```

The underlying Swift package can also be run directly:

```sh
swift run FrameGrab
```

## Using NiceGrab

1. Launch NiceGrab and find the overlapping-window icon in the menu bar.
2. Choose a background image and output aspect ratio.
3. Optionally select a template and edit its corner text.
4. Bring the window you want to capture to the front.
5. Press the configured shortcut—**Control–Shift–4** by default.
6. Paste the finished image into Messages, Mail, X, Slack, a document, or an image editor.

For video, press **Control–Shift–5** to start recording the front window and press it again to stop. System audio and the cursor are included automatically. Turn on **Include Microphone** in the NiceGrab menu when narration is needed. NiceGrab saves the framed MP4 in its local Application Support folder and places the file on the clipboard.

Preferences such as the background, canvas format, padding, template text, and keyboard shortcut persist between launches.

## Privacy

NiceGrab works locally on your Mac. Screenshots, recordings, microphone audio, and background images are processed on the device and are never uploaded.

Read the full [NiceGrab Privacy Policy](PRIVACY.md).

## Project structure

- `Sources/FrameGrab` — AppKit menu-bar app and screenshot compositor
- `Resources/Assets.xcassets` — NiceGrab app icon assets
- `FrameGrab.xcodeproj` — Xcode project
- `scripts/build-app.sh` — standalone app-bundle builder
- `scripts/generate-icon.swift` — app-icon source generator
