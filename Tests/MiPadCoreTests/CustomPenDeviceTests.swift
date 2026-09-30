import Foundation
import Testing
@testable import MiPadCore

struct CustomPenDeviceTests {
    private func device(vendor: Int = 0x1234, name: String = "Test Pen", page: Int = 13,
                        descriptor: Data? = nil) -> CustomPenDevice? {
        let hex = XiaomiDigitizer.descriptorHex
        let bytes = Data(stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        })
        return CustomPenDevice(vendorID: vendor, productID: 0x1111, usagePage: page, usage: 2,
                               manufacturer: "Test", product: name, descriptor: descriptor ?? bytes)
    }
    @Test func selectionDoesNotPersistUntilSeparateSaveAndDeletionSurvivesReload() throws {
        let suite = "custom-pen-tests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let pen = try #require(device()), prefs = CustomPenPreferences(defaults: defaults)
        #expect(prefs.devices.isEmpty)
        #expect(!prefs.recognizes(pen))
        prefs.save(pen)
        let reloaded = CustomPenPreferences(defaults: defaults)
        #expect(reloaded.recognizes(try #require(device())))
        prefs.save(try #require(device()))
        #expect(prefs.devices.count == 1)
        prefs.remove(pen.id)
        #expect(reloaded.devices.isEmpty)
    }
    @Test func sameNameNeverAuthorizesDifferentIdentityOrUnknownLayout() throws {
        let a = try #require(device()), b = try #require(device(vendor: 0x1235))
        #expect(!a.matches(b))
        #expect(device(page: 1) == nil)
        #expect(device(descriptor: Data([0x05, 0x0d])) == nil)
        #expect(device(name: "") == nil)
        #expect(device(vendor: -1) == nil)
    }
    @Test func invalidStoredProfilesAreRejected() throws {
        let suite = "custom-pen-tests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = CustomPenPreferences(defaults: defaults)
        defaults.set(Data("bad JSON".utf8), forKey: "penCustomDeviceProfiles")
        #expect(prefs.devices.isEmpty)
        let valid = try #require(device())
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        object["descriptor"] = Data([1,2]).base64EncodedString()
        defaults.set(try JSONSerialization.data(withJSONObject: [object]), forKey: "penCustomDeviceProfiles")
        #expect(prefs.devices.isEmpty)
    }
}
