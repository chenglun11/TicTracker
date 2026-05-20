import axios from 'axios'
import type {
  StatusResponse,
  IssuesResponse,
  SendFeishuResponse,
  UpdateIssueRequest,
  CreateIssueRequest,
  AddCommentRequest,
  SetupConfig,
  SetupRequest,
  AuthStatusResponse,
  LoginRequest,
  LoginResponse,
  InitRequest
} from '../types'

const client = axios.create({
  baseURL: '',
  timeout: 30000
})

client.interceptors.request.use((config) => {
  const token = localStorage.getItem('token')
  if (token) {
    config.headers.Authorization = `Bearer ${token}`
  }
  return config
})

client.interceptors.response.use(
  (response) => response,
  (error) => {
    if (error.response?.status === 401) {
      localStorage.removeItem('token')
      window.history.replaceState(null, '', `${window.location.pathname}${window.location.search}`)
      window.location.reload()
    }
    return Promise.reject(error)
  }
)

const API_BASE = '/api/v1'

export const getStatus = async (): Promise<StatusResponse> => {
  const { data } = await client.get<StatusResponse>(`${API_BASE}/status`)
  return data
}

export const getIssues = async (status?: string): Promise<IssuesResponse> => {
  const { data } = await client.get<IssuesResponse>(`${API_BASE}/issues`, {
    params: status ? { status } : undefined
  })
  return data
}

export const sendFeishu = async (): Promise<SendFeishuResponse> => {
  const { data } = await client.post<SendFeishuResponse>(`${API_BASE}/feishu/send`)
  return data
}

export const updateIssue = async (id: string, data: UpdateIssueRequest) => {
  const { data: res } = await client.patch(`${API_BASE}/issues/${id}`, data)
  return res
}

export const addComment = async (issueId: string, data: AddCommentRequest) => {
  const { data: res } = await client.post(`${API_BASE}/issues/${issueId}/comments`, data)
  return res
}

export const createIssue = async (data: CreateIssueRequest) => {
  const { data: res } = await client.post(`${API_BASE}/issues`, data)
  return res
}

export const deleteIssue = async (id: string) => {
  const { data } = await client.delete(`${API_BASE}/issues/${id}`)
  return data
}

export const getSetup = async (): Promise<SetupConfig> => {
  const { data } = await client.get<SetupConfig>(`${API_BASE}/setup`)
  return data
}

export const saveSetup = async (payload: SetupRequest): Promise<SetupConfig> => {
  const { data } = await client.put<SetupConfig>(`${API_BASE}/setup`, payload)
  return data
}

export const getAuthStatus = async (): Promise<AuthStatusResponse> => {
  const { data } = await client.get<AuthStatusResponse>(`${API_BASE}/auth/status`)
  return data
}

export const login = async (payload: LoginRequest): Promise<LoginResponse> => {
  const { data } = await client.post<LoginResponse>(`${API_BASE}/auth/login`, payload)
  return data
}

export const initSystem = async (payload: InitRequest): Promise<LoginResponse> => {
  const { data } = await client.post<LoginResponse>(`${API_BASE}/auth/init`, payload)
  return data
}
