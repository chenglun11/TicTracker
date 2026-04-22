import { useState } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { List, Input, Button, Space, Typography, message } from 'antd'
import type { Comment } from '../types'
import type { AddCommentRequest } from '../types'
import { addComment } from '../api/client'
import { formatDate } from '../utils/format'

const { Text } = Typography

interface CommentSectionProps {
  issueId: string
  comments: Comment[]
}

function CommentSection({ issueId, comments }: CommentSectionProps) {
  const [text, setText] = useState('')
  const queryClient = useQueryClient()

  const mutation = useMutation({
    mutationFn: (data: AddCommentRequest) => addComment(issueId, data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['issues'] })
      setText('')
      message.success('评论添加成功')
    },
    onError: () => {
      message.error('评论添加失败')
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

      <Space.Compact style={{ width: '100%', marginTop: 8 }}>
        <Input
          placeholder="添加评论..."
          value={text}
          onChange={(e) => setText(e.target.value)}
          onPressEnter={() => text.trim() && mutation.mutate({ text: text.trim() })}
        />
        <Button
          type="primary"
          loading={mutation.isPending}
          onClick={() => text.trim() && mutation.mutate({ text: text.trim() })}
        >
          发送
        </Button>
      </Space.Compact>
    </div>
  )
}

export default CommentSection
