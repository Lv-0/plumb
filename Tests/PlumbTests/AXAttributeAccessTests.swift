import CoreFoundation
import Foundation
import Testing

@testable import Plumb

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - AXAttributeAccess 数值解码测试
//
// 锁定 `AXWindowNumber` 的 64 位安全解码语义。AXWindowNumber 是单调递增的
// 32 位无符号值，接近 UInt32.max 时会远超 Int32.max；旧 `.sInt32Type` 解码会
// 把这些值截断/溢出，导致 windowID 错误、坐标推断拿不到正确窗口。
// 这些测试覆盖被旧实现破坏的关键区间（> Int32.max 且 < UInt32.max）。
// ─────────────────────────────────────────────────────────────────────────────

private let int32Max = Int(Int32.max)          // 2_147_483_647
private let uint32Max = Int(UInt32.max)        // 4_294_967_295

@Test
func axPositiveIntegerDecodesValueAboveInt32Max() {
    // 关键区间：旧 .sInt32Type 解码在此会溢出/截断。用 CFNumber 构造一个落在
    // (Int32.max, UInt32.max) 之间的真实窗口编号，验证 64 位解码正确返回。
    var largeWindowNumber = int32Max + 1
    let number = CFNumberCreate(nil, .sInt64Type, &largeWindowNumber) as CFNumber
    let decoded = AXAttributeAccess.positiveInteger(from: number)
    #expect(decoded == largeWindowNumber)
}

@Test
func axPositiveIntegerDecodesValueNearUInt32Max() {
    // 接近 UInt32 上限的值同样必须完整解码（CGWindowID 的合法上界）。
    var nearMax = uint32Max - 1
    let number = CFNumberCreate(nil, .sInt64Type, &nearMax) as CFNumber
    let decoded = AXAttributeAccess.positiveInteger(from: number)
    #expect(decoded == nearMax)
}

@Test
func axPositiveIntegerDecodesSmallPositiveValue() {
    // 常规小正数（典型窗口编号）仍正确返回。
    var value: Int64 = 42
    let number = CFNumberCreate(nil, .sInt64Type, &value) as CFNumber
    #expect(AXAttributeAccess.positiveInteger(from: number) == 42)
}

@Test
func axPositiveIntegerRejectsZeroAndNegative() {
    var zero: Int64 = 0
    let zeroNumber = CFNumberCreate(nil, .sInt64Type, &zero) as CFNumber
    #expect(AXAttributeAccess.positiveInteger(from: zeroNumber) == nil)

    var negative: Int64 = -5
    let negativeNumber = CFNumberCreate(nil, .sInt64Type, &negative) as CFNumber
    #expect(AXAttributeAccess.positiveInteger(from: negativeNumber) == nil)
}
