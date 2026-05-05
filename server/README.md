# TicTracker Server

技术支持工单追踪系统的本地服务端：提供 macOS 客户端数据同步、Web 后台 API、飞书机器人推送/事件回调。

技术栈：Go 1.22 + gin v1.10 + 内嵌前端 dist。

---

## 快速开始

```bash
cd server
go run .              # 调试启动
go build -o tictacker-server . && ./tictacker-server
```

默认监听 **`127.0.0.1:9999`**。健康检查：`curl http://127.0.0.1:9999/healthz`。

---

## 配置文件

`config.yaml`（位于 `server/` 目录）。完整字段见 `config.example.yaml`。

```yaml
port: "9999"
bind: "127.0.0.1"             # 默认仅本机；要让 LAN 访问需改 "0.0.0.0"（注意安全）
sync_token: "<openssl rand -base64 32>"
web_token:  "<openssl rand -base64 32>"
data_dir:   "./data"
max_body_bytes: 10485760      # 请求体上限（DoS 防护），默认 10MB

# 飞书事件回调安全（强烈建议配置；否则 /feishu/event 与 /feishu/card 仅做时间窗口和去重）
feishu_verification_token: ""
feishu_encrypt_key: ""

# 飞书应用平台凭证（用于 tenant_access_token、Tasks API、卡片回调）
feishu_app_id: ""
feishu_app_secret: ""
```

所有字段都支持环境变量覆盖（命名规则见 `config.go: applyEnvOverrides`）。

---

## ⚠️ 部署前手动操作清单

服务端可以"开箱即跑"，但以下事项**强烈建议**在投入使用前完成。这些都是出于安全/兼容考虑，源码层面不会自动替你做。

### 1. 替换为强 token（必做）

```bash
# 在 server/ 目录下：
openssl rand -base64 32   # 输出贴进 sync_token
openssl rand -base64 32   # 输出贴进 web_token
```

弱口令（如纯数字）可被 1 秒内暴力枚举。

### 2. 收紧 `config.yaml` 与 `data/` 目录权限（必做）

```bash
chmod 600 server/config.yaml          # 仅当前用户可读写
chmod -R go-rwx server/data/          # 备份和 sync.json 不让其他用户读
```

`config.yaml` 含密钥；`data/sync.json` 与 `data/backups/` 含飞书 webhook secret。
代码层面新写入的文件已使用 `0600` 权限，但**已存在的旧文件需要手动改**一次。

### 3. 飞书事件回调签名校验（强烈建议）

如果你启用了飞书机器人的事件订阅（`/feishu/event`）或卡片交互（`/feishu/card`），按以下步骤打开签名校验。**未启用前，这两个端点暴露在网络上没有签名验证**，攻击者只要知道 URL 就能伪造请求。

1. 飞书开放平台 → 你的应用 → 「事件与回调」/「事件订阅」
2. 启用「加密推送」，复制 **Encrypt Key** 和 **Verification Token**
3. 写入 `config.yaml`：
   ```yaml
   feishu_verification_token: "<复制过来的值>"
   feishu_encrypt_key:        "<复制过来的值>"
   ```
4. 重启服务

启动日志中能看到 `feishu encrypt_key not configured` 警告时即未启用此功能。

### 4. `bind` 配置（按需）

默认 `127.0.0.1` 仅允许本机访问。如果你需要：

- **同 LAN 设备访问**（手机、其他电脑的浏览器/客户端）：
  ```yaml
  bind: "0.0.0.0"
  ```
- **仅本机访问**：保持默认或不写该字段

**注意**：监听 `0.0.0.0` 后服务暴露在整个 LAN，务必先完成第 1、2 步（强 token + 收紧文件权限）。该模式下传输仍是明文 HTTP，咖啡馆/酒店等不可信网络下建议套一层反向代理（Caddy 自动证书 / Cloudflare Tunnel 等）。

### 5. 客户端 macOS App 配置同步（如需双向同步）

服务端的飞书任务双向同步（`task.task.update_v1` 事件）需要：
- `feishu_app_id` / `feishu_app_secret`（服务端 yaml 配置，或在 macOS 客户端通过同步数据传入）
- 飞书开发者后台为应用申请 `task:task` 权限并订阅 `task.task.update_v1` 事件

---

## 端点

### 公开端点
| 路径 | 说明 |
|------|------|
| `GET /healthz` | 健康检查 |
| `GET /assets/*`、`GET /` | 内嵌前端 SPA |
| `POST /feishu/event` | 飞书事件订阅（中间件验签） |
| `POST /feishu/card` | 飞书卡片交互（中间件验签） |

### 鉴权端点（`Authorization: Bearer <token>`）

**`sync_token`** 用于：
- `GET /sync` / `POST /sync` — macOS 客户端整体同步

**`web_token`** 用于（同时挂在 `/api/*` 和 `/api/v1/*` 两个版本下，等价）：
- `GET /api/v1/status` — 状态/统计
- `GET /api/v1/issues` — 工单列表
- `PATCH /api/v1/issues/:id` — 编辑工单
- `POST /api/v1/issues` — 新建工单
- `DELETE /api/v1/issues/:id` — 删除工单
- `POST /api/v1/issues/:id/comments` — 加评论
- `POST /api/v1/feishu/send` — 立即推送日报到飞书

---

## 数据存储

- `data/sync.json` — 主数据，原子写（temp+rename），权限 `0600`
- `data/backups/sync_YYYY-MM-DD.json` — 自动备份，每天最多 1 份，保留 7 天

---

## 安全设计（已落地）

| 措施 | 位置 |
|------|------|
| Token 常量时间比较（防 timing attack） | `middleware.go: AuthMiddleware` |
| 飞书事件 HMAC-SHA256 签名 + AES-256-CBC 解密 + 时间窗口 ±5 分钟 + verification_token | `feishu_verify.go: FeishuVerifyMiddleware` |
| event_id 去重（5 分钟 TTL） | `feishu_verify.go: eventDedup` |
| 全局请求体大小上限 | `main.go` (`http.MaxBytesReader`) |
| Server 三项超时（防 slowloris） | `main.go` (`ReadHeaderTimeout/ReadTimeout/WriteTimeout/IdleTimeout`) |
| 飞书出站请求指数退避 + 错误码分类 | `feishu.go: sendOneWebhook` |
| `tenant_access_token` 双检锁缓存 + 失效自动刷新 | `feishu_app.go: TenantAccessToken` |
| 数据文件 `0600`、目录 `0700`、原子写 | `store.go: atomicWrite` |
| `config.yaml` 启动时权限警告 | `config.go: LoadConfig` |
| `gin.ReleaseMode` 默认开启 | `main.go` |

---

## 测试与构建

```bash
go vet ./...              # 静态检查
go test ./...             # 单元测试（28 用例）
go test -race ./...       # 并发竞态检测
go build -o tictacker-server .
```

测试覆盖：Store 原子性/并发/权限/拷贝、FlexTime 反序列化、状态常量稳定性、飞书签名校验、event_id 去重、merge 逻辑。

---

## 日志

默认 JSON 格式输出到 stderr。切换为人类可读：

```bash
TICTRACKER_LOG=text ./tictacker-server
```

关键日志事件：
- `feishu event signature mismatch` — 验签失败
- `feishu event timestamp outside window` — 重放攻击拦截
- `feishu event deduped` — 飞书重试导致的重复事件被拦截
- `tenant_access_token refreshed` — 飞书 token 刷新

---

## 优雅关闭

`SIGINT` / `SIGTERM` 触发：先 cancel scheduler ctx → `server.Shutdown(5s timeout)` → 退出。日志中能看到顺序 `shutdown signal received` → `scheduler stopped` → `server stopped`。

---

## 已知限制 / 后续 TODO

- HTTPS：当前仅支持明文 HTTP；生产环境建议在前面套 Caddy/Nginx 终止 TLS
- 客户端 UI：`AppSecret` / `EncryptKey` / `VerificationToken` / `AllowedChatIDs` 字段已在 `FeishuBotConfig` 模型中，但 macOS 客户端 SettingsView 暂未提供输入框 — 当前需通过 `config.yaml` 配置
- 飞书任务双向同步需要在飞书开发者后台手动订阅 `task.task.update_v1` 事件 + 申请 `task:task` 权限
