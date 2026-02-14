# TicTracker

轻量级 macOS 菜单栏计数工具。快捷键记录，日报提醒，周报汇总。

<p align="center">
  <img src="image/menubar.png" width="320" alt="菜单栏主界面" />
  &nbsp;&nbsp;
  <img src="image/settings.png" width="320" alt="设置界面" />
</p>

## 功能

- 菜单栏常驻，点击即用
- 自定义项目分类，按项目计数
- 全局快捷键快速 +1（修饰键可自定义）
- 快捷键快速日报弹窗（修饰键+0）
- 日期切换，回看和编辑历史数据
- 每日小记，支持 Markdown
- 本周趋势图 — 按项目堆叠彩色柱状图，点击查看明细
- 连续打卡天数
- 日期范围项目统计视图（Swift Charts）
- 每日提醒写日报
- 一键复制周报汇总
- 数据导入 / 导出（JSON、CSV）
- RSS 订阅监控
- 开机自动启动

## 系统要求

- macOS 14.0+（Sonoma），macOS 15+ 体验更佳
- Swift 6.0+

## 构建

```bash
# 编译并打包为 .app
bash build.sh

# 启动
open TicTracker.app
```

脚本会自动完成 release 编译、组装 .app bundle、ad-hoc 签名。

## 快捷键

默认修饰键为 `⌃⇧`，可在设置中更改为 `⌘⇧` / `⌥⇧` / `⌃⌥` / `⌘⌃`。

| 快捷键 | 功能 |
|--------|------|
| `修饰键+1` | 第 1 个项目 +1 |
| `修饰键+2` | 第 2 个项目 +1 |
| ... | 最多支持 9 个项目 |
| `修饰键+0` | 打开快速日报弹窗 |

## 数据存储

数据保存在 `UserDefaults`，包括项目列表、每日计数和小记。支持 JSON / CSV 导出备份。

## License

MIT
