import { useQuery } from '@tanstack/react-query'
import { Row, Col, Card, Spin, Alert } from 'antd'
import { getStatus, getIssues } from '../api/client'
import Statistics from './Statistics'
import IssueList from './IssueList'
import FeishuControl from './FeishuControl'

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

  if (statusLoading || issuesLoading) {
    return (
      <div style={{ textAlign: 'center', padding: '100px 0' }}>
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
    <div>
      <Statistics status={status!} />

      <Row gutter={24} style={{ marginTop: 24 }}>
        <Col span={18}>
          <Card>
            <IssueList issues={issuesData?.issues || []} departments={status?.departments} />
          </Card>
        </Col>

        <Col span={6}>
          <FeishuControl
            lastSentTime={status?.lastSentTime}
            cooldownRemain={status?.cooldownRemain || 0}
            feishuEnabled={status?.feishuEnabled || false}
          />
        </Col>
      </Row>
    </div>
  )
}

export default Dashboard
