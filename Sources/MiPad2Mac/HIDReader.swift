import Foundation
import IOKit.hid
import MiPadCore

final class HIDReader {
    private var manager = IOHIDManagerCreate(kCFAllocatorDefault, IOHIDManagerOptions.independentDevices.rawValue)
    private var devices: [DeviceContext] = []
    var status: (String) -> Void = { print($0) }
    var sample: (Sample) -> Void = { _ in }
    var disconnected: () -> Void = {}
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
        // Match only Xiaomi's digitizer. Never open its keyboard collection or the Mac keyboard.
        let match: [String: Any] = [kIOHIDVendorIDKey: 0x2717, kIOHIDProductIDKey: 0x2d05,
                                  kIOHIDPrimaryUsagePageKey: 0x0d, kIOHIDPrimaryUsageKey: 0x02]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HIDReader>.fromOpaque(context).takeUnretainedValue().attach(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let reader = Unmanaged<HIDReader>.fromOpaque(context).takeUnretainedValue()
            reader.detach(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, 0)
        running = true
        status("HID manager: \(result == 0 ? "已打开" : String(format: "0x%08x", result))")
    }

    private func attach(_ device: IOHIDDevice) {
        guard !devices.contains(where: { CFEqual($0.device, device) }) else { return }
        let descriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data ?? Data()
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
        status(supported ? "已连接 Xiaomi 数位笔接口；描述符匹配" : "未知描述符：仅诊断，禁止输出鼠标事件")
    }

    private func registerReports(_ deviceContext: DeviceContext) {
        let device = deviceContext.device
        IOHIDDeviceRegisterInputReportCallback(device, deviceContext.buffer, 4096, {
            context, result, _, _, reportID, bytes, length in
            guard let context else { return }
            let d = Unmanaged<DeviceContext>.fromOpaque(context).takeUnretainedValue()
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
        }, Unmanaged.passUnretained(deviceContext).toOpaque())
    }

    /// Exclusive access applies only to the known pen interface while control is enabled.
    /// Pausing restores native handling; the keyboard/mouse interface is never seized.
    @discardableResult func setExclusive(_ desired: Bool) -> Bool {
        guard devices.count == 1, let d = devices.first, d.supported else { return !desired }
        if d.exclusive == desired { return true }
        IOHIDDeviceUnscheduleFromRunLoop(d.device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
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
        IOHIDDeviceClose(d.device, 0)
        devices.remove(at: index)
        disconnected()
        status("平板已断开，已释放鼠标")
    }

    func stop() {
        guard running else { return }
        for d in Array(devices) { detach(d.device) }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, 0)
        running = false
    }
}
