# TicTracker 客户端重构计划

> 基于 2026-05-05 代码审查结果，按优先级排列。
> 每个任务标注预估耗时和依赖关系。

---

## P0 — 安全修复（必须立即做）

### 1. UpdateChecker 加签名验证
- **文件**: `Sources/UpdateChecker.swift`
- **问题**: 从 GitHub 下载 zip 后直接替换 .app，无签名/hash 校验
- **修复方案**:
  - 下载完成后执行 `codesign --verify --deep --strict` 验证签名
  - 或在 GitHub Release 中附带 SHA256 文件，下载后校验
  - 验证失败则删除下载文件并提示用户
- **耗时**: 1h
- **依赖**: 无

### 2. 移除 Keychain Mirror 或加密
- **文件**: `Sources/KeychainHelper.swift:33-68`
- **问题**: 凭证明文镜像到 `~/Library/Application Support/TicTracker/keychain-mirror/`
- **修复方案（二选一）**:
  - **方案 A（推荐）**: 完全移除 mirror 机制。Keychain 本身就是 fallback，mirror 的存在意义不大
  - **方案 B**: 保留 mirror 但用 AES-256-GCM 加密，密钥从设备 UUID + bundle ID 派生
- **耗时**: 1-2h
- **依赖**: 无

### 3. Keychain 添加 kSecAttrAccessible
- **文件**: `Sources/KeychainHelper.swift:76-83`
- **修复方案**:
  ```swift
  // 需要后台访问的 token（同步用）
  kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
  
  // 高敏感凭证（App Secret）
  kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
  ```
- **耗时**: 30min
- **依赖**: 无

---

## P1 — 架构改善（本月内完成）

### 4. SettingsView 物理拆分
- **当前**: 2369 行，1 个文件
- **目标结构**:
  ```
  Sources/Settings/
    SettingsView.swift              (~120 行，TabView 容器)
    DepartmentTab.swift             (~130 行)
    GeneralTab.swift                (~200 行)
    RSSTab.swift                    (~220 行)
    JiraTab.swift                   (~360 行)
    FeishuBotTab.swift              (~480 行)
    AITab.swift                     (~270 行)
    DataTab.swift                   (~150 行)
    SyncTab.swift                   (~230 行)
    AboutTab.swift                  (~50 行)
    SettingsHelpers.swift           (~60 行)
  ```
- **步骤**:
  1. 创建 `Sources/Settings/` 目录
  2. 每个 `private struct XXXTab` 移到对应文件，改为 `struct XXXTab`
  3. `UnderlineTextFieldStyle` 和 `autoSaveSecureField` 移到 Helpers
  4. `departmentColors` 移到 `Theme.swift`
  5. 主 `SettingsView.swift` 仅保留 TabView 容器
- **耗时**: 2h
- **依赖**: 无

### 5. App.swift 启动逻辑解耦
- **文件**: `Sources/App.swift:109-136`
- **问题**: 服务初始化放在 `MenuBarView.onAppear`，依赖 UI 渲染时序
- **修复方案**:
  - 将 HotkeyManager、RSSFeedManager、JiraService、FeishuBotService、SyncManager 的初始化移到 `AppDelegate.applicationDidFinishLaunching`
  - 或在 App 的 `init()` 中通过 `Task { @MainActor in ... }` 延迟初始化
- **耗时**: 1h
- **依赖**: 无

### 6. IssueTrackerView Timer → .task modifier
- **文件**: `Sources/IssueTrackerView.swift:29, 1161-1178`
- **问题**: `@State Timer?` 可能泄漏，闭包循环引用
- **修复方案**:
  ```swift
  .task {
      while !Task.isCancelled {
          await syncFeishuBoundTasks()
          try? await Task.sleep(for: .seconds(interval))
      }
  }
  ```
- **耗时**: 30min
- **依赖**: 无

### 7. OAuth 回调限制 localhost
- **文件**: `Sources/FeishuOAuthService.swift:248-253`
- **修复方案**:
  ```swift
  let parameters = NWParameters.tcp
  parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)
  let listener = try NWListener(using: parameters, on: port)
  ```
- **耗时**: 30min
- **依赖**: 无

### 8. 同步 URL 强制 HTTPS 校验
- **文件**: `Sources/HTTPAPISyncService.swift`, `Sources/WebDAVSyncService.swift`
- **修复方案**:
  - 在 `makeService()` 中校验 URL scheme
  - `http://127.0.0.1` 和 `http://localhost` 豁免（本机开发）
  - 其余 HTTP URL 弹出警告或拒绝
- **耗时**: 30min
- **依赖**: 无

---

## P2 — 代码质量（下个迭代）

### 9. DataStore 持久化层抽象
- **目标**: 为迁移 SwiftData/SQLite 铺路
- **方案**:
  ```swift
  protocol PersistenceProvider {
      func load<T: Decodable>(key: String) -> T?
      func save<T: Encodable>(key: String, value: T)
  }
  struct UserDefaultsPersistence: PersistenceProvider { ... }
  ```
- **步骤**:
  1. 定义 `PersistenceProvider` protocol
  2. 实现 `UserDefaultsPersistence`（当前逻辑）
  3. DataStore 通过 provider 读写，不直接依赖 UserDefaults
  4. 添加 didSet 防抖（debounce 500ms）
- **耗时**: 4h
- **依赖**: #4 完成后更容易操作

### 10. 全局单例 → Protocol + DI
- **涉及**: HotkeyManager、NotificationManager、RSSFeedManager、JiraService、FeishuBotService、UpdateChecker、SyncManager（7 个）
- **方案**:
  1. 为每个 Service 定义 protocol
  2. 通过 `@Environment` 或 DataStore 构造器注入
  3. 测试时可注入 Mock
- **耗时**: 6h
- **依赖**: #5（启动逻辑解耦后更容易注入）

### 11. IssueTrackerView 拆分 List + Detail
- **目标**: 30 个 @State → 分散到子视图
- **方案**:
  ```swift
  struct IssueTrackerView: View {
      var body: some View {
          HSplitView {
              IssueListView(store: store, selection: $selectedIssueID)
              IssueDetailView(store: store, issueID: selectedIssueID)
          }
      }
  }
  ```
- **耗时**: 3h
- **依赖**: 无

### 12. MenuBarView 提取子视图
- **目标**: body 380 行 → 每个功能区块独立
- **提取**:
  - `DateNavigationView`
  - `DepartmentCounterView`
  - `DailyNoteSection`
  - `ToolbarSection`（统一 `openAppWindow` 辅助方法）
- **耗时**: 2h
- **依赖**: 无

### 13. AIChatView 统一到 @Observable
- **文件**: `Sources/AIChatView.swift`
- **问题**: 混用 `ObservableObject` + `@StateObject`
- **修复**: `AIChatViewModel` 改为 `@Observable`，用 `@State` 持有
- **耗时**: 1h
- **依赖**: 无

### 14. Accessibility 标签补全
- **范围**: 所有图标 Button
- **方案**: 为每个 `Image(systemName:)` Button 添加 `.accessibilityLabel()`
- **耗时**: 2h
- **依赖**: 无

### 15. DateFormatter 复用
- **方案**: 创建 `Formatters.swift`，所有 formatter 用 `static let` 缓存
- **耗时**: 30min
- **依赖**: 无

---

## 执行顺序建议

```
Week 1: P0 安全修复（#1 #2 #3）— 约 3.5h
Week 2: P1 架构改善（#4 #5 #6 #7 #8）— 约 4.5h
Week 3-4: P2 代码质量（#9-#15）— 约 18.5h
```

**总计约 26.5h 工作量。**

---

## 不做的事情（明确排除）

- ❌ 不迁移到 SwiftData（P2 #9 只做抽象层，不做实际迁移）
- ❌ 不重写 DataStore（渐进式改进）
- ❌ 不引入第三方依赖管理（SPM 已够用）
- ❌ 不改变现有 UI 交互模式
- ❌ 不做 iOS 移植

---

## 验收标准

- [ ] `codesign --verify` 在 UpdateChecker 下载后执行
- [ ] `keychain-mirror/` 目录不再存在或文件已加密
- [ ] Keychain 条目有明确的 `kSecAttrAccessible`
- [ ] SettingsView.swift < 150 行
- [ ] `go test ./...` 服务端仍全绿
- [ ] Swift 编译无 warning
- [ ] 现有功能无回归（手动冒烟测试）
