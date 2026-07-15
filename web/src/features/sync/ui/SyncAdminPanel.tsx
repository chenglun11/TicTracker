import { useState } from 'react'
import { Alert, Button, Card, Col, Popconfirm, Row, Space, Statistic, Tag, Typography, message } from 'antd'
import { CopyOutlined, ReloadOutlined, SafetyCertificateOutlined, SyncOutlined } from '@ant-design/icons'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { getSyncAdminStatus, rotateSyncToken } from '../../../api/client'
import { queryKeys } from '../../../shared/api/queryKeys'

const { Text } = Typography

function formatTimestamp(value?: number) {
  if (!value) return '暂无上传记录'
  return new Date(value * 1000).toLocaleString('zh-CN')
}

export default function SyncAdminPanel() {
  const queryClient = useQueryClient()
  const [newToken, setNewToken] = useState<string | null>(null)
  const status = useQuery({
    queryKey: queryKeys.sync.admin,
    queryFn: getSyncAdminStatus,
    refetchInterval: 15000
  })
  const rotate = useMutation({
    mutationFn: rotateSyncToken,
    onSuccess: (result) => {
      setNewToken(result.token)
      void queryClient.invalidateQueries({ queryKey: queryKeys.sync.admin })
      message.success('同步 Token 已轮换；请立即更新 macOS 客户端')
    },
    onError: () => message.error('同步 Token 轮换失败，请检查管理员会话')
  })

  const copyToken = async () => {
    if (!newToken) return
    await navigator.clipboard.writeText(newToken)
    message.success('Token 已复制')
  }

  return (
    <Card
      className="sync-admin-panel"
      title={
        <div className="sync-admin-heading">
          <span className="sync-admin-icon"><SyncOutlined /></span>
          <span>
            <strong>同步中心</strong>
            <small>线上工作区 · 多设备状态</small>
          </span>
        </div>
      }
      extra={<Button icon={<ReloadOutlined />} loading={status.isFetching} onClick={() => void status.refetch()}>刷新</Button>}
    >
      <div className="sync-admin-hero">
        <div>
          <div className="sync-admin-eyebrow"><span className="sync-admin-live-dot" />实时监测</div>
          <h3>让每一次提交都有迹可循</h3>
          <p>服务端以 Revision 记录工作区变更，客户端可安全地拉取、提交和恢复。</p>
        </div>
        <div className="sync-admin-hero-mark">r{status.data?.revision ?? 0}</div>
      </div>
      {status.isError ? <Alert type="error" showIcon message="同步状态读取失败" description="请确认当前管理员会话仍有效。" /> : null}
      <Row className="sync-admin-metrics" gutter={[10, 10]}>
        <Col xs={12} md={6}><div className="sync-admin-metric"><Statistic title="线上 Revision" value={status.data?.revision ?? 0} prefix="r" /><span>当前服务端版本</span></div></Col>
        <Col xs={12} md={6}><div className="sync-admin-metric"><Statistic title="事件游标" value={status.data?.eventCursor ?? 0} /><span>增量同步位置</span></div></Col>
        <Col xs={24} md={12}>
          <div className="sync-admin-upload-state">
            <Text type="secondary">最近一次服务端变更</Text>
            <strong>{formatTimestamp(status.data?.lastModified)}</strong>
            <span>来源：{status.data?.lastModifiedBy || '暂无记录'}</span>
          </div>
        </Col>
      </Row>
      <div className="sync-admin-token-row">
        <div>
          <Text strong>同步 Token</Text>
          <div>
            {status.data?.syncTokenConfigured ? <Tag color="green">已配置 {status.data.syncTokenHint}</Tag> : <Tag color="red">未配置</Tag>}
            <Text type="secondary">仅用于 macOS /sync，不等同于网页登录 Token</Text>
          </div>
        </div>
        <Popconfirm
          title="轮换同步 Token？"
          description="旧 Token 会立即失效，所有 macOS 客户端都需要更新。"
          okText="确认轮换"
          cancelText="取消"
          onConfirm={() => rotate.mutate()}
        >
          <Button danger icon={<SafetyCertificateOutlined />} loading={rotate.isPending}>轮换 Token</Button>
        </Popconfirm>
      </div>
      {newToken ? (
        <Alert
          type="warning"
          showIcon
          message="新 Token 只在这里显示一次"
          description={<Space.Compact style={{ width: '100%' }}><Text code copyable={{ text: newToken }}>{newToken}</Text><Button icon={<CopyOutlined />} onClick={() => void copyToken}>复制</Button></Space.Compact>}
        />
      ) : null}
      <div className="sync-admin-footnote">每 15 秒自动刷新。只有真正写入服务端的上传或 Issue 变更才会推进 Revision；普通读取不会改变版本。</div>
    </Card>
  )
}
