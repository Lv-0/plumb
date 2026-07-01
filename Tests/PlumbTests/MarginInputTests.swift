import CoreGraphics
import Testing
@testable import Plumb

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - MarginRow 数字输入解析测试
//
// 验证：在边距文本框直接输入数字时，解析 → 钳制 → 四舍五入的逻辑在各种输入下都正确。
// 覆盖：普通整数、小数、空串、非法字符、负数、超大值、带空格、前导零。
// ─────────────────────────────────────────────────────────────────────────────

@Test
func marginInput_plainInteger() async throws {
    #expect(MarginValueParser.parse(text: "24") == 24)
}

@Test
func marginInput_decimalRoundsToNearest() async throws {
    #expect(MarginValueParser.parse(text: "23.6") == 24)
    #expect(MarginValueParser.parse(text: "23.4") == 23)
}

@Test
func marginInput_emptyStringFallsBackToZero() async throws {
    #expect(MarginValueParser.parse(text: "") == 0)
}

@Test
func marginInput_garbageFallsBackToZero() async throws {
    #expect(MarginValueParser.parse(text: "abc") == 0)
    #expect(MarginValueParser.parse(text: "--") == 0)
}

@Test
func marginInput_negativeClampedToMinimum() async throws {
    #expect(MarginValueParser.parse(text: "-5") == AppTilingSettings.minimumEdgeMargin)
    #expect(MarginValueParser.parse(text: "-9999") == AppTilingSettings.minimumEdgeMargin)
}

@Test
func marginInput_hugeValueClampedToMaximum() async throws {
    #expect(MarginValueParser.parse(text: "9999") == AppTilingSettings.maximumEdgeMargin)
}

@Test
func marginInput_trimsWhitespace() async throws {
    #expect(MarginValueParser.parse(text: "  24  ") == 24)
}

@Test
func marginInput_leadingZeros() async throws {
    #expect(MarginValueParser.parse(text: "007") == 7)
}

@Test
func marginInput_atBoundaries() async throws {
    #expect(MarginValueParser.parse(text: "0") == 0)
    #expect(MarginValueParser.parse(text: "400") == 400)
}

@Test
func marginInput_intStringFormatting() async throws {
    #expect(MarginValueParser.intString(24) == "24")
    #expect(MarginValueParser.intString(23.6) == "24")
    #expect(MarginValueParser.intString(0) == "0")
}
