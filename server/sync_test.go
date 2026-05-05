package main

import (
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

func TestMergeWebChangesPicksLatest(t *testing.T) {
	older := FlexTime{Value: "2024-01-01 00:00:00"}
	newer := FlexTime{Value: "2024-06-01 00:00:00"}
	server := &SyncPayload{TrackedIssues: []TrackedIssue{
		{ID: "1", Title: "server", UpdatedAt: &newer},
		{ID: "web-only", Title: "web", Source: "Web"},
	}}
	incoming := &SyncPayload{TrackedIssues: []TrackedIssue{
		{ID: "1", Title: "client", UpdatedAt: &older},
	}}
	mergeWebChanges(incoming, server)
	if len(incoming.TrackedIssues) != 2 {
		t.Fatalf("expected 2 issues after merge, got %d", len(incoming.TrackedIssues))
	}
	for _, iss := range incoming.TrackedIssues {
		if iss.ID == "1" && iss.Title != "server" {
			t.Errorf("expected server (newer) to win, got %q", iss.Title)
		}
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
