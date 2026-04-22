import { useState } from 'react'
import { Card, Form, Input, Button, Typography, message } from 'antd'
import { LockOutlined } from '@ant-design/icons'
import axios from 'axios'

const { Title, Text } = Typography

interface LoginPageProps {
  onLogin: (token: string) => void
}

function LoginPage({ onLogin }: LoginPageProps) {
  const [loading, setLoading] = useState(false)

  const handleSubmit = async (values: { token: string }) => {
    const token = values.token.trim()
    if (!token) {
      message.error('请输入有效的网页访问 Token')
      return
    }

    setLoading(true)
    try {
      await axios.get('/api/status', {
        headers: { Authorization: `Bearer ${token}` },
        timeout: 10000,
      })
      onLogin(token)
      message.success('登录成功')
    } catch (error: any) {
      if (error.response?.status === 401) {
        message.error('网页访问 Token 无效，请检查后重试')
      } else {
        message.error('无法连接服务器，请检查网络')
      }
    } finally {
      setLoading(false)
    }
  }

  return (
    <div style={{
      display: 'flex',
      justifyContent: 'center',
      alignItems: 'center',
      minHeight: '100vh',
      background: 'linear-gradient(135deg, #667eea 0%, #764ba2 100%)'
    }}>
      <Card
        style={{
          width: 400,
          boxShadow: '0 8px 24px rgba(0,0,0,0.12)'
        }}
      >
        <div style={{ textAlign: 'center', marginBottom: 32 }}>
          <Title level={2}>TicTracker</Title>
          <Text type="secondary">技术支持工单追踪系统</Text>
        </div>

        <Form onFinish={handleSubmit} layout="vertical">
          <Form.Item
            name="token"
            rules={[{ required: true, message: '请输入网页访问 Token' }]}
          >
            <Input.Password
              prefix={<LockOutlined />}
              placeholder="请输入网页访问 Token"
              size="large"
            />
          </Form.Item>

          <Form.Item>
            <Button
              type="primary"
              htmlType="submit"
              loading={loading}
              block
              size="large"
            >
              登录
            </Button>
          </Form.Item>
        </Form>
      </Card>
    </div>
  )
}

export default LoginPage
