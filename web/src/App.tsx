import { lazy, useState, useEffect } from 'react'
import { Layout, Button, Space, Typography } from 'antd'
import { AppstoreOutlined, LogoutOutlined, SettingOutlined, TeamOutlined } from '@ant-design/icons'
import { useQuery } from '@tanstack/react-query'
import { getAuthStatus, getSetup, logout } from './api/client'
import { queryKeys } from './shared/api/queryKeys'
import { getCurrentUser } from './features/members/api/members'

const Dashboard = lazy(() => import('./components/Dashboard'))
const InitPage = lazy(() => import('./components/InitPage'))
const LoginPage = lazy(() => import('./components/LoginPage'))
const MemberManagement = lazy(() => import('./components/MemberManagement'))
const AccountSecurityModal = lazy(() => import('./components/AccountSecurityModal'))

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
  const [showMembers, setShowMembers] = useState(false)
  const [showAccount, setShowAccount] = useState(false)

  const { data: authStatus, isLoading: authLoading } = useQuery({
    queryKey: queryKeys.auth.status,
    queryFn: getAuthStatus,
    enabled: !token
  })

  const { data: setup } = useQuery({
    queryKey: queryKeys.setup,
    queryFn: getSetup,
    enabled: Boolean(token)
  })

  const { data: currentUser, isLoading: userLoading } = useQuery({
    queryKey: queryKeys.auth.me,
    queryFn: getCurrentUser,
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

  const handleLogout = async () => {
    try {
      await logout()
    } catch {
      // Local logout must still complete if the server is temporarily unavailable.
    }
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

  if (token && userLoading) {
    return <div className="app-route-loading">正在载入成员身份…</div>
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
          {currentUser ? (
            <Button
              type="text"
              icon={<AppstoreOutlined />}
              onClick={() => setShowInit(false)}
              style={{ color: 'rgba(255,255,255,.82)' }}
            >
              工作台
            </Button>
          ) : null}
          <button className="current-user-chip current-user-button" onClick={() => setShowAccount(true)} type="button" title="账户安全">
            <span>{currentUser?.displayName || '成员'}</span>
            <small>{currentUser?.role || 'member'}</small>
          </button>
          {currentUser?.role === 'admin' ? (
            <>
              <Button type="text" icon={<TeamOutlined />} onClick={() => setShowMembers(true)} style={{ color: 'white' }}>
                <Text style={{ color: 'rgba(255,255,255,.82)' }}>成员</Text>
              </Button>
              <Button type="text" icon={<SettingOutlined />} onClick={() => setShowInit(true)} style={{ color: 'white' }}>
                <Text style={{ color: 'rgba(255,255,255,.82)' }}>配置</Text>
              </Button>
            </>
          ) : null}
          <Button
            type="text"
            icon={<LogoutOutlined />}
            onClick={() => void handleLogout()}
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
          currentUser ? <Dashboard currentUser={currentUser} /> : null
        )}
      </Content>
      {currentUser?.role === 'admin' ? (
        <MemberManagement open={showMembers} currentUser={currentUser} onClose={() => setShowMembers(false)} />
      ) : null}
      {currentUser ? (
        <AccountSecurityModal
          open={showAccount}
          user={currentUser}
          onClose={() => setShowAccount(false)}
          onTokenChanged={setToken}
        />
      ) : null}
    </Layout>
  )
}

export default App
