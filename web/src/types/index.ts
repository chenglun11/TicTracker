export type IssueSource = 'Web' | '手动' | 'Jira' | 'Meta Direct Support' | '飞书任务' | string

export interface TrackedIssue {
  id: string
  issueNumber: number
  type: string
  title: string
  dateKey: string
  createdAt: string | number
  status: string
  source: IssueSource
  assignee?: string
  jiraKey?: string
  ticketURL?: string
  department?: string
  resolvedAt?: string | number
  hasDevActivity: boolean
  isEscalated?: boolean
  comments: Comment[]
  feishuTaskGuid?: string
  feishuTaskSummary?: string
  feishuTaskCompletedAt?: string
  feishuTasklistGuids?: string[]
  feishuTaskAssigneeIds?: string[]
  linearIssueId?: string
  linearKey?: string
  linearUrl?: string
  linearProjectId?: string
  linearProjectName?: string
  linearAssignee?: string
  followers?: string[]
  reporterId?: string
  reporterName?: string
  reportedAt?: string | number
  issueTags?: string[]
}

export interface Comment {
  id: string
  text: string
  createdAt: string | number
}

export interface StatusResponse {
  statistics: {
    newToday: number
    resolvedToday: number
    pending: number
    scheduled: number
    testing: number
    observing: number
  }
  lastSentTime?: string
  cooldownRemain: number
  feishuEnabled: boolean
  todayTotal: number
  departments: string[]
}

export interface IssuesResponse {
  issues: TrackedIssue[]
}

export interface SendFeishuResponse {
  success: boolean
  message: string
  nextAvailable?: string
}

export interface UpdateIssueRequest {
  status?: string
  assignee?: string
  department?: string
  ticketURL?: string
  feishuTaskGuid?: string | null
  reporterId?: string
  reporterName?: string
  issueTags?: string[]
}

export interface CreateIssueRequest {
  title: string
  type: string
  department?: string
  ticketURL?: string
  reporterId?: string
  reporterName?: string
  issueTags?: string[]
}

export interface AddCommentRequest {
  text: string
}

export interface SetupConfig {
  initialized: boolean
  departments: string[]
  teamMembers: string[]
  currentMemberName: string
  feishu: {
    enabled: boolean
    webhookCount: number
    webhookSecretConfigured: boolean
    sendTime: string
    focusIssueTag: string
    appID: string
    appSecretConfigured: boolean
    verificationTokenPresent: boolean
    encryptKeyPresent: boolean
    tasklistGUID: string
  }
  linear: {
    enabled: boolean
    teamId: string
    teamName: string
    projectId: string
    projectName: string
  }
}

export interface SetupRequest {
  departments: string[]
  teamMembers: string[]
  currentMemberName: string
  feishu: {
    enabled: boolean
    webhookURL: string
    webhookSecret: string
    sendHour: number
    sendMinute: number
    focusIssueTag: string
    appID: string
    appSecret: string
    verificationToken: string
    encryptKey: string
    tasklistGUID: string
  }
  linear: {
    enabled: boolean
    teamId: string
    teamName: string
    projectId: string
    projectName: string
  }
}

export interface AuthStatusResponse {
  initialized: boolean
}

export interface LoginRequest {
  username: string
  password: string
}

export interface LoginResponse {
  token: string
}

export interface InitRequest {
  username: string
  password: string
  setup: SetupRequest
}
