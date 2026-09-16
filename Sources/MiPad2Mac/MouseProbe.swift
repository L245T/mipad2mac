import Foundation
import IOKit.hid

/// A bounded diagnostic for the tablet's composite keyboard/mouse interface.
/// Match only Report 2 mouse elements; keyboard elements and raw reports are never subscribed to.
final class MouseProbe {
    private var manager: IOHIDManager?
    private var devices: [IOHIDDevice] = []
    private var timer: Timer?
    var status: (String) -> Void = { _ in }
    private(set) var running = false
    private(set) var changes = 0
    func start() {
        stop()
        changes = 0; running = true
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOHIDManagerOptions.independentDevices.rawValue)
        self.manager = manager
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x2717, kIOHIDProductIDKey: 0x2d05,
                                               kIOHIDPrimaryUsagePageKey: 1, kIOHIDPrimaryUsageKey: 6] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<MouseProbe>.fromOpaque(context).takeUnretainedValue().attach(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        _ = IOHIDManagerOpen(manager, 0)
        status("检测 15 秒：请把笔移开，只用手指点按和滑动平板。")
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            guard let self else { return }
            let opened = !self.devices.isEmpty
            self.stop()
            self.status(opened ? "检测结束：鼠标字段变化 \(self.changes) 次。此检测只覆盖鼠标通路，不代表所有手指通路。" : "检测未完成：鼠标接口未打开，请检查输入监控权限。")
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    private func attach(_ device: IOHIDDevice) {
        guard running, !devices.contains(where: { CFEqual($0, device) }) else { return }
        let criteria = [(1, 0x30), (1, 0x31), (1, 0x38), (9, 1), (9, 2), (9, 3)].map { page, usage in
            [kIOHIDElementUsagePageKey: page, kIOHIDElementUsageKey: usage]
        }
        let elements = IOHIDDeviceCopyMatchingElements(device, nil, 0) as? [IOHIDElement] ?? []
        let mouseElements = elements.filter {
            let page = IOHIDElementGetUsagePage($0), usage = IOHIDElementGetUsage($0)
            return IOHIDElementGetReportID($0) == 2 && ((page == 1 && [0x30, 0x31, 0x38].contains(usage)) || (page == 9 && (1...3).contains(usage)))
        }
        guard !mouseElements.isEmpty else { status("接口中未找到匹配的鼠标字段，不能据此判断手指无数据。"); return }
        IOHIDDeviceSetInputValueMatchingMultiple(device, criteria as CFArray)
        let result = IOHIDDeviceOpen(device, 0)
        guard result == kIOReturnSuccess else {
            status(String(format: "鼠标检测接口无法打开：0x%08x；可能需要输入监控权限。", result))
            return
        }
        devices.append(device)
        status("鼠标接口已打开，匹配 \(mouseElements.count) 个字段。请只用手指操作。")
        IOHIDDeviceRegisterInputValueCallback(device, { context, result, _, value in
            guard let context, result == kIOReturnSuccess else { return }
            let probe = Unmanaged<MouseProbe>.fromOpaque(context).takeUnretainedValue()
            guard probe.running else { return }
            let e = IOHIDValueGetElement(value)
            let page = IOHIDElementGetUsagePage(e), usage = IOHIDElementGetUsage(e)
            guard IOHIDElementGetReportID(e) == 2,
                  (page == 1 && [0x30, 0x31, 0x38].contains(usage)) || (page == 9 && (1...3).contains(usage)) else { return }
            probe.changes += 1
            probe.status("检测中：鼠标字段变化 \(probe.changes) 次；请只用手指，避免笔干扰。")
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    }
    func stop(cancelled: Bool = false) {
        if cancelled && running { status("手指检测已取消；请重新运行完整的 15 秒检测。") }
        running = false; timer?.invalidate(); timer = nil
        for device in devices {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDDeviceClose(device, 0)
        }
        devices.removeAll()
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, 0)
        }
        manager = nil
    }
}
