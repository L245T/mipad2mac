import Foundation
import Testing
@testable import MiPadCore

private var penDescriptor: Data {
    let hex = XiaomiDigitizer.descriptorHex
    return Data(stride(from: 0, to: hex.count, by: 2).map { offset in
        let start = hex.index(hex.startIndex, offsetBy: offset)
        return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
    })
}
private func permits(_ vendor: Int, productID: Int = 0x2d05, page: Int = 0x0d, usage: Int = 2,
                     manufacturer: String? = "Xiaomi", product: String? = "Xiaomi Pad 9 Pro Max",
                     descriptor: Data = penDescriptor) -> Bool {
    PenDeviceIdentity.permits(vendorID: vendor, productID: productID, usagePage: page, usage: usage,
                              manufacturer: manufacturer, product: product, descriptor: descriptor)
}
@Test func verifiedOriginalAndCurrentTabletPenIdentitiesAreAccepted() {
    #expect(permits(0x2717))
    #expect(permits(0x18d1))
}
@Test func sharedVendorRequiresObservedModelAndExactPenLayout() {
    #expect(!permits(0x18d1, manufacturer: nil))
    #expect(!permits(0x18d1, manufacturer: "Google"))
    #expect(!permits(0x18d1, product: nil))
    #expect(!permits(0x18d1, product: "Other Tablet"))
    #expect(!permits(0x18d1, descriptor: Data()))
    var modified = penDescriptor; modified[0] = 0
    #expect(!permits(0x18d1, descriptor: modified))
}
@Test func matchingNeverIncludesKeyboardMouseOrUnknownUsbIdentity() {
    for vendor in PenDeviceIdentity.vendorIDs {
        #expect(!permits(vendor, page: 1, usage: 6))
        #expect(!permits(vendor, page: 1, usage: 2))
        #expect(!permits(vendor, productID: 0x2d06))
        #expect(!permits(vendor, usage: 4))
    }
    #expect(!permits(0x1234))
}
@Test func legacyUnknownLayoutRemainsDiagnosticOnly() {
    let unknown = Data([0x05, 0x0d])
    #expect(permits(0x2717, descriptor: unknown))
    #expect(!XiaomiDigitizer.supports(unknown))
    #expect(!permits(0x18d1, descriptor: unknown))
}
