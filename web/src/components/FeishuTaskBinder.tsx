import { Space, Tag, Typography } from 'antd'
import type { TrackedIssue } from '../types'

const { Text } = Typography

interface FeishuTaskBinderProps {
  issue: TrackedIssue
}

function FeishuTaskBinder({ issue }: FeishuTaskBinderProps) {
  return (
    <div style={{ padding: '8px 0 12px' }}>
      <Space direction="vertical" size={8} style={{ width: '100%' }}>
        <Space wrap>
          <Text strong>飞书任务绑定</Text>
          {issue.feishuTaskGuid ? <Tag color="cyan">已绑定</Tag> : <Tag>客户端绑定</Tag>}
        </Space>
        {issue.feishuTaskGuid ? (
          <Space wrap size={8}>
            <Text type="secondary">已绑定：</Text>
            <Text code>{issue.feishuTaskGuid}</Text>
            <Text type="secondary">状态由 macOS 客户端从飞书单向同步。</Text>
          </Space>
        ) : (
          <Text type="secondary">Web 端不再使用服务端 tenant token 拉取任务；请在 macOS 客户端授权后绑定。</Text>
        )}
      </Space>
    </div>
  )
}

export default FeishuTaskBinder
