import { Typography, Space } from 'antd'
import { HistoryOutlined } from '@ant-design/icons'
import { formatRelativeTime } from '../utils/format'

const { Text, Title } = Typography

interface SendHistoryProps {
  lastSentTime?: string
}

function SendHistory({ lastSentTime }: SendHistoryProps) {
  return (
    <div>
      <Title level={5}>发送历史</Title>
      <Space>
        <HistoryOutlined />
        <Text type="secondary">
          上次发送: {lastSentTime ? formatRelativeTime(lastSentTime) : '暂无记录'}
        </Text>
      </Space>
    </div>
  )
}

export default SendHistory
