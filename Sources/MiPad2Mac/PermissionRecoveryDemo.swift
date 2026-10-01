import AppKit
import SwiftUI

/// Local illustration only: never invokes permission, settings or input APIs.
private final class PermissionDemoState: ObservableObject {
    @Published private(set) var tick = 0
    @Published private(set) var playing = false
    private var timer: Timer?
    private var presented = false
    private var visible = false
    private var reducedMotion = false
    private var wantsPlayback = true
    var phase: Int { tick / 3 }
    var actionPerformed: Bool { tick % 3 == 2 }
    var completed: Bool { tick == 14 && !playing }

    func appear(reducedMotion: Bool) {
        presented = true; self.reducedMotion = reducedMotion; synchronizeTimer()
    }
    func disappear() { presented = false; invalidateTimer() }
    func setVisible(_ value: Bool) {
        guard visible != value else { return }; visible = value; synchronizeTimer()
    }
    func setReducedMotion(_ value: Bool) { reducedMotion = value; synchronizeTimer() }
    func pause() { wantsPlayback = false; invalidateTimer() }
    func resume() { wantsPlayback = true; synchronizeTimer() }
    func restart() { invalidateTimer(); tick = 0; wantsPlayback = true; synchronizeTimer() }
    private func synchronizeTimer() {
        guard presented, visible, !reducedMotion, wantsPlayback, tick < 14 else {
            invalidateTimer(); return
        }
        guard timer == nil else { return }
        playing = true
        let timer = Timer(timeInterval: 0.95, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tick += 1
            if self.tick == 14 { self.wantsPlayback = false; self.invalidateTimer() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func invalidateTimer() { timer?.invalidate(); timer = nil; if playing { playing = false } }
    deinit { timer?.invalidate() }
}

struct PermissionRecoveryDemo: View {
    @StateObject private var state = PermissionDemoState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let captions = [
        "选中MiPad2Mac，点“−”移除旧条目。",
        "点“＋”添加应用。",
        "选择当前安装的MiPad2Mac.app，点“打开”。",
        "开启新条目右侧的开关。",
        "返回MiPad2Mac，点“重新检查”查看权限状态。"
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("操作演示").font(.callout.weight(.semibold))
                Spacer(minLength: 8)
                if !reduceMotion {
                    Button(state.playing ? "暂停" : (state.completed ? "已结束" : "继续")) {
                        if state.playing { state.pause() } else { state.resume() }
                    }.disabled(state.completed).controlSize(.small)
                    Button("重播") { state.restart() }.controlSize(.small)
                }
            }
            if reduceMotion {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(captions.indices, id: \.self) { index in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1).").monospacedDigit().frame(width: 18, alignment: .leading)
                            Text(captions[index]).fixedSize(horizontal: false, vertical: true)
                        }.font(.callout)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ForEach(captions.indices, id: \.self) { index in
                        Text("\(index + 1)").font(.caption.weight(.semibold)).monospacedDigit()
                            .frame(width: 22, height: 22)
                            .foregroundStyle(index == state.phase ? Color.white : Color.secondary)
                            .background(index == state.phase ? Color.accentColor : Color.secondary.opacity(0.12), in: Circle())
                    }
                    Spacer(minLength: 0)
                    Text("\(state.phase + 1) / \(captions.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }.accessibilityElement(children: .ignore)
                    .accessibilityLabel("第\(state.phase + 1)步，共\(captions.count)步")
                illustration
                    .frame(maxWidth: .infinity).frame(height: 112)
                    .padding(12)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
                    .overlayPreferenceValue(DemoTargetBounds.self) { anchors in
                        GeometryReader { geometry in
                            if let anchor = anchors[cursorTarget] {
                                let bounds = geometry[anchor]
                                demoCursor
                                    .position(x: bounds.midX + 7, y: bounds.midY + 9)
                                    .animation(.easeInOut(duration: 0.42), value: state.tick)
                            }
                        }
                    }
                    .background(PermissionDemoVisibility { state.setVisible($0) })
                    .allowsHitTesting(false).accessibilityHidden(true)
                Text("\(state.phase + 1). \(captions[state.phase])").id(state.phase).font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("示意演示，不会更改系统权限。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .onAppear { state.appear(reducedMotion: reduceMotion) }
        .onDisappear { state.disappear() }
        .onChange(of: reduceMotion) { state.setReducedMotion($0) }
    }
    private var cursorTarget: DemoTarget {
        switch state.phase {
        case 0: return state.tick % 3 == 0 ? .row : .remove
        case 1: return .add
        case 2: return state.tick % 3 == 0 ? .file : .open
        case 3: return .toggle
        default: return .check
        }
    }
    private var demoCursor: some View {
        ZStack {
            Circle().stroke(Color.accentColor, lineWidth: 2).frame(width: 28, height: 28)
                .scaleEffect(state.actionPerformed ? 1.2 : 0.6)
                .opacity(state.actionPerformed ? 0.8 : 0)
            Image(systemName: "cursorarrow").font(.system(size: 20)).foregroundStyle(.black)
                .shadow(color: .white, radius: 1).shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        }.frame(width: 32, height: 32)
    }
    @ViewBuilder private var illustration: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.phase == 2 ? "选择当前应用" : (state.phase == 4 ? "MiPad2Mac · 权限检查" : "系统设置 · 相应权限项"))
                .font(.caption).foregroundStyle(.secondary)
            if state.phase == 2 {
                HStack(spacing: 10) {
                    Image(systemName: "app").font(.title2).foregroundStyle(Color.accentColor)
                    Text("MiPad2Mac.app").font(.callout).lineLimit(1)
                    Spacer(minLength: 8)
                    Button("打开") {}.buttonStyle(.borderedProminent).controlSize(.small).demoTarget(.open)
                }.padding(8).background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6)).demoTarget(.file)
            } else if state.phase == 4 {
                HStack {
                    Text("权限检查").font(.callout)
                    Spacer(minLength: 8)
                    Button("重新检查") {}.buttonStyle(.borderedProminent).controlSize(.small).demoTarget(.check)
                }.padding(8)
            } else {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        if state.phase == 1 || (state.phase == 0 && state.actionPerformed) {
                            Text("尚未添加应用").font(.callout).foregroundStyle(.secondary)
                            Spacer()
                        } else {
                            Image(systemName: "app").foregroundStyle(Color.accentColor)
                            Text("MiPad2Mac").font(.callout)
                            Spacer(minLength: 8)
                            Toggle("权限开关", isOn: .constant(state.phase == 0 || state.actionPerformed))
                                .labelsHidden().toggleStyle(.switch).controlSize(.mini).demoTarget(.toggle)
                        }
                    }.padding(8)
                        .background(state.phase == 0 ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .demoTarget(.row)
                    HStack(spacing: 0) {
                        Button {} label: { Image(systemName: "plus").frame(width: 24, height: 22) }.demoTarget(.add)
                        Divider().frame(height: 16)
                        Button {} label: { Image(systemName: "minus").frame(width: 24, height: 22) }.demoTarget(.remove)
                        Spacer(minLength: 0)
                    }.buttonStyle(.borderless).controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private enum DemoTarget: Hashable { case row, remove, add, file, open, toggle, check }
private struct DemoTargetBounds: PreferenceKey {
    static var defaultValue: [DemoTarget: Anchor<CGRect>] = [:]
    static func reduce(value: inout [DemoTarget: Anchor<CGRect>], nextValue: () -> [DemoTarget: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
private extension View {
    func demoTarget(_ target: DemoTarget) -> some View {
        transformAnchorPreference(key: DemoTargetBounds.self, value: .bounds) { anchors, bounds in anchors[target] = bounds }
    }
}

/// orderOut/miniaturize/app hiding do not always remove a SwiftUI view from its hierarchy.
private struct PermissionDemoVisibility: NSViewRepresentable {
    let changed: (Bool) -> Void
    func makeNSView(context: Context) -> VisibilityView { VisibilityView(changed: changed) }
    func updateNSView(_ view: VisibilityView, context: Context) { view.changed = changed }
    final class VisibilityView: NSView {
        var changed: (Bool) -> Void
        private var observers: [NSObjectProtocol] = []
        private var clipObserver: NSObjectProtocol?
        private weak var observedClip: NSClipView?
        private var reportPending = false
        private var lastVisible: Bool?
        init(changed: @escaping (Bool) -> Void) { self.changed = changed; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); removeObservers()
            if let window {
                for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.report() })
                }
                for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: NSApp, queue: .main) { [weak self] _ in self?.report() })
                }
            }
            report()
        }
        override func layout() { super.layout(); report() }
        override func viewDidHide() { super.viewDidHide(); report() }
        override func viewDidUnhide() { super.viewDidUnhide(); report() }
        private func report() {
            guard !reportPending else { return }; reportPending = true
            // Avoid publishing during a SwiftUI update/layout pass; inspect the final layout.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.reportPending = false
                if let clip = self.enclosingScrollView?.contentView, clip !== self.observedClip {
                    if let token = self.clipObserver { NotificationCenter.default.removeObserver(token) }
                    self.observedClip = clip; clip.postsBoundsChangedNotifications = true
                    self.clipObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in self?.report() }
                }
                let inViewport = self.observedClip.map { $0.bounds.intersects($0.convert(self.bounds, from: self)) } ?? !self.visibleRect.isEmpty
                let visible = self.window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
                let value = visible && !NSApp.isHidden && !self.isHiddenOrHasHiddenAncestor && inViewport
                guard self.lastVisible != value else { return }; self.lastVisible = value
                self.changed(value)
            }
        }
        private func removeObservers() {
            observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
            if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
            clipObserver = nil; observedClip = nil
        }
        deinit { removeObservers() }
    }
}
