import { CloudSyncOutlined, DisconnectOutlined, LoadingOutlined } from '@ant-design/icons'
import { Tooltip } from 'antd'

interface SyncStatusPillProps {
  revision?: number
  isConnected: boolean
  isChecking: boolean
  lastModified?: number
  lastModifiedBy?: string
}

export function SyncStatusPill({
  revision,
  isConnected,
  isChecking,
  lastModified,
  lastModifiedBy
}: SyncStatusPillProps) {
  const icon = isChecking
    ? <LoadingOutlined spin />
    : isConnected
      ? <CloudSyncOutlined />
      : <DisconnectOutlined />
  const label = isConnected ? `线上已连接 · r${revision ?? 0}` : '等待线上连接'
  const actor = lastModifiedBy ? ` · 来源：${lastModifiedBy}` : ''
  const detail = lastModified
    ? `线上数据更新时间：${new Date(lastModified * 1000).toLocaleString('zh-CN')}${actor}`
    : '线上平台是团队数据的唯一来源'

  return (
    <Tooltip title={detail}>
      <span className={`status-pill sync-status-pill ${isConnected ? 'is-online' : 'is-offline'}`}>
        {icon}
        {label}
      </span>
    </Tooltip>
  )
}
