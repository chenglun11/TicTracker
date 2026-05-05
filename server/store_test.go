package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

func newTestStore(t *testing.T) *Store {
	t.Helper()
	dir := t.TempDir()
	store, err := NewStore(dir)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	return store
}

func TestStoreLoadEmpty(t *testing.T) {
	store := newTestStore(t)
	payload, err := store.Load(context.Background())
	if err != nil {
		t.Fatalf("Load empty: %v", err)
	}
	if payload == nil {
		t.Fatal("expected non-nil payload")
	}
	if len(payload.TrackedIssues) != 0 {
		t.Errorf("expected empty issues, got %d", len(payload.TrackedIssues))
	}
}

func TestStoreUpdatePersists(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	err := store.Update(ctx, func(p *SyncPayload) error {
		p.TrackedIssues = append(p.TrackedIssues, TrackedIssue{ID: "x1", Title: "hello", Status: StatusPending})
		return nil
	})
	if err != nil {
		t.Fatalf("Update: %v", err)
	}

	got, err := store.Load(ctx)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(got.TrackedIssues) != 1 || got.TrackedIssues[0].ID != "x1" {
		t.Errorf("unexpected payload: %+v", got)
	}
}

func TestStoreLoadReturnsCopy(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()
	if err := store.Update(ctx, func(p *SyncPayload) error {
		p.TrackedIssues = []TrackedIssue{{ID: "a", Title: "orig"}}
		return nil
	}); err != nil {
		t.Fatalf("Update: %v", err)
	}

	first, _ := store.Load(ctx)
	first.TrackedIssues[0].Title = "mutated"

	second, _ := store.Load(ctx)
	if second.TrackedIssues[0].Title != "orig" {
		t.Errorf("Load did not return a defensive copy: %q", second.TrackedIssues[0].Title)
	}
}

func TestStoreReplaceRawValidation(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	if err := store.ReplaceRaw(ctx, []byte("not json")); err == nil {
		t.Error("expected error for invalid json")
	}
	if err := store.ReplaceRaw(ctx, []byte(`{"foo":1}`)); err == nil {
		t.Error("expected error when lastModified missing")
	}
	if err := store.ReplaceRaw(ctx, []byte(`{"lastModified":1234567890}`)); err != nil {
		t.Errorf("expected success, got: %v", err)
	}
}

func TestStoreReplaceRawWritesAtomically(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()
	if err := store.ReplaceRaw(ctx, []byte(`{"lastModified":1}`)); err != nil {
		t.Fatalf("ReplaceRaw: %v", err)
	}
	tmp := filepath.Join(store.dataDir, "sync.json.tmp")
	if _, err := os.Stat(tmp); !os.IsNotExist(err) {
		t.Errorf("temp file should not remain after rename")
	}
}

// TestStoreUpdateConcurrent 验证并发 Update 数据无丢失
func TestStoreUpdateConcurrent(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	const N = 50
	var wg sync.WaitGroup
	for i := 0; i < N; i++ {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			err := store.Update(ctx, func(p *SyncPayload) error {
				p.Departments = append(p.Departments, "d")
				return nil
			})
			if err != nil {
				t.Errorf("Update %d: %v", n, err)
			}
		}(i)
	}
	wg.Wait()

	got, err := store.Load(ctx)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(got.Departments) != N {
		t.Errorf("expected %d departments, got %d", N, len(got.Departments))
	}
}

func TestStoreFilePerm(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()
	if err := store.Update(ctx, func(p *SyncPayload) error { return nil }); err != nil {
		t.Fatalf("Update: %v", err)
	}
	info, err := os.Stat(store.filePath())
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if info.Mode().Perm()&0o077 != 0 {
		t.Errorf("sync.json perm too open: %o", info.Mode().Perm())
	}
}

// 确保 marshal/unmarshal 不会丢失字段
func TestSyncPayloadRoundtrip(t *testing.T) {
	src := &SyncPayload{
		LastModified:  1234,
		Departments:   []string{"a", "b"},
		TrackedIssues: []TrackedIssue{{ID: "1", Title: "t", Status: StatusPending}},
	}
	data, err := json.Marshal(src)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var dst SyncPayload
	if err := json.Unmarshal(data, &dst); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(dst.TrackedIssues) != 1 || dst.TrackedIssues[0].Title != "t" {
		t.Errorf("roundtrip mismatch: %+v", dst)
	}
}
