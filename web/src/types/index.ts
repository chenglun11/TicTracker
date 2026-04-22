export interface TrackedIssue {
  id: string
  issueNumber: number
  type: string
  title: string
  dateKey: string
  createdAt: string
  status: string
  source: string
  assignee?: string
  jiraKey?: string
  department?: string
  resolvedAt?: string
  hasDevActivity: boolean
  comments: Comment[]
}

export interface Comment {
  id: string
  text: string
  createdAt: string
}

export interface StatusResponse {
  statistics: {
    newToday: number
    resolvedToday: number
    pending: number
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
}

export interface CreateIssueRequest {
  title: string
  type: string
  department?: string
}

export interface AddCommentRequest {
  text: string
}
