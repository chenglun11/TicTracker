import { useState, useEffect } from 'react'
import { Card, Button, Space, Typography, message, Divider } from 'antd'
import { SendOutlined, ClockCircleOutlined } from '@ant-design/icons'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { sendFeishu } from '../api/client'
import SendHistory from './SendHistory'

const { Text, Title } = Typography

interface FeishuControlProps {
  lastSentTime?: string
  cooldownRemain: number
  feishuEnabled: boolean
}

function FeishuControl({ lastSentTime, cooldownRemain, feishuEnabled }: FeishuControlProps) {
  const [countdown, setCountdown] = useState(cooldownRemain)
  const queryClient = useQueryClient()

  useEffect(() => {
    setCountdown(cooldownRemain)
  }, [cooldownRemain])

  useEffect(() => {
    if (countdown <= 0) return

    const timer = setInterval(() => {
      setCountdown(prev => {
        if (prev <= 1) {
          clearInterval(timer)
          return 0
        }
        return prev - 1
      })
    }, 1000)

    return () => clearInterval(timer)
  }, [countdown > 0]) // eslint-disable-line react-hooks/exhaustive-deps

  const mutation = useMutation({
    mutationFn: sendFeishu,
    onSuccess: (data) => {
      if (data.success) {
        message.success(data.message || '发送成功')
        queryClient.invalidateQueries({ queryKey: ['status'] })
      } else {
        message.error(data.message || '发送失败')
      }
    },
    onError: (error: any) => {
      message.error(error.response?.data?.message || '发送失败，请稍后重试')
    }
  })

  const handleSend = () => {
    if (countdown > 0) {
      message.warning(`请等待 ${countdown} 秒后再发送`)
      return
    }
    mutation.mutate()
  }

  const formatCountdown = (seconds: number): string => {
    if (seconds <= 0) return '可以发送'
    const minutes = Math.floor(seconds / 60)
    const secs = seconds % 60
    return minutes > 0 ? `${minutes}分${secs}秒` : `${secs}秒`
  }

  return (
    <Card title="飞书通知控制">
      <Space direction="vertical" style={{ width: '100%' }} size="large">
        <div>
          <Title level={5}>发送状态</Title>
          {!feishuEnabled && (
            <Text type="warning">飞书通知未启用</Text>
          )}
          {feishuEnabled && countdown > 0 && (
            <Space>
              <ClockCircleOutlined style={{ color: '#faad14' }} />
              <Text type="warning">冷却中: {formatCountdown(countdown)}</Text>
            </Space>
          )}
          {feishuEnabled && countdown <= 0 && (
            <Text type="success">可以发送</Text>
          )}
        </div>

        <Button
          type="primary"
          icon={<SendOutlined />}
          onClick={handleSend}
          loading={mutation.isPending}
          disabled={!feishuEnabled || countdown > 0}
          block
          size="large"
        >
          发送飞书通知
        </Button>

        <Divider />

        <SendHistory lastSentTime={lastSentTime} />
      </Space>
    </Card>
  )
}

export default FeishuControl
