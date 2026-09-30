import Foundation

/// Verified USB identities of this tablet's pen collection, never a vendor-wide HID match.
public enum PenDeviceIdentity {
    public static let vendorIDs = [0x2717, 0x18d1]
    public static let productID = 0x2d05
    public static let usagePage = 0x0d
    public static let usage = 0x02

    public static func permits(vendorID: Int, productID: Int, usagePage: Int, usage: Int,
                               manufacturer: String?, product: String?, descriptor: Data) -> Bool {
        guard vendorIDs.contains(vendorID), productID == Self.productID,
              usagePage == Self.usagePage, usage == Self.usage else { return false }
        // Preserve the original unknown-descriptor diagnostic path; output still checks supports().
        if vendorID == 0x2717 { return true }
        // 18d1 is not Xiaomi-specific. Require the observed model AND the entire known pen layout.
        return manufacturer == "Xiaomi" && product == "Xiaomi Pad 9 Pro Max"
            && XiaomiDigitizer.supports(descriptor)
    }
}
