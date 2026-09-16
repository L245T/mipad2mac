import AppKit
import IOKit.hid

/// Target-device-only, bounded input report capture. No SET_REPORT or USB claiming.
final class HIDMonitor: NSObject, NSWindowDelegate {
    private var manager: IOHIDManager?
    private var contexts: [Context] = []
    private var records: [[String: Any]] = []
    private var inventory: [[String: Any]] = []
    private var usb: [[String: Any]] = []
    private var counts: [String: Int] = [:]
    private var bytesStored = 0
    private var dropped = 0
    private var started = 0.0
    private var startedDate = ""
    private var captureSeconds = 0.0
    private var timer: Timer?
    private var phase = "idle"
    private(set) var running = false
    var onFinish: () -> Void = {}
    var onStart: () -> Void = {}
    private var window: NSWindow?
    private let label = NSTextField(wrappingLabelWithString: "")
    private let details = NSTextField(wrappingLabelWithString: "")
    private let beginButton = NSButton(title: "开始分段监控（45 秒）", target: nil, action: nil)
    private let exportButton = NSButton(title: "导出诊断…", target: nil, action: nil)
    private final class Context {
        let device: IOHIDDevice
        let id: Int
        let capacity: Int
        let buffer: UnsafeMutablePointer<UInt8>
        unowned let owner: HIDMonitor
        init(_ device: IOHIDDevice, id: Int, capacity: Int, owner: HIDMonitor) {
            self.device = device; self.id = id; self.capacity = capacity; self.owner = owner
            buffer = .allocate(capacity: capacity)
        }
        deinit { buffer.deallocate() }
    }
    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 490), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "平板 USB / HID 分段监控"; w.isReleasedWhenClosed = false; w.delegate = self
            let note = NSTextField(wrappingLabelWithString: "仅监控 Xiaomi 2717:2d05 的 HID 输入，不是完整 USB 总线抓包。会记录该设备复合键盘接口的原始报文；测试期间请不要使用平板键盘输入私人内容。不会读取 Mac 键盘、发送设备命令或接管 USB。\n\n开始后：0–5 秒不操作；5–25 秒只用手指点按、单指/双指滑动（笔远离屏幕）；25–40 秒只用笔画圈、轻点；40–45 秒再次静置。")
            beginButton.target = self; beginButton.action = #selector(start)
            exportButton.target = self; exportButton.action = #selector(export)
            exportButton.isEnabled = false
            let stop = NSButton(title: "停止", target: self, action: #selector(stopClicked))
            let row = NSStackView(views: [beginButton, stop, exportButton]); row.spacing = 12
            let stack = NSStackView(views: [note, row, label, details])
            stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 20
            stack.translatesAutoresizingMaskIntoConstraints = false
            w.contentView!.addSubview(stack)
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: w.contentView!.topAnchor, constant: 24), note.widthAnchor.constraint(equalTo: stack.widthAnchor), label.widthAnchor.constraint(equalTo: stack.widthAnchor), details.widthAnchor.constraint(equalTo: stack.widthAnchor)])
            details.isSelectable = true; w.center(); window = w
        }
        window?.makeKeyAndOrderFront(nil)
    }
    @objc private func start() {
        guard !running else { return }
        onStart()
        records = []; inventory = []; counts = [:]; bytesStored = 0; dropped = 0; captureSeconds = 0
        usb = usbInventory()
        started = ProcessInfo.processInfo.systemUptime
        startedDate = ISO8601DateFormatter().string(from: Date())
        running = true; beginButton.isEnabled = false; exportButton.isEnabled = false
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOHIDManagerOptions.independentDevices.rawValue)
        manager = m
        IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: 0x2717, kIOHIDProductIDKey: 0x2d05] as CFDictionary)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue().attach(device)
        }, pointer)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { context, _, _, device in
            guard let context else { return }
            let owner = Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue()
            if let c = owner.contexts.first(where: { CFEqual($0.device, device) }) {
                owner.inventory[c.id]["removedAtSeconds"] = ProcessInfo.processInfo.systemUptime - owner.started
            }
        }, pointer)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(m, 0)
        details.stringValue = String(format: "管理器打开结果 0x%08x", result)
        tick()
        timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }
    private func phaseAt(_ elapsed: Double) -> String {
        if elapsed < 5 { return "baseline" }
        if elapsed < 25 { return "finger" }
        if elapsed < 40 { return "pen" }
        return "rest"
    }
    private func tick() {
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        if elapsed >= 45 { stop(); return }
        phase = phaseAt(elapsed)
        let names = ["baseline": "静置，不要操作", "finger": "只用手指操作，笔远离屏幕", "pen": "只用笔画圈、轻点", "rest": "再次静置"]
        label.stringValue = "剩余 \(Int(ceil(45 - elapsed))) 秒：\(names[phase] ?? phase)"
        details.stringValue = "发现 HID 接口 \(inventory.count) · 已打开 \(contexts.count) · 保存 \(records.count) 条 · 丢弃 \(dropped) 条\n" + counts.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "  ")
    }
    private func attach(_ device: IOHIDDevice) {
        guard running, !contexts.contains(where: { CFEqual($0.device, device) }) else { return }
        let id = inventory.count
        var entry: [String: Any] = ["interface": id]
        for key in [kIOHIDPrimaryUsagePageKey, kIOHIDPrimaryUsageKey, kIOHIDMaxInputReportSizeKey, kIOHIDTransportKey] {
            if let value = IOHIDDeviceGetProperty(device, key as CFString) { entry[key] = value }
        }
        let descriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data ?? Data()
        entry["descriptorHex"] = descriptor.map { String(format: "%02x", $0) }.joined()
        let elements = IOHIDDeviceCopyMatchingElements(device, nil, 0) as? [IOHIDElement] ?? []
        entry["elements"] = elements.map { e -> [String: Any] in
            ["type": IOHIDElementGetType(e).rawValue, "page": IOHIDElementGetUsagePage(e), "usage": IOHIDElementGetUsage(e), "reportID": IOHIDElementGetReportID(e), "bits": IOHIDElementGetReportSize(e), "count": IOHIDElementGetReportCount(e), "min": IOHIDElementGetLogicalMin(e), "max": IOHIDElementGetLogicalMax(e)]
        }
        let result = IOHIDDeviceOpen(device, 0)
        entry["openResult"] = String(format: "0x%08x", result)
        inventory.append(entry)
        guard result == kIOReturnSuccess else { return }
        let capacity = max(4096, min(65536, (entry[kIOHIDMaxInputReportSizeKey] as? NSNumber)?.intValue ?? 4096))
        let c = Context(device, id: id, capacity: capacity, owner: self); contexts.append(c)
        IOHIDDeviceRegisterInputReportCallback(device, c.buffer, capacity, { context, result, _, type, reportID, bytes, length in
            guard let context else { return }
            let c = Unmanaged<Context>.fromOpaque(context).takeUnretainedValue()
            let owner = c.owner
            guard owner.running else { return }
            let elapsed = ProcessInfo.processInfo.systemUptime - owner.started
            guard elapsed < 45 else { return }
            guard result == kIOReturnSuccess, length >= 0, length <= c.capacity else { owner.dropped += 1; return }
            let phase = owner.phaseAt(elapsed)
            let key = "\(phase)/接口\(c.id)/ID\(reportID)"
            owner.counts[key, default: 0] += 1
            guard owner.records.count < 20000, owner.bytesStored + length <= 8 * 1024 * 1024 else { owner.dropped += 1; return }
            owner.bytesStored += length
            let data = Data(bytes: bytes, count: length)
            owner.records.append(["seconds": elapsed, "phase": phase, "interface": c.id, "reportID": reportID, "type": type.rawValue, "bytes": data])
        }, Unmanaged.passUnretained(c).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    }
    @objc private func stopClicked() { stop() }
    func stop() {
        guard running else { return }
        captureSeconds = ProcessInfo.processInfo.systemUptime - started
        running = false; timer?.invalidate(); timer = nil
        for c in contexts {
            IOHIDDeviceUnscheduleFromRunLoop(c.device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDDeviceClose(c.device, 0)
        }
        contexts.removeAll()
        if let m = manager {
            IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(m, 0)
        }
        manager = nil
        label.stringValue = "监控已停止（\(Int(ProcessInfo.processInfo.systemUptime - started)) 秒）。保存 \(records.count) 条，丢弃 \(dropped) 条。可导出后分析。"
        beginButton.isEnabled = true; exportButton.isEnabled = true
        onFinish()
    }
    @objc private func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "MiPad-HID-\(Int(Date().timeIntervalSince1970)).json"
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            var rows = self.records
            for i in rows.indices {
                if let data = rows[i].removeValue(forKey: "bytes") as? Data {
                    rows[i]["hex"] = data.map { String(format: "%02x", $0) }.joined(separator: " ")
                }
            }
            let payload: [String: Any] = ["schema": 1, "appVersion": appVersion, "started": self.startedDate, "captureSeconds": self.captureSeconds, "completed": self.captureSeconds >= 45, "scope": "Input reports only for 2717:2d05; not USB bus capture; phases are user instructions, not inferred source identities", "limits": "20000 reports / 8 MiB payload", "dropped": self.dropped, "usb": self.usb, "hid": self.inventory, "counts": self.counts, "reports": rows]
            do {
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: url, options: .atomic)
                self.label.stringValue = "已导出：\(url.lastPathComponent)"
            } catch { self.label.stringValue = "导出失败：\(error.localizedDescription)" }
        }
    }
    func windowWillClose(_ notification: Notification) { stop(); onFinish() }
    private func usbInventory() -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var entries: [[String: Any]] = []
        while true {
            let service = IOIteratorNext(iterator); if service == 0 { break }
            defer { IOObjectRelease(service) }
            let options = IOOptionBits(kIORegistryIterateParents | kIORegistryIterateRecursively)
            func inherited(_ key: String) -> Int? {
                (IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault, options) as? NSNumber)?.intValue
            }
            guard inherited("idVendor") == 0x2717, inherited("idProduct") == 0x2d05 else { continue }
            var row: [String: Any] = [:]
            for key in ["bInterfaceNumber", "bAlternateSetting", "bInterfaceClass", "bInterfaceSubClass", "bInterfaceProtocol", "bNumEndpoints"] {
                if let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber { row[key] = value }
            }
            entries.append(row)
        }
        return entries
    }
}
