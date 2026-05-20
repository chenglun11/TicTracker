import { useState } from 'react'
import { Form, Input, Button, Typography, message } from 'antd'
import { LockOutlined, UserOutlined } from '@ant-design/icons'
import { login } from '../api/client'

const { Title, Text } = Typography

interface LoginPageProps {
  onLogin: (token: string) => void
}

function LoginPage({ onLogin }: LoginPageProps) {
  const [loading, setLoading] = useState(false)

  const handleSubmit = async (values: { username: string; password: string }) => {
    const username = values.username.trim()
    if (!username || !values.password) {
      message.error('请输入账号和密码')
      return
    }

    setLoading(true)
    try {
      const res = await login({ username, password: values.password })
      onLogin(res.token)
      message.success('登录成功')
    } catch (error: any) {
      if (error.response?.status === 401) {
        message.error('账号或密码不正确')
      } else {
        message.error('无法连接服务器，请检查网络')
      }
    } finally {
      setLoading(false)
    }
  }

  return (
    <div className="login-shell">
      <div className="login-panel">
        <div style={{ textAlign: 'center', marginBottom: 32 }}>
          <Title level={2}>TicTracker</Title>
          <Text type="secondary">使用初始化时创建的账号登录</Text>
        </div>

        <Form onFinish={handleSubmit} layout="vertical">
          <Form.Item
            name="username"
            label="账号"
            rules={[{ required: true, message: '请输入账号' }]}
          >
            <Input prefix={<UserOutlined />} placeholder="admin" size="large" autoComplete="username" />
          </Form.Item>

          <Form.Item
            name="password"
            label="密码"
            rules={[{ required: true, message: '请输入密码' }]}
          >
            <Input.Password
              prefix={<LockOutlined />}
              placeholder="请输入密码"
              size="large"
              autoComplete="current-password"
            />
          </Form.Item>

          <Form.Item>
            <Button type="primary" htmlType="submit" loading={loading} block size="large">
              登录
            </Button>
          </Form.Item>
        </Form>
      </div>
    </div>
  )
}

export default LoginPage
