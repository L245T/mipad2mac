import Testing
import Foundation
@testable import MiPadCore

struct DigitizerTests {
    @Test func testRepeatedLiftResetDoesNotWarpButHoverResumes() throws {
        let reset = try #require(XiaomiDigitizer.decode([3, 8, 0, 0, 255, 127, 0, 0, 0, 0], reportID: 3))
        #expect(!reset.positionValid)
        var gesture = PointerGesture()
        let mapping = Mapping(bounds: CGRect(x: -1000, y: 0, width: 1001, height: 1001))
        let down = gesture.consume(Sample(x: 0.5, y: 0.5, touching: true, inRange: true), mapping: mapping)
        #expect(gesture.consume(reset, mapping: mapping)?.point == down?.point)
        #expect(gesture.consume(reset, mapping: mapping) == nil)
        #expect(gesture.consume(reset, mapping: mapping) == nil)
        let hover = gesture.consume(Sample(x: 0.6, y: 0.4, touching: false, inRange: true), mapping: mapping)
        #expect(hover == PointerEvent(action: .move, point: CGPoint(x: -400, y: 400)))
    }
    @Test func testCornerContactIsNotFiltered() throws {
        let contact = try #require(XiaomiDigitizer.decode([3, 9, 0, 0, 255, 127, 1, 0, 0, 0], reportID: 3))
        #expect(contact.positionValid && contact.touching)
        var gesture = PointerGesture()
        #expect(gesture.consume(contact, mapping: Mapping(bounds: CGRect(x: 0, y: 0, width: 100, height: 100)))?.action == .down)
    }

    @Test func testTapReleasesAtPressPointDespiteResetCoordinates() throws {
        var gesture = PointerGesture()
        let mapping = Mapping(bounds: CGRect(x: 2000, y: -200, width: 1001, height: 1001))
        let downResult = gesture.consume(Sample(x: 0.5, y: 0.5, touching: true, inRange: true), mapping: mapping)
        let down = try #require(downResult)
        #expect(down == PointerEvent(action: .down, point: CGPoint(x: 2500, y: 300)))
        #expect(gesture.consume(Sample(x: 0.501, y: 0.501, touching: true, inRange: true), mapping: mapping) == nil)
        let upResult = gesture.consume(Sample(x: 0, y: 1, touching: false, inRange: true), mapping: mapping)
        let up = try #require(upResult)
        #expect(up == PointerEvent(action: .up, point: down.point))
    }
    @Test func testDragReleaseUsesLastDragPoint() throws {
        var gesture = PointerGesture()
        let mapping = Mapping(bounds: CGRect(x: -1000, y: 0, width: 1001, height: 1001))
        _ = gesture.consume(Sample(x: 0.5, y: 0.5, touching: true, inRange: true), mapping: mapping)
        let dragResult = gesture.consume(Sample(x: 0.6, y: 0.6, touching: true, inRange: true), mapping: mapping)
        let drag = try #require(dragResult)
        #expect(drag.action == .drag)
        #expect(gesture.release() == PointerEvent(action: .up, point: drag.point))
        #expect(gesture.release() == nil)
    }
    @Test func testActualDeviceReport() throws {
        // Observed in the running app on 2026-09-16; user confirmed this was the stylus.
        let s = try #require(XiaomiDigitizer.decode([0x03, 0x09, 0x8d, 0x38, 0x38, 0x4f, 0xdb, 0x02, 0xeb, 0x1c], reportID: 3))
        #expect(s.touching && s.inRange)
        #expect(s.x == Double(0x388d) / 32767)
        #expect(s.y == Double(0x4f38) / 32767)
        #expect(s.pressure == 731)
        #expect(s.tiltX == -21 && s.tiltY == 28)
    }
    @Test func testCapturedDescriptorAndUnknownFirmware() {
        let hex = XiaomiDigitizer.descriptorHex
        let bytes = stride(from: 0, to: hex.count, by: 2).map { offset -> UInt8 in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
        #expect(XiaomiDigitizer.supports(Data(bytes)))
        #expect(!(XiaomiDigitizer.supports(Data(bytes.dropLast()))))
    }
    @Test func testPenReportCoordinatesFlagsAndSignedTilt() throws {
        // Synthetic fixture based on the real descriptor, not a recorded touch report.
        let s = try #require(XiaomiDigitizer.decode([3, 0x0b, 0xff, 0x7f, 0, 0, 0xff, 0x1f, 0xc4, 60], reportID: 3))
        #expect(s.x == 1); #expect(s.y == 0)
        #expect(s.touching); #expect(s.inRange); #expect(s.barrel)
        #expect(s.pressure == 8191); #expect(s.tiltX == -60); #expect(s.tiltY == 60)
    }
    @Test func testRejectsTruncatedWrongIDAndOutOfRange() {
        #expect(XiaomiDigitizer.decode([3, 9], reportID: 3) == nil)
        #expect(XiaomiDigitizer.decode([2, 9, 0, 0, 0, 0, 0, 0, 0, 0], reportID: 2) == nil)
        #expect(XiaomiDigitizer.decode([3, 9, 0, 128, 0, 0, 0, 0, 0, 0], reportID: 3) == nil)
        #expect(XiaomiDigitizer.decode([3, 9, 0, 0, 0, 0, 0, 32, 0, 0], reportID: 3) == nil)
    }
    @Test func testMappingHiDPIAndNegativeOrigin() {
        let m = Mapping(bounds: CGRect(x: -1720, y: 120, width: 1720, height: 1080))
        #expect(m.point(x: 0, y: 0) == CGPoint(x: -1720, y: 120))
        #expect(m.point(x: 1, y: 1) == CGPoint(x: -1, y: 1199))
        #expect(m.point(x: 2, y: -1) == CGPoint(x: -1, y: 120))
    }
    @Test func testRotationAndFlip() {
        var m = Mapping(bounds: CGRect(x: 0, y: 0, width: 101, height: 201), rotation: 90)
        #expect(m.point(x: 0, y: 0) == CGPoint(x: 100, y: 0))
        m.flipX = true
        #expect(m.point(x: 0, y: 0) == CGPoint(x: 0, y: 0))
    }
    @Test func testPressDragReleaseAndDisconnect() {
        var state = PointerState()
        let down = Sample(x: 0.5, y: 0.5, touching: true, inRange: true)
        #expect(state.consume(down) == .down)
        #expect(state.consume(down) == .drag)
        #expect(state.release() == .up)
        #expect(state.release() == nil)
        #expect(state.consume(down) == .down)
        #expect(state.consume(Sample(x: 0, y: 0, touching: false, inRange: false)) == .up)
        #expect(state.consume(Sample(x: 0, y: 0, touching: false, inRange: false)) == nil)
    }
    @Test func testHoverAndEraserDoNotPress() {
        var state = PointerState()
        #expect(state.consume(Sample(x: 0, y: 0, touching: false, inRange: true)) == .move)
        #expect(state.consume(Sample(x: 0, y: 0, touching: true, inRange: true, eraser: true)) == .move)
        #expect(!(state.isDown))
    }
}
