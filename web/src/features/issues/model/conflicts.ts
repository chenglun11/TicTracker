import axios from 'axios'
import type { TrackedIssue } from '../../../entities/issue/model/types'

interface IssueMutationErrorBody {
  code?: string
  error?: string
  current?: TrackedIssue | null
}

export interface IssueMutationConflict {
  code: 'issue_revision_conflict' | 'issue_deleted'
  current?: TrackedIssue | null
  message: string
}

export function issueMutationConflict(error: unknown): IssueMutationConflict | null {
  if (!axios.isAxiosError<IssueMutationErrorBody>(error)) return null
  const body = error.response?.data
  if (body?.code !== 'issue_revision_conflict' && body?.code !== 'issue_deleted') return null
  return {
    code: body.code,
    current: body.current,
    message: body.error || (body.code === 'issue_deleted' ? '工单已被删除' : '工单已被其他成员更新')
  }
}
