# 公开源码与发布

公开仓库：https://github.com/L245T/mipad2mac

## 文件范围

上传源码、单元测试、产品通用 HID 描述符、包配置、MIT 许可证、必要说明、构建脚本和当前 v8 SVG/PNG 图标。

不上传本机路径或账户资料、原始诊断和系统日志、构建缓存、历史二进制、idea/协作记录，以及旧图标草稿。生成的 ICNS 和 DMG 不进入源码；经过审核的分发包可另行作为 Release 附件发布。

本地开发历史与公开源码历史分别保留；首次公开采用审查后的快照，不推送包含本机协作记录和旧素材的开发分支历史。

```sh
python3 scripts/export-source.py /tmp/mipad2mac-public-source
```

输出目录必须不存在。脚本使用明确清单，新增文件需人工审核后扩充；导出不等于自动发布。每次上传前检查差异及所有新增内容，扫描凭证、序列号和个人路径，不只依赖 `.gitignore`。

## 更新检查约定

应用从固定仓库 `/releases?per_page=100&page=N` 读取 Release 列表。默认稳定版渠道排除草稿、GitHub Pre-release 和带预发布后缀的标签；Beta 渠道包含正式版与预发布版，仍排除草稿。支持可选 v 前缀及 SemVer 预发布后缀、构建元数据，按版本优先级选择候选，不依赖 API 返回顺序。构建元数据不影响排序。

一次检查最多 10 页，每页 100 条、4 MiB，总计 10 MiB；有后续页但超过上限或任一页失败时，不使用不完整列表宣称最新。自动检查仍默认关闭，启用后各渠道每天最多一次；切换取消旧请求，旧回调不覆盖新渠道状态。下载入口使用具体 tag 页面。

仅有 Git 提交或标签不会产生更新提醒，需要创建已发布的 GitHub Release；预发布仅在 Beta 渠道被检查。升版时同步 `main.swift` 的回退版本、构建脚本的版本/构建号及 CHANGELOG；README 不必显示固定版本号。发布前运行测试、检查 UI、构建并验证 DMG。上传源码不代表已发布安装包。


使用 `v0.4.0-beta.1` 等标签时，包内应用版本也应使用匹配的语义版本以区分后续 Beta 和同号正式版。仅切换 GitHub Pre-release 标记或代码摘要不会使相同数字版本变成更新；不自动降级。本次新增渠道功能没有创建或修改线上 Release。

## 构建与发布节奏

日常修改和本地构建不自动提升数字版本或构建号。提交推送、升版、打标签和创建 Release 是分别授权的操作；用户要求“推送但不升版本”时，只提交推送审核后的修改。源码推送不代表安装包已发布。

App 只显示应用版本号，不嵌入源码摘要或 Git 提交编号。仅修改文档不触发构建。赞助原图位于 `assets/sponsor/`，README 与应用共用，不重绘二维码。

## 构建标识

App 保留 `CFBundleShortVersionString` 与原生数字构建号 `CFBundleVersion`，不写入 `MiPadSourceRevision` / `MiPadGitRevision`，关于页和日志不展示这两种摘要。

`scripts/source-revision.py` 与 `scripts/build-revision.py` 只作包外校验。前者计算 Package.swift、Swift 源码及应用图片的内容摘要；后者逐项比较实际输入和干净的公开参考仓库 HEAD。二者均不是二进制可复现性证明，也不能单独证明提交已经推送。

正式发布顺序：测试 → 本地提交 → 审查同步公开仓库并提交推送 → 核对远端及打包输入 → 构建 App 和 DMG → 验证后创建正式 Release。开发与公开历史分离时：

```sh
MIPAD_REVISION_REPO=/path/to/public-checkout MIPAD_REQUIRE_GIT_REVISION=1 bash scripts/build-dmg.sh
```

正式 DMG 命名为 `MiPad2Mac-<应用版本>.dmg`。需要制作 Beta 包时，在上述命令中增加 `MIPAD_BETA=1`；脚本要求输入匹配公开参考提交，且提交与 GitHub master 一致，然后使用至少 7 位公开短 SHA：

- 普通应用版本：`MiPad2Mac-0.5.0-beta.<公开短SHA>.dmg`。
- 已有 Beta 后缀：`MiPad2Mac-0.5.0-beta.1.<公开短SHA>.dmg`，不重复添加 beta。

校验文件为同名 `.dmg.sha256`，内容只含 SHA-256 和 DMG 文件名。短 SHA 取自公开提交，不取开发 main 或源码内容摘要。Beta 文件名不改变 App 版本和更新比较语义；若需要 Beta 迭代更新提醒，App 版本与 Release 标签仍须使用匹配的预发布版本号。

构建前后会重新核对输入，校验不替代共享写入互斥。发布版本、标签和附件需要明确授权；日常功能同步不自动发布 Release。

## 文档同步检查

- README 的页面入口、控件名称及能力范围应与当前源码一致；历史版本说明保留在 CHANGELOG，不将历史能力写成当前功能。
- UI 规范公开稿为 `docs/UI.md`；本地设计交接、用户参考截图、idea 和原始诊断不随公开文档上传。
- 导出脚本的清单已包含 `docs/UI.md`。该脚本只生成待审快照，不能代替本地与公开文件差异审查；保留公开仓库已有的构建脚本和文档差异。
- 本地开发历史与公开历史分别提交，不强推或用本地开发分支覆盖公开历史。

## DMG 安装窗口

打包使用 dmgbuild 1.6.7 写入 Finder 布局，Swift/AppKit 生成中英文均可清晰显示的双分辨率背景。左侧 App、右侧 Applications、中间箭头；安装说明位于下方。背景和布局自包含于映像，不依赖开发机路径，不通过 Finder UI 自动化排版。

首次准备：

```sh
python3 -m venv .build/dmg-tools
.build/dmg-tools/bin/pip install 'dmgbuild==1.6.7'
MIPAD_DMGBUILD="$PWD/.build/dmg-tools/bin/dmgbuild" bash scripts/build-dmg.sh
```

每次发布需挂载最终 DMG 目视核对背景、文字、图标位置和 Applications 入口；首次布局实施需验证复制。最终文件生成后再计算 SHA-256，上传后核对附件。Release 正文依次为更新内容、注意事项（如有）、下载与安装、第三方备用下载（国内下载）、末尾 SHA-256；工程验证记录不放入正文。

正式发布须完成安装窗口验收后再上传：窗口完整显示 App、方向箭头与 Applications 入口，安装说明可打开，复制出的 App 与包内内容及签名一致。Release 文案中的版本、附件名和 SHA-256 必须与最终产物相符。

## 独立打包目录

`MIPAD_OUTPUT_DIR` 可将 App 或 DMG 放入独立目录，默认仍为 `dist/`。使用 `MIPAD_APP_PATH` 指向已准备好的 MiPad2Mac.app 时，DMG 脚本不重新构建应用；它校验 Bundle ID，并拒绝覆盖该目录已有同名 DMG。

可用 `MIPAD_INSTALL_NOTES_FILE` 提供已审核的安装说明。说明必须符合当前包的真实验证状态，不从旧 Release 复制安全提示或发行结论。若后续还有会修改包字节的步骤，使用 `MIPAD_DEFER_CHECKSUM=1`，全部完成后再生成最终 SHA-256；中间产物不能作为最终分发包。

版本提交、源码推送和本地验证不代表 GitHub Release 已更新。各历史附件的状态以对应 Release 为准。
