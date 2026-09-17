import Foundation

/// Bounded raw capture on the pen interface, before descriptor/report filtering.
public final class PenCapture {
    public let start: Double
    public let duration: Double
    public let label: String
    public private(set) var lines: [String] = []
    public private(set) var dropped = 0
    public private(set) var decoded = 0
    public private(set) var pressureRange: ClosedRange<Int>?
    public private(set) var tiltXRange: ClosedRange<Int>?
    public private(set) var tiltYRange: ClosedRange<Int>?
    public private(set) var flagValues = Set<UInt8>()
    public private(set) var stopped = false
    private var previous: [UInt32: [UInt8]] = [:]
    private var byteCount = 0
    private let limit: Int
    public init(start: Double, label: String, duration: Double = 30, limit: Int = 12000) {
        self.start = start; self.label = label; self.duration = duration; self.limit = limit
    }
    public func stop() { stopped = true }
    public func receive(at time: Double, reportID: UInt32, bytes: [UInt8], sample: Sample?) {
        guard !stopped, time >= start, time < start + duration else { return }
        guard lines.count < limit, byteCount + bytes.count <= 2 * 1024 * 1024 else { dropped += 1; return }
        let old = previous[reportID]
        let changes = bytes.indices.compactMap { i -> String? in
            guard let old, old.indices.contains(i) else { return "b\(i)=new" }
            let mask = old[i] ^ bytes[i]
            return mask == 0 ? nil : String(format: "b%d xor=%02x", i, mask)
        }.joined(separator: ",")
        previous[reportID] = bytes; byteCount += bytes.count
        var interpretation = "unparsed"
        if let s = sample {
            decoded += 1
            func expand(_ r: ClosedRange<Int>?, _ v: Int) -> ClosedRange<Int> { min(r?.lowerBound ?? v, v)...max(r?.upperBound ?? v, v) }
            pressureRange = expand(pressureRange, s.pressure)
            tiltXRange = expand(tiltXRange, s.tiltX); tiltYRange = expand(tiltYRange, s.tiltY)
            if bytes.count > 1 { flagValues.insert(bytes[1]) }
            interpretation = "p=\(s.pressure) tx=\(s.tiltX) ty=\(s.tiltY) tip=\(s.touching) range=\(s.inRange) barrel=\(s.barrel) eraser=\(s.eraser) valid=\(s.positionValid)"
        }
        lines.append(String(format: "t=%.6f +%.6f ID=%u len=%d ", time, time-start, reportID, bytes.count)
            + bytes.map { String(format: "%02x", $0) }.joined(separator: " ") + " | " + changes + " | " + interpretation)
    }
    public var summary: String {
        func range(_ r: ClosedRange<Int>?) -> String { r.map { "\($0.lowerBound)…\($0.upperBound)" } ?? "无" }
        return "\(label)：原始 \(lines.count) / 解析 \(decoded) / 未记录 \(dropped)；压力 \(range(pressureRange))，倾斜 X \(range(tiltXRange)) / Y \(range(tiltYRange))；flags=" + flagValues.sorted().map { String(format: "%02x", $0) }.joined(separator: ",")
    }
    public var export: String { summary + "\n原始笔接口记录（非 USB 总线抓包；xor 相对同 Report ID 前一条；截断/变长需结合 len 判断）\n" + lines.joined(separator: "\n") }
}

public extension Mapping {
    /// Transform a signed tilt vector with the same rotation/flips as position.
    /// HID tilt is in degrees; normalize against 90 degrees, not the device's ±60 limit.
    func tilt(x: Int, y: Int) -> CGPoint {
        var u = Double(x) / 90, v = Double(y) / 90
        switch rotation {
        case 90: (u, v) = (-v, u)
        case 180: (u, v) = (-u, -v)
        case 270: (u, v) = (v, -u)
        default: break
        }
        if flipX { u = -u }; if flipY { v = -v }
        return CGPoint(x: max(-1, min(1, u)), y: max(-1, min(1, v)))
    }
}
