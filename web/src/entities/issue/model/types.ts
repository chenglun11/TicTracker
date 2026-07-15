export type IssueSource = 'Web' | '手动' | 'Jira' | 'Meta Direct Support' | '飞书任务' | string

export interface IssueComment {
  id: string
  text: string
  createdAt: string | number
}

export interface TrackedIssue {
  revision: number
  id: string
  issueNumber: number
  type: string
  title: string
  dateKey: string
  createdAt: string | number
  updatedAt?: string | number | null
  updatedBy?: string | null
  deletedAt?: string | number | null
  status: string
  source: IssueSource
  assignee?: string
  jiraKey?: string
  ticketURL?: string
  department?: string
  resolvedAt?: string | number
  hasDevActivity: boolean
  isEscalated?: boolean
  comments: IssueComment[]
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
  linearCreator?: string
  linearCreatedAt?: string
  linearUpdatedAt?: string
  followers?: string[]
  reporterId?: string
  reporterName?: string
  reportedAt?: string | number
  issueTags?: string[]
}

export interface IssuesResponse {
  issues: TrackedIssue[]
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
