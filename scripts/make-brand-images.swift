// Draws the app icon and the launch screen mark from the pin shape in
// ios/Sublette/Core/DesignSystem/PinMark.swift (the same numbers).
//
//   swift scripts/make-brand-images.swift      (from the sublette folder, on a Mac)
//
// Writes PNGs into ios/Sublette/Resources/Assets.xcassets. Run it again only
// if the mark or the colors change.

import AppKit
import CoreGraphics
import Foundation

let aspectRatio: CGFloat = 1.25
let windowRatio: CGFloat = 0.4

func contours(width: CGFloat, steps: Int = 192) -> [[CGPoint]] {
    let radius = width / 2
    let center = CGPoint(x: radius, y: radius)
    let tipDistance = width * aspectRatio - radius
    let tip = CGPoint(x: center.x, y: center.y + tipDistance)
    let spread = acos(radius / tipDistance)
    let right = CGFloat.pi / 2 - spread
    let left = CGFloat.pi / 2 + spread - 2 * .pi
    var outline = [tip]
    for step in 0...steps {
        let angle = right + (left - right) * CGFloat(step) / CGFloat(steps)
        outline.append(CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle)))
    }
    let window = (0..<steps).map { step -> CGPoint in
        let angle = 2 * CGFloat.pi * CGFloat(step) / CGFloat(steps)
        return CGPoint(x: center.x + radius * windowRatio * cos(angle), y: center.y + radius * windowRatio * sin(angle))
    }
    return [outline, window]
}

func color(_ hex: UInt32) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

/// A context with y pointing down, like SwiftUI.
func canvas(_ size: Int, opaque: Bool) -> CGContext {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue
    )!
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: 1, y: -1)
    return context
}

func drawMark(in context: CGContext, width: CGFloat, center: CGPoint, fill: CGColor) {
    let height = width * aspectRatio
    let origin = CGPoint(x: center.x - width / 2, y: center.y - height / 2)
    context.beginPath()
    for contour in contours(width: width) {
        context.addLines(between: contour.map { CGPoint(x: origin.x + $0.x, y: origin.y + $0.y) })
        context.closePath()
    }
    context.setFillColor(fill)
    context.fillPath(using: .evenOdd)
}

func save(_ context: CGContext, to path: String) {
    let image = context.makeImage()!
    let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

let assets = "ios/Sublette/Resources/Assets.xcassets"
let yellow: UInt32 = 0xFFC629, orange: UInt32 = 0xFF7A1A, magenta: UInt32 = 0xD6177A
let cream: UInt32 = 0xFFF8EC

// The app icon: the brand gradient with a cream pin. No transparency, as Apple requires.
let icon = canvas(1024, opaque: true)
let gradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
    colors: [color(yellow), color(orange), color(magenta)] as CFArray,
    locations: [0, 0.5, 1]
)!
icon.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 1024, y: 1024), options: [])
drawMark(in: icon, width: 470, center: CGPoint(x: 512, y: 512), fill: color(cream))
save(icon, to: "\(assets)/AppIcon.appiconset/AppIcon.png")

// The launch screen mark: magenta on a clear background, at three scales.
for scale in 1...3 {
    let size = 120 * scale
    let mark = canvas(size, opaque: false)
    drawMark(in: mark, width: CGFloat(size) / aspectRatio, center: CGPoint(x: CGFloat(size) / 2, y: CGFloat(size) / 2), fill: color(magenta))
    save(mark, to: "\(assets)/LaunchMark.imageset/LaunchMark@\(scale)x.png")
}
