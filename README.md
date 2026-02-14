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
- 每个项目可自定义独立快捷键组合（录制式设置）
- 快捷键快速日报弹窗（首个修饰键+0）
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

每个项目可在「设置 → 通用 → 快捷键」中单独录制快捷键组合（如 `⌃⇧1`、`⌘⌥A` 等）。
升级时会自动从旧版全局修饰键迁移。

| 操作 | 说明 |
|------|------|
| 点击录制框 → 按下组合键 | 为该项目绑定快捷键 |
| ✕ 按钮 | 清除该项目的快捷键 |
| 首个修饰键+0 | 打开快速日报弹窗 |

## 数据存储

数据保存在 `UserDefaults`，包括项目列表、每日计数和小记。支持 JSON / CSV 导出备份。

## License

MIT
