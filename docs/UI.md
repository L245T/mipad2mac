# 界面设计约定

MiPad2Mac 采用 macOS 系统设置式布局，优先使用公开原生组件，不依赖第三方 UI 框架。

## 结构与布局

- 主窗口使用 NSSplitViewController、原生侧栏和统一工具栏标题。侧栏固定 220 pt，不支持收起，不重复展示应用 Logo 与名称。品牌信息保留在关于页。
- 侧栏使用 SwiftUI List.sidebar 和 SF Symbols；控制使用 pencil，其他导航图标与文字保持统一尺寸和系统强调色。
- 五个页面使用 SwiftUI Form.grouped、Section、LabeledContent、Picker 和 Toggle，优先由系统管理行高、间距、控件宽度与滚动行为。
- 关联设置放在同一分组，标签在左、值或操作在右。长说明放在分组页脚或问号弹出说明中。
- 使用系统语义颜色；授权和运行状态同时保留文字，不只依赖颜色表达。
- 原生侧栏材质可在设置中关闭；尊重系统降低透明度偏好。不保证私有系统设置页面的逐像素复刻。

## 行为约束

展示层复用既有控制和权限操作。测试监控关闭时停止诊断刷新与新增日志，不停止正常笔输入读取。界面刷新复用已有低频定时器，高频 HID 报文不直接驱动界面重绘。

## 验证范围

已在 macOS 27 检查五个页面、监控开关、压力与倾斜开关、侧栏导航和关于页代码摘要。深色及辅助功能对比度完整矩阵、其他 macOS 版本仍待验证。UI 构建和自动化测试不代替平板输入与 Photoshop 端到端验收。

## 官方参考

- [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
- [SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)
- [Branding](https://developer.apple.com/design/human-interface-guidelines/branding)
- [Build an AppKit app with the new design](https://developer.apple.com/videos/play/wwdc2025/310/)
