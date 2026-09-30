import SwiftUI

/// A local illustration only: no permission APIs, system settings or input devices.
private final class PermissionDemoState: ObservableObject {
    @Published var phase = 0
    @Published var playing = false
    private var timer: Timer?
    func play() {
        stop(); phase = 0; playing = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.phase == 5 { self.stop(); return }
            withAnimation(.easeInOut(duration: 0.25)) { self.phase += 1 }
        }
    }
    func stop() { timer?.invalidate(); timer = nil; playing = false }
    deinit { timer?.invalidate() }
}

struct PermissionRecoveryDemo: View {
    @StateObject private var state = PermissionDemoState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let captions = ["选中MiPad2Mac，点“−”移除旧条目", "点“+”添加当前应用", "选择当前MiPad2Mac.app，点“打开”", "找到新添加的MiPad2Mac，开启右侧开关", "开关已开启，返回MiPad2Mac", "点“重新检查”，查看权限状态"]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("操作演示").font(.callout.weight(.semibold))
                Spacer(minLength: 8)
                if !reduceMotion {
                    Button(state.playing ? "重新播放" : (state.phase == 5 ? "重播" : "播放演示")) { state.play() }
                        .controlSize(.small)
                }
            }
            if reduceMotion {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach([0, 1, 2, 3, 5], id: \.self) { index in
                        Text(captions[index]).font(.callout)
                    }
                }
            } else {
                illustration
                    .frame(maxWidth: .infinity).frame(height: 86)
                    .padding(12)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
                    .allowsHitTesting(false).accessibilityHidden(true)
                Text(captions[state.phase]).id(state.phase).font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("示意演示，不会更改系统权限。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .onDisappear { state.stop() }
        .onChange(of: reduceMotion) { value in
            if value { state.stop() }
        }
    }
    @ViewBuilder private var illustration: some View {
        if state.phase == 2 {
            HStack(spacing: 10) {
                Image(systemName: "app").font(.title2).foregroundStyle(Color.accentColor)
                Text("MiPad2Mac.app").font(.callout).lineLimit(1)
                Spacer(minLength: 8)
                Button("打开") {}.buttonStyle(.borderedProminent).controlSize(.small)
            }.transition(.opacity)
        } else if state.phase == 5 {
            HStack {
                Text("权限检查").font(.callout)
                Spacer(minLength: 8)
                Button("重新检查") {}.buttonStyle(.borderedProminent).controlSize(.small)
            }.transition(.opacity)
        } else {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    if state.phase != 1 {
                        Image(systemName: "app").foregroundStyle(Color.accentColor)
                        Text("MiPad2Mac").font(.callout)
                        Spacer(minLength: 8)
                        Toggle("权限开关", isOn: .constant(state.phase == 0 || state.phase == 4))
                            .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    } else {
                        Text("尚未添加应用").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                    }
                }.padding(8)
                    .background(state.phase == 0 ? Color.accentColor.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6))
                HStack(spacing: 8) {
                    demoButton("+", highlighted: state.phase == 1)
                    demoButton("−", highlighted: state.phase == 0)
                    Spacer()
                }
            }.transition(.opacity)
        }
    }
    private func demoButton(_ title: String, highlighted: Bool) -> some View {
        Button(title) {}.controlSize(.small)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(highlighted ? Color.accentColor : Color.clear, lineWidth: 2))
    }
}
