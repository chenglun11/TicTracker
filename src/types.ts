export type IssueType = "Bug" | "Feature" | "Support";

export type IssueStatus =
  | "Pending"
  | "InProgress"
  | "Testing"
  | "Scheduled"
  | "Observing"
  | "Fixed"
  | "Ignored";

export interface TeamMember {
  id: string;
  name: string;
}

export interface IssueComment {
  id: string;
  text: string;
  createdAt: string;
}

export interface TrackedIssue {
  id: string;
  issueNumber: number;
  issueType: IssueType;
  title: string;
  dateKey: string;
  createdAt: string;
  updatedAt?: string | null;
  status: IssueStatus;
  source: string;
  assignee?: string | null;
  ticketUrl?: string | null;
  department?: string | null;
  comments: IssueComment[];
  followers: string[];
  tags: string[];
}

export interface TodoTask {
  id: string;
  title: string;
  description: string;
  isCompleted: boolean;
  dueDate?: string | null;
  priority: string;
  createdAt: string;
  completedAt?: string | null;
  dateKey: string;
}

export interface RssFeed {
  id: string;
  title: string;
  url: string;
  isEnabled: boolean;
}

export interface JiraConfig {
  enabled: boolean;
  baseUrl: string;
}

export interface LinearConfig {
  enabled: boolean;
  teamId: string;
  projectId: string;
}

export interface FeishuBotConfig {
  enabled: boolean;
  sendHour: number;
  sendMinute: number;
}

export interface AiConfig {
  enabled: boolean;
  provider: string;
  baseUrl: string;
  model: string;
  customPrompt: string;
}

export interface AppSnapshot {
  version: number;
  departments: string[];
  records: Record<string, Record<string, number>>;
  dailyNotes: Record<string, string>;
  tapTimestamps: Record<string, Record<string, string[]>>;
  trackedIssues: TrackedIssue[];
  teamMembers: TeamMember[];
  currentMemberId: string;
  todoTasks: TodoTask[];
  rssFeeds: RssFeed[];
  jiraConfig: JiraConfig;
  linearConfig: LinearConfig;
  feishuBotConfig: FeishuBotConfig;
  aiConfig: AiConfig;
}

export interface IssueCounts {
  open: number;
  resolved: number;
  observing: number;
  today: number;
}

export interface AppOverview {
  todayKey: string;
  todayTotal: number;
  todayNote: string;
  issueCounts: IssueCounts;
  pendingTodos: number;
}

export interface CreateIssueInput {
  title: string;
  issueType: IssueType;
  department?: string;
  assignee?: string;
  ticketUrl?: string;
}

export interface TodoUpdateInput {
  id: string;
  title?: string;
  description?: string;
  isCompleted?: boolean;
  priority?: string;
}
