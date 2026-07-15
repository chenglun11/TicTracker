import type {
  StatusResponse,
  SendFeishuResponse,
  SetupConfig,
  SetupRequest,
  AuthStatusResponse,
  LoginRequest,
  LoginResponse,
  InitRequest,
  RotateSyncTokenResponse,
  SyncAdminStatus
} from '../types'
import { API_BASE, httpClient } from '../shared/api/http'

export const getStatus = async (): Promise<StatusResponse> => {
  const { data } = await httpClient.get<StatusResponse>(`${API_BASE}/status`)
  return data
}

export const sendFeishu = async (): Promise<SendFeishuResponse> => {
  const { data } = await httpClient.post<SendFeishuResponse>(`${API_BASE}/feishu/send`)
  return data
}

export const getSetup = async (): Promise<SetupConfig> => {
  const { data } = await httpClient.get<SetupConfig>(`${API_BASE}/setup`)
  return data
}

export const saveSetup = async (payload: SetupRequest): Promise<SetupConfig> => {
  const { data } = await httpClient.put<SetupConfig>(`${API_BASE}/setup`, payload)
  return data
}

export const getAuthStatus = async (): Promise<AuthStatusResponse> => {
  const { data } = await httpClient.get<AuthStatusResponse>(`${API_BASE}/auth/status`)
  return data
}

export const login = async (payload: LoginRequest): Promise<LoginResponse> => {
  const { data } = await httpClient.post<LoginResponse>(`${API_BASE}/auth/login`, payload)
  return data
}

export const initSystem = async (payload: InitRequest): Promise<LoginResponse> => {
  const { data } = await httpClient.post<LoginResponse>(`${API_BASE}/auth/init`, payload)
  return data
}

export const logout = async (): Promise<void> => {
  await httpClient.post(`${API_BASE}/auth/logout`)
}

export const changePassword = async (payload: { currentPassword: string; newPassword: string }): Promise<LoginResponse> => {
  const { data } = await httpClient.post<LoginResponse>(`${API_BASE}/auth/password`, payload)
  return data
}

export const getSyncAdminStatus = async (): Promise<SyncAdminStatus> => {
  const { data } = await httpClient.get<SyncAdminStatus>(`${API_BASE}/sync/status`)
  return data
}

export const rotateSyncToken = async (): Promise<RotateSyncTokenResponse> => {
  const { data } = await httpClient.post<RotateSyncTokenResponse>(`${API_BASE}/sync/token/rotate`)
  return data
}
