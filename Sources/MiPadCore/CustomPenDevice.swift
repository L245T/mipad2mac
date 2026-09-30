import Foundation

/// A user-approved identity, not a name-only allowlist. Never stores serial numbers or registry IDs.
public struct CustomPenDevice: Codable, Equatable, Identifiable {
    public let id: UUID
    public let vendorID: Int
    public let productID: Int
    public let manufacturer: String?
    public let product: String
    public let descriptor: Data
    public var isValid: Bool {
        (0...65535).contains(vendorID) && (0...65535).contains(productID)
            && !product.isEmpty && product.count <= 256 && (manufacturer?.count ?? 0) <= 256
            && XiaomiDigitizer.supports(descriptor)
    }
    public init?(vendorID: Int, productID: Int, usagePage: Int, usage: Int,
                 manufacturer: String?, product: String?, descriptor: Data) {
        guard usagePage == PenDeviceIdentity.usagePage, usage == PenDeviceIdentity.usage,
              let product else { return nil }
        id = UUID(); self.vendorID = vendorID; self.productID = productID
        self.manufacturer = manufacturer; self.product = product; self.descriptor = descriptor
        guard isValid else { return nil }
    }
    public func matches(_ other: Self) -> Bool {
        isValid && other.isValid && vendorID == other.vendorID && productID == other.productID
            && manufacturer == other.manufacturer && product == other.product && descriptor == other.descriptor
    }
}

public final class CustomPenPreferences {
    private let defaults: UserDefaults
    private let key = "penCustomDeviceProfiles"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var devices: [CustomPenDevice] {
        guard let data = defaults.data(forKey: key), data.count <= 65536,
              let decoded = try? JSONDecoder().decode([CustomPenDevice].self, from: data) else { return [] }
        var unique: [CustomPenDevice] = []
        for device in decoded.prefix(32) where device.isValid {
            if !unique.contains(where: { $0.matches(device) }) { unique.append(device) }
        }
        return unique
    }
    public func recognizes(_ candidate: CustomPenDevice) -> Bool { devices.contains { $0.matches(candidate) } }
    /// Called only by the separate Save action; selecting/using a device never persists it.
    public func save(_ device: CustomPenDevice) {
        guard device.isValid else { return }
        var list = devices
        guard !list.contains(where: { $0.matches(device) }), list.count < 32 else { return }
        list.append(device); write(list)
    }
    public func remove(_ id: UUID) { write(devices.filter { $0.id != id }) }
    private func write(_ devices: [CustomPenDevice]) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        defaults.set(data, forKey: key)
    }
}
