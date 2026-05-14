# Linear 问题反馈接入与 Jira 入口化计划

## Summary

- 问题追踪继续作为本地和 Web 的主体验，外部系统只作为反馈入口接入。
- Linear 作为后续主反馈服务候选，先按并行接入设计，不立即替换现有数据模型。
- Jira 保留为外部入口，继续支持轮询、映射、状态同步和历史数据展示，但不再作为主服务口径。

## Local Changes Applied

- 设置页、菜单栏、窗口标题、通知、周报和 README 已统一改为 `Jira 入口` 口径。
- 设置页中 `Jira 入口` tab 已移到同步之后，问题追踪仍保留在主位置。
- 问题追踪设置页改为 `反馈入口`，Jira 作为其中一个入口开关展示。

## Linear Implementation Plan

- 新增 Linear 配置：API token、team/project、默认负责人、状态映射和启用开关。
- 新增 Linear adapter：负责 GraphQL 创建 issue、更新状态、写评论、解析 webhook。
- 扩展 `TrackedIssue` 关联字段：保留现有来源字段，增加 Linear issue id/key/url，不复用 Jira 字段。
- Web 端新建问题支持选择 Linear 目标；本地问题详情展示 Linear 链接和同步状态。
- Webhook 回流先处理状态和评论，避免一开始做完整双向冲突解决。

## Test Plan

- 创建本地问题后能生成 Linear issue，并保留本地 issue 编号。
- Linear 状态和评论回流后，本地数据更新且不会重复写入。
- Jira 入口关闭或隐藏后，不影响手动、Meta、飞书文档和未来 Linear 入口。
- `swift build`、Web API issue 增删改查、问题追踪筛选和周报输出保持可用。

