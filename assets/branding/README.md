# 当前图标（v8）

无品牌标志的橙色平板、白色笔迹及触控笔，线缆连接带刘海的笔记本；笔记本内为输入画布与橙色轨迹。

- `mipad2mac-logo-v8.svg`：完整白底可编辑源稿。
- `mipad2mac-app-icon-v8.svg`：白色圆角底及透明外边缘的 ICNS 源稿。
- `mipad2mac-app-icon-v8.png`：经视觉检查的 1024 像素渲染，构建直接使用。

修改 SVG 后可用 Inkscape 导出 PNG，再检查小尺寸效果：

```sh
inkscape assets/branding/mipad2mac-app-icon-v8.svg --export-type=png --export-filename=assets/branding/mipad2mac-app-icon-v8.png --export-width=1024 --export-height=1024
bash scripts/build-icon.sh
```

目前是传统 ICNS，不是 Icon Composer 分层图标。旧稿仅保留在本地设计历史，不进入公开源码快照。
