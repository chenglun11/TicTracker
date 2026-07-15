package main

import (
	"context"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"crypto/sha256"
	"encoding/json"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
)

func init() { gin.SetMode(gin.TestMode) }

func makeSignature(ts, nonce, key string, body []byte) string {
	h := sha256.New()
	h.Write([]byte(ts))
	h.Write([]byte(nonce))
	h.Write([]byte(key))
	h.Write(body)
	return hex.EncodeToString(h.Sum(nil))
}

func TestVerifyLarkSignatureMatch(t *testing.T) {
	ts := strconv.FormatInt(time.Now().Unix(), 10)
	nonce := "n1"
	key := "secret"
	body := []byte(`{"event_type":"x"}`)
	sig := makeSignature(ts, nonce, key, body)
	if !verifyLarkSignature(ts, nonce, key, body, sig) {
		t.Error("signature should match")
	}
	if verifyLarkSignature(ts, nonce, key, body, sig+"a") {
		t.Error("signature should not match for tampered sig")
	}
}

func TestEventDedup(t *testing.T) {
	d := newEventDedup()
	if d.seen("e1") {
		t.Error("first should not be seen")
	}
	if !d.seen("e1") {
		t.Error("second should be seen")
	}
	if d.seen("") {
		t.Error("empty id should not be considered seen")
	}
}

func TestExtractEventID(t *testing.T) {
	cases := map[string]string{
		`{"header":{"event_id":"abc"}}`: "abc",
		`{"uuid":"u-legacy"}`:           "u-legacy",
		`{}`:                            "",
		`not json`:                      "",
	}
	for in, want := range cases {
		if got := extractEventID([]byte(in)); got != want {
			t.Errorf("extractEventID(%q)=%q, want %q", in, got, want)
		}
	}
}

func TestCheckVerificationToken(t *testing.T) {
	good := `{"header":{"token":"abc"}}`
	if !checkVerificationToken([]byte(good), "abc") {
		t.Error("schema 2.0 token should match")
	}
	if checkVerificationToken([]byte(good), "wrong") {
		t.Error("wrong token should not match")
	}
	legacy := `{"token":"abc"}`
	if !checkVerificationToken([]byte(legacy), "abc") {
		t.Error("schema 1.0 token should match")
	}
}

func TestMiddlewareRejectsStaleTimestamp(t *testing.T) {
	mw := FeishuVerifyMiddleware(FeishuVerifyOptions{EncryptKey: "k", VerificationToken: "v"})
	r := gin.New()
	r.POST("/feishu/event", mw, func(c *gin.Context) { c.JSON(200, gin.H{"ok": true}) })

	body := []byte(`{}`)
	w := httptest.NewRecorder()
	staleTS := strconv.FormatInt(time.Now().Add(-30*time.Minute).Unix(), 10)
	req, _ := http.NewRequest("POST", "/feishu/event", strings.NewReader(string(body)))
	req.Header.Set("X-Lark-Request-Timestamp", staleTS)
	req.Header.Set("X-Lark-Request-Nonce", "n")
	req.Header.Set("X-Lark-Signature", makeSignature(staleTS, "n", "k", body))
	r.ServeHTTP(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("stale ts should be rejected, got %d", w.Code)
	}
}

func TestMiddlewareRejectsWrongSignature(t *testing.T) {
	mw := FeishuVerifyMiddleware(FeishuVerifyOptions{EncryptKey: "k"})
	r := gin.New()
	r.POST("/feishu/event", mw, func(c *gin.Context) { c.JSON(200, gin.H{"ok": true}) })

	body := []byte(`{}`)
	ts := strconv.FormatInt(time.Now().Unix(), 10)
	req, _ := http.NewRequest("POST", "/feishu/event", strings.NewReader(string(body)))
	req.Header.Set("X-Lark-Request-Timestamp", ts)
	req.Header.Set("X-Lark-Request-Nonce", "n")
	req.Header.Set("X-Lark-Signature", "00deadbeef")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("wrong signature should be rejected, got %d", w.Code)
	}
}

func TestMiddlewareDedupReturns200(t *testing.T) {
	mw := FeishuVerifyMiddleware(FeishuVerifyOptions{}) // 无 EncryptKey/Token，仅测试去重
	r := gin.New()
	called := 0
	r.POST("/feishu/event", mw, func(c *gin.Context) {
		called++
		c.JSON(200, gin.H{"ok": true})
	})
	body, _ := json.Marshal(map[string]any{"header": map[string]any{"event_id": "evt-1"}})
	for i := 0; i < 3; i++ {
		req, _ := http.NewRequest("POST", "/feishu/event", strings.NewReader(string(body)))
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		if w.Code != http.StatusOK {
			t.Errorf("attempt %d: status=%d body=%s", i, w.Code, w.Body.String())
		}
	}
	if called != 1 {
		t.Errorf("handler should be called once due to dedup, got %d", called)
	}
}

func TestPreserveFeishuSentTimes(t *testing.T) {
	server := &SyncPayload{FeishuBotConfig: &FeishuBotConfig{
		LastSentDateTime: "2024-06-01 12:00:00",
		LastSentTimes:    map[string]string{"18:00": "2024-06-01"},
	}}
	incoming := &SyncPayload{FeishuBotConfig: &FeishuBotConfig{
		LastSentDateTime: "2024-05-01 12:00:00",
		LastSentTimes:    map[string]string{"18:00": "2024-05-01"},
	}}
	preserveFeishuSentTimes(incoming, server)
	if incoming.FeishuBotConfig.LastSentDateTime != "2024-06-01 12:00:00" {
		t.Errorf("LastSentDateTime should be preserved from server, got %q",
			incoming.FeishuBotConfig.LastSentDateTime)
	}
	if incoming.FeishuBotConfig.LastSentTimes["18:00"] != "2024-06-01" {
		t.Errorf("LastSentTimes[18:00] should be from server")
	}
}

func TestSyncPayloadPreservesSchemaAndConfigurationScope(t *testing.T) {
	payload := SyncPayload{
		SchemaVersion:      2,
		PayloadScope:       "workspace-data",
		ConfigurationScope: "server-runtime-only",
		Records:            map[string]map[string]int{"2026-07-14": {"Support": 1}},
	}
	data, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	var roundTrip SyncPayload
	if err := json.Unmarshal(data, &roundTrip); err != nil {
		t.Fatal(err)
	}
	if roundTrip.SchemaVersion != 2 || roundTrip.PayloadScope != "workspace-data" || roundTrip.ConfigurationScope != "server-runtime-only" {
		t.Fatalf("sync metadata did not round-trip: %+v", roundTrip)
	}
}

func TestSyncClientProjectionRedactsRuntimeConfiguration(t *testing.T) {
	payload := &SyncPayload{
		JiraConfig:           json.RawMessage(`{"serverURL":"https://jira.example.com"}`),
		LinearConfig:         json.RawMessage(`{"teamId":"team-1"}`),
		FeishuBotConfig:      &FeishuBotConfig{AppSecret: "app-secret"},
		FeishuWebhookSecrets: map[string]string{"hook-1": "sign-secret"},
		AIConfig:             json.RawMessage(`{"model":"private-model"}`),
		RSSFeeds:             json.RawMessage(`[{"url":"https://private.example.com/feed"}]`),
		TodoTasks:            json.RawMessage(`[{"title":"private task"}]`),
		Records:              map[string]map[string]int{"2026-07-14": {"Support": 3}},
	}
	data, err := json.Marshal(syncClientProjection(payload))
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"jiraConfig", "linearConfig", "feishuBotConfig", "feishuWebhookSecrets", "aiConfig", "rssFeeds", "todoTasks", "app-secret", "sign-secret", "private task"} {
		if strings.Contains(string(data), forbidden) {
			t.Fatalf("sync response leaked %q: %s", forbidden, data)
		}
	}
	if !strings.Contains(string(data), "records") {
		t.Fatalf("workspace data was removed from projection: %s", data)
	}
}

func TestSyncClientProjectionKeepsRequiredEmptyCollections(t *testing.T) {
	data, err := json.Marshal(syncClientProjection(&SyncPayload{}))
	if err != nil {
		t.Fatal(err)
	}
	var object map[string]any
	if err := json.Unmarshal(data, &object); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"departments", "records", "dailyNotes", "trackedIssues", "teamMembers"} {
		if value, exists := object[key]; !exists || value == nil {
			t.Fatalf("required empty collection %q missing from sync payload: %s", key, data)
		}
	}
}

func TestSyncUploadPreservesServerRuntimeConfiguration(t *testing.T) {
	server := &SyncPayload{
		JiraConfig:           json.RawMessage(`{"serverURL":"https://jira.example.com"}`),
		FeishuBotConfig:      &FeishuBotConfig{AppSecret: "server-secret"},
		FeishuWebhookSecrets: map[string]string{"hook-1": "sign-secret"},
		RSSFeeds:             json.RawMessage(`[{"url":"https://server.example.com/feed"}]`),
		TodoTasks:            json.RawMessage(`[{"title":"server task"}]`),
	}
	incoming := &SyncPayload{
		JiraConfig:           json.RawMessage(`{"serverURL":"https://attacker.invalid"}`),
		FeishuBotConfig:      &FeishuBotConfig{AppSecret: "incoming-secret"},
		FeishuWebhookSecrets: map[string]string{"hook-1": "incoming-sign-secret"},
		RSSFeeds:             json.RawMessage(`[{"url":"https://incoming.invalid/feed"}]`),
		TodoTasks:            json.RawMessage(`[{"title":"incoming task"}]`),
	}
	preserveServerRuntimeConfiguration(incoming, server)
	if string(incoming.JiraConfig) != string(server.JiraConfig) || incoming.FeishuBotConfig.AppSecret != "server-secret" || incoming.FeishuWebhookSecrets["hook-1"] != "sign-secret" {
		t.Fatalf("client upload changed server runtime configuration: %+v", incoming)
	}
	if string(incoming.RSSFeeds) != string(server.RSSFeeds) || string(incoming.TodoTasks) != string(server.TodoTasks) {
		t.Fatalf("client upload changed local-only collections: %+v", incoming)
	}
}

func TestSyncRequiresRevisionAndRejectsStaleSnapshot(t *testing.T) {
	store, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	router := gin.New()
	router.GET("/sync", HandleGetSync(store))
	router.POST("/sync", HandlePostSync(store))

	body := `{"schemaVersion":2,"payloadScope":"workspace-data","lastModified":1,"departments":[],"records":{},"dailyNotes":{},"teamMembers":[],"trackedIssues":[{"id":"issue-1","issueNumber":1,"type":"Bug","title":"first","dateKey":"2026-07-13","createdAt":"2026-07-13 10:00:00","status":"Pending","source":"macOS"}]}`

	withoutRevision := httptest.NewRecorder()
	req, _ := http.NewRequest(http.MethodPost, "/sync", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	router.ServeHTTP(withoutRevision, req)
	if withoutRevision.Code != http.StatusPreconditionRequired {
		t.Fatalf("missing If-Match status = %d, want %d", withoutRevision.Code, http.StatusPreconditionRequired)
	}

	created := httptest.NewRecorder()
	req, _ = http.NewRequest(http.MethodPost, "/sync", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("If-Match", `"0"`)
	router.ServeHTTP(created, req)
	if created.Code != http.StatusOK {
		t.Fatalf("initial sync status = %d, body=%s", created.Code, created.Body.String())
	}
	if got := created.Header().Get("X-Sync-Revision"); got != "1" {
		t.Fatalf("initial revision = %q, want 1", got)
	}

	staleBody := strings.Replace(body, `"first"`, `"stale overwrite"`, 1)
	stale := httptest.NewRecorder()
	req, _ = http.NewRequest(http.MethodPost, "/sync", strings.NewReader(staleBody))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("If-Match", `"0"`)
	router.ServeHTTP(stale, req)
	if stale.Code != http.StatusConflict {
		t.Fatalf("stale sync status = %d, want %d; body=%s", stale.Code, http.StatusConflict, stale.Body.String())
	}
	if got := stale.Header().Get("X-Sync-Revision"); got != "1" {
		t.Fatalf("conflict revision = %q, want 1", got)
	}

	if err := store.Update(context.Background(), func(payload *SyncPayload) error {
		payload.TrackedIssues[0].Title = "edited online"
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	staleAfterWebEdit := httptest.NewRecorder()
	req, _ = http.NewRequest(http.MethodPost, "/sync", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("If-Match", `"1"`)
	router.ServeHTTP(staleAfterWebEdit, req)
	if staleAfterWebEdit.Code != http.StatusConflict {
		t.Fatalf("sync after online edit status = %d, want %d", staleAfterWebEdit.Code, http.StatusConflict)
	}
	if got := staleAfterWebEdit.Header().Get("X-Sync-Revision"); got != "2" {
		t.Fatalf("online edit revision = %q, want 2", got)
	}

	read := httptest.NewRecorder()
	req, _ = http.NewRequest(http.MethodGet, "/sync", nil)
	router.ServeHTTP(read, req)
	if read.Code != http.StatusOK {
		t.Fatalf("GET sync status = %d, body=%s", read.Code, read.Body.String())
	}
	if read.Header().Get("ETag") != `"2"` {
		t.Fatalf("GET ETag = %q, want revision 2", read.Header().Get("ETag"))
	}
	if strings.Contains(read.Body.String(), "stale overwrite") || !strings.Contains(read.Body.String(), "edited online") {
		t.Fatal("stale client overwrote the online edit")
	}
}

func TestSyncRejectsIncompleteSnapshotWithoutChangingWorkspace(t *testing.T) {
	store, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Update(context.Background(), func(payload *SyncPayload) error {
		payload.Departments = []string{"Support"}
		payload.Records = map[string]map[string]int{"2026-07-14": {"Support": 7}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	router := gin.New()
	router.POST("/sync", HandlePostSync(store))

	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/sync", strings.NewReader(`{"schemaVersion":2,"payloadScope":"workspace-data","lastModified":1,"trackedIssues":[],"teamMembers":[]}`))
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("If-Match", `"1"`)
	router.ServeHTTP(response, request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("incomplete snapshot status=%d body=%s", response.Code, response.Body.String())
	}
	payload, err := store.Load(context.Background())
	if err != nil || payload.Records["2026-07-14"]["Support"] != 7 {
		t.Fatalf("incomplete snapshot changed workspace: payload=%+v err=%v", payload, err)
	}
}

func TestSyncInitializesLegacyPayloadRevisionOnce(t *testing.T) {
	store, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := store.ReplaceRaw(context.Background(), []byte(`{"lastModified":123,"departments":["Support"]}`)); err != nil {
		t.Fatal(err)
	}
	router := gin.New()
	router.GET("/sync", HandleGetSync(store))

	for attempt := 0; attempt < 2; attempt++ {
		response := httptest.NewRecorder()
		request := httptest.NewRequest(http.MethodGet, "/sync", nil)
		router.ServeHTTP(response, request)
		if response.Code != http.StatusOK {
			t.Fatalf("attempt %d status=%d body=%s", attempt, response.Code, response.Body.String())
		}
		if got := response.Header().Get("X-Sync-Revision"); got != "1" {
			t.Fatalf("attempt %d revision=%q, want 1", attempt, got)
		}
	}
}

func TestServerManagedSendTimeDoesNotAdvanceRevision(t *testing.T) {
	store, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	if err := store.Update(ctx, func(payload *SyncPayload) error {
		payload.FeishuBotConfig = &FeishuBotConfig{Enabled: true}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if err := store.Update(ctx, func(payload *SyncPayload) error {
		payload.FeishuBotConfig.LastSentDateTime = "2026-07-13 16:30:00"
		payload.FeishuBotConfig.LastSentTimes = map[string]string{"16:30": "2026-07-13"}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	payload, err := store.Load(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if payload.Revision != 1 {
		t.Fatalf("server-managed send timestamps advanced revision to %d, want 1", payload.Revision)
	}
}

func TestRevisionRecordsLastActor(t *testing.T) {
	store, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	ctx := withActor(context.Background(), "web:alice")
	if err := store.Update(ctx, func(payload *SyncPayload) error {
		payload.Departments = []string{"Support"}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	payload, err := store.Load(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if payload.Revision != 1 || payload.LastModifiedBy != "web:alice" {
		t.Fatalf("revision actor = (%d, %q), want (1, web:alice)", payload.Revision, payload.LastModifiedBy)
	}
}
