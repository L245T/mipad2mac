import Testing
import CoreGraphics
@testable import MiPadCore

struct PenDiagnosticsTests {
    @Test func testRawUnknownReportsAndLimit() {
        let c = PenCapture(start: 10, label: "button", duration: 30, limit: 2)
        c.receive(at: 11, reportID: 9, bytes: [9, 0], sample: nil)
        c.receive(at: 12, reportID: 9, bytes: [9, 128], sample: nil)
        c.receive(at: 13, reportID: 9, bytes: [9, 0], sample: nil)
        #expect(c.lines.count == 2); #expect(c.dropped == 1)
        #expect(c.lines[1].contains("b1 xor=80")); #expect(c.decoded == 0)
        c.stop(); c.receive(at: 14, reportID: 9, bytes: [9], sample: nil)
        #expect(c.dropped == 1)
    }
    @Test func testCaptureDeadlineAndRange() {
        let c = PenCapture(start: 10, label: "pressure")
        let s = Sample(x: 0, y: 0, touching: true, inRange: true, pressure: 8191, tiltX: -60, tiltY: 60)
        c.receive(at: 9, reportID: 3, bytes: [3, 9], sample: s)
        c.receive(at: 11, reportID: 3, bytes: [3, 9], sample: s)
        c.receive(at: 40, reportID: 3, bytes: [3, 9], sample: s)
        #expect(c.lines.count == 1); #expect(c.pressureRange == 8191...8191)
        #expect(c.tiltXRange == -60 ... -60)
    }
    @Test func testTiltRotationAndFlips() {
        for (rotation, x, y) in [(0, 30, -60), (90, 60, 30), (180, -30, 60), (270, -60, -30)] {
            for fx in [false, true] { for fy in [false, true] {
                let t = Mapping(bounds: .zero, rotation: rotation, flipX: fx, flipY: fy).tilt(x: 30, y: -60)
                #expect(abs(t.x - Double(fx ? -x : x)/90) < 0.00001)
                #expect(abs(t.y - Double(fy ? -y : y)/90) < 0.00001)
            }}
        }
    }
    @Test func testDrawingPreservesStationaryPressureAndRelease() {
        var g = PointerGesture()
        let m = Mapping(bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(g.consume(Sample(x: 0.5, y: 0.5, touching: true, inRange: true, pressure: 1), mapping: m, drawing: true)?.action == .down)
        #expect(g.consume(Sample(x: 0.5, y: 0.5, touching: true, inRange: true, pressure: 8000), mapping: m, drawing: true)?.action == .drag)
        #expect(g.release()?.action == .up); #expect(g.release() == nil)
    }
}
