// Draws the menu bar icon of the Mac app: the Zettelspiess of the app icon in one color, as a
// vector template image that the menu bar tints. The shapes follow generate.mjs, drawn simpler
// for 18 points: slips that lie flatter, wider apart and less turned, and a base without a side.
// The red mark is cut out of the top slip.
//
//   swift apple/icon/menubar.swift                  writes apple/Pendenz/Assets.xcassets/MenuBarIcon.imageset
//   swift apple/icon/menubar.swift --preview a.png  also renders it large into a.png

import AppKit

// The canvas of generate.mjs: 1024 x 1024, with the drawing moved up by DY.
let DY: CGFloat = -26
// The menu bar icon is 18 points square, and the drawing is fitted into it with half a point
// around. `unit` is the size of one unit of the canvas in points; it is set below, once the
// shapes are known.
let points: CGFloat = 18
// The gap between two layers, in points, and the width of the spike at the menu bar's size.
let gap: CGFloat = 1
let spikeWidth: CGFloat = 1.5
// How much a slip is flattened, seen from the side. The app icon uses 0.42.
let flat: CGFloat = 0.32

func plane(_ cx: CGFloat, _ cy: CGFloat, _ rot: CGFloat, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    let rounded = CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
    var transform = CGAffineTransform(translationX: cx, y: cy + DY)
        .scaledBy(x: 1, y: flat)
        .rotated(by: rot * .pi / 180)
    return rounded.copy(using: &transform)!
}

func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: cx - rx, y: cy + DY - ry, width: rx * 2, height: ry * 2), transform: nil)
}

func slip(_ cy: CGFloat, _ rot: CGFloat) -> CGPath {
    plane(512, cy, rot, -240, -160, 480, 320, 56)
}

// The spike from `from` up to its point, as wide as `spikeWidth` points.
func spike(from: CGFloat) -> CGPath {
    let half = spikeWidth / unit / 2
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 512 - half, y: from + DY))
    path.addLine(to: CGPoint(x: 512 - half, y: 300 + DY))
    path.addQuadCurve(to: CGPoint(x: 512 + half, y: 300 + DY), control: CGPoint(x: 512, y: 230 + DY))
    path.addLine(to: CGPoint(x: 512 + half, y: from + DY))
    path.closeSubpath()
    return path
}

let base = ellipse(512, 800, 150, 40)
let bottomSlip = slip(680, -12)
let middleSlip = slip(570, 9)
let topSlip = slip(460, -7)

// Everything but the spike, whose width depends on `unit`, and the point of the spike.
let bounds = [base, bottomSlip, middleSlip, topSlip]
    .reduce(CGRect(x: 512, y: 230 + DY, width: 0, height: 0)) { $0.union($1.boundingBoxOfPath) }
let unit = (points - 1) / max(bounds.width, bounds.height)

enum Ink {
    case fill(CGPath, evenOdd: Bool = false)
    case cut(CGPath)
}

// Bottom to top, as the layers of the app icon lie.
let layers: [Ink] = [
    .fill(base),
    .fill(spike(from: 800)),
    .fill(bottomSlip),
    .fill(middleSlip),
    .fill(topSlip),
    .cut(plane(512, 460, -7, 50, 40, 140, 70, 35)),
    .fill(spike(from: 460)),
]

// Each layer without the layers above it and a thin edge around them, so the slips stay apart
// in a single color. Plain shapes, so the PDF stays a vector image at every scale.
func shapes() -> [CGPath] {
    var visible: [CGPath] = []
    var above = CGMutablePath() as CGPath
    for layer in layers.reversed() {
        switch layer {
        case .fill(let path, let evenOdd):
            let rule: CGPathFillRule = evenOdd ? .evenOdd : .winding
            let filled = path.normalized(using: rule)
            visible.append(filled.subtracting(above))
            let edge = filled.copy(strokingWithWidth: gap * 2 / unit, lineCap: .round, lineJoin: .round, miterLimit: 1)
            above = above.union(filled).union(edge)
        case .cut(let path):
            above = above.union(path)
        }
    }
    return visible
}

func pdf() -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: points, height: points)
    let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
    context.beginPDFPage(nil)
    // The canvas's y runs down. Fit the drawing into the square and center it.
    context.translateBy(x: 0, y: points)
    context.scaleBy(x: 1, y: -1)
    context.translateBy(x: points / 2, y: points / 2)
    context.scaleBy(x: unit, y: unit)
    context.translateBy(x: -bounds.midX, y: -bounds.midY)
    context.setFillColor(.black)
    for shape in shapes() {
        context.addPath(shape)
        context.fillPath()
    }
    context.endPDFPage()
    context.closePDF()
    return data as Data
}

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let set = here.appending(path: "../Pendenz/Assets.xcassets/MenuBarIcon.imageset").standardized
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
try pdf().write(to: set.appending(path: "MenuBarIcon.pdf"))
let contents = """
{
  "images" : [
    { "filename" : "MenuBarIcon.pdf", "idiom" : "mac" }
  ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : {
    "preserves-vector-representation" : true,
    "template-rendering-intent" : "template"
  }
}

"""
try contents.write(to: set.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
print("wrote \(set.path)")
if let i = CommandLine.arguments.firstIndex(of: "--preview"), i + 1 < CommandLine.arguments.count {
    let image = NSImage(data: pdf())!
    let size = CGSize(width: points * 16, height: points * 16)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0,
    )!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: CGRect(origin: .zero, size: size))
    NSGraphicsContext.current = nil
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
}
