import { useMemo } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Alert, Spin, Typography } from 'antd'
import { ApiOutlined, DatabaseOutlined, TeamOutlined } from '@ant-design/icons'
import { getIssues, getStatus } from '../api/client'
import FeishuControl from './FeishuControl'
import IssueList from './IssueList'
import Statistics from './Statistics'

const { Text } = Typography

function Dashboard() {
  const { data: status, isLoading: statusLoading, error: statusError } = useQuery({
    queryKey: ['status'],
    queryFn: getStatus,
    refetchInterval: 30000
  })

  const { data: issuesData, isLoading: issuesLoading, error: issuesError } = useQuery({
    queryKey: ['issues'],
    queryFn: () => getIssues(),
    refetchInterval: 30000
  })

  const issues = issuesData?.issues || []
  const flowStats = useMemo(() => {
    const myReported = issues.filter((issue) => issue.reporterName || issue.reporterId).length
    const focusTagged = issues.filter((issue) => (issue.issueTags || []).length > 0).length
    const external = issues.filter((issue) => issue.linearIssueId || issue.feishuTaskGuid || issue.jiraKey || issue.ticketURL).length
    return { myReported, focusTagged, external }
  }, [issues])

  if (statusLoading || issuesLoading) {
    return (
      <div style={{ display: 'grid', placeItems: 'center', minHeight: 360 }}>
        <Spin size="large" />
      </div>
    )
  }

  if (statusError || issuesError) {
    return (
      <Alert
        message="加载失败"
        description="无法连接到服务器，请检查网络连接或稍后重试"
        type="error"
        showIcon
      />
    )
  }

  return (
    <div className="dashboard">
      <div className="dashboard-topline">
        <div>
          <div className="dashboard-kicker">Support Operations</div>
          <h2 className="dashboard-title">团队问题流</h2>
          <div className="dashboard-subtitle">
            <Text type="secondary">完整日数据、外部入口和我的提交在同一个工作台里收束。</Text>
          </div>
        </div>
        <span className="status-pill">
          <DatabaseOutlined />
          SQLite SaaS 组件
        </span>
      </div>

      <Statistics status={status!} />

      <div className="dashboard-grid">
        <section className="workbench-panel">
          <IssueList issues={issues} departments={status?.departments} />
        </section>

        <aside className="side-stack">
          <FeishuControl
            lastSentTime={status?.lastSentTime}
            cooldownRemain={status?.cooldownRemain || 0}
            feishuEnabled={status?.feishuEnabled || false}
          />

          <div className="side-panel">
            <div className="side-panel-title">数据流</div>
            <div className="side-panel-copy">服务端保存完整快照，同时把 issue、tag、外部绑定拆成可统计的数据。</div>
            <div className="data-flow-list">
              <div className="data-flow-item">
                <div className="data-flow-dot"><TeamOutlined /></div>
                <div>
                  <div className="data-flow-title">我提交的问题</div>
                  <div className="data-flow-desc">{flowStats.myReported} 条带提交人信息，可进入日报追踪。</div>
                </div>
              </div>
              <div className="data-flow-item">
                <div className="data-flow-dot"><ApiOutlined /></div>
                <div>
                  <div className="data-flow-title">外部入口</div>
                  <div className="data-flow-desc">{flowStats.external} 条绑定 Jira、Linear、飞书任务或外部链接。</div>
                </div>
              </div>
              <div className="data-flow-item">
                <div className="data-flow-dot">#</div>
                <div>
                  <div className="data-flow-title">重点标签</div>
                  <div className="data-flow-desc">{flowStats.focusTagged} 条带 tag，可被日报重点分组拾取。</div>
                </div>
              </div>
            </div>
          </div>
        </aside>
      </div>
    </div>
  )
}

export default Dashboard
