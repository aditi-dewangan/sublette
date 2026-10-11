import SwiftUI
import UIKit
import XCTest
@testable import Sublette

final class BrandColorsTests: XCTestCase {
    func testPaletteMatchesTheSpec() {
        assertColor(Brand.yellow, red: 0xFF, green: 0xC6, blue: 0x29)
        assertColor(Brand.magenta, red: 0xD6, green: 0x17, blue: 0x7A)
        assertColor(Brand.orange, red: 0xFF, green: 0x7A, blue: 0x1A)
        assertColor(Brand.ink, red: 0x2A, green: 0x14, blue: 0x22)
        assertColor(Brand.cream, red: 0xFF, green: 0xF8, blue: 0xEC)
    }

    func testTextOnYellowAndOrangeIsInk() {
        XCTAssertEqual(Brand.textOnYellow, Brand.ink)
        XCTAssertEqual(Brand.textOnOrange, Brand.ink)
        XCTAssertEqual(Brand.textOnCream, Brand.ink)
        XCTAssertEqual(Brand.textOnMagenta, Color.white)
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
