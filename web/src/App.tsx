import { useState, useEffect } from 'react'
import { Layout, Button, Space, Typography } from 'antd'
import { LogoutOutlined, SettingOutlined } from '@ant-design/icons'
import { useQuery } from '@tanstack/react-query'
import { getAuthStatus, getSetup } from './api/client'
import Dashboard from './components/Dashboard'
import InitPage from './components/InitPage'
import LoginPage from './components/LoginPage'

const { Header, Content } = Layout
const { Text } = Typography

function tokenFromHash(): string | null {
  const hash = window.location.hash.startsWith('#') ? window.location.hash.slice(1) : window.location.hash
  const params = new URLSearchParams(hash)
  const token = params.get('token')?.trim()
  return token ? token : null
}

function App() {
  const [token, setToken] = useState<string | null>(null)
  const [showInit, setShowInit] = useState(false)

  const { data: authStatus, isLoading: authLoading } = useQuery({
    queryKey: ['auth-status'],
    queryFn: getAuthStatus,
    enabled: !token
  })

  const { data: setup } = useQuery({
    queryKey: ['setup'],
    queryFn: getSetup,
    enabled: Boolean(token)
  })

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
    setShowInit(false)
  }

  if (!token && authStatus?.initialized === false) {
    return (
      <InitPage
        firstRun
        onInitialized={handleLogin}
        onDone={() => undefined}
      />
    )
  }

  if (!token) {
    if (authLoading) {
      return (
        <div className="login-shell">
          <div className="login-card">
            <div className="dashboard-kicker">TicTracker</div>
            <h1 className="login-title">正在检查工作台状态</h1>
            <p className="login-copy">稍等一下，正在确认是否需要首次初始化。</p>
          </div>
        </div>
      )
    }
    return <LoginPage onLogin={handleLogin} />
  }

  return (
    <Layout className="app-shell">
      <Header className="app-header">
        <div className="app-brand">
          <div className="app-brand-mark">TT</div>
          <div>
            <h1 className="app-brand-title">TicTracker</h1>
            <div className="app-brand-subtitle">技术支持工作台 · 团队问题流</div>
          </div>
        </div>
        <Space>
          <Button
            type="text"
            icon={<SettingOutlined />}
            onClick={() => setShowInit(true)}
            style={{ color: 'white' }}
          >
            <Text style={{ color: 'rgba(255,255,255,.82)' }}>初始化</Text>
          </Button>
          <Button
            type="text"
            icon={<LogoutOutlined />}
            onClick={handleLogout}
            style={{ color: 'white' }}
          >
            <Text style={{ color: 'rgba(255,255,255,.82)' }}>退出</Text>
          </Button>
        </Space>
      </Header>
      <Content className="app-content">
        {showInit || setup?.initialized === false ? (
          <InitPage onDone={() => setShowInit(false)} />
        ) : (
          <Dashboard />
        )}
      </Content>
    </Layout>
  )
}

export default App
