// Copyright (C) 2026 Twarge LLC
// SPDX-License-Identifier: Apache-2.0
//
// Writes the branch symbol as an SF Symbols template:
//
//   swift scripts/make-branch-symbol.swift
//
// The output is App/Resources/Assets.xcassets/git.branch.symbolset, which
// the asset compiler turns into a custom symbol: it takes every weight and
// scale, sits on the baseline and lines up with the system's symbols.
//
// The picture is a branching diagram: a base commit, a trunk running up from
// it to one tip, and a branch curving off the same commit to a second tip.
// The curve is the one the history graph and the app icon draw between
// lanes, leaving and arriving vertically with its control points at
// mid-height. Commits are rings, as in the app icon.
//
// A symbol template holds filled outlines, not strokes, so the lines are
// drawn here as their outlines: the rings as a circle with a circular hole,
// the trunk as a rectangle and the branch as the curve offset to either side,
// fitted with cubics. The template gives Ultralight, Regular and Black, and
// the system interpolates the weights between, which needs every one of the
// three built of the same points in the same order. So each is made by the
// same steps from its own measurements.
//
// The symbol set is committed, so this only needs running when the design
// changes.

import Foundation

// MARK: - Design (y upward from the baseline, x from the left margin)

struct Weight {
    var name: String
    /// The lines' thickness, as the system's symbols have it at this weight.
    var stroke: Double
    /// The rings' outer radius; their band is as thick as a line.
    var ringRadius: Double
    /// How far the glyph reaches below the baseline and above it.
    var bottom: Double
    var top: Double
    var sideBearing: Double
    /// From the trunk to the branch, wider as the rings grow.
    var laneGap: Double
}

let weights = [
    Weight(name: "Ultralight-S", stroke: 2.2, ringRadius: 11, bottom: -4, top: 75, sideBearing: 1.5, laneGap: 36.7),
    Weight(name: "Regular-S", stroke: 7.6, ringRadius: 12, bottom: -5, top: 76, sideBearing: 1.5, laneGap: 38.3),
    Weight(name: "Black-S", stroke: 14, ringRadius: 16.5, bottom: -6, top: 77, sideBearing: 1.5, laneGap: 40.2),
]

/// How many cubics each side of the branch is fitted with.
let pieces = 4

// MARK: - Geometry

struct Point {
    var x: Double
    var y: Double

    static func + (a: Point, b: Point) -> Point { Point(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: Point, b: Point) -> Point { Point(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: Point, k: Double) -> Point { Point(x: a.x * k, y: a.y * k) }
    func dot(_ other: Point) -> Double { x * other.x + y * other.y }
    var length: Double { hypot(x, y) }
    var unit: Point { self * (1 / length) }
}

enum Segment {
    case line(Point)
    case curve(Point, Point, Point)
}

/// A closed outline: counterclockwise to fill, clockwise for a hole.
struct Contour {
    var start: Point
    var segments: [Segment]
}

typealias Cubic = (Point, Point, Point, Point)

func point(on c: Cubic, at u: Double) -> Point {
    let m = 1 - u
    return c.0 * (m * m * m) + c.1 * (3 * m * m * u) + c.2 * (3 * m * u * u) + c.3 * (u * u * u)
}

func tangent(of c: Cubic, at u: Double) -> Point {
    let m = 1 - u
    return ((c.1 - c.0) * (3 * m * m) + (c.2 - c.1) * (6 * m * u) + (c.3 - c.2) * (3 * u * u)).unit
}

/// The curve moved sideways by `h`: to the left of its direction for a
/// positive `h`.
func offset(of c: Cubic, at u: Double, by h: Double) -> Point {
    let t = tangent(of: c, at: u)
    return point(on: c, at: u) + Point(x: -t.y, y: t.x) * h
}

/// The parameter in `range` where the curve is `radius` from `center`.
func parameter(of c: Cubic, at radius: Double, from center: Point, in range: ClosedRange<Double>) -> Double {
    func distance(_ u: Double) -> Double { (point(on: c, at: u) - center).length - radius }
    var (low, high) = (range.lowerBound, range.upperBound)
    for _ in 0..<80 {
        let middle = (low + high) / 2
        if (distance(low) < 0) == (distance(middle) < 0) { low = middle } else { high = middle }
    }
    return (low + high) / 2
}

/// A cubic for the offset curve between two parameters: through its ends,
/// tangent to it there, with handle lengths fitted to it by least squares.
/// Returns the cubic and its largest distance from the true offset curve.
func fitOffset(of c: Cubic, from ua: Double, to ub: Double, by h: Double, samples: Int = 24) -> (Cubic, Double) {
    let q0 = offset(of: c, at: ua, by: h), q3 = offset(of: c, at: ub, by: h)
    var t0 = tangent(of: c, at: ua), t3 = tangent(of: c, at: ub)
    if ub < ua { (t0, t3) = (t0 * -1, t3 * -1) }
    let samplePoints = (0...samples).map { offset(of: c, at: ua + (ub - ua) * Double($0) / Double(samples), by: h) }
    var chord = [0.0]
    for (a, b) in zip(samplePoints, samplePoints.dropFirst()) { chord.append(chord.last! + (b - a).length) }
    var (aa, ab, bb, ra, rb) = (0.0, 0.0, 0.0, 0.0, 0.0)
    for (distance, target) in zip(chord, samplePoints) {
        let s = distance / chord.last!, m = 1 - s
        let residual = target - (q0 * (m * m * m + 3 * m * m * s) + q3 * (3 * m * s * s + s * s * s))
        let a = t0 * (3 * m * m * s), b = t3 * (-3 * m * s * s)
        aa += a.dot(a); ab += a.dot(b); bb += b.dot(b)
        ra += residual.dot(a); rb += residual.dot(b)
    }
    let determinant = aa * bb - ab * ab
    let handle0 = (ra * bb - rb * ab) / determinant, handle3 = (aa * rb - ab * ra) / determinant
    let fitted: Cubic = (q0, q0 + t0 * handle0, q3 - t3 * handle3, q3)
    var error = 0.0
    for k in 0...100 {
        let target = offset(of: c, at: ua + (ub - ua) * Double(k) / 100, by: h)
        error = max(error, (0...400).map { (point(on: fitted, at: Double($0) / 400) - target).length }.min()!)
    }
    return (fitted, error)
}

/// An arc of up to a quarter turn as one cubic.
func arc(around center: Point, radius r: Double, from a0: Double, to a1: Double) -> (start: Point, segment: Segment) {
    let k = 4.0 / 3 * tan((a1 - a0) / 4)
    let p0 = center + Point(x: r * cos(a0), y: r * sin(a0))
    let p3 = center + Point(x: r * cos(a1), y: r * sin(a1))
    let c1 = p0 + Point(x: -sin(a0), y: cos(a0)) * (k * r)
    let c2 = p3 - Point(x: -sin(a1), y: cos(a1)) * (k * r)
    return (p0, .curve(c1, c2, p3))
}

func circle(around center: Point, radius: Double, clockwise: Bool) -> Contour {
    let step = (clockwise ? -1.0 : 1.0) * .pi / 2
    let quarters = (0..<4).map { arc(around: center, radius: radius, from: Double($0) * step, to: Double($0 + 1) * step) }
    return Contour(start: quarters[0].start, segments: quarters.map(\.segment))
}

func signedArea(of contour: Contour) -> Double {
    var points = [contour.start], current = contour.start
    for segment in contour.segments {
        switch segment {
        case .line(let p):
            points.append(p); current = p
        case .curve(let c1, let c2, let p):
            let c: Cubic = (current, c1, c2, p)
            points += (1...16).map { point(on: c, at: Double($0) / 16) }; current = p
        }
    }
    return 0.5 * zip(points, points.dropFirst() + [points[0]]).reduce(0) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y }
}

// MARK: - The glyph

func glyph(_ w: Weight) -> (contours: [Contour], width: Double, error: Double) {
    let t = w.stroke, ro = w.ringRadius
    let bandMiddle = ro - t / 2, hole = ro - t
    let trunkX = w.sideBearing + ro, branchX = trunkX + w.laneGap
    let width = branchX + ro + w.sideBearing
    let baseY = w.bottom + ro, tipY = w.top - ro
    let base = Point(x: trunkX, y: baseY), trunkTip = Point(x: trunkX, y: tipY), branchTip = Point(x: branchX, y: tipY)

    var contours: [Contour] = []
    for center in [base, trunkTip, branchTip] {
        contours.append(circle(around: center, radius: ro, clockwise: false))
        contours.append(circle(around: center, radius: hole, clockwise: true))
    }
    // The trunk, ending in the middle of each ring's band: past the ring's
    // edge, short of its hole.
    let y0 = baseY + bandMiddle, y1 = tipY - bandMiddle
    contours.append(Contour(start: Point(x: trunkX - t / 2, y: y0), segments: [
        .line(Point(x: trunkX + t / 2, y: y0)), .line(Point(x: trunkX + t / 2, y: y1)), .line(Point(x: trunkX - t / 2, y: y1)),
    ]))
    // The branch: the graph's curve from the base commit to the branch's tip,
    // cut where it crosses the middle of each ring's band.
    let middle = (baseY + tipY) / 2
    let curve: Cubic = (base, Point(x: trunkX, y: middle), Point(x: branchX, y: middle), branchTip)
    let u0 = parameter(of: curve, at: bandMiddle, from: base, in: 0...0.5)
    let u1 = parameter(of: curve, at: bandMiddle, from: branchTip, in: 0.5...1)
    let cuts = (0...pieces).map { u0 + (u1 - u0) * Double($0) / Double(pieces) }
    var segments: [Segment] = [], error = 0.0
    // Up its right-hand side, then back down its left.
    for (ua, ub) in zip(cuts, cuts.dropFirst()) {
        let (c, e) = fitOffset(of: curve, from: ua, to: ub, by: -t / 2)
        segments.append(.curve(c.1, c.2, c.3)); error = max(error, e)
    }
    segments.append(.line(offset(of: curve, at: u1, by: t / 2)))
    let back = Array(cuts.reversed())
    for (ua, ub) in zip(back, back.dropFirst()) {
        let (c, e) = fitOffset(of: curve, from: ua, to: ub, by: t / 2)
        segments.append(.curve(c.1, c.2, c.3)); error = max(error, e)
    }
    contours.append(Contour(start: offset(of: curve, at: u0, by: -t / 2), segments: segments))

    for (index, contour) in contours.enumerated() {
        let isHole = index < 6 && index % 2 == 1
        precondition((signedArea(of: contour) < 0) == isHole, "contour \(index) winds the wrong way")
    }
    return (contours, width, error)
}

// MARK: - The template

func number(_ value: Double) -> String {
    var text = String(format: "%.4f", value)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text
}

/// Path data, flipped to SVG's downward y.
func pathData(_ contours: [Contour]) -> String {
    func p(_ point: Point) -> String { "\(number(point.x)) \(number(-point.y))" }
    var data = ""
    for contour in contours {
        data += "M" + p(contour.start)
        for segment in contour.segments {
            switch segment {
            case .line(let end): data += "L" + p(end)
            case .curve(let c1, let c2, let end): data += "C" + [c1, c2, end].map(p).joined(separator: " ")
            }
        }
        data += "Z"
    }
    return data
}

let baselines = [("S", 696.0), ("M", 1126.0), ("L", 1556.0)]
let capHeight = 70.459
let columns = ["Ultralight-S": 560.0, "Regular-S": 1460.0, "Black-S": 2360.0]
let guide = #"style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;""#
let margin = #"style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;""#
let note = #"style="stroke:none;fill:black;font-family:sans-serif;font-size:13;""#

var guides: [String] = []
for (scale, y) in baselines {
    guides.append(#"  <line id="Baseline-\#(scale)" \#(guide) x1="263" x2="3036" y1="\#(number(y))" y2="\#(number(y))"/>"#)
    guides.append(#"  <line id="Capline-\#(scale)" \#(guide) x1="263" x2="3036" y1="\#(number(y - capHeight))" y2="\#(number(y - capHeight))"/>"#)
}
var symbols: [String] = []
for weight in weights {
    let (contours, width, error) = glyph(weight)
    print("\(weight.name): width \(number(width)), largest offset fit error \(String(format: "%.4f", error))")
    let x = columns[weight.name]!, y = baselines[0].1
    guides.append(#"  <line id="left-margin-\#(weight.name)" \#(margin) x1="\#(number(x))" x2="\#(number(x))" y1="\#(number(y - 95))" y2="\#(number(y + 24))"/>"#)
    guides.append(#"  <line id="right-margin-\#(weight.name)" \#(margin) x1="\#(number(x + width))" x2="\#(number(x + width))" y1="\#(number(y - 95))" y2="\#(number(y + 24))"/>"#)
    symbols.append(#"  <g id="\#(weight.name)" transform="matrix(1 0 0 1 \#(number(x)) \#(number(y)))">"# + "\n"
        + #"   <path d="\#(pathData(contours))"/>"# + "\n  </g>")
}

let svg = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
<svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">
 <!--Written by scripts/make-branch-symbol.swift. A base commit, a trunk to one tip, and a branch curving off to another.-->
 <g id="Notes">
  <rect height="2200" id="artboard" style="fill:white;opacity:1" width="3300" x="0" y="0"/>
  <text id="template-version" \(note) transform="matrix(1 0 0 1 3036 1933)" text-anchor="end">Template v.3.0</text>
 </g>
 <g id="Guides">
\(guides.joined(separator: "\n"))
 </g>
 <g id="Symbols">
\(symbols.joined(separator: "\n"))
 </g>
</svg>

"""

let contents = """
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "symbols" : [
    {
      "filename" : "git.branch.svg",
      "idiom" : "universal"
    }
  ]
}

"""

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let symbolSet = root.appending(path: "App/Resources/Assets.xcassets/git.branch.symbolset")
try FileManager.default.createDirectory(at: symbolSet, withIntermediateDirectories: true)
try svg.write(to: symbolSet.appending(path: "git.branch.svg"), atomically: true, encoding: .utf8)
try contents.write(to: symbolSet.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
print("Wrote \(symbolSet.path(percentEncoded: false))")
