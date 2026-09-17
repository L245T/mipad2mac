import Foundation
import CoreGraphics

/// Exact descriptor read from Xiaomi 2717:2d05 on 2026-09-16.
/// Unknown layouts fail closed; no guessed offsets are used for another firmware.
public enum XiaomiDigitizer {
    public static let descriptorHex = "050d0902a10185030920a102094215002501750195018102094481020945810209328102750481030501550e65110930150026ff7f3500466009751095018102093126ff7f466009810255006500050d0930150026ff1f75108102093d15c4253c75088102093e8102c0c0"
    public static func supports(_ descriptor: Data) -> Bool {
        descriptor.map { String(format: "%02x", $0) }.joined() == descriptorHex
    }

    /// IOKit numbered input reports include their report ID as the first byte.
    public static func decode(_ bytes: [UInt8], reportID: UInt32) -> Sample? {
        guard reportID == 3, bytes.count == 10, bytes[0] == 3 else { return nil }
        let flags = bytes[1]
        let x = Int(bytes[2]) | Int(bytes[3]) << 8
        let y = Int(bytes[4]) | Int(bytes[5]) << 8
        let pressure = Int(bytes[6]) | Int(bytes[7]) << 8
        let tiltX = Int(Int8(bitPattern: bytes[8]))
        let tiltY = Int(Int8(bitPattern: bytes[9]))
        guard flags & 0xf0 == 0, x <= 32767, y <= 32767, pressure <= 8191,
              abs(tiltX) <= 60, abs(tiltY) <= 60 else { return nil }
        return Sample(x: Double(x) / 32767, y: Double(y) / 32767,
                      touching: flags & 1 != 0, inRange: flags & 8 != 0,
                      barrel: flags & 2 != 0, eraser: flags & 4 != 0,
                      pressure: pressure, tiltX: tiltX, tiltY: tiltY,
                      positionValid: bytes != [3, 8, 0, 0, 255, 127, 0, 0, 0, 0])
    }
}

public struct Sample {
    public let positionValid: Bool
    public let x: Double
    public let y: Double
    public let touching: Bool
    public let inRange: Bool
    public let barrel: Bool
    public let eraser: Bool
    public let pressure: Int
    public let tiltX: Int
    public let tiltY: Int
    public init(x: Double, y: Double, touching: Bool, inRange: Bool,
                barrel: Bool = false, eraser: Bool = false,
                pressure: Int = 0, tiltX: Int = 0, tiltY: Int = 0, positionValid: Bool = true) {
        self.positionValid = positionValid
        self.x = x; self.y = y; self.touching = touching; self.inRange = inRange
        self.barrel = barrel; self.eraser = eraser; self.pressure = pressure
        self.tiltX = tiltX; self.tiltY = tiltY
    }
}

public struct Mapping {
    public var bounds: CGRect
    public var rotation: Int
    public var flipX: Bool
    public var flipY: Bool
    public init(bounds: CGRect, rotation: Int = 0, flipX: Bool = false, flipY: Bool = false) {
        self.bounds = bounds; self.rotation = rotation; self.flipX = flipX; self.flipY = flipY
    }
    public func point(x: Double, y: Double) -> CGPoint {
        var u = min(1, max(0, x)), v = min(1, max(0, y))
        switch rotation {
        case 90: (u, v) = (1 - v, u)
        case 180: (u, v) = (1 - u, 1 - v)
        case 270: (u, v) = (v, 1 - u)
        default: break
        }
        if flipX { u = 1 - u }
        if flipY { v = 1 - v }
        // Keep the endpoint inside this display, including a display with negative origin.
        return CGPoint(x: bounds.minX + u * max(0, bounds.width - 1),
                       y: bounds.minY + v * max(0, bounds.height - 1))
    }
}

public enum PointerAction: Equatable { case move, down, drag, up, rightDown, rightUp }

public struct PointerEvent: Equatable {
    public let action: PointerAction
    public let point: CGPoint
    public init(action: PointerAction, point: CGPoint) { self.action = action; self.point = point }
}

/// Keep a tap at its press point until movement exceeds a small logical-point threshold.
/// Never use lift-packet coordinates for mouseUp: this device has sent (0, maxY) on lift.
public struct PointerGesture {
    private var state = PointerState()
    private var pressPoint = CGPoint.zero
    private var lastPoint = CGPoint.zero
    private var dragging = false
    public init() {}
    public mutating func consume(_ sample: Sample, mapping: Mapping, drawing: Bool = false) -> PointerEvent? {
        guard let action = state.consume(sample) else { return nil }
        let point = mapping.point(x: sample.x, y: sample.y)
        switch action {
        case .down:
            pressPoint = point; lastPoint = point; dragging = false
        case .drag:
            if !drawing && !dragging && hypot(point.x - pressPoint.x, point.y - pressPoint.y) < 4 { return nil }
            dragging = true; lastPoint = point
        case .up:
            // Even an in-range lift can have reset coordinates. Release where we last pressed/dragged.
            return PointerEvent(action: .up, point: lastPoint)
        case .rightDown, .rightUp:
            return nil
        case .move:
            guard sample.positionValid else { return nil }
            lastPoint = point
        }
        return PointerEvent(action: action, point: lastPoint)
    }
    public mutating func release() -> PointerEvent? {
        guard state.release() != nil else { return nil }
        return PointerEvent(action: .up, point: lastPoint)
    }
}

public struct PointerState {
    public private(set) var isDown = false
    public init() {}
    public mutating func consume(_ sample: Sample) -> PointerAction? {
        // Eraser and pen side buttons are intentionally not mapped in this version.
        let contact = sample.touching && sample.inRange && !sample.eraser
        if contact {
            let action: PointerAction = isDown ? .drag : .down
            isDown = true
            return action
        }
        if isDown { isDown = false; return .up }
        return sample.inRange ? .move : nil
    }
    public mutating func release() -> PointerAction? {
        guard isDown else { return nil }
        isDown = false
        return .up
    }
}
