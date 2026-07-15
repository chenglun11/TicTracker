import type {
  AuthUser,
  CreateMemberRequest,
  UpdateMemberRequest,
  WorkspaceMember
} from '../../../entities/member/model/types'
import { API_BASE, httpClient } from '../../../shared/api/http'

export async function getCurrentUser(): Promise<AuthUser> {
  const { data } = await httpClient.get<{ user: AuthUser }>(`${API_BASE}/auth/me`)
  return data.user
}

export async function getMembers(): Promise<WorkspaceMember[]> {
  const { data } = await httpClient.get<{ members: WorkspaceMember[] }>(`${API_BASE}/members`)
  return data.members
}

export async function createMember(request: CreateMemberRequest) {
  const { data } = await httpClient.post(`${API_BASE}/members`, request)
  return data
}

export async function updateMember(username: string, request: UpdateMemberRequest) {
  const { data } = await httpClient.patch(`${API_BASE}/members/${encodeURIComponent(username)}`, request)
  return data
}
