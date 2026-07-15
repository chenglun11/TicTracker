import React from 'react'
import ReactDOM from 'react-dom/client'
import { QueryClientProvider } from '@tanstack/react-query'
import { ConfigProvider } from 'antd'
import zhCN from 'antd/locale/zh_CN'
import App from './App'
import 'dayjs/locale/zh-cn'
import './styles.css'
import { queryClient } from './app/queryClient'

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <QueryClientProvider client={queryClient}>
      <ConfigProvider
        locale={zhCN}
        theme={{
          token: {
            colorPrimary: '#315f7d',
            colorInfo: '#315f7d',
            colorSuccess: '#4f7a52',
            colorWarning: '#a86f25',
            colorError: '#bf3f33',
            borderRadius: 6,
            fontFamily: '"Avenir Next", "Noto Sans SC", "PingFang SC", sans-serif'
          },
          components: {
            Card: { borderRadiusLG: 6 },
            Button: { borderRadius: 6 },
            Table: { borderRadius: 4 }
          }
        }}
      >
        <React.Suspense fallback={<div className="app-route-loading">正在连接团队工作台…</div>}>
          <App />
        </React.Suspense>
      </ConfigProvider>
    </QueryClientProvider>
  </React.StrictMode>
)
