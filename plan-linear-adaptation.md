# Linear 问题反馈系统适配计划

## 目标
完善 Linear 集成，使其具备完整的问题反馈能力（导入、同步、展示）。

## 现状
- 基础架构已完成：LinearModels、LinearService、LinearTab、DataStore 集成
- 缺少：问题导入/搜索、评论标识、同步按钮、assignee 同步

## 任务分解

### A组：Service 层（LinearService.swift + LinearModels.swift）

| # | 任务 | 文件 | 说明 |
|---|------|------|------|
| A1 | fetchMyIssues | LinearService.swift | GraphQL 查询当前用户分配的 issues，返回 [LinearIssue]，支持 teamId/projectId 过滤 |
| A2 | searchIssues | LinearService.swift | GraphQL 按关键词搜索 issues，返回 [LinearIssue] |
| A3 | assignee 同步 | LinearService.swift | syncTrackedIssues() 中检测 assignee 变更，记录为评论 |
| A4 | defaultAssigneeId | LinearService.swift | createIssue() 无显式 assigneeId 时使用 config.defaultAssigneeId |

### B组：UI 层（IssueTrackerView.swift）

| # | 任务 | 文件 | 说明 |
|---|------|------|------|
| B1 | Linear issue picker | IssueTrackerView.swift | 搜索/选择 Linear issue 并关联到本地 TrackedIssue 的 popover |
| B2 | 同步按钮 | IssueTrackerView.swift | 侧边栏 header 添加 Linear sync 按钮 |
| B3 | commentSourceBadge | IssueTrackerView.swift | 识别 [Linear] 前缀或 linear: jiraCommentId，显示 Linear 来源标签 |

## 依赖关系
- B1 依赖 A1/A2（需要 fetch/search API）
- B2 无依赖（调用已有的 syncTrackedIssues）
- B3 无依赖（纯 UI 逻辑）
- A3/A4 无依赖

## 执行策略
- 2 个 agent 并行：Service agent 先完成 A1-A4，UI agent 先完成 B2/B3，再做 B1
