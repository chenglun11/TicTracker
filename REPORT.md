# 2026 年上半年代码工作报告 - chengun11

## 摘要

本报告基于 `chengun11 <lchnan7@outlook.com>` 在 2026-01-01 至 2026-06-30 期间的 Git 提交记录生成。默认 prompt 中的 2025 年范围在该仓库内没有记录，因此结合当前年中总结上下文，将分析范围调整为 2026 年上半年。

上半年该作者在 TechSupportTracker/TicTracker 项目中完成了从 macOS 菜单栏工具原型到多集成、多端协作工具的主要建设工作。代码贡献覆盖 macOS Swift 客户端、Jira/飞书/Linear 集成、AI 周报与 AI 对话、问题追踪、同步机制、服务端后台和报表工作区等多个方向。

年度关键词：**支持工作台产品化、问题追踪闭环、AI 与自动化提效**。

## 工作内容

### 1. TicTracker macOS 工具从 0 到 1 建设

项目从 `Initial commit: Tech Support Tracker macOS menu bar app` 开始，快速完成菜单栏应用、日报/日记记录、设置页、快捷键、通知、统计视图、最近记录、版本管理、打包和自动更新等基础能力。相关提交集中触达 `Sources/App.swift`、`Sources/MenuBarView.swift`、`Sources/DataStore.swift`、`Sources/RecentNotesView.swift`、`Sources/SettingsView.swift`、`Info.plist` 等核心文件。

这部分工作说明作者不只是做单点脚本，而是在构建一个长期可用的个人/团队支持工作台，涉及桌面应用交互、状态管理、本地存储、应用发布和日常使用体验。

### 2. 问题追踪与 Jira 集成能力建设

上半年多次围绕 Jira Server/DC、项目问题追踪、Bug 追踪模式、状态映射、评论同步、来源修正、已排期/测试中状态、经办人同步等方向迭代。相关模块包括 `Sources/JiraService.swift`、`Sources/JiraModels.swift`、`Sources/JiraView.swift`、`Sources/IssueModels.swift`、`Sources/IssueTrackerView.swift` 和 `Sources/WeeklyReport.swift`。

这部分贡献将日常支持记录和正式缺陷/任务系统连接起来，使问题不只停留在个人记录中，而是可以进入状态流转、周报汇总、评论同步和跨团队跟进流程。

### 3. 飞书 Bot、飞书任务与服务端能力扩展

4-5 月重点推进飞书 Bot 日报推送、多 Webhook 地址、签名校验、发送失败重试、发送历史、飞书卡片分类、飞书任务集成、OAuth、服务端安全加固、双向同步和网页后台。相关提交触达 `Sources/FeishuBotService.swift`、`Sources/FeishuTaskService.swift`、`Sources/FeishuOAuthService.swift`、`server/feishu.go`、`server/feishu_task.go`、`server/feishu_app.go`、`server/api.go`、`server/scheduler.go` 等文件。

这部分工作体现了较强的系统集成能力：需要同时处理客户端配置、服务端接口、鉴权、任务绑定、消息卡片、推送可靠性和团队协作场景。

### 4. AI 周报、AI 对话与知识处理能力

2-3 月开始引入 AI 周报生成，支持 Claude/OpenAI 双服务商、自定义 Prompt、Keychain 持久化、富文本输出；随后扩展到 AI 对话、文件上传、高级设置、流式输出和周报生成修复。主要文件包括 `Sources/AIService.swift`、`Sources/AIChatView.swift`、`Sources/RecentNotesView.swift`、`Sources/SettingsView.swift`、`Sources/WeeklyReport.swift`。

这部分工作将 AI 从“外部辅助工具”嵌入到日常支持记录和周报生成链路中，提升了记录整理、信息摘要和阶段性复盘的效率。

### 5. Linear 集成、服务端化与报表工作区

5-6 月围绕 Linear 问题反馈系统、Linear 评论和标题同步、项目映射、客户端同步优化、飞书报告中的 Linear 链接、可选周报范围、月度 issue 报告工作区等方向迭代。相关模块包括 `Sources/LinearService.swift`、`Sources/LinearModels.swift`、`Sources/Settings/LinearTab.swift`、`Sources/ReportPeriodSummarySheet.swift`、`Sources/ReportVisualRenderer.swift`、`Sources/IssueStatisticsView.swift` 和 Tauri/Web 相关目录。

这部分工作将问题记录进一步扩展到正式产品/研发协作工具，并开始形成面向统计、报告和管理视图的工作区能力。

## 季度工作重点

### Q1：产品基础、个人工作台与 AI/Jira 能力成型

Q1 共 86 个非合并提交，是上半年最高密度的建设阶段。重点包括 macOS 菜单栏应用初始化、日记/周报、快捷键、通知、设置页、RSS、自动更新、Jira 集成、AI 周报、AI 对话、待办任务、Bug/问题追踪、操作日志和数据快照等能力。

从提交内容看，Q1 的核心不是单一功能开发，而是快速建立支持工程师日常工作流的基础平台：记录、提醒、聚合、统计、AI 辅助和问题追踪逐步合并到一个桌面工具中。

### Q2：协作系统集成、服务端化和问题闭环深化

Q2 共 31 个非合并提交，提交数量少于 Q1，但单次改动范围明显更大。重点从本地工具扩展到飞书 Bot、云同步、服务端后台、飞书任务、Linear 集成、SaaS server workflow、月度报告工作区等方向。

这一阶段的工作更偏系统化和协作化：支持记录开始和飞书、Jira、Linear、服务端任务、网页后台、报表渲染等链路连接，工具属性从个人效率工具向团队支持工作台演进。

### Q3

当前分析范围截止到 2026-06-30，暂无 Q3 数据。

### Q4

当前分析范围截止到 2026-06-30，暂无 Q4 数据。

## 代码与工程质量分析

### 提交活跃度

上半年共 117 个非合并提交，月度分布如下：

- 2026-02：40 个
- 2026-03：46 个
- 2026-04：17 个
- 2026-05：13 个
- 2026-06：1 个

提交活跃度呈现明显的“前期快速构建、后期系统整合”特征。2-3 月以高频小步快跑为主，快速完成产品基础能力；4-5 月提交数量减少，但涉及服务端、飞书、Linear、报表工作区等更复杂模块，单次提交影响范围更大。

### 提交类型分布

按提交信息前缀估算：

- Feature：54 个，约 46%
- Fix：33 个，约 28%
- Chore：13 个，约 11%
- Refactor：9 个，约 8%
- Docs：3 个，约 3%
- CI：3 个，约 3%
- Perf：1 个，约 1%
- Initial Commit：1 个

整体上以功能建设为主，同时有较高比例的修复提交，说明项目处于快速迭代和真实使用反馈驱动阶段。`fix` 数量较多不是坏事，结合提交内容看，主要集中在 UI 交互、同步边界、Jira/飞书状态流转、AI 周报和自动更新等使用链路，反映出作者在边使用边收敛问题。

### 主要触达模块

按文件触达频次统计，主要集中在以下模块：

- `Sources/SettingsView.swift`：44 次触达，设置页和配置体验长期迭代。
- `Sources/DataStore.swift`：43 次触达，本地数据模型、状态持久化和同步基础。
- `Sources/MenuBarView.swift`：30 次触达，菜单栏主交互入口。
- `Sources/IssueTrackerView.swift`：26 次触达，问题追踪核心界面。
- `Sources/App.swift`：25 次触达，应用入口和全局能力集成。
- `Sources/RecentNotesView.swift`：21 次触达，日记/记录视图。
- `Sources/JiraService.swift`：16 次触达，Jira 集成。
- `Sources/IssueModels.swift`：16 次触达，问题模型和状态体系。
- `Sources/WeeklyReport.swift`：14 次触达，周报逻辑。
- `Sources/FeishuBotService.swift`：13 次触达，飞书 Bot 推送。

按目录触达看，`Sources` 是绝对核心，说明上半年主要建设 macOS Swift 客户端；`server` 和 `web` 在 Q2 开始明显增加，说明项目从本地工具向服务端和网页后台扩展。

### 代码影响力

从路径和提交主题看，作者的改动集中在核心业务链路，而不是边缘配置。`DataStore`、`IssueTrackerView`、`JiraService`、`FeishuBotService`、`LinearService`、`WeeklyReport`、`server/api.go`、`server/scheduler.go` 等文件都属于数据模型、同步、问题追踪、外部系统集成和报告生成的核心路径。

上半年累计统计约 57,125 行新增、11,691 行删除。需要注意的是，该数字包含 `package-lock`、`Cargo.lock`、`server/web/dist`、Tauri/Web 构建文件等生成或依赖文件，不能直接等同于手写业务代码规模。但即便剔除这些因素，核心 Swift、Go、Web 模块的触达广度也说明作者承担了项目主要设计和实现工作。

### 工作习惯

提交信息整体可读性较好，常见前缀包括 `feat`、`fix`、`refactor`、`chore`、`docs`、`ci`，能基本反映变更意图。早期提交粒度较细，适合快速推进；中后期出现了一些大提交，例如服务端安全加固、飞书双向同步、Linear 适配、月度报告工作区等，单次提交涉及文件较多、主题较复合。

建议后续在大型能力落地时进一步拆分提交：先拆模型/存储，再拆服务端接口，再拆 UI，再拆测试和文档。这样更利于 code review、回滚和后续追溯。

## 总结与展望

整体来看，`chengun11` 在 2026 年上半年对 TechSupportTracker/TicTracker 的贡献非常集中且具有主导性：从 0 到 1 建立 macOS 支持工作台，并围绕 Jira、飞书、Linear、AI、云同步、服务端后台和报表工作区持续扩展。工作重心与技术支持岗位的实际需求高度一致，体现出把日常支持痛点产品化、工具化和自动化的能力。

从工程角度看，作者已经不只是完成单点功能，而是在持续构建“记录 -> 追踪 -> 同步 -> 推送 -> 报告 -> 复盘”的闭环系统。后续如果继续加强模块边界、测试覆盖、提交拆分和服务端/客户端接口契约管理，这个项目可以从个人效率工具进一步成长为团队级技术支持工作台。
