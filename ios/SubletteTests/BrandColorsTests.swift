import SwiftUI
import UIKit
import XCTest
@testable import Sublette

final class BrandColorsTests: XCTestCase {
    func testPaletteMatchesTheSpec() {
        assertColor(Brand.yellow, red: 0xFF, green: 0xC6, blue: 0x29)
        assertColor(Brand.magenta, red: 0xD6, green: 0x17, blue: 0x7A)
        assertColor(Brand.orange, red: 0xFF, green: 0x7A, blue: 0x1A)
        assertColor(Palette.ink, red: 0x2A, green: 0x14, blue: 0x22)
        assertColor(Palette.cream, red: 0xFF, green: 0xF8, blue: 0xEC)
    }

    func testTextOnYellowAndOrangeIsInkInBothModes() {
        XCTAssertEqual(Brand.textOnYellow, Palette.ink)
        XCTAssertEqual(Brand.textOnOrange, Palette.ink)
        XCTAssertEqual(Brand.textOnCream, Brand.ink)
        XCTAssertEqual(Brand.textOnMagenta, Color.white)
    }

    func testInkAndCreamSwapInDarkMode() {
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        assertColor(Brand.ink, in: light, red: 0x2A, green: 0x14, blue: 0x22)
        assertColor(Brand.ink, in: dark, red: 0xFF, green: 0xF8, blue: 0xEC)
        assertColor(Brand.cream, in: light, red: 0xFF, green: 0xF8, blue: 0xEC)
        assertColor(Brand.cream, in: dark, red: 0x2A, green: 0x14, blue: 0x22)
        assertColor(Brand.card, in: dark, red: 0x3A, green: 0x24, blue: 0x31)
        assertColor(Brand.accentText, in: light, red: 0xD6, green: 0x17, blue: 0x7A)
        assertColor(Brand.accentText, in: dark, red: 0xFF, green: 0x6F, blue: 0xB0)
    }

    private func assertColor(
        _ color: Color,
        in traits: UITraitCollection,
        red: Int,
        green: Int,
        blue: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let resolved = UIColor(color).resolvedColor(with: traits)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(Int((r * 255).rounded()), red, file: file, line: line)
        XCTAssertEqual(Int((g * 255).rounded()), green, file: file, line: line)
        XCTAssertEqual(Int((b * 255).rounded()), blue, file: file, line: line)
    }

    private func assertColor(
        _ color: Color,
        red: Int,
        green: Int,
        blue: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        XCTAssertTrue(
            UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a),
            file: file,
            line: line
        )
        XCTAssertEqual(Int((r * 255).rounded()), red, "red", file: file, line: line)
        XCTAssertEqual(Int((g * 255).rounded()), green, "green", file: file, line: line)
        XCTAssertEqual(Int((b * 255).rounded()), blue, "blue", file: file, line: line)
        XCTAssertEqual(a, 1, "alpha", file: file, line: line)
    }
}
