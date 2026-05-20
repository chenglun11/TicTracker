# Team Workflow, My Submissions, and Scheduled Feishu Report Plan

## Summary

Make the local workspace support both team coordination and personal bug submission tracking. Treat scheduled Feishu reports as the main daily output: they should always send a complete snapshot of the day, with extra sections for my submissions and configured focus tags.

## Key Changes

- Add local identity through `currentMemberId` / current team member selection.
- Add issue reporter fields: `reporterId`, `reporterName`, and `reportedAt`.
- Add issue tags through `issueTags`, separate from `DiaryBadge`.
- Add workbench filters for `我提交的`, `今日提交`, and `我提交未关闭`.
- Add Feishu daily report focus tag config, defaulting to `今日Bug`.
- Scheduled Feishu reports include full daily statistics plus `我今日提交` and `今日重点` sections.

## Scheduling Behavior

- Keep `sendTimes` as the scheduling source of truth.
- Each schedule slot sends at most once per day after a successful send.
- Manual sends use the same report-generation path as scheduled sends.
- Tags do not narrow the full report; they only add a highlighted group.

## Test Plan

- New local issues inherit the selected current member as reporter.
- Workbench filters show the correct personal queues.
- A `今日Bug` tag appears in the Feishu focus section without hiding other report sections.
- macOS local send and server scheduled send produce matching report sections.
- Old issues without reporter or tags still load and sync correctly.
