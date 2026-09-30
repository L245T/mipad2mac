import Foundation
import IOKit.hid
import MiPadCore

final class HIDReader {
    private var manager = IOHIDManagerCreate(kCFAllocatorDefault, IOHIDManagerOptions.independentDevices.rawValue)
    private var devices: [DeviceContext] = []
    var status: (String) -> Void = { print($0) }
    var sample: (Sample) -> Void = { _ in }
    var disconnected: () -> Void = {}
    var devicesChanged: () -> Void = {}
    var candidatesChanged: () -> Void = {}
    let customPens = CustomPenPreferences()
    private(set) var candidates: [Candidate] = []
    private var manualID: UUID?
    var manualProfile: CustomPenDevice? { candidates.first { $0.id == manualID }?.profile }
    var canSaveManualDevice: Bool {
        readyForControl && manualProfile.map { !customPens.recognizes($0) } == true
    }
    var manualCandidates: [Candidate] { candidates.filter { $0.profile != nil } }
    var needsManualSelection: Bool {
        !readyForControl && !candidates.contains(where: { $0.automatic }) && !manualCandidates.isEmpty
    }
    final class Candidate: Identifiable {
        let id = UUID()
        let device: IOHIDDevice
        let name: String
        let vendorID: Int
        let productID: Int
        let profile: CustomPenDevice?
        let builtIn: Bool
        var automatic: Bool
        init(device: IOHIDDevice, reader: HIDReader) {
            self.device = device
            func number(_ key: String) -> Int { (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? -1 }
            vendorID = number(kIOHIDVendorIDKey); productID = number(kIOHIDProductIDKey)
            let page = number(kIOHIDPrimaryUsagePageKey), usage = number(kIOHIDPrimaryUsageKey)
            let manufacturer = IOHIDDeviceGetProperty(device, kIOHIDManufacturerKey as CFString) as? String
            let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
            let descriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data ?? Data()
            name = product ?? "未命名笔设备"
            profile = CustomPenDevice(vendorID: vendorID, productID: productID, usagePage: page, usage: usage,
                                      manufacturer: manufacturer, product: product, descriptor: descriptor)
            builtIn = PenDeviceIdentity.permits(vendorID: vendorID, productID: productID, usagePage: page, usage: usage,
                                               manufacturer: manufacturer, product: product, descriptor: descriptor)
            automatic = builtIn || (profile.map { reader.customPens.recognizes($0) } ?? false)
        }
    }
    var diagnosticsEnabled = false
    var measurement: InputRateMeasurement?
    var penCapture: PenCapture?
    var reports = 0
    var decoded = 0
    private var lastBytes: [UInt8] = []
    private var lastReportID: UInt32 = 0
    var resetReports = 0
    var lastReport: String {
        guard !lastBytes.isEmpty else { return "等待报文" }
        return "ID \(lastReportID) / \(lastBytes.count) bytes: " + lastBytes.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
    }
    var deviceCount: Int { devices.count }
    var readyForControl: Bool { devices.count == 1 && devices[0].supported }
    var running = false

    final class DeviceContext {
        let device: IOHIDDevice
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        let supported: Bool
        var exclusive = false
        unowned let reader: HIDReader
        init(device: IOHIDDevice, reader: HIDReader, supported: Bool) {
            self.device = device; self.reader = reader; self.supported = supported
        }
        deinit { buffer.deallocate() }
    }

    func resetDiagnostics() {
        reports = 0; decoded = 0; resetReports = 0; lastBytes = []; lastReportID = 0
    }

    func start() {
        guard !running else { return }
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOHIDManagerOptions.independentDevices.rawValue)
        // Discovery reads pen metadata only. Unknown candidates are not opened or monitored.
        // Independent-devices mode keeps IOHIDManager from opening candidates on our behalf.
        let match: [String: Any] = [kIOHIDPrimaryUsagePageKey: PenDeviceIdentity.usagePage,
                                   kIOHIDPrimaryUsageKey: PenDeviceIdentity.usage]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HIDReader>.fromOpaque(context).takeUnretainedValue().observe(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let reader = Unmanaged<HIDReader>.fromOpaque(context).takeUnretainedValue()
            reader.removeCandidate(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, 0)
        running = true
        status("HID manager: \(result == 0 ? "已打开" : String(format: "0x%08x", result))")
    }

    private func observe(_ device: IOHIDDevice) {
        guard !candidates.contains(where: { CFEqual($0.device, device) }) else { return }
        let candidate = Candidate(device: device, reader: self)
        candidates.append(candidate)
        if manualID == nil && candidate.automatic { attach(candidate) }
        candidatesChanged()
    }
    private func removeCandidate(_ device: IOHIDDevice) {
        if let candidate = candidates.first(where: { CFEqual($0.device, device) }), candidate.id == manualID {
            manualID = nil
        }
        detach(device)
        candidates.removeAll { CFEqual($0.device, device) }
        candidatesChanged()
    }
    @discardableResult func selectCandidate(_ id: UUID) -> Bool {
        guard let candidate = manualCandidates.first(where: { $0.id == id }) else { return false }
        // The caller releases output before switching. Close the previous pen, never another HID class.
        for device in Array(devices) { detach(device.device) }
        manualID = id
        attach(candidate)
        candidatesChanged()
        return readyForControl
    }
    func saveManualDevice() {
        guard canSaveManualDevice, let profile = manualProfile else { return }
        customPens.save(profile)
        candidates.first { $0.id == manualID }?.automatic = true
        candidatesChanged()
    }
    func removeSavedDevice(_ id: UUID) {
        customPens.remove(id)
        for candidate in candidates {
            candidate.automatic = candidate.builtIn || (candidate.profile.map { customPens.recognizes($0) } ?? false)
        }
        // Keep an already selected device for this connection; deletion only removes future trust.
        candidatesChanged()
    }
    private func attach(_ candidate: Candidate) {
        let device = candidate.device
        guard !devices.contains(where: { CFEqual($0.device, device) }),
              candidate.automatic || candidate.id == manualID else { return }
        let descriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data ?? Data()
        // Revalidate the layout just before opening a manual/custom candidate.
        let current = Candidate(device: device, reader: self)
        if candidate.builtIn {
            guard current.builtIn else { return }
        } else {
            guard let original = candidate.profile, let verified = current.profile,
                  original.matches(verified) else { return }
        }
        let supported = XiaomiDigitizer.supports(descriptor)
        let result = IOHIDDeviceOpen(device, 0)
        guard result == kIOReturnSuccess else {
            status(String(format: "设备打开失败 0x%08x；检查输入监控权限后重新启动", result))
            return
        }
        let deviceContext = DeviceContext(device: device, reader: self, supported: supported)
        devices.append(deviceContext)
        registerReports(deviceContext)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        status(supported ? candidate.name + String(format: "（%04x:%04x）；笔描述符匹配", candidate.vendorID, candidate.productID)
                         : "未知描述符：仅诊断，禁止输出鼠标事件")
        devicesChanged()
    }

    private func registerReports(_ deviceContext: DeviceContext) {
        let device = deviceContext.device
        IOHIDDeviceRegisterInputReportCallback(device, deviceContext.buffer, 4096, {
            context, result, _, _, reportID, bytes, length in
            guard let context else { return }
            let reader = Unmanaged<HIDReader>.fromOpaque(context).takeUnretainedValue()
            // A queued callback may outlive a closed/reselected DeviceContext. Resolve only a
            // currently owned buffer; never dereference a released context from an old callback.
            guard let d = reader.devices.first(where: { $0.buffer == bytes }) else { return }
            guard result == kIOReturnSuccess, length > 0, length <= 4096 else {
                d.reader.disconnected(); return
            }
            d.reader.reports += 1
            let data = Array(UnsafeBufferPointer(start: bytes, count: length))
            if d.reader.diagnosticsEnabled {
                d.reader.lastBytes = data
                d.reader.lastReportID = reportID
            }
            let decoded = d.supported ? XiaomiDigitizer.decode(data, reportID: reportID) : nil
            if d.reader.diagnosticsEnabled {
                d.reader.penCapture?.receive(at: ProcessInfo.processInfo.systemUptime, reportID: reportID, bytes: data, sample: decoded)
            }
            d.reader.measurement?.receive(at: ProcessInfo.processInfo.systemUptime, sample: decoded)
            guard let sample = decoded else { return }
            d.reader.decoded += 1
            if !sample.positionValid { d.reader.resetReports += 1 }
            d.reader.sample(sample)
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Exclusive access applies only to the known pen interface while control is enabled.
    /// Pausing restores native handling; the keyboard/mouse interface is never seized.
    @discardableResult func setExclusive(_ desired: Bool) -> Bool {
        guard devices.count == 1, let d = devices.first, d.supported else { return !desired }
        if d.exclusive == desired { return true }
        IOHIDDeviceUnscheduleFromRunLoop(d.device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDDeviceRegisterInputReportCallback(d.device, d.buffer, 4096, nil, nil)
        IOHIDDeviceClose(d.device, 0)
        let result = IOHIDDeviceOpen(d.device, desired ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice) : 0)
        d.exclusive = desired && result == kIOReturnSuccess
        if result != kIOReturnSuccess {
            let fallback = IOHIDDeviceOpen(d.device, 0)
            status(String(format: "笔接口切换失败 0x%08x（诊断恢复：0x%08x），控制未启用", result, fallback))
        }
        registerReports(d)
        IOHIDDeviceScheduleWithRunLoop(d.device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        return result == kIOReturnSuccess
    }

    private func detach(_ device: IOHIDDevice) {
        guard let index = devices.firstIndex(where: { CFEqual($0.device, device) }) else { return }
        let d = devices[index]
        IOHIDDeviceUnscheduleFromRunLoop(d.device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDDeviceRegisterInputReportCallback(d.device, d.buffer, 4096, nil, nil)
        IOHIDDeviceClose(d.device, 0)
        devices.remove(at: index)
        disconnected()
        status("平板已断开，已释放鼠标")
        devicesChanged()
    }

    func stop() {
        guard running else { return }
        for d in Array(devices) { detach(d.device) }
        candidates.removeAll(); manualID = nil
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, 0)
        running = false
    }
}
