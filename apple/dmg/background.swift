// Draws the background of the DMG window: a light ground, an arrow from the app to the
// Applications folder and one line of help. Finder draws the icon names in black, so the
// ground stays light. Writes background.png and background@2x.png into the given folder.
//
//   swift apple/dmg/background.swift <folder>
//
// The sizes and positions match apple/dmg/make-dmg.sh.

import AppKit

let size = NSSize(width: 600, height: 400)
// Icon centres in the window, measured from the top left as Finder does.
let appCentre = NSPoint(x: 160, y: 180)
let folderCentre = NSPoint(x: 440, y: 180)

func flipped(_ point: NSPoint) -> NSPoint {
    NSPoint(x: point.x, y: size.height - point.y)
}

func render(scale: CGFloat, to url: URL) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0,
    ) else { throw CocoaError(.fileWriteUnknown) }
    rep.size = size

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    NSColor(srgbRed: 0.965, green: 0.965, blue: 0.97, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()

    // The arrow runs between the two icons, which are 128 points wide.
    let start = flipped(NSPoint(x: appCentre.x + 88, y: appCentre.y))
    let end = flipped(NSPoint(x: folderCentre.x - 88, y: folderCentre.y))
    let arrow = NSBezierPath()
    arrow.move(to: start)
    arrow.line(to: end)
    arrow.move(to: NSPoint(x: end.x - 12, y: end.y + 12))
    arrow.line(to: end)
    arrow.line(to: NSPoint(x: end.x - 12, y: end.y - 12))
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    NSColor(srgbRed: 0.63, green: 0.63, blue: 0.65, alpha: 1).setStroke()
    arrow.stroke()

    let text = "Drag Pendenz into Applications" as NSString
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13),
        .foregroundColor: NSColor(srgbRed: 0.43, green: 0.43, blue: 0.45, alpha: 1),
        .paragraphStyle: style,
    ]
    text.draw(in: NSRect(x: 0, y: 52, width: size.width, height: 20), withAttributes: attributes)

    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try png.write(to: url)
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try render(scale: 1, to: folder.appendingPathComponent("background.png"))
try render(scale: 2, to: folder.appendingPathComponent("background@2x.png"))
