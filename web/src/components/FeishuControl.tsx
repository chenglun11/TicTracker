import { useState, useEffect } from 'react'
import { Button, Typography, message } from 'antd'
import { ClockCircleOutlined, SendOutlined } from '@ant-design/icons'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { sendFeishu } from '../api/client'
import SendHistory from './SendHistory'

const { Text } = Typography

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

  const statusText = !feishuEnabled ? '未启用' : formatCountdown(countdown)
  const statusTone = !feishuEnabled ? 'var(--tt-gold)' : countdown > 0 ? 'var(--tt-gold)' : 'var(--tt-green)'

  return (
    <div className="side-panel">
      <div className="side-panel-title">飞书日报</div>
      <div className="side-panel-copy">
        手动发送和定时发送使用同一份日报快照；重点 Tag 只影响额外分组，不改变完整统计。
      </div>

      <div className="feishu-status-line">
        <span className="status-pill" style={{ color: statusTone }}>
          <ClockCircleOutlined />
          {statusText}
        </span>
      </div>

      <Button
        type="primary"
        icon={<SendOutlined />}
        onClick={handleSend}
        loading={mutation.isPending}
        disabled={!feishuEnabled || countdown > 0}
        block
      >
        立即发送日报
      </Button>

      <div style={{ marginTop: 14 }}>
        <Text type="secondary" style={{ fontSize: 12 }}>最近发送</Text>
        <SendHistory lastSentTime={lastSentTime} />
      </div>
    </div>
  )
}

export default FeishuControl
