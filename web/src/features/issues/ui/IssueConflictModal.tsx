import { Alert, Button, Descriptions, Modal, Space, Tag, Typography } from 'antd'
import { WarningOutlined } from '@ant-design/icons'
import type { TrackedIssue, UpdateIssueRequest } from '../../../types'

const { Text } = Typography

export interface RecoverableIssueConflict {
  kind: 'update' | 'delete'
  current?: TrackedIssue | null
  attempted?: UpdateIssueRequest
}

interface IssueConflictModalProps {
  conflict: RecoverableIssueConflict | null
  retrying: boolean
  onRetry: () => void
  onAcceptOnline: () => void
}

function attemptedSummary(data?: UpdateIssueRequest) {
  if (!data) return '删除工单'
  return Object.entries(data)
    .map(([key, value]) => `${key}: ${value === null || value === '' ? '清空' : String(value)}`)
    .join(' · ')
}

export function IssueConflictModal({ conflict, retrying, onRetry, onAcceptOnline }: IssueConflictModalProps) {
  const current = conflict?.current
  const deleted = Boolean(conflict && !current)

  return (
    <Modal
      open={Boolean(conflict)}
      title={<Space><WarningOutlined />检测到并发修改</Space>}
      closable={!retrying}
      maskClosable={false}
      onCancel={onAcceptOnline}
      footer={[
        <Button key="online" disabled={retrying} onClick={onAcceptOnline}>采用线上版本</Button>,
        <Button key="retry" type="primary" danger={conflict?.kind === 'delete'} loading={retrying} disabled={deleted} onClick={onRetry}>
          {conflict?.kind === 'delete' ? '基于最新版继续删除' : '保留本次修改并重试'}
        </Button>
      ]}
    >
      <Alert
        type="warning"
        showIcon
        message={deleted ? '这条工单已在线上删除' : '你编辑期间，线上工单已经发生变化'}
        description="系统没有覆盖任何人的内容。请确认采用线上版本，或在最新 revision 上重新应用你刚才的操作。"
        style={{ marginBottom: 16 }}
      />
      {current ? (
        <Descriptions size="small" bordered column={1}>
          <Descriptions.Item label="线上工单">#{current.issueNumber} {current.title}</Descriptions.Item>
          <Descriptions.Item label="线上 revision"><Tag color="blue">r{current.revision}</Tag></Descriptions.Item>
          <Descriptions.Item label="线上状态">{current.status}</Descriptions.Item>
          <Descriptions.Item label="线上负责人">{current.assignee || '未指定'}</Descriptions.Item>
          <Descriptions.Item label="你的操作"><Text code>{attemptedSummary(conflict?.attempted)}</Text></Descriptions.Item>
        </Descriptions>
      ) : null}
    </Modal>
  )
}
