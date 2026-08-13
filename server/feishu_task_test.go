package main

import (
	"context"
	"testing"
)

func TestIncompleteFeishuTaskPreservesPendingAcceptanceStatus(t *testing.T) {
	store, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	taskGUID := "task-pending-acceptance"
	if err := store.Update(context.Background(), func(payload *SyncPayload) error {
		payload.TrackedIssues = []TrackedIssue{{
			ID:             "issue-acceptance",
			IssueNumber:    1,
			Title:          "waiting for acceptance",
			Status:         StatusPendingAcceptance,
			FeishuTaskGUID: &taskGUID,
		}}
		return nil
	}); err != nil {
		t.Fatalf("seed store: %v", err)
	}

	UpsertIssueFromFeishuTask(context.Background(), store, taskGUID, "", "", "", false)

	payload, err := store.Load(context.Background())
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(payload.TrackedIssues) != 1 || payload.TrackedIssues[0].Status != StatusPendingAcceptance {
		t.Fatalf("incomplete task should preserve pending acceptance, got %+v", payload.TrackedIssues)
	}
}
