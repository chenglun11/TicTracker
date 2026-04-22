import { useState, useEffect } from 'react'
import { Layout, Button, Space, Typography } from 'antd'
import { LogoutOutlined } from '@ant-design/icons'
import Dashboard from './components/Dashboard'
import LoginPage from './components/LoginPage'

const { Header, Content } = Layout
const { Title } = Typography

function tokenFromHash(): string | null {
  const hash = window.location.hash.startsWith('#') ? window.location.hash.slice(1) : window.location.hash
  const params = new URLSearchParams(hash)
  const token = params.get('token')?.trim()
  return token ? token : null
}

function App() {
  const [token, setToken] = useState<string | null>(null)

  useEffect(() => {
    const hashToken = tokenFromHash()
    if (hashToken) {
      localStorage.setItem('token', hashToken)
      window.history.replaceState(null, '', `${window.location.pathname}${window.location.search}`)
      setToken(hashToken)
      return
    }

    const savedToken = localStorage.getItem('token')
    if (savedToken) {
      setToken(savedToken)
    }
  }, [])

  const handleLogin = (newToken: string) => {
    localStorage.setItem('token', newToken)
    setToken(newToken)
  }

  const handleLogout = () => {
    localStorage.removeItem('token')
    setToken(null)
  }

  if (!token) {
    return <LoginPage onLogin={handleLogin} />
  }

  return (
    <Layout style={{ minHeight: '100vh' }}>
      <Header style={{
        background: '#001529',
        display: 'flex',
        justifyContent: 'space-between',
        alignItems: 'center',
        padding: '0 24px'
      }}>
        <Title level={3} style={{ color: 'white', margin: 0 }}>
          TicTracker - 技术支持工单追踪
        </Title>
        <Space>
          <Button
            type="text"
            icon={<LogoutOutlined />}
            onClick={handleLogout}
            style={{ color: 'white' }}
          >
            退出登录
          </Button>
        </Space>
      </Header>
      <Content style={{ padding: '24px', minWidth: '1024px' }}>
        <Dashboard />
      </Content>
    </Layout>
  )
}

export default App
