import { useState } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { Alert, List, Input, Button, Space, Typography, message } from 'antd'
import type { Comment } from '../types'
import type { AddCommentRequest } from '../types'
import { addComment } from '../features/issues/api/issues'
import { issueMutationConflict } from '../features/issues/model/conflicts'
import { queryKeys } from '../shared/api/queryKeys'
import { formatDate } from '../utils/format'

const { Text } = Typography

interface CommentSectionProps {
  issueId: string
  revision: number
  comments: Comment[]
  readOnly?: boolean
}

function CommentSection({ issueId, revision, comments, readOnly = false }: CommentSectionProps) {
  const [text, setText] = useState('')
  const [retryRevision, setRetryRevision] = useState<number | null>(null)
  const queryClient = useQueryClient()

  const mutation = useMutation({
    mutationFn: ({ data, baseRevision }: { data: AddCommentRequest; baseRevision: number }) =>
      addComment(issueId, baseRevision, data),
    onSuccess: () => {
    queryClient.invalidateQueries({ queryKey: queryKeys.issues.all })
      setText('')
      message.success('评论添加成功')
    },
    onError: (error) => {
      queryClient.invalidateQueries({ queryKey: queryKeys.issues.all })
      const current = issueMutationConflict(error)?.current
      if (current) {
        setRetryRevision(current.revision)
        return
      }
      message.error('评论未保存，请检查网络后重试')
    }
  })

  return (
    <div style={{ padding: '8px 0' }}>
      <List
        size="small"
        dataSource={comments}
        renderItem={(comment) => (
          <List.Item>
            <Text type="secondary" style={{ marginRight: 8 }}>
              {formatDate(comment.createdAt)}
            </Text>
            <Text>{comment.text}</Text>
          </List.Item>
        )}
        locale={{ emptyText: '暂无评论' }}
      />

      {retryRevision !== null ? (
        <Alert
          type="warning"
          showIcon
          message="线上刚有新评论或状态变化"
          description={(
            <Space wrap>
              <span>你的评论仍保留在输入框，可基于最新版 r{retryRevision} 重试。</span>
              <Button
                size="small"
                type="primary"
                loading={mutation.isPending}
                onClick={() => text.trim() && mutation.mutate(
                  { data: { text: text.trim() }, baseRevision: retryRevision },
                  { onSuccess: () => setRetryRevision(null) }
                )}
              >
                保留评论并重试
              </Button>
              <Button size="small" onClick={() => setRetryRevision(null)}>取消</Button>
            </Space>
          )}
          style={{ marginBottom: 8 }}
        />
      ) : null}

      {!readOnly ? <Space.Compact style={{ width: '100%', marginTop: 8 }}>
        <Input
          placeholder="添加评论..."
          value={text}
          onChange={(e) => setText(e.target.value)}
          onPressEnter={() => text.trim() && mutation.mutate({ data: { text: text.trim() }, baseRevision: revision })}
        />
        <Button
          type="primary"
          loading={mutation.isPending}
          onClick={() => text.trim() && mutation.mutate({ data: { text: text.trim() }, baseRevision: revision })}
        >
          发送
        </Button>
      </Space.Compact> : <Text type="secondary">只读角色不能添加评论</Text>}
    </div>
  )
}

export default CommentSection
