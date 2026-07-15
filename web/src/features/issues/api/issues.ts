import type {
  AddCommentRequest,
  CreateIssueRequest,
  IssuesResponse,
  UpdateIssueRequest
} from '../../../entities/issue/model/types'
import { API_BASE, httpClient } from '../../../shared/api/http'

export const getIssues = async (status?: string): Promise<IssuesResponse> => {
  const { data } = await httpClient.get<IssuesResponse>(`${API_BASE}/issues`, {
    params: status ? { status } : undefined
  })
  return data
}

const revisionHeaders = (revision: number) => ({ 'If-Match': `"${revision}"` })

export const updateIssue = async (id: string, revision: number, data: UpdateIssueRequest) => {
  const { data: response } = await httpClient.patch(`${API_BASE}/issues/${id}`, data, {
    headers: revisionHeaders(revision)
  })
  return response
}

export const addComment = async (issueId: string, revision: number, data: AddCommentRequest) => {
  const { data: response } = await httpClient.post(`${API_BASE}/issues/${issueId}/comments`, data, {
    headers: revisionHeaders(revision)
  })
  return response
}

export const createIssue = async (data: CreateIssueRequest) => {
  const { data: response } = await httpClient.post(`${API_BASE}/issues`, data)
  return response
}

export const deleteIssue = async (id: string, revision: number) => {
  const { data } = await httpClient.delete(`${API_BASE}/issues/${id}`, {
    headers: revisionHeaders(revision)
  })
  return data
}

export const claimIssue = async (id: string, revision: number) => {
  const { data } = await httpClient.post(`${API_BASE}/issues/${id}/claim`, undefined, {
    headers: revisionHeaders(revision)
  })
  return data
}
