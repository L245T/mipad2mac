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

## 页面与尺寸

默认窗口 780×700 pt，最小 720×580 pt；侧栏 220 pt、正文最小 480 pt 是当前工程参数，不是 Apple 强制规范。原生表单负责实际行高与间距，不再沿用旧版手工卡片参数。

| 页面 | 内容 |
| --- | --- |
| 控制 | 处理方式、状态、目标显示器、方向、压力与倾斜、连接操作 |
| 权限检查 | 控制与输入监控状态、分别申请、重新检查 |
| 测试 | 监控开关、验收窗口、输入输出、速率、限时采集、记录与导出 |
| 设置 | 侧栏材质、关闭行为、登录自启动 |
| 关于 | 图标与身份信息并排、代码摘要、项目、更新渠道（稳定版/Beta）、检查更新和赞助 |

不增加无业务用途的搜索、前进后退或品牌标题。关于页保留应用图标。按钮禁用仍采用系统样式，并用文字说明前提或当前状态。

## 验证范围

已在 macOS 27 检查五个页面、监控开关、压力与倾斜开关、侧栏导航和关于页代码摘要。深色及辅助功能对比度完整矩阵、其他 macOS 版本仍待验证。UI 构建和自动化测试不代替平板输入与 Photoshop 端到端验收。

## 官方参考

- [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
- [SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)
- [Branding](https://developer.apple.com/design/human-interface-guidelines/branding)
- [Build an AppKit app with the new design](https://developer.apple.com/videos/play/wwdc2025/310/)
