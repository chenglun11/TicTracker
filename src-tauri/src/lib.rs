use chrono::{Local, NaiveDate, SecondsFormat};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    env,
    fs,
    path::PathBuf,
    process::Command,
    sync::Mutex,
};
use tauri::{
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    ActivationPolicy, AppHandle, Manager, PhysicalPosition, State, WebviewWindow, WindowEvent,
};
use thiserror::Error;
use uuid::Uuid;

type AppResult<T> = Result<T, AppError>;

#[derive(Debug, Error)]
enum AppError {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("tauri error: {0}")]
    Tauri(#[from] tauri::Error),
    #[error("request error: {0}")]
    Request(#[from] reqwest::Error),
    #[error("invalid date key: {0}")]
    InvalidDateKey(String),
    #[error("item not found")]
    NotFound,
    #[error("app path unavailable")]
    AppPathUnavailable,
    #[error("{0}")]
    Message(String),
}

impl Serialize for AppError {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_str(&self.to_string())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AppSnapshot {
    version: u32,
    departments: Vec<String>,
    records: BTreeMap<String, BTreeMap<String, i32>>,
    daily_notes: BTreeMap<String, String>,
    tap_timestamps: BTreeMap<String, BTreeMap<String, Vec<String>>>,
    tracked_issues: Vec<TrackedIssue>,
    team_members: Vec<TeamMember>,
    current_member_id: String,
    todo_tasks: Vec<TodoTask>,
    rss_feeds: Vec<RssFeed>,
    jira_config: JiraConfig,
    linear_config: LinearConfig,
    feishu_bot_config: FeishuBotConfig,
    ai_config: AiConfig,
}

impl Default for AppSnapshot {
    fn default() -> Self {
        Self {
            version: 1,
            departments: vec![
                "工单-客服".into(),
                "工单-销售".into(),
                "工单-产品".into(),
                "邮件支持".into(),
            ],
            records: BTreeMap::new(),
            daily_notes: BTreeMap::new(),
            tap_timestamps: BTreeMap::new(),
            tracked_issues: Vec::new(),
            team_members: Vec::new(),
            current_member_id: String::new(),
            todo_tasks: Vec::new(),
            rss_feeds: Vec::new(),
            jira_config: JiraConfig::default(),
            linear_config: LinearConfig::default(),
            feishu_bot_config: FeishuBotConfig::default(),
            ai_config: AiConfig::default(),
        }
    }
}

impl AppSnapshot {
    fn today_total(&self) -> i32 {
        let key = today_key();
        self.records
            .get(&key)
            .map(|items| items.values().sum())
            .unwrap_or_default()
    }

    fn issue_counts(&self) -> IssueCounts {
        let mut counts = IssueCounts::default();
        for issue in &self.tracked_issues {
            if issue.status.is_resolved() {
                counts.resolved += 1;
            } else if issue.status == IssueStatus::Observing {
                counts.observing += 1;
            } else {
                counts.open += 1;
            }
            if issue.date_key == today_key() {
                counts.today += 1;
            }
        }
        counts
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct IssueCounts {
    open: usize,
    resolved: usize,
    observing: usize,
    today: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AppOverview {
    today_key: String,
    today_total: i32,
    today_note: String,
    issue_counts: IssueCounts,
    pending_todos: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TeamMember {
    id: Uuid,
    name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
enum IssueType {
    Bug,
    Feature,
    Support,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
enum IssueStatus {
    Pending,
    InProgress,
    Testing,
    Scheduled,
    Observing,
    Fixed,
    Ignored,
}

impl IssueStatus {
    fn is_resolved(&self) -> bool {
        matches!(self, IssueStatus::Fixed | IssueStatus::Ignored)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct IssueComment {
    id: Uuid,
    text: String,
    created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TrackedIssue {
    id: Uuid,
    issue_number: i32,
    issue_type: IssueType,
    title: String,
    date_key: String,
    created_at: String,
    updated_at: Option<String>,
    status: IssueStatus,
    source: String,
    assignee: Option<String>,
    ticket_url: Option<String>,
    department: Option<String>,
    comments: Vec<IssueComment>,
    followers: Vec<String>,
    tags: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TodoTask {
    id: Uuid,
    title: String,
    description: String,
    is_completed: bool,
    due_date: Option<String>,
    priority: String,
    created_at: String,
    completed_at: Option<String>,
    date_key: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RssFeed {
    id: Uuid,
    title: String,
    url: String,
    is_enabled: bool,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct JiraConfig {
    enabled: bool,
    base_url: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LinearConfig {
    enabled: bool,
    team_id: String,
    project_id: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct FeishuBotConfig {
    enabled: bool,
    send_hour: u8,
    send_minute: u8,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AiConfig {
    #[serde(default)]
    enabled: bool,
    #[serde(default = "default_ai_provider")]
    provider: String,
    #[serde(default)]
    base_url: String,
    #[serde(default)]
    model: String,
    #[serde(default)]
    custom_prompt: String,
}

impl Default for AiConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            provider: default_ai_provider(),
            base_url: String::new(),
            model: String::new(),
            custom_prompt: String::new(),
        }
    }
}

fn default_ai_provider() -> String {
    "Claude".into()
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CreateIssueInput {
    title: String,
    issue_type: IssueType,
    department: Option<String>,
    assignee: Option<String>,
    ticket_url: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TodoUpdateInput {
    id: Uuid,
    title: Option<String>,
    description: Option<String>,
    is_completed: Option<bool>,
    priority: Option<String>,
}

struct AppState {
    snapshot: Mutex<AppSnapshot>,
    path: PathBuf,
}

impl AppState {
    fn load(app: &AppHandle) -> AppResult<Self> {
        let dir = app
            .path()
            .app_data_dir()
            .map_err(|_| AppError::AppPathUnavailable)?;
        fs::create_dir_all(&dir)?;
        let path = dir.join("app-snapshot.json");
        let snapshot = if path.exists() {
            let content = fs::read_to_string(&path)?;
            serde_json::from_str(&content)?
        } else {
            AppSnapshot::default()
        };
        Ok(Self {
            snapshot: Mutex::new(snapshot),
            path,
        })
    }

    fn save(&self, snapshot: &AppSnapshot) -> AppResult<()> {
        let data = serde_json::to_vec_pretty(snapshot)?;
        let temp = self.path.with_extension("json.tmp");
        fs::write(&temp, data)?;
        fs::rename(temp, &self.path)?;
        Ok(())
    }

    fn mutate<F, T>(&self, action: F) -> AppResult<T>
    where
        F: FnOnce(&mut AppSnapshot) -> AppResult<T>,
    {
        let mut guard = self.snapshot.lock().expect("app snapshot mutex poisoned");
        let output = action(&mut guard)?;
        self.save(&guard)?;
        Ok(output)
    }
}

#[tauri::command]
fn get_snapshot(state: State<'_, AppState>) -> AppResult<AppSnapshot> {
    Ok(state
        .snapshot
        .lock()
        .expect("app snapshot mutex poisoned")
        .clone())
}

#[tauri::command]
fn get_overview(state: State<'_, AppState>) -> AppResult<AppOverview> {
    let snapshot = state.snapshot.lock().expect("app snapshot mutex poisoned");
    let key = today_key();
    Ok(AppOverview {
        today_key: key.clone(),
        today_total: snapshot.today_total(),
        today_note: snapshot.daily_notes.get(&key).cloned().unwrap_or_default(),
        issue_counts: snapshot.issue_counts(),
        pending_todos: snapshot
            .todo_tasks
            .iter()
            .filter(|task| !task.is_completed)
            .count(),
    })
}

#[tauri::command]
fn save_snapshot(snapshot: AppSnapshot, state: State<'_, AppState>) -> AppResult<AppSnapshot> {
    state.mutate(|current| {
        *current = snapshot.clone();
        Ok(snapshot)
    })
}

#[tauri::command]
fn increment_count(date_key: String, department: String, state: State<'_, AppState>) -> AppResult<AppSnapshot> {
    validate_date_key(&date_key)?;
    state.mutate(|snapshot| {
        let day = snapshot.records.entry(date_key.clone()).or_default();
        *day.entry(department.clone()).or_insert(0) += 1;
        let times = snapshot
            .tap_timestamps
            .entry(date_key)
            .or_default()
            .entry(department)
            .or_default();
        times.push(Local::now().format("%H:%M:%S").to_string());
        Ok(snapshot.clone())
    })
}

#[tauri::command]
fn decrement_count(date_key: String, department: String, state: State<'_, AppState>) -> AppResult<AppSnapshot> {
    validate_date_key(&date_key)?;
    state.mutate(|snapshot| {
        if let Some(day) = snapshot.records.get_mut(&date_key) {
            let value = day.entry(department).or_insert(0);
            *value = (*value - 1).max(0);
        }
        Ok(snapshot.clone())
    })
}

#[tauri::command]
fn set_note(date_key: String, text: String, state: State<'_, AppState>) -> AppResult<AppSnapshot> {
    validate_date_key(&date_key)?;
    state.mutate(|snapshot| {
        if text.trim().is_empty() {
            snapshot.daily_notes.remove(&date_key);
        } else {
            snapshot.daily_notes.insert(date_key, text);
        }
        Ok(snapshot.clone())
    })
}

#[tauri::command]
fn create_issue(input: CreateIssueInput, date_key: String, state: State<'_, AppState>) -> AppResult<AppSnapshot> {
    validate_date_key(&date_key)?;
    state.mutate(|snapshot| {
        let next = snapshot
            .tracked_issues
            .iter()
            .map(|issue| issue.issue_number)
            .max()
            .unwrap_or(0)
            + 1;
        snapshot.tracked_issues.push(TrackedIssue {
            id: Uuid::new_v4(),
            issue_number: next,
            issue_type: input.issue_type,
            title: input.title.trim().to_string(),
            date_key,
            created_at: now_iso(),
            updated_at: None,
            status: IssueStatus::Pending,
            source: "手动".into(),
            assignee: input.assignee.filter(|value| !value.trim().is_empty()),
            ticket_url: input.ticket_url.filter(|value| !value.trim().is_empty()),
            department: input.department.filter(|value| !value.trim().is_empty()),
            comments: Vec::new(),
            followers: Vec::new(),
            tags: Vec::new(),
        });
        Ok(snapshot.clone())
    })
}

#[tauri::command]
fn update_issue_status(id: Uuid, status: IssueStatus, state: State<'_, AppState>) -> AppResult<AppSnapshot> {
    state.mutate(|snapshot| {
        let issue = snapshot
            .tracked_issues
            .iter_mut()
            .find(|issue| issue.id == id)
            .ok_or(AppError::NotFound)?;
        issue.status = status;
        issue.updated_at = Some(now_iso());
        Ok(snapshot.clone())
    })
}

#[tauri::command]
fn add_issue_comment(id: Uuid, text: String, state: State<'_, AppState>) -> AppResult<AppSnapshot> {
    state.mutate(|snapshot| {
        let issue = snapshot
            .tracked_issues
            .iter_mut()
            .find(|issue| issue.id == id)
            .ok_or(AppError::NotFound)?;
        issue.comments.push(IssueComment {
            id: Uuid::new_v4(),
            text,
            created_at: now_iso(),
        });
        issue.updated_at = Some(now_iso());
        Ok(snapshot.clone())
    })
}

#[tauri::command]
fn update_todo(input: TodoUpdateInput, state: State<'_, AppState>) -> AppResult<AppSnapshot> {
    state.mutate(|snapshot| {
        let task = snapshot
            .todo_tasks
            .iter_mut()
            .find(|task| task.id == input.id)
            .ok_or(AppError::NotFound)?;
        if let Some(title) = input.title {
            task.title = title;
        }
        if let Some(description) = input.description {
            task.description = description;
        }
        if let Some(priority) = input.priority {
            task.priority = priority;
        }
        if let Some(is_completed) = input.is_completed {
            task.is_completed = is_completed;
            task.completed_at = is_completed.then(now_iso);
        }
        Ok(snapshot.clone())
    })
}

#[tauri::command]
fn create_todo(
    title: String,
    date_key: String,
    priority: Option<String>,
    state: State<'_, AppState>,
) -> AppResult<AppSnapshot> {
    validate_date_key(&date_key)?;
    state.mutate(|snapshot| {
        snapshot.todo_tasks.push(TodoTask {
            id: Uuid::new_v4(),
            title,
            description: String::new(),
            is_completed: false,
            due_date: None,
            priority: priority
                .filter(|value| !value.trim().is_empty())
                .unwrap_or_else(|| "中".into()),
            created_at: now_iso(),
            completed_at: None,
            date_key,
        });
        Ok(snapshot.clone())
    })
}

#[tauri::command]
fn export_snapshot_json(state: State<'_, AppState>) -> AppResult<String> {
    let snapshot = state.snapshot.lock().expect("app snapshot mutex poisoned");
    Ok(serde_json::to_string_pretty(&*snapshot)?)
}

#[tauri::command]
fn import_snapshot_json(json: String, state: State<'_, AppState>) -> AppResult<AppSnapshot> {
    let snapshot: AppSnapshot = serde_json::from_str(&json)?;
    state.mutate(|current| {
        *current = snapshot.clone();
        Ok(snapshot)
    })
}

#[tauri::command]
fn copy_text(text: String) -> AppResult<()> {
    run_osascript(&[
        "-e",
        &format!(
            "set the clipboard to {}",
            apple_script_string_literal(&text)
        ),
    ])
}

#[tauri::command]
fn open_external(url: String) -> AppResult<()> {
    Command::new("open").arg(url).spawn()?;
    Ok(())
}

#[tauri::command]
fn notify(title: String, body: String) -> AppResult<()> {
    run_osascript(&[
        "-e",
        &format!(
            "display notification {} with title {}",
            apple_script_string_literal(&body),
            apple_script_string_literal(&title)
        ),
    ])
}

#[tauri::command]
fn hide_panel(app: AppHandle) -> AppResult<()> {
    if let Some(window) = app.get_webview_window("main") {
        window.hide()?;
    }
    Ok(())
}

#[tauri::command]
async fn generate_ai_weekly_report(raw_report: String, state: State<'_, AppState>) -> AppResult<String> {
    let config = {
        state
            .snapshot
            .lock()
            .expect("app snapshot mutex poisoned")
            .ai_config
            .clone()
    };
    generate_ai_report(raw_report, config).await
}

async fn generate_ai_report(raw_report: String, config: AiConfig) -> AppResult<String> {
    let provider = normalized_provider(&config.provider);
    let api_key = load_ai_api_key(&provider)?;
    if api_key.trim().is_empty() {
        return Err(AppError::Message(
            "未配置 AI API Key，请先在原 Swift 版 AI 设置中保存 Key".into(),
        ));
    }

    let system = effective_ai_prompt(&config);
    let user = format!("以下是本周的原始技术支持数据，请生成周报摘要：\n\n{raw_report}");
    match provider.as_str() {
        "openai" => call_openai(&api_key, &config, &system, &user).await,
        _ => call_claude(&api_key, &config, &system, &user).await,
    }
}

async fn call_claude(api_key: &str, config: &AiConfig, system: &str, user: &str) -> AppResult<String> {
    let base = effective_ai_base_url(config, "https://api.anthropic.com");
    let model = effective_ai_model(config, "claude-sonnet-4-20250514");
    let url = format!("{base}/v1/messages");
    let body = serde_json::json!({
        "model": model,
        "max_tokens": 1600,
        "system": system,
        "messages": [{ "role": "user", "content": user }]
    });
    let value: serde_json::Value = reqwest::Client::new()
        .post(url)
        .header("x-api-key", api_key)
        .header("anthropic-version", "2023-06-01")
        .json(&body)
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;
    value
        .get("content")
        .and_then(|content| content.as_array())
        .and_then(|items| items.iter().find_map(|item| item.get("text")?.as_str()))
        .map(|text| text.trim().to_string())
        .filter(|text| !text.is_empty())
        .ok_or_else(|| AppError::Message("无法解析 Claude 响应".into()))
}

async fn call_openai(api_key: &str, config: &AiConfig, system: &str, user: &str) -> AppResult<String> {
    let base = effective_ai_base_url(config, "https://api.openai.com");
    let model = effective_ai_model(config, "gpt-4o-mini");
    let url = format!("{base}/v1/chat/completions");
    let body = serde_json::json!({
        "model": model,
        "messages": [
            { "role": "system", "content": system },
            { "role": "user", "content": user }
        ],
        "temperature": 0.2
    });
    let value: serde_json::Value = reqwest::Client::new()
        .post(url)
        .bearer_auth(api_key)
        .json(&body)
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;
    value
        .get("choices")
        .and_then(|choices| choices.as_array())
        .and_then(|choices| choices.first())
        .and_then(|choice| choice.get("message"))
        .and_then(|message| message.get("content"))
        .and_then(|content| content.as_str())
        .map(|text| text.trim().to_string())
        .filter(|text| !text.is_empty())
        .ok_or_else(|| AppError::Message("无法解析 OpenAI 响应".into()))
}

fn normalized_provider(provider: &str) -> String {
    if provider.to_ascii_lowercase().contains("openai") {
        "openai".into()
    } else {
        "claude".into()
    }
}

fn effective_ai_prompt(config: &AiConfig) -> String {
    if !config.custom_prompt.trim().is_empty() {
        return config.custom_prompt.trim().to_string();
    }
    [
        "你是一个技术支持团队的周报助手。根据提供的原始数据，生成一份简洁专业的周报摘要。",
        "要求：",
        "1. 用中文撰写",
        "2. 包含本周工作概览（总量、趋势）",
        "3. 按项目/部门总结重点",
        "4. 如有日报笔记，提炼关键事项",
        "5. 只总结本周实际完成的工作，不要写展望或计划",
        "6. 保持简洁，不要过度展开",
    ]
    .join("\n")
}

fn effective_ai_base_url(config: &AiConfig, default_base: &str) -> String {
    let value = config.base_url.trim();
    let base = if value.is_empty() { default_base } else { value };
    base.trim_end_matches('/').to_string()
}

fn effective_ai_model(config: &AiConfig, default_model: &str) -> String {
    let value = config.model.trim();
    if value.is_empty() {
        default_model.into()
    } else {
        value.into()
    }
}

fn load_ai_api_key(provider: &str) -> AppResult<String> {
    let env_key = if provider == "openai" {
        env::var("OPENAI_API_KEY").unwrap_or_default()
    } else {
        env::var("ANTHROPIC_API_KEY").unwrap_or_default()
    };
    if !env_key.trim().is_empty() {
        return Ok(env_key);
    }

    let output = Command::new("security")
        .args([
            "find-generic-password",
            "-s",
            "com.tictracker.keychain",
            "-a",
            "api-key",
            "-w",
        ])
        .output()?;
    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
    } else {
        Ok(String::new())
    }
}

fn run_osascript(args: &[&str]) -> AppResult<()> {
    Command::new("osascript").args(args).status()?;
    Ok(())
}

fn apple_script_string_literal(value: &str) -> String {
    format!("\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\""))
}

fn today_key() -> String {
    Local::now().format("%Y-%m-%d").to_string()
}

fn now_iso() -> String {
    Local::now().to_rfc3339_opts(SecondsFormat::Secs, true)
}

fn validate_date_key(date_key: &str) -> AppResult<()> {
    NaiveDate::parse_from_str(date_key, "%Y-%m-%d")
        .map(|_| ())
        .map_err(|_| AppError::InvalidDateKey(date_key.to_string()))
}

fn show_main_window(window: &WebviewWindow) {
    position_quick_window(window, None);
    let _ = window.show();
    let _ = window.unminimize();
    let _ = window.set_focus();
}

fn show_main_window_at(window: &WebviewWindow, position: PhysicalPosition<f64>) {
    position_quick_window(window, Some(position));
    let _ = window.show();
    let _ = window.unminimize();
    let _ = window.set_focus();
}

fn position_quick_window(window: &WebviewWindow, tray_position: Option<PhysicalPosition<f64>>) {
    let size = match window.outer_size() {
        Ok(size) => size,
        Err(_) => return,
    };
    if let Some(position) = tray_position {
        let x = (position.x as i32 - size.width as i32 + 26).max(8);
        let y = (position.y as i32 + 8).max(8);
        let _ = window.set_position(PhysicalPosition::new(x, y));
        return;
    }

    if let Ok(Some(monitor)) = window.primary_monitor() {
        let work_area = monitor.work_area();
        let x = work_area.position.x + work_area.size.width as i32 - size.width as i32 - 12;
        let y = work_area.position.y + 8;
        let _ = window.set_position(PhysicalPosition::new(x, y));
    }
}

pub fn run() {
    tauri::Builder::default()
        .on_window_event(|window, event| {
            if let WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .setup(|app| {
            app.set_activation_policy(ActivationPolicy::Accessory);
            app.set_dock_visibility(false);

            let state = AppState::load(&app.handle())?;
            app.manage(state);

            let show_i = MenuItem::with_id(app, "show", "打开 TicTracker", true, None::<&str>)?;
            let quit_i = MenuItem::with_id(app, "quit", "退出", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&show_i, &quit_i])?;
            let mut tray = TrayIconBuilder::new()
                .menu(&menu)
                .show_menu_on_left_click(false)
                .tooltip("TicTracker")
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "show" => {
                        if let Some(window) = app.get_webview_window("main") {
                            show_main_window(&window);
                        }
                    }
                    "quit" => app.exit(0),
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click {
                        position,
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        ..
                    } = event
                    {
                        let app = tray.app_handle();
                        if let Some(window) = app.get_webview_window("main") {
                            show_main_window_at(&window, position);
                        }
                    }
                });
            if let Some(icon) = app.default_window_icon() {
                tray = tray.icon(icon.clone());
            }
            tray.build(app)?;
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_snapshot,
            get_overview,
            save_snapshot,
            increment_count,
            decrement_count,
            set_note,
            create_issue,
            update_issue_status,
            add_issue_comment,
            create_todo,
            update_todo,
            export_snapshot_json,
            import_snapshot_json,
            copy_text,
            open_external,
            notify,
            hide_panel,
            generate_ai_weekly_report
        ])
        .run(tauri::generate_context!())
        .expect("error while running TicTracker Tauri app");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snapshot_round_trips_as_stable_json() {
        let mut snapshot = AppSnapshot::default();
        snapshot
            .records
            .entry("2026-05-27".into())
            .or_default()
            .insert("工单-客服".into(), 3);
        snapshot.daily_notes.insert("2026-05-27".into(), "已跟进".into());

        let json = serde_json::to_string(&snapshot).expect("snapshot encodes");
        assert!(json.contains("dailyNotes"));
        assert!(json.contains("tapTimestamps"));

        let decoded: AppSnapshot = serde_json::from_str(&json).expect("snapshot decodes");
        assert_eq!(decoded.records["2026-05-27"]["工单-客服"], 3);
        assert_eq!(decoded.daily_notes["2026-05-27"], "已跟进");
    }

    #[test]
    fn issue_counts_split_open_observing_and_resolved() {
        let mut snapshot = AppSnapshot::default();
        snapshot.tracked_issues = vec![
            issue_with_status(IssueStatus::Pending),
            issue_with_status(IssueStatus::Observing),
            issue_with_status(IssueStatus::Fixed),
            issue_with_status(IssueStatus::Ignored),
        ];

        let counts = snapshot.issue_counts();
        assert_eq!(counts.open, 1);
        assert_eq!(counts.observing, 1);
        assert_eq!(counts.resolved, 2);
    }

    #[test]
    fn validates_snapshot_date_keys() {
        assert!(validate_date_key("2026-05-27").is_ok());
        assert!(validate_date_key("2026/05/27").is_err());
        assert!(validate_date_key("2026-13-27").is_err());
    }

    fn issue_with_status(status: IssueStatus) -> TrackedIssue {
        TrackedIssue {
            id: Uuid::new_v4(),
            issue_number: 1,
            issue_type: IssueType::Bug,
            title: "测试问题".into(),
            date_key: today_key(),
            created_at: now_iso(),
            updated_at: None,
            status,
            source: "手动".into(),
            assignee: None,
            ticket_url: None,
            department: None,
            comments: Vec::new(),
            followers: Vec::new(),
            tags: Vec::new(),
        }
    }
}
