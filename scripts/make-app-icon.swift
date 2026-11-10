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
// The picture is a twig that forks the way history does: one stem, two side
// shoots each ending in a leaf, and a round node where each shoot leaves the
// stem. Every shape is defined once, below, and both the SVG layers and the
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
}

/// A leaf: a lens between two quadratic curves from its base to its tip.
struct Leaf {
    var base: Point
    var tip: Point
    /// Half the leaf's width at its widest, as a fraction of its length.
    var fullness: Double

    /// The two control points, either side of the midrib.
    var controls: (Point, Point) {
        let dx = tip.x - base.x, dy = tip.y - base.y
        // Perpendicular to the midrib; a quadratic peaks at half its control's
        // offset, so the control sits at twice the wanted half-width.
        let nx = -dy * fullness * 2, ny = dx * fullness * 2
        let mid = Point(x: base.x + dx * 0.5, y: base.y + dy * 0.5)
        return (Point(x: mid.x + nx, y: mid.y + ny), Point(x: mid.x - nx, y: mid.y - ny))
    }
}

struct Node {
    var center: Point
    var radius: Double
}

enum Design {
    // The stem rises from the lower left and leans right, as a cut twig held
    // up would.
    static let stem = Stroke(
        from: Point(x: 392, y: 884),
        control1: Point(x: 430, y: 690),
        control2: Point(x: 520, y: 430),
        to: Point(x: 652, y: 176),
        width: 92
    )
    // The two shoots leave the stem at the nodes and curve out to their leaves.
    static let shoots = [
        Stroke(
            from: Point(x: 455, y: 620),
            control1: Point(x: 380, y: 560),
            control2: Point(x: 310, y: 520),
            to: Point(x: 270, y: 430),
            width: 64
        ),
        Stroke(
            from: Point(x: 540, y: 400),
            control1: Point(x: 620, y: 380),
            control2: Point(x: 690, y: 400),
            to: Point(x: 742, y: 352),
            width: 64
        )
    ]
    static let leaves = [
        Leaf(base: Point(x: 270, y: 430), tip: Point(x: 160, y: 226), fullness: 0.32),
        Leaf(base: Point(x: 742, y: 352), tip: Point(x: 900, y: 236), fullness: 0.32),
        Leaf(base: Point(x: 652, y: 176), tip: Point(x: 712, y: 56), fullness: 0.30)
    ]
    static let nodes = [
        Node(center: Point(x: 455, y: 620), radius: 72),
        Node(center: Point(x: 540, y: 400), radius: 72)
    ]

    // Colours, as sRGB components.
    static let wood = (r: 0.988, g: 0.937, b: 0.835)       // pale bark, nearly white
    static let leaf = (r: 0.659, g: 0.902, b: 0.416)        // spring green
    static let nodeRing = (r: 0.988, g: 0.937, b: 0.835)
    static let nodeCore = (r: 0.086, g: 0.329, b: 0.243)    // the ground, showing through
    static let nodeRingWidth = 34.0
    // Ground, top to bottom: deep green, darker at the foot.
    static let groundTop = (r: 0.149, g: 0.494, b: 0.357)
    static let groundBottom = (r: 0.031, g: 0.200, b: 0.149)
}

// MARK: - SVG

func hex(_ c: (r: Double, g: Double, b: Double)) -> String {
    String(format: "#%02X%02X%02X", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
}

func n(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
}

func svg(_ body: String) -> String {
    """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
    \(body)</svg>

    """
}

func path(_ s: Stroke) -> String {
    "M\(n(s.from.x)) \(n(s.from.y)) C\(n(s.control1.x)) \(n(s.control1.y)) \(n(s.control2.x)) \(n(s.control2.y)) \(n(s.to.x)) \(n(s.to.y))"
}

func path(_ l: Leaf) -> String {
    let (a, b) = l.controls
    return "M\(n(l.base.x)) \(n(l.base.y)) Q\(n(a.x)) \(n(a.y)) \(n(l.tip.x)) \(n(l.tip.y)) Q\(n(b.x)) \(n(b.y)) \(n(l.base.x)) \(n(l.base.y)) Z"
}

let twigSVG = svg(
    "  <g fill=\"none\" stroke=\"\(hex(Design.wood))\" stroke-linecap=\"round\" stroke-linejoin=\"round\">\n"
        + ([Design.stem] + Design.shoots).map { "    <path d=\"\(path($0))\" stroke-width=\"\(n($0.width))\"/>\n" }.joined()
        + "  </g>\n"
        + Design.nodes.map {
            "  <circle cx=\"\(n($0.center.x))\" cy=\"\(n($0.center.y))\" r=\"\(n($0.radius - Design.nodeRingWidth / 2))\" fill=\"\(hex(Design.nodeCore))\" stroke=\"\(hex(Design.nodeRing))\" stroke-width=\"\(n(Design.nodeRingWidth))\"/>\n"
        }.joined()
)

let leavesSVG = svg(
    "  <g fill=\"\(hex(Design.leaf))\">\n"
        + Design.leaves.map { "    <path d=\"\(path($0))\"/>\n" }.joined()
        + "  </g>\n"
)

func srgb(_ c: (r: Double, g: Double, b: Double)) -> String {
    String(format: "extended-srgb:%.5f,%.5f,%.5f,1.00000", c.r, c.g, c.b)
}

let iconJSON = """
{
  "fill" : {
    "linear-gradient" : [
      "\(srgb(Design.groundTop))",
      "\(srgb(Design.groundBottom))"
    ]
  },
  "groups" : [
    {
      "layers" : [
        {
          "image-name" : "Leaves.svg",
          "name" : "Leaves"
        }
      ],
      "shadow" : {
        "kind" : "neutral",
        "opacity" : 0.4
      },
      "translucency" : {
        "enabled" : false,
        "value" : 0.5
      }
    },
    {
      "layers" : [
        {
          "image-name" : "Twig.svg",
          "name" : "Twig"
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
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    try iconJSON.write(to: bundle.appending(path: "icon.json"), atomically: true, encoding: .utf8)
    try twigSVG.write(to: assets.appending(path: "Twig.svg"), atomically: true, encoding: .utf8)
    try leavesSVG.write(to: assets.appending(path: "Leaves.svg"), atomically: true, encoding: .utf8)
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

func color(_ c: (r: Double, g: Double, b: Double)) -> CGColor {
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

for leaf in Design.leaves {
    let (a, b) = leaf.controls
    context.move(to: cg(leaf.base))
    context.addQuadCurve(to: cg(leaf.tip), control: cg(a))
    context.addQuadCurve(to: cg(leaf.base), control: cg(b))
    context.closePath()
}
context.setFillColor(color(Design.leaf))
context.fillPath()

context.setLineCap(.round)
context.setLineJoin(.round)
context.setStrokeColor(color(Design.wood))
for s in [Design.stem] + Design.shoots {
    context.setLineWidth(s.width)
    context.move(to: cg(s.from))
    context.addCurve(to: cg(s.to), control1: cg(s.control1), control2: cg(s.control2))
    context.strokePath()
}
for node in Design.nodes {
    let r = node.radius - Design.nodeRingWidth / 2
    let rect = CGRect(x: node.center.x - r, y: node.center.y - r, width: r * 2, height: r * 2)
    context.setFillColor(color(Design.nodeCore))
    context.fillEllipse(in: rect)
    context.setLineWidth(Design.nodeRingWidth)
    context.setStrokeColor(color(Design.nodeRing))
    context.strokeEllipse(in: rect)
}

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(previewURL as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { exit(1) }
print("Wrote \(previewURL.path)")
