import SwiftUI

/// Sublette's logo mark: a map pin with a round window. Drawn here, not from
/// an image, so it is sharp at every size and takes any color.
/// `scripts/make-brand-images.swift` draws the same shape for the app icon.
struct PinMarkShape: Shape {
    /// Height divided by width.
    static let aspectRatio: CGFloat = 1.25
    /// The window's radius, as a share of the pin's round top.
    static let windowRatio: CGFloat = 0.4

    func path(in rect: CGRect) -> Path {
        let width = min(rect.width, rect.height / Self.aspectRatio)
        let height = width * Self.aspectRatio
        let origin = CGPoint(x: rect.midX - width / 2, y: rect.midY - height / 2)
        var path = Path()
        for contour in Self.contours(width: width) {
            path.addLines(contour.map { CGPoint(x: origin.x + $0.x, y: origin.y + $0.y) })
            path.closeSubpath()
        }
        return path
    }

    /// The outline and the window, as point lists in a box `width` wide,
    /// y pointing down. Filled even-odd, the window is a hole.
    static func contours(width: CGFloat, steps: Int = 96) -> [[CGPoint]] {
        let radius = width / 2
        let center = CGPoint(x: radius, y: radius)
        let tipDistance = width * aspectRatio - radius
        let tip = CGPoint(x: center.x, y: center.y + tipDistance)
        // Where the straight sides touch the round top.
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
            let small = radius * windowRatio
            return CGPoint(x: center.x + small * cos(angle), y: center.y + small * sin(angle))
        }
        return [outline, window]
    }
}

/// The mark filled in one color, at a given width.
struct PinMark: View {
    var color: Color = Brand.magenta
    var width: CGFloat = 44

    var body: some View {
        PinMarkShape()
            .fill(color, style: FillStyle(eoFill: true))
            .frame(width: width, height: width * PinMarkShape.aspectRatio)
            .accessibilityHidden(true)
    }
}

/// The yellow to orange to magenta gradient of the match moment and the icon.
enum BrandGradient {
    static let colors = [Palette.yellow, Palette.orange, Palette.magenta]

    static var linear: LinearGradient {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

#Preview("Mark") {
    HStack(spacing: 24) {
        PinMark(width: 60)
        PinMark(color: Brand.ink, width: 40)
        PinMark(color: Brand.cream, width: 60)
            .padding(12)
            .background(BrandGradient.linear, in: RoundedRectangle(cornerRadius: 20))
    }
    .padding()
    .background(Brand.cream)
}
