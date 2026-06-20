import {
  Activity,
  Bell,
  Check,
  ChevronRight,
  Clipboard,
  Download,
  ExternalLink,
  FileJson,
  History,
  Minus,
  Plus,
  RefreshCw,
  Settings,
  Send,
  Sparkles,
  Trash2,
  Upload,
  X,
} from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import {
  addIssueComment,
  copyText,
  createIssue,
  decrementCount,
  exportSnapshotJson,
  generateAIWeeklyReport,
  getSnapshot,
  importSnapshotJson,
  incrementCount,
  notify,
  openExternal,
  saveSnapshot,
  setNote,
  updateIssueStatus,
  hidePanel as hideNativePanel,
} from "./native";
import type { AppSnapshot, IssueStatus, IssueType, TrackedIssue } from "./types";

const statusLabels: Record<IssueStatus, string> = {
  Pending: "待处理",
  InProgress: "处理中",
  Testing: "测试中",
  Scheduled: "已排期",
  Observing: "观测中",
  Fixed: "已修复",
  Ignored: "已忽略",
};

const issueTypeLabels: Record<IssueType, string> = {
  Bug: "Bug",
  Feature: "需求",
  Support: "支持",
};

const statusOptions = Object.keys(statusLabels) as IssueStatus[];
const issueTypeOptions = Object.keys(issueTypeLabels) as IssueType[];

function todayKey() {
  const now = new Date();
  return [
    now.getFullYear(),
    `${now.getMonth() + 1}`.padStart(2, "0"),
    `${now.getDate()}`.padStart(2, "0"),
  ].join("-");
}

function weekdayLabel(dateKey: string) {
  return new Intl.DateTimeFormat("zh-CN", {
    month: "numeric",
    day: "numeric",
    weekday: "short",
  }).format(new Date(`${dateKey}T12:00:00`));
}

function countFor(snapshot: AppSnapshot, dateKey: string, department: string) {
  return snapshot.records[dateKey]?.[department] ?? 0;
}

function totalFor(snapshot: AppSnapshot, dateKey: string) {
  return Object.values(snapshot.records[dateKey] ?? {}).reduce((sum, value) => sum + value, 0);
}

function dateKeyFromOffset(offset: number) {
  const date = new Date();
  date.setDate(date.getDate() + offset);
  return [
    date.getFullYear(),
    `${date.getMonth() + 1}`.padStart(2, "0"),
    `${date.getDate()}`.padStart(2, "0"),
  ].join("-");
}

function compactDateLabel(dateKey: string) {
  return new Intl.DateTimeFormat("zh-CN", {
    month: "numeric",
    day: "numeric",
    weekday: "short",
  }).format(new Date(`${dateKey}T12:00:00`));
}

function recentDays(snapshot: AppSnapshot) {
  return Array.from({ length: 7 }, (_, index) => {
    const key = dateKeyFromOffset(index - 6);
    return {
      key,
      label: compactDateLabel(key),
      total: totalFor(snapshot, key),
      note: snapshot.dailyNotes[key] ?? "",
    };
  }).reverse();
}

function isOpenIssue(issue: TrackedIssue) {
  return issue.status !== "Fixed" && issue.status !== "Ignored";
}

function latestIssues(snapshot: AppSnapshot) {
  return [...snapshot.trackedIssues]
    .filter(isOpenIssue)
    .sort((a, b) => b.issueNumber - a.issueNumber)
    .slice(0, 5);
}

function weeklyReport(snapshot: AppSnapshot) {
  const now = new Date();
  const lines = ["本周技术支持周报", ""];
  for (let index = 6; index >= 0; index -= 1) {
    const date = new Date(now);
    date.setDate(now.getDate() - index);
    const key = [
      date.getFullYear(),
      `${date.getMonth() + 1}`.padStart(2, "0"),
      `${date.getDate()}`.padStart(2, "0"),
    ].join("-");
    const records = snapshot.records[key] ?? {};
    const total = Object.values(records).reduce((sum, value) => sum + value, 0);
    if (total === 0 && !snapshot.dailyNotes[key]) {
      continue;
    }
    lines.push(`${key}  总量 ${total}`);
    for (const department of snapshot.departments) {
      const value = records[department] ?? 0;
      if (value > 0) {
        lines.push(`- ${department}: ${value}`);
      }
    }
    if (snapshot.dailyNotes[key]) {
      lines.push(`- 小记: ${snapshot.dailyNotes[key]}`);
    }
  }
  const active = snapshot.trackedIssues.filter(isOpenIssue);
  if (active.length > 0) {
    lines.push("", "待跟进问题");
    for (const issue of active.slice(0, 10)) {
      lines.push(`#${issue.issueNumber} [${statusLabels[issue.status]}] ${issue.title}`);
    }
  }
  return lines.join("\n").trim();
}

export default function App() {
  const [snapshot, setSnapshot] = useState<AppSnapshot | null>(null);
  const [dateKey] = useState(todayKey());
  const [noteDraft, setNoteDraft] = useState("");
  const [issueTitle, setIssueTitle] = useState("");
  const [issueType, setIssueType] = useState<IssueType>("Bug");
  const [issueDepartment, setIssueDepartment] = useState("");
  const [issueAssignee, setIssueAssignee] = useState("");
  const [issueUrl, setIssueUrl] = useState("");
  const [jsonDraft, setJsonDraft] = useState("");
  const [aiReportText, setAiReportText] = useState("");
  const [message, setMessage] = useState("");
  const [busy, setBusy] = useState(false);
  const [aiBusy, setAiBusy] = useState(false);
  const [issueOpen, setIssueOpen] = useState(false);
  const [historyOpen, setHistoryOpen] = useState(false);
  const [reportOpen, setReportOpen] = useState(false);
  const [dataOpen, setDataOpen] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [departmentDraft, setDepartmentDraft] = useState("");
  const [commentDrafts, setCommentDrafts] = useState<Record<string, string>>({});

  useEffect(() => {
    void refresh();
  }, []);

  useEffect(() => {
    if (snapshot) {
      setNoteDraft(snapshot.dailyNotes[dateKey] ?? "");
      setIssueDepartment(snapshot.departments[0] ?? "");
      setDepartmentDraft(snapshot.departments.join("\n"));
    }
  }, [dateKey, snapshot]);

  const todayTotal = useMemo(() => {
    if (!snapshot) {
      return 0;
    }
    return totalFor(snapshot, dateKey);
  }, [dateKey, snapshot]);

  const openIssueCount = useMemo(
    () => snapshot?.trackedIssues.filter(isOpenIssue).length ?? 0,
    [snapshot],
  );
  const reportText = useMemo(() => (snapshot ? weeklyReport(snapshot) : ""), [snapshot]);

  async function run<T>(action: () => Promise<T>, success?: string) {
    setBusy(true);
    try {
      const result = await action();
      setMessage(success ?? "");
      return result;
    } catch (error) {
      setMessage(error instanceof Error ? error.message : String(error));
      throw error;
    } finally {
      setBusy(false);
    }
  }

  async function refresh() {
    await run(async () => {
      const next = await getSnapshot();
      setSnapshot(next);
      setMessage("已同步");
    });
  }

  async function changeCount(department: string, delta: 1 | -1) {
    const next = await run(
      () =>
        delta > 0
          ? incrementCount(dateKey, department)
          : decrementCount(dateKey, department),
      delta > 0 ? `${department} +1` : `${department} -1`,
    );
    setSnapshot(next);
  }

  async function saveNote() {
    const next = await run(() => setNote(dateKey, noteDraft), "小记已保存");
    setSnapshot(next);
  }

  async function submitIssue() {
    const title = issueTitle.trim();
    if (!title) {
      setMessage("问题标题不能为空");
      return;
    }
    const next = await run(
      () =>
        createIssue(
          {
            title,
            issueType,
            department: issueDepartment,
            assignee: issueAssignee,
            ticketUrl: issueUrl,
          },
          dateKey,
        ),
      "问题已创建",
    );
    setSnapshot(next);
    setIssueTitle("");
    setIssueAssignee("");
    setIssueUrl("");
  }

  async function setIssueStatus(issue: TrackedIssue, status: IssueStatus) {
    const next = await run(
      () => updateIssueStatus(issue.id, status),
      `#${issue.issueNumber} ${statusLabels[status]}`,
    );
    setSnapshot(next);
  }

  async function submitComment(issue: TrackedIssue) {
    const text = commentDrafts[issue.id]?.trim();
    if (!text) {
      return;
    }
    const next = await run(() => addIssueComment(issue.id, text), "备注已追加");
    setSnapshot(next);
    setCommentDrafts((drafts) => ({ ...drafts, [issue.id]: "" }));
  }

  async function exportJson() {
    const json = await run(() => exportSnapshotJson(), "JSON 已导出");
    setJsonDraft(json);
  }

  async function importJson() {
    if (!jsonDraft.trim()) {
      setMessage("请先粘贴 JSON");
      return;
    }
    const next = await run(() => importSnapshotJson(jsonDraft), "JSON 已导入");
    setSnapshot(next);
  }

  async function applySettings() {
    if (!snapshot) {
      return;
    }
    const departments = Array.from(
      new Set(departmentDraft.split("\n").map((item) => item.trim()).filter(Boolean)),
    );
    if (departments.length === 0) {
      setMessage("至少保留一个部门");
      return;
    }
    const next = await run(
      () =>
        saveSnapshot({
          ...snapshot,
          departments,
        }),
      "设置已保存",
    );
    setSnapshot(next);
    setSettingsOpen(false);
  }

  async function clearTodayCounts() {
    if (!snapshot) {
      return;
    }
    const next = await run(
      () =>
        saveSnapshot({
          ...snapshot,
          records: {
            ...snapshot.records,
            [dateKey]: Object.fromEntries(
              snapshot.departments.map((department) => [department, 0]),
            ),
          },
          tapTimestamps: {
            ...snapshot.tapTimestamps,
            [dateKey]: {},
          },
        }),
      "今日计数已清空",
    );
    setSnapshot(next);
  }

  async function copyReport() {
    if (!snapshot) {
      return;
    }
    await run(() => copyText(aiReportText || reportText), "周报已复制");
  }

  async function generateAIReport() {
    if (!reportText.trim()) {
      setMessage("暂无周报原始数据");
      return;
    }
    setAiBusy(true);
    setMessage("AI 周报生成中");
    try {
      const text = await generateAIWeeklyReport(reportText);
      setAiReportText(text);
      setMessage("AI 周报已生成");
    } catch (error) {
      setMessage(error instanceof Error ? error.message : String(error));
    } finally {
      setAiBusy(false);
    }
  }

  async function pingNotification() {
    await run(
      () => notify("TicTracker", `${weekdayLabel(dateKey)} 已记录 ${todayTotal} 条`),
      "已通知",
    );
  }

  async function hidePanel() {
    await hideNativePanel();
  }

  if (!snapshot) {
    return (
      <main className="quick-shell loading-screen">
        <Activity className="spin" size={20} />
        <span>载入中</span>
      </main>
    );
  }

  return (
    <main className="quick-shell">
      <div className="panel-grain" aria-hidden="true" />
      <header className="quick-header">
        <div>
          <strong>Hola</strong>
          <span>{weekdayLabel(dateKey)}</span>
        </div>
        <b>{todayTotal}</b>
        <button className="ghost-button" disabled={busy} onClick={refresh} title="刷新">
          <RefreshCw size={15} />
        </button>
        <button className="ghost-button close-button" onClick={hidePanel} title="关闭面板">
          <X size={15} />
        </button>
      </header>

      <section className="quick-counts">
        {snapshot.departments.map((department) => (
          <div className="quick-row" key={department}>
            <button
              className="row-hit"
              disabled={busy}
              onClick={() => changeCount(department, 1)}
              title={`${department} +1`}
            >
              <span>{department}</span>
              <strong>{countFor(snapshot, dateKey, department)}</strong>
            </button>
            <button
              className="minus-button"
              disabled={busy}
              onClick={() => changeCount(department, -1)}
              title={`${department} -1`}
            >
              <Minus size={13} />
            </button>
          </div>
        ))}
      </section>

      <section className="quick-section">
        <button className="section-toggle" onClick={() => setIssueOpen((value) => !value)}>
          <span>问题追踪 <small>{openIssueCount}</small></span>
          <span className="open-link">打开</span>
        </button>
        {issueOpen ? (
          <div className="quick-expand">
            <div className="issue-create">
              <input
                value={issueTitle}
                onChange={(event) => setIssueTitle(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === "Enter") {
                    void submitIssue();
                  }
                }}
                placeholder="新增问题"
              />
              <select
                aria-label="问题类型"
                value={issueType}
                onChange={(event) => setIssueType(event.target.value as IssueType)}
              >
                {issueTypeOptions.map((type) => (
                  <option key={type} value={type}>
                    {issueTypeLabels[type]}
                  </option>
                ))}
              </select>
              <button disabled={busy} onClick={submitIssue} title="新建问题">
                <Plus size={15} />
              </button>
            </div>
            <select
              aria-label="问题部门"
              className="wide-select"
              value={issueDepartment}
              onChange={(event) => setIssueDepartment(event.target.value)}
            >
              {snapshot.departments.map((department) => (
                <option key={department} value={department}>
                  {department}
                </option>
              ))}
            </select>
            <div className="issue-meta-create">
              <input
                value={issueAssignee}
                onChange={(event) => setIssueAssignee(event.target.value)}
                placeholder="负责人"
              />
              <input
                value={issueUrl}
                onChange={(event) => setIssueUrl(event.target.value)}
                placeholder="外部链接"
              />
            </div>
            <div className="issue-list">
              {latestIssues(snapshot).map((issue) => (
                <article className="issue-item" key={issue.id}>
                  <div className="issue-title-line">
                    <span>#{issue.issueNumber}</span>
                    <strong>{issue.title}</strong>
                  </div>
                  <div className="issue-actions">
                    <select
                      aria-label={`#${issue.issueNumber} 状态`}
                      value={issue.status}
                      onChange={(event) =>
                        setIssueStatus(issue, event.target.value as IssueStatus)
                      }
                    >
                      {statusOptions.map((status) => (
                        <option key={status} value={status}>
                          {statusLabels[status]}
                        </option>
                      ))}
                    </select>
                    <div className="comment-add">
                      <input
                        value={commentDrafts[issue.id] ?? ""}
                        onChange={(event) =>
                          setCommentDrafts((drafts) => ({
                            ...drafts,
                            [issue.id]: event.target.value,
                          }))
                        }
                        onKeyDown={(event) => {
                          if (event.key === "Enter") {
                            void submitComment(issue);
                          }
                        }}
                        placeholder="备注"
                      />
                      <button
                        disabled={busy}
                        onClick={() => submitComment(issue)}
                        title="追加备注"
                      >
                        <Send size={13} />
                      </button>
                    </div>
                    {issue.ticketUrl ? (
                      <button
                        className="link-action"
                        onClick={() => openExternal(issue.ticketUrl ?? "")}
                        title="打开外部链接"
                      >
                        <ExternalLink size={13} />
                        打开链接
                      </button>
                    ) : null}
                  </div>
                </article>
              ))}
              {latestIssues(snapshot).length === 0 ? (
                <div className="empty-line">暂无待跟进问题</div>
              ) : null}
            </div>
          </div>
        ) : null}
      </section>

      <section className="quick-section note-section">
        <div className="section-label">今日小记</div>
        <textarea
          value={noteDraft}
          onBlur={saveNote}
          onChange={(event) => setNoteDraft(event.target.value)}
          placeholder="记录今天需要留痕的上下文"
        />
      </section>

      <section className="quick-section">
        <button className="section-toggle" onClick={() => setHistoryOpen((value) => !value)}>
          <span>最近记录 <small>7</small></span>
          <span className="open-link">打开</span>
        </button>
        {historyOpen ? (
          <div className="quick-expand history-list">
            {recentDays(snapshot).map((day) => (
              <div className="history-row" key={day.key}>
                <span>{day.label}</span>
                <strong>{day.total}</strong>
                <small>{day.note || "无小记"}</small>
              </div>
            ))}
          </div>
        ) : null}
      </section>

      <footer className="quick-footer">
        <button onClick={() => setReportOpen(true)} title="周报预览">
          <Sparkles size={15} />
        </button>
        <button disabled={busy} onClick={pingNotification} title="通知">
          <Bell size={15} />
        </button>
        <button onClick={() => setDataOpen((value) => !value)} title="导入导出">
          <FileJson size={15} />
        </button>
        <button onClick={() => setSettingsOpen(true)} title="设置">
          <Settings size={15} />
        </button>
        <span>{message || `今日 ${todayTotal}`}</span>
      </footer>

      {reportOpen ? (
        <section className="data-drawer">
          <div className="drawer-head">
            <div>
              <strong>AI 周报</strong>
              <span>{aiReportText ? "已生成" : "最近 7 天原始数据"}</span>
            </div>
            <button onClick={() => setReportOpen(false)} title="关闭周报">
              <X size={16} />
            </button>
          </div>
          <textarea readOnly value={aiReportText || reportText || "暂无可复制内容"} />
          <div>
            <button disabled={busy || aiBusy} onClick={generateAIReport}>
              <Sparkles size={14} />
              {aiBusy ? "生成中" : "AI"}
            </button>
            <button disabled={busy} onClick={copyReport}>
              <Clipboard size={14} />
              复制
            </button>
            <button onClick={() => setHistoryOpen(true)}>
              <History size={14} />
              记录
            </button>
            <button onClick={() => setReportOpen(false)}>
              <ChevronRight size={14} />
              收起
            </button>
          </div>
        </section>
      ) : null}

      {dataOpen ? (
        <section className="data-drawer">
          <textarea
            value={jsonDraft}
            onChange={(event) => setJsonDraft(event.target.value)}
            placeholder="AppSnapshot JSON"
          />
          <div>
            <button disabled={busy} onClick={exportJson}>
              <Download size={14} />
              导出
            </button>
            <button disabled={busy} onClick={importJson}>
              <Upload size={14} />
              导入
            </button>
            <button
              disabled={busy || !jsonDraft}
              onClick={() => copyText(jsonDraft).then(() => setMessage("JSON 已复制"))}
            >
              <Clipboard size={14} />
              复制
            </button>
            <button onClick={() => setDataOpen(false)}>
              <ChevronRight size={14} />
              收起
            </button>
          </div>
        </section>
      ) : null}

      {settingsOpen ? (
        <section className="settings-drawer">
          <div className="drawer-head">
            <div>
              <strong>设置</strong>
              <span>菜单栏快捷面板</span>
            </div>
            <button onClick={() => setSettingsOpen(false)} title="关闭设置">
              <X size={16} />
            </button>
          </div>

          <label className="settings-field">
            <span>部门列表</span>
            <textarea
              value={departmentDraft}
              onChange={(event) => setDepartmentDraft(event.target.value)}
              placeholder="每行一个部门"
            />
          </label>
          <div className="drawer-actions">
            <button className="danger-action" disabled={busy} onClick={clearTodayCounts}>
              <Trash2 size={14} />
              清空今日
            </button>
            <button disabled={busy} onClick={applySettings}>
              <Check size={14} />
              保存设置
            </button>
          </div>
        </section>
      ) : null}
    </main>
  );
}
