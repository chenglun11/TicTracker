import { invoke } from "@tauri-apps/api/core";
import type {
  AppOverview,
  AppSnapshot,
  CreateIssueInput,
  IssueStatus,
  TodoUpdateInput,
} from "./types";

export async function getSnapshot() {
  return invoke<AppSnapshot>("get_snapshot");
}

export async function getOverview() {
  return invoke<AppOverview>("get_overview");
}

export async function saveSnapshot(snapshot: AppSnapshot) {
  return invoke<AppSnapshot>("save_snapshot", { snapshot });
}

export async function incrementCount(dateKey: string, department: string) {
  return invoke<AppSnapshot>("increment_count", { dateKey, department });
}

export async function decrementCount(dateKey: string, department: string) {
  return invoke<AppSnapshot>("decrement_count", { dateKey, department });
}

export async function setNote(dateKey: string, text: string) {
  return invoke<AppSnapshot>("set_note", { dateKey, text });
}

export async function createIssue(input: CreateIssueInput, dateKey: string) {
  return invoke<AppSnapshot>("create_issue", { input, dateKey });
}

export async function updateIssueStatus(id: string, status: IssueStatus) {
  return invoke<AppSnapshot>("update_issue_status", { id, status });
}

export async function addIssueComment(id: string, text: string) {
  return invoke<AppSnapshot>("add_issue_comment", { id, text });
}

export async function createTodo(title: string, dateKey: string, priority?: string) {
  return invoke<AppSnapshot>("create_todo", { title, dateKey, priority });
}

export async function updateTodo(input: TodoUpdateInput) {
  return invoke<AppSnapshot>("update_todo", { input });
}

export async function exportSnapshotJson() {
  return invoke<string>("export_snapshot_json");
}

export async function importSnapshotJson(json: string) {
  return invoke<AppSnapshot>("import_snapshot_json", { json });
}

export async function copyText(text: string) {
  return invoke<void>("copy_text", { text });
}

export async function openExternal(url: string) {
  return invoke<void>("open_external", { url });
}

export async function notify(title: string, body: string) {
  return invoke<void>("notify", { title, body });
}

export async function hidePanel() {
  return invoke<void>("hide_panel");
}

export async function generateAIWeeklyReport(rawReport: string) {
  return invoke<string>("generate_ai_weekly_report", { rawReport });
}
