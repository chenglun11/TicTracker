package main

import (
	"context"
	"fmt"
	"strings"
	"time"
)

type CreateTrackedIssueInput struct {
	Title             string
	Type              string
	Department        *string
	TicketURL         *string
	ReporterID        *string
	ReporterName      *string
	Assignee          *string
	Source            string
	IssueTags         []string
	LinearIssueID     *string
	LinearKey         *string
	LinearURL         *string
	LinearProjectID   *string
	LinearProjectName *string
	LinearAssignee    *string
	LinearCreator     *string
	LinearCreatedAt   *string
	LinearUpdatedAt   *string
}

func newIssueUUID() string {
	raw, err := randomHex(16)
	if err != nil || len(raw) != 32 {
		return fmt.Sprintf("%d", time.Now().UnixNano())
	}
	return raw[0:8] + "-" + raw[8:12] + "-" + raw[12:16] + "-" + raw[16:20] + "-" + raw[20:32]
}

func CreateTrackedIssue(ctx context.Context, store PayloadStore, input CreateTrackedIssueInput) (TrackedIssue, error) {
	title := strings.TrimSpace(input.Title)
	issueType := strings.TrimSpace(input.Type)
	if title == "" || issueType == "" {
		return TrackedIssue{}, fmt.Errorf("title and type are required")
	}

	source := strings.TrimSpace(input.Source)
	if source == "" {
		source = "Web"
	}

	var createdIssue TrackedIssue
	err := store.Update(ctx, func(payload *SyncPayload) error {
		maxNumber := 0
		for _, issue := range payload.TrackedIssues {
			if issue.IssueNumber > maxNumber {
				maxNumber = issue.IssueNumber
			}
		}

		now := FlexTime{Value: time.Now().Format("2006-01-02 15:04:05")}
		createdIssue = TrackedIssue{
			Revision:    1,
			ID:          newIssueUUID(),
			IssueNumber: maxNumber + 1,
			Type:        issueType,
			Title:       title,
			DateKey:     time.Now().Format("2006-01-02"),
			CreatedAt:   now,
			Status:      StatusPending,
			Source:      source,
			Comments:    []IssueComment{},
		}
		if actor := actorFromContext(ctx); actor != "" {
			createdIssue.UpdatedBy = &actor
		}
		createdIssue.Department = trimPtr(input.Department)
		createdIssue.TicketURL = trimPtr(input.TicketURL)
		createdIssue.ReporterID = trimPtr(input.ReporterID)
		createdIssue.ReporterName = trimPtr(input.ReporterName)
		createdIssue.Assignee = trimPtr(input.Assignee)
		createdIssue.LinearIssueID = trimPtr(input.LinearIssueID)
		createdIssue.LinearKey = trimPtr(input.LinearKey)
		createdIssue.LinearURL = trimPtr(input.LinearURL)
		createdIssue.LinearProjectID = trimPtr(input.LinearProjectID)
		createdIssue.LinearProjectName = trimPtr(input.LinearProjectName)
		createdIssue.LinearAssignee = trimPtr(input.LinearAssignee)
		createdIssue.LinearCreator = trimPtr(input.LinearCreator)
		createdIssue.LinearCreatedAt = trimPtr(input.LinearCreatedAt)
		createdIssue.LinearUpdatedAt = trimPtr(input.LinearUpdatedAt)
		if createdIssue.ReporterID == nil && payload.CurrentMemberID != "" {
			createdIssue.ReporterID = &payload.CurrentMemberID
		}
		if createdIssue.ReporterName == nil && payload.CurrentMemberName != "" {
			createdIssue.ReporterName = &payload.CurrentMemberName
		}
		if createdIssue.ReporterID != nil || createdIssue.ReporterName != nil {
			reportedAt := createdIssue.CreatedAt
			createdIssue.ReportedAt = &reportedAt
		}
		createdIssue.IssueTags = normalizeIssueTags(input.IssueTags)

		payload.TrackedIssues = append(payload.TrackedIssues, createdIssue)
		return nil
	})
	if err != nil {
		return TrackedIssue{}, err
	}
	return createdIssue, nil
}

func BuildStatusSummary(payload *SyncPayload, now time.Time) map[string]any {
	today := now.Format("2006-01-02")
	newToday := 0
	resolvedToday := 0
	pending := 0
	pendingAcceptance := 0
	scheduled := 0
	testing := 0
	observing := 0
	todayTotal := 0

	for _, issue := range payload.TrackedIssues {
		if issue.DeletedAt != nil {
			continue
		}
		isResolved := isResolvedStatus(issue.Status)
		if issue.DateKey == today && !isResolved {
			newToday++
		}
		if issue.ResolvedAt != nil && strings.HasPrefix(issue.ResolvedAt.Value, today) {
			resolvedToday++
		}
		switch issue.Status {
		case StatusScheduled:
			scheduled++
		case StatusTesting:
			testing++
		case StatusPendingAcceptance:
			pendingAcceptance++
		case StatusObserving:
			observing++
		default:
			if !isResolved {
				pending++
			}
		}
	}

	if payload.Records != nil {
		if rec, ok := payload.Records[today]; ok {
			for _, v := range rec {
				todayTotal += v
			}
		}
	}

	return map[string]any{
		"statistics": map[string]int{
			"newToday":          newToday,
			"resolvedToday":     resolvedToday,
			"pending":           pending,
			"pendingAcceptance": pendingAcceptance,
			"scheduled":         scheduled,
			"testing":           testing,
			"observing":         observing,
		},
		"todayTotal":  todayTotal,
		"departments": payload.Departments,
	}
}
