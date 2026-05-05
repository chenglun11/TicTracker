export type IssueSource = 'Web' | '手动' | 'Jira' | 'Meta Direct Support' | '飞书文档' | string

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
  comments: Comment[]
  feishuTaskGuid?: string
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
}

export interface CreateIssueRequest {
  title: string
  type: string
  department?: string
  ticketURL?: string
}

export interface AddCommentRequest {
  text: string
}
