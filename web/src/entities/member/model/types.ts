export type WorkspaceRole = 'admin' | 'member' | 'viewer'

export interface AuthUser {
  username: string
  displayName: string
  role: WorkspaceRole
}

export interface WorkspaceMember extends AuthUser {
  disabledAt?: string
}

export interface CreateMemberRequest {
  username: string
  displayName: string
  role: WorkspaceRole
  password: string
}

export interface UpdateMemberRequest {
  displayName?: string
  role?: WorkspaceRole
  disabled?: boolean
  password?: string
}
