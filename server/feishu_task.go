package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/url"
	"regexp"
	"strings"
	"time"
)

// FeishuTaskClient 飞书任务 API 客户端
type FeishuTaskClient struct {
	app *FeishuApp
}

func NewFeishuTaskClient(app *FeishuApp) *FeishuTaskClient {
	return &FeishuTaskClient{app: app}
}

var taskGUIDRegexp = regexp.MustCompile(`^[A-Za-z0-9_-]{8,}$`)

func validTaskGUID(s string) bool {
	return taskGUIDRegexp.MatchString(s)
}

// UpsertIssueFromFeishuTask 根据飞书任务事件创建或更新对应 issue
//
// 关键规则：
//   - 已进入细分状态（已排期/测试中/观测中）的 issue，若飞书端仍未完成，不会被打回"待处理"
//   - 只有"完成↔未完成"真正翻转时才推进状态
//   - summary/description 为空时不覆盖旧值
func UpsertIssueFromFeishuTask(ctx context.Context, store *Store, taskGUID, summary, description string, completed bool) {
	if taskGUID == "" {
		return
	}
	err := store.Update(ctx, func(payload *SyncPayload) error {
		now := FlexTime{Value: time.Now().Format("2006-01-02 15:04:05")}

		for i := range payload.TrackedIssues {
			issue := &payload.TrackedIssues[i]
			if issue.FeishuTaskGUID == nil || *issue.FeishuTaskGUID != taskGUID {
				continue
			}
			if summary != "" && summary != issue.Title {
				issue.Title = summary
			}
			if description != "" {
				ensureFeishuTaskComment(issue, description, now)
			}

			// 状态同步：仅在真正翻转时修改，保留已排期/测试中/观测中
			wasResolved := isResolvedStatus(issue.Status)
			if completed && !wasResolved {
				applyIssueStatus(issue, StatusResolved)
			} else if !completed && wasResolved {
				applyIssueStatus(issue, StatusPending)
			}
			// 其它情况下，保留 issue.Status 原值

			issue.UpdatedAt = &now
			return nil
		}

		// 新建：仅当 summary 非空时才创建，避免空标题脏数据
		if strings.TrimSpace(summary) == "" {
			return nil
		}
		maxNumber := 0
		for _, issue := range payload.TrackedIssues {
			if issue.IssueNumber > maxNumber {
				maxNumber = issue.IssueNumber
			}
		}
		guid := taskGUID
		newIssue := TrackedIssue{
			ID:             fmt.Sprintf("%d", time.Now().UnixNano()),
			IssueNumber:    maxNumber + 1,
			Type:           "Support",
			Title:          summary,
			DateKey:        time.Now().Format("2006-01-02"),
			CreatedAt:      now,
			UpdatedAt:      &now,
			Status:         StatusPending,
			Source:         "手动",
			Comments:       []IssueComment{},
			FeishuTaskGUID: &guid,
		}
		if completed {
			applyIssueStatus(&newIssue, StatusResolved)
		}
		if description != "" {
			ensureFeishuTaskComment(&newIssue, description, now)
		}
		payload.TrackedIssues = append(payload.TrackedIssues, newIssue)
		slog.Info("imported feishu task as issue",
			"task_guid", taskGUID, "issue_number", newIssue.IssueNumber)
		return nil
	})
	if err != nil {
		slog.Error("upsert issue from feishu task failed", "task_guid", taskGUID, "err", err)
	}
}

func ensureFeishuTaskComment(issue *TrackedIssue, description string, now FlexTime) {
	body := strings.TrimSpace(description)
	if body == "" {
		return
	}
	text := "[飞书任务] " + body
	for _, existing := range issue.Comments {
		if existing.Text == text {
			return
		}
	}
	issue.Comments = append(issue.Comments, IssueComment{
		ID:        fmt.Sprintf("%d", time.Now().UnixNano()),
		Text:      text,
		CreatedAt: now,
	})
}

// feishuTaskSummary 是飞书任务列表/详情的精简结构
type feishuTaskSummary struct {
	GUID        string `json:"guid"`
	Summary     string `json:"summary"`
	Description string `json:"description"`
	CompletedAt string `json:"completed_at"`
}

// listTasklistTasks 拉取指定清单下的任务列表（分页直到末页）
func (c *FeishuTaskClient) listTasklistTasks(ctx context.Context, tasklistGUID string) ([]feishuTaskSummary, error) {
	if !validTaskGUID(tasklistGUID) {
		return nil, fmt.Errorf("invalid tasklist guid")
	}

	all := make([]feishuTaskSummary, 0, 32)
	pageToken := ""
	for {
		endpoint := fmt.Sprintf("%s/open-apis/task/v2/tasklists/%s/tasks?page_size=50",
			feishuAPIBase, url.PathEscape(tasklistGUID))
		if pageToken != "" {
			endpoint += "&page_token=" + url.QueryEscape(pageToken)
		}

		var result struct {
			Code int    `json:"code"`
			Msg  string `json:"msg"`
			Data struct {
				Items     []feishuTaskSummary `json:"items"`
				PageToken string              `json:"page_token"`
				HasMore   bool                `json:"has_more"`
			} `json:"data"`
		}
		if err := c.app.Get(ctx, endpoint, &result); err != nil {
			return nil, fmt.Errorf("list tasklist tasks: %w", err)
		}
		if result.Code != 0 {
			return nil, fmt.Errorf("list tasklist tasks: code=%d msg=%s", result.Code, result.Msg)
		}
		all = append(all, result.Data.Items...)
		if !result.Data.HasMore || result.Data.PageToken == "" {
			break
		}
		pageToken = result.Data.PageToken
	}
	return all, nil
}

// getTaskDetail 调用 GET /task/v2/tasks/:task_guid 获取任务详情
func (c *FeishuTaskClient) getTaskDetail(ctx context.Context, taskGUID string) (*feishuTaskSummary, error) {
	if !validTaskGUID(taskGUID) {
		return nil, fmt.Errorf("invalid task guid")
	}
	endpoint := fmt.Sprintf("%s/open-apis/task/v2/tasks/%s",
		feishuAPIBase, url.PathEscape(taskGUID))
	var result struct {
		Code int    `json:"code"`
		Msg  string `json:"msg"`
		Data struct {
			Task feishuTaskSummary `json:"task"`
		} `json:"data"`
	}
	if err := c.app.Get(ctx, endpoint, &result); err != nil {
		return nil, fmt.Errorf("get task: %w", err)
	}
	if result.Code != 0 {
		return nil, fmt.Errorf("get task: code=%d msg=%s", result.Code, result.Msg)
	}
	return &result.Data.Task, nil
}
