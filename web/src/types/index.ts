export type {
  AddCommentRequest,
  CreateIssueRequest,
  IssueComment as Comment,
  IssuesResponse,
  IssueSource,
  TrackedIssue,
  UpdateIssueRequest
} from '../entities/issue/model/types'

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

export interface SyncMetaResponse {
  revision: number
  lastModified: number
  lastModifiedBy?: string
}

export interface SyncAdminStatus {
  revision: number
  lastModified: number
  lastModifiedBy?: string
  eventCursor: number
  syncTokenConfigured: boolean
  syncTokenHint?: string
  checkedAt: string
}

export interface RotateSyncTokenResponse {
  token: string
  tokenHint: string
  rotatedAt: string
}

export interface SendFeishuResponse {
  success: boolean
  message: string
  nextAvailable?: string
}

export interface SetupConfig {
  initialized: boolean
  departments: string[]
  teamMembers: string[]
  currentMemberName: string
  feishu: {
    enabled: boolean
    webhookCount: number
    webhookURL: string
    webhookSecretConfigured: boolean
    webhookSecretHint?: string
    sendTime: string
    focusIssueTag: string
    appID: string
    appSecretConfigured: boolean
    appSecretHint?: string
    verificationTokenPresent: boolean
    verificationTokenHint?: string
    encryptKeyPresent: boolean
    encryptKeyHint?: string
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
  user: import('../entities/member/model/types').AuthUser
}

export interface InitRequest {
  username: string
  password: string
  setup: SetupRequest
}
