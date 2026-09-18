# 界面设计约定

MiPad2Mac 采用 macOS 系统设置式布局，优先使用公开原生组件，不依赖第三方 UI 框架。

## 结构与布局

- 主窗口使用 NSSplitViewController、原生侧栏和统一工具栏标题。侧栏固定 220 pt，不支持收起，不重复展示应用 Logo 与名称。品牌信息保留在关于页。
- 侧栏使用 AppKit NSTableView 和 SF Symbols；控制使用 pencil。选中行采用系统 controlAccentColor，失焦采用 unemphasizedSelectedContentBackgroundColor；圆角 9 pt、行高 32 pt，保留原生键盘导航与无障碍语义。
- 五个页面共享 SettingsSection 分组、LabeledContent、原生菜单和 NSSwitch。右侧承载视图约束到 NSWindow.contentLayoutGuide 下方并裁切，滚动内容不会穿过标题栏；滚动条由系统 ScrollView 管理，遵循系统显示偏好。
- 页面标题与正文标签共用右侧起点 30 pt（20 pt 外边距 + 10 pt 行内边距）。控制状态与连接操作统一放在首组，成功状态不再在底部重复；等待或失败时在首组保留原因。
- 关联设置放在同一分组，标签在左、值或操作在右。长说明放在分组页脚或问号弹出说明中。
- 状态和选中颜色使用系统语义颜色；分组底色按参考图校准为浅色白度 0.965 / 深色 0.18，并提供增强对比度变体。授权和运行状态同时保留文字，不只依赖颜色表达。原生处理状态为红色建议；只有已启用才显示绿色，等待或失败为橙色。状态旁问号展开当前处理方式的说明，并提供独立的无障碍名称。
- 原生侧栏材质可在设置中关闭；尊重系统降低透明度偏好。不保证私有系统设置页面的逐像素复刻。

## 说明文字层级

- 设置项名称沿用系统正文字体与主要文字颜色；名称下的补充说明统一使用 callout 和 secondary 语义颜色，左对齐、间隔 3 pt，自然换行，不固定行数。
- 同一规则用于透明侧栏、压力与倾斜、测试监控等两行设置项；组外说明仍使用 footnote。错误与操作前提不降为装饰性说明。
- 根据 Apple 的 Typography 和 Labels 指南区分信息层级，避免通过调低整个控件透明度处理说明文字；保留深色模式的语义颜色适配。
- 应用包声明 zh-Hans 本地化，原生右键菜单与保存面板由 macOS 提供中文文案，不修改用户系统语言。

## 长按右键帮助

“长按右键帮助…”位于笔输入设置组下方，采用文字链接按钮，不独占组内设置行。“长按右键”和“长按时间”保持相邻。帮助使用原生 sheet，分段控件切换“排查步骤”和“兼容设置”。标题、分段控件与底部完成按钮固定，正文独立滚动；Escape 关闭。默认尺寸 560×580 pt 为项目布局选择，不是 Apple 强制数值。

排查说明分为触发条件、浏览器扩展、进一步排查三组。兼容页复用原生 NSSwitch 和设置分组；所选应用按行显示，移除按钮右对齐，添加按钮位于名单底部。空名单提供明确说明；关闭兼容选项仍可管理名单，不清空已有配置。静态网页注意事项保留完整文字与强调样式，不仅依赖警告颜色。

本轮在 macOS 27 浅色模式检查两页、空名单与 Chrome 名单、添加/移除和开关操作。深色、增强对比度、多应用长名单仍待检查；此布局验证不代表实体笔兼容效果通过。

控制页虚拟按键状态按用户要求显示“研发中”；手指输入作为与笔输入同级的分组，状态显示“研发中”。这些状态仅为界面文案，不代表已有输入实现或验收结果。

## 行为约束

展示层复用既有控制和权限操作。测试监控关闭时停止诊断刷新与新增日志，不停止正常笔输入读取。界面刷新复用已有低频定时器，高频 HID 报文不直接驱动界面重绘。

## 页面与尺寸

默认窗口 780×700 pt，最小 720×580 pt；侧栏 220 pt、正文最小 480 pt 是当前工程参数，不是 Apple 强制规范。正文四周 20 pt；组间 22 pt；组内行垂直内边距 9 pt、水平 10 pt；分组圆角 12 pt。这些是依据用户参考图确定的项目参数，不是 Apple 公布的强制值。下拉菜单按内容宽度收缩、右对齐；开关采用 NSSwitch.regular 的固有尺寸，不拉伸或缩放。

| 页面 | 内容 |
| --- | --- |
| 控制 | 处理方式、状态、目标显示器、方向、压力与倾斜、连接操作 |
| 权限检查 | 控制与输入监控状态、分别申请、重新检查 |
| 测试 | 监控开关、验收窗口、输入输出、速率、限时采集、记录与导出 |
| 设置 | 侧栏材质、关闭行为、登录自启动 |
| 关于 | 图标与身份信息并排、代码摘要、项目、更新渠道（稳定版/Beta）、检查更新和赞助 |

不增加无业务用途的搜索、前进后退或品牌标题。关于页保留应用图标。按钮禁用仍采用系统样式，并用文字说明前提或当前状态。

## 验证范围

已在 macOS 27 检查五个页面、侧栏激活高亮以及滚动到底部时的标题裁切、监控开关、压力与倾斜开关、侧栏导航和关于页代码摘要。深色及辅助功能对比度完整矩阵、其他 macOS 版本仍待验证。UI 构建和自动化测试不代替平板输入与 Photoshop 端到端验收。

## 官方参考

- [Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- [Labels](https://developer.apple.com/design/human-interface-guidelines/labels)

- [Window content layout](https://developer.apple.com/documentation/appkit/nswindow/contentlayoutguide)
- [Color](https://developer.apple.com/design/human-interface-guidelines/color)
- [Buttons and contextual help](https://developer.apple.com/design/human-interface-guidelines/buttons)
- [Toggles](https://developer.apple.com/design/human-interface-guidelines/toggles)
- [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
- [SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)
- [Branding](https://developer.apple.com/design/human-interface-guidelines/branding)
- [Build an AppKit app with the new design](https://developer.apple.com/videos/play/wwdc2025/310/)
