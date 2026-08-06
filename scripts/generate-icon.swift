import AppKit

let side = 1024
guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
    fatalError("Could not create icon bitmap")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: side, height: side).fill()

let tileRect = NSRect(x: 104, y: 94, width: 816, height: 836)
let tile = NSBezierPath(roundedRect: tileRect, xRadius: 190, yRadius: 190)
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.34)
shadow.shadowBlurRadius = 42
shadow.shadowOffset = NSSize(width: 0, height: -22)
shadow.set()
NSColor.black.setFill()
tile.fill()

NSGraphicsContext.saveGraphicsState()
tile.addClip()
let gradient = NSGradient(colorsAndLocations:
    (NSColor(calibratedRed: 0.25, green: 0.16, blue: 0.55, alpha: 1), 0),
    (NSColor(calibratedRed: 0.48, green: 0.25, blue: 0.63, alpha: 1), 0.48),
    (NSColor(calibratedRed: 0.94, green: 0.38, blue: 0.47, alpha: 1), 1)
)
gradient?.draw(in: tileRect, angle: -38)
let glow = NSGradient(starting: NSColor.white.withAlphaComponent(0.22), ending: NSColor.white.withAlphaComponent(0))
glow?.draw(in: NSRect(x: 104, y: 510, width: 816, height: 420), angle: -90)
NSGraphicsContext.restoreGraphicsState()

NSColor.white.withAlphaComponent(0.18).setStroke()
tile.lineWidth = 3
tile.stroke()

let configuration = NSImage.SymbolConfiguration(pointSize: 420, weight: .medium)
guard let base = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else {
    fatalError("SF Symbol is unavailable")
}
let symbolSize = NSSize(width: 520, height: 520)
let symbol = NSImage(size: symbolSize)
symbol.lockFocus()
base.draw(in: NSRect(origin: .zero, size: symbolSize), from: .zero, operation: .sourceOver, fraction: 1)
NSColor.white.setFill()
NSRect(origin: .zero, size: symbolSize).fill(using: .sourceAtop)
symbol.unlockFocus()

let symbolShadow = NSShadow()
symbolShadow.shadowColor = NSColor.black.withAlphaComponent(0.20)
symbolShadow.shadowBlurRadius = 16
symbolShadow.shadowOffset = NSSize(width: 0, height: -8)
symbolShadow.set()
symbol.draw(in: NSRect(x: 252, y: 252, width: 520, height: 520), from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode icon") }
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "NiceGrab-1024.png")
try png.write(to: output)
