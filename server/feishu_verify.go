package main

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
)

// signatureWindow 飞书事件签名时间窗口；超出视为重放
const signatureWindow = 5 * time.Minute

// eventDedupTTL 事件 ID 缓存有效期；飞书 3s 超时未应答会重试，5 分钟覆盖所有重试场景
const eventDedupTTL = 5 * time.Minute

// eventDedup 进程内 event_id 去重缓存
type eventDedup struct {
	mu      sync.Mutex
	entries map[string]time.Time
}

func newEventDedup() *eventDedup {
	return &eventDedup{entries: make(map[string]time.Time)}
}

// seen 返回 true 表示这个 event_id 在 TTL 内已被处理过
func (d *eventDedup) seen(id string) bool {
	if id == "" {
		return false
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	now := time.Now()
	// 顺手清理过期条目
	for k, t := range d.entries {
		if now.Sub(t) > eventDedupTTL {
			delete(d.entries, k)
		}
	}
	if t, ok := d.entries[id]; ok && now.Sub(t) <= eventDedupTTL {
		return true
	}
	d.entries[id] = now
	return false
}

// FeishuVerifyOptions 验签中间件可调项
type FeishuVerifyOptions struct {
	VerificationToken string // 飞书事件订阅 Verification Token；空则跳过 token 校验
	EncryptKey        string // 飞书事件加密推送 Encrypt Key；空则跳过签名校验和解密
	BodyLimit         int64  // 请求体大小上限
	Dedup             *eventDedup
}

// FeishuVerifyMiddleware 校验飞书事件回调来源、解密、防重放、event_id 去重
//
// 使用约定：
//   - 中间件读完 body 后会把解密/原文 body 缓存到 c.Keys["feishu.body"]，下游 handler 直接取用
//   - event_id 去重命中时直接返回 200（避免飞书重试导致命令重复执行）
//   - 时间戳超出 ±5 分钟视为重放，返回 401
//   - 未配置 EncryptKey 时不进行签名/解密校验（开发模式），但仍会进行 verification_token 校验和去重
func FeishuVerifyMiddleware(opts FeishuVerifyOptions) gin.HandlerFunc {
	if opts.BodyLimit <= 0 {
		opts.BodyLimit = 1 << 20 // 默认 1MB，飞书事件 payload 通常很小
	}
	if opts.Dedup == nil {
		opts.Dedup = newEventDedup()
	}
	return func(c *gin.Context) {
		// 1) 读取 body（受大小限制）
		c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, opts.BodyLimit)
		raw, err := io.ReadAll(c.Request.Body)
		if err != nil {
			c.AbortWithStatusJSON(http.StatusBadRequest, gin.H{"error": "read body failed"})
			return
		}

		// 2) 时间窗口校验
		if ts := c.GetHeader("X-Lark-Request-Timestamp"); ts != "" {
			n, parseErr := strconv.ParseInt(ts, 10, 64)
			if parseErr != nil {
				c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "invalid timestamp"})
				return
			}
			if math.Abs(float64(time.Now().Unix()-n)) > signatureWindow.Seconds() {
				slog.Warn("feishu event timestamp outside window", "ts", ts)
				c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "stale request"})
				return
			}
		}

		// 3) 签名校验（仅当 EncryptKey 配置时强制）
		body := raw
		if opts.EncryptKey != "" {
			ts := c.GetHeader("X-Lark-Request-Timestamp")
			nonce := c.GetHeader("X-Lark-Request-Nonce")
			sig := c.GetHeader("X-Lark-Signature")
			if ts == "" || sig == "" {
				c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "missing signature headers"})
				return
			}
			if !verifyLarkSignature(ts, nonce, opts.EncryptKey, raw, sig) {
				slog.Warn("feishu event signature mismatch")
				c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "signature mismatch"})
				return
			}

			// 4) 解密 encrypt 字段（如果包体使用了加密推送）
			var enc struct {
				Encrypt string `json:"encrypt"`
			}
			if jsonErr := json.Unmarshal(raw, &enc); jsonErr == nil && enc.Encrypt != "" {
				plain, decErr := decryptLarkPayload(enc.Encrypt, opts.EncryptKey)
				if decErr != nil {
					slog.Warn("feishu event decrypt failed", "err", decErr)
					c.AbortWithStatusJSON(http.StatusBadRequest, gin.H{"error": "decrypt failed"})
					return
				}
				body = plain
			}
		}

		// 5) verification_token 校验
		if opts.VerificationToken != "" {
			if !checkVerificationToken(body, opts.VerificationToken) {
				slog.Warn("feishu event verification token mismatch")
				c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "verification failed"})
				return
			}
		}

		// 6) event_id 去重
		if id := extractEventID(body); id != "" {
			if opts.Dedup.seen(id) {
				slog.Info("feishu event deduped", "event_id", id)
				c.JSON(http.StatusOK, gin.H{})
				c.Abort()
				return
			}
		}

		// 7) 把 body 交给后续 handler；同时还原 c.Request.Body 便于 handler 直接读
		c.Set("feishu.body", body)
		c.Request.Body = io.NopCloser(bytes.NewReader(body))
		c.Next()
	}
}

// verifyLarkSignature 计算 sha256(timestamp + nonce + encryptKey + body) 与 X-Lark-Signature 比较
func verifyLarkSignature(timestamp, nonce, encryptKey string, body []byte, signature string) bool {
	h := sha256.New()
	h.Write([]byte(timestamp))
	h.Write([]byte(nonce))
	h.Write([]byte(encryptKey))
	h.Write(body)
	want := hex.EncodeToString(h.Sum(nil))
	return subtleConstTimeEqual(want, signature)
}

func subtleConstTimeEqual(a, b string) bool {
	if len(a) != len(b) {
		return false
	}
	var diff byte
	for i := 0; i < len(a); i++ {
		diff |= a[i] ^ b[i]
	}
	return diff == 0
}

// decryptLarkPayload 解密飞书加密推送的 encrypt 字段
//
// 飞书规范：key = sha256(encryptKey)；前 16 字节为 IV；之后为 AES-256-CBC 密文（PKCS7 padding）
func decryptLarkPayload(encrypted, encryptKey string) ([]byte, error) {
	cipherText, err := base64.StdEncoding.DecodeString(encrypted)
	if err != nil {
		return nil, fmt.Errorf("base64 decode: %w", err)
	}
	if len(cipherText) < aes.BlockSize {
		return nil, errors.New("ciphertext too short")
	}
	keyHash := sha256.Sum256([]byte(encryptKey))
	block, err := aes.NewCipher(keyHash[:])
	if err != nil {
		return nil, fmt.Errorf("new cipher: %w", err)
	}
	iv := cipherText[:aes.BlockSize]
	cipherText = cipherText[aes.BlockSize:]
	if len(cipherText)%aes.BlockSize != 0 {
		return nil, errors.New("ciphertext not block aligned")
	}
	mode := cipher.NewCBCDecrypter(block, iv)
	plain := make([]byte, len(cipherText))
	mode.CryptBlocks(plain, cipherText)
	// PKCS7 unpadding
	if len(plain) == 0 {
		return nil, errors.New("empty plaintext")
	}
	pad := int(plain[len(plain)-1])
	if pad <= 0 || pad > aes.BlockSize || pad > len(plain) {
		return nil, errors.New("bad padding")
	}
	return plain[:len(plain)-pad], nil
}

// checkVerificationToken 校验事件中的 verification token
//
// 兼容 schema 1.0（顶层 `token` 字段）和 schema 2.0（`header.token`）
func checkVerificationToken(body []byte, expected string) bool {
	var raw struct {
		Token  string `json:"token"`
		Header struct {
			Token string `json:"token"`
		} `json:"header"`
	}
	if err := json.Unmarshal(body, &raw); err != nil {
		return false
	}
	got := raw.Header.Token
	if got == "" {
		got = raw.Token
	}
	if got == "" {
		return false
	}
	return subtleConstTimeEqual(got, expected)
}

// extractEventID 从事件 body 中提取 event_id（schema 2.0 在 header.event_id）
func extractEventID(body []byte) string {
	var raw struct {
		Header struct {
			EventID string `json:"event_id"`
		} `json:"header"`
		UUID string `json:"uuid"` // schema 1.0 兜底
	}
	if err := json.Unmarshal(body, &raw); err != nil {
		return ""
	}
	if raw.Header.EventID != "" {
		return raw.Header.EventID
	}
	return raw.UUID
}
