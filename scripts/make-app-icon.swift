// Copyright (C) 2026 Twarge LLC
// SPDX-License-Identifier: Apache-2.0
//
// Writes the app icon as an Icon Composer bundle:
//
//   swift scripts/make-app-icon.swift [preview.png]
//
// The output is App/Resources/AppIcon.icon: icon.json plus one SVG per layer.
// Xcode's asset compiler turns it into every size both platforms need (the
// macOS .icns and Assets.car, the iOS 1024 and the device sizes), and applies
// the system shape, so the artwork here is full bleed and carries no mask.
//
// The picture is a wye: two lines of history, one green and one blue, coming
// down from their commits and joining into a single stem, the way a branch
// meets the line it merges into. It is the app's own commit graph, drawn
// large. Every shape is defined once, below, and both the SVG layers and the
// optional PNG preview are drawn from that one definition, so the preview is
// the icon and not an approximation of it.
//
// The bundle is committed, so this only needs running when the design changes.
// Pass a path to also render a 1024px preview with the gradient and an
// approximate system mask, for looking at the result without building.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Design (1024 × 1024 canvas, y downward, as in SVG)

typealias RGB = (r: Double, g: Double, b: Double)

struct Point {
    var x: Double
    var y: Double
}

/// A cubic Bézier, stroked with round caps.
struct Stroke {
    var from: Point
    var control1: Point
    var control2: Point
    var to: Point
    var width: Double
    var color: RGB
}

/// A commit: a ring with the ground showing through.
struct Node {
    var center: Point
    var radius: Double
    var ring: RGB
}

/// One layer of the icon, which Icon Composer lights and shadows by itself.
struct Layer {
    var name: String
    var strokes: [Stroke]
    var nodes: [Node]
}

enum Design {
    // Colours, as sRGB components.
    static let green: RGB = (0.298, 0.851, 0.482)    // the branch coming in
    static let blue: RGB = (0.302, 0.741, 1.000)     // the line it joins
    static let stem: RGB = (0.965, 0.973, 1.000)     // what they become
    static let nodeCore: RGB = (0.071, 0.094, 0.180)
    static let nodeRingWidth = 36.0
    // Ground, top to bottom: ink blue, darker at the foot.
    static let groundTop: RGB = (0.137, 0.176, 0.337)
    static let groundBottom: RGB = (0.039, 0.051, 0.110)

    static let lineWidth = 88.0
    static let joint = Point(x: 512, y: 598)
    static let foot = Point(x: 512, y: 838)
    static let left = Point(x: 268, y: 216)
    static let right = Point(x: 756, y: 216)

    /// An arm leaves its commit straight down and bends into the joint, as
    /// a lane of the graph changes column.
    static func arm(from top: Point, color: RGB) -> Stroke {
        Stroke(
            from: top,
            control1: Point(x: top.x, y: top.y + 250),
            control2: Point(x: joint.x, y: joint.y - 250),
            to: joint,
            width: lineWidth, color: color
        )
    }

    static let layers = [
        // The incoming branch, underneath.
        Layer(
            name: "Branch",
            strokes: [arm(from: left, color: green)],
            nodes: [Node(center: left, radius: 84, ring: green)]
        ),
        // The line it joins.
        Layer(
            name: "Line",
            strokes: [arm(from: right, color: blue)],
            nodes: [Node(center: right, radius: 84, ring: blue)]
        ),
        // The stem and the merge, on top.
        Layer(
            name: "Stem",
            strokes: [Stroke(from: joint, control1: joint, control2: foot, to: foot, width: lineWidth, color: stem)],
            nodes: [Node(center: joint, radius: 96, ring: stem)]
        )
    ]
}

// MARK: - SVG

func hex(_ c: RGB) -> String {
    String(format: "#%02X%02X%02X", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
}

func n(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
}

func path(_ s: Stroke) -> String {
    "M\(n(s.from.x)) \(n(s.from.y)) C\(n(s.control1.x)) \(n(s.control1.y)) \(n(s.control2.x)) \(n(s.control2.y)) \(n(s.to.x)) \(n(s.to.y))"
}

func svg(_ layer: Layer) -> String {
    let strokes = layer.strokes.map {
        "  <path d=\"\(path($0))\" fill=\"none\" stroke=\"\(hex($0.color))\" stroke-width=\"\(n($0.width))\" stroke-linecap=\"round\"/>\n"
    }.joined()
    let nodes = layer.nodes.map {
        "  <circle cx=\"\(n($0.center.x))\" cy=\"\(n($0.center.y))\" r=\"\(n($0.radius - Design.nodeRingWidth / 2))\" fill=\"\(hex(Design.nodeCore))\" stroke=\"\(hex($0.ring))\" stroke-width=\"\(n(Design.nodeRingWidth))\"/>\n"
    }.joined()
    return """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
    \(strokes)\(nodes)</svg>

    """
}

func srgb(_ c: RGB) -> String {
    String(format: "extended-srgb:%.5f,%.5f,%.5f,1.00000", c.r, c.g, c.b)
}

// Icon Composer lists the front group first.
let groups = Design.layers.reversed().map { layer in
    """
        {
          "layers" : [
            {
              "image-name" : "\(layer.name).svg",
              "name" : "\(layer.name)"
            }
          ],
          "shadow" : {
            "kind" : "neutral",
            "opacity" : 0.5
          },
          "translucency" : {
            "enabled" : false,
            "value" : 0.5
          }
        }
    """
}.joined(separator: ",\n")

let iconJSON = """
{
  "fill" : {
    "linear-gradient" : [
      "\(srgb(Design.groundTop))",
      "\(srgb(Design.groundBottom))"
    ]
  },
  "groups" : [
\(groups)
  ],
  "supported-platforms" : {
    "squares" : "shared"
  }
}

"""

// MARK: - Write the bundle

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let bundle = root.appending(path: "App/Resources/AppIcon.icon")
let assets = bundle.appending(path: "Assets")
do {
    // Layers of an earlier design are not left behind.
    try? FileManager.default.removeItem(at: assets)
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    try iconJSON.write(to: bundle.appending(path: "icon.json"), atomically: true, encoding: .utf8)
    for layer in Design.layers {
        try svg(layer).write(to: assets.appending(path: "\(layer.name).svg"), atomically: true, encoding: .utf8)
    }
    print("Wrote \(bundle.path)")
} catch {
    print("error: \(error)")
    exit(1)
}

// MARK: - Preview

guard CommandLine.arguments.count > 1 else { exit(0) }
let previewURL = URL(fileURLWithPath: CommandLine.arguments[1])
let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }

// SVG's y runs down; flip so the same coordinates draw the same picture.
context.translateBy(x: 0, y: CGFloat(size))
context.scaleBy(x: 1, y: -1)

func color(_ c: RGB) -> CGColor {
    CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
}
func cg(_ p: Point) -> CGPoint { CGPoint(x: p.x, y: p.y) }

// Approximate system mask: a rounded square at Apple's corner proportion.
let mask = CGPath(roundedRect: CGRect(x: 0, y: 0, width: size, height: size),
                  cornerWidth: 229, cornerHeight: 229, transform: nil)
context.addPath(mask)
context.clip()
let gradient = CGGradient(colorsSpace: space, colors: [color(Design.groundTop), color(Design.groundBottom)] as CFArray, locations: [0, 1])!
context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size), options: [])

context.setLineCap(.round)
for layer in Design.layers {
    // Roughly the shadow the system gives each layer.
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    for s in layer.strokes {
        context.setStrokeColor(color(s.color))
        context.setLineWidth(s.width)
        context.move(to: cg(s.from))
        context.addCurve(to: cg(s.to), control1: cg(s.control1), control2: cg(s.control2))
        context.strokePath()
    }
    for node in layer.nodes {
        let r = node.radius - Design.nodeRingWidth / 2
        let rect = CGRect(x: node.center.x - r, y: node.center.y - r, width: r * 2, height: r * 2)
        context.setFillColor(color(Design.nodeCore))
        context.fillEllipse(in: rect)
        context.setLineWidth(Design.nodeRingWidth)
        context.setStrokeColor(color(node.ring))
        context.strokeEllipse(in: rect)
    }
    context.endTransparencyLayer()
}

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(previewURL as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { exit(1) }
print("Wrote \(previewURL.path)")
