import { Row, Col, Card, Statistic } from 'antd'
import {
  PlusCircleOutlined,
  CheckCircleOutlined,
  ClockCircleOutlined,
  EyeOutlined,
  CalendarOutlined,
  ExperimentOutlined
} from '@ant-design/icons'
import type { StatusResponse } from '../types'

interface StatisticsProps {
  status: StatusResponse
}

function Statistics({ status }: StatisticsProps) {
  const { statistics, todayTotal } = status

  return (
    <>
      <Row gutter={16}>
        <Col span={4}>
          <Card>
            <Statistic
              title="今日新建"
              value={statistics.newToday}
              valueStyle={{ color: '#52c41a' }}
              prefix={<PlusCircleOutlined />}
            />
          </Card>
        </Col>
        <Col span={4}>
          <Card>
            <Statistic
              title="今日解决"
              value={statistics.resolvedToday}
              valueStyle={{ color: '#1890ff' }}
              prefix={<CheckCircleOutlined />}
            />
          </Card>
        </Col>
        <Col span={4}>
          <Card>
            <Statistic
              title="待处理"
              value={statistics.pending}
              valueStyle={{ color: '#ff4d4f' }}
              prefix={<ClockCircleOutlined />}
            />
          </Card>
        </Col>
        <Col span={4}>
          <Card>
            <Statistic
              title="已排期"
              value={statistics.scheduled}
              valueStyle={{ color: '#722ed1' }}
              prefix={<CalendarOutlined />}
            />
          </Card>
        </Col>
        <Col span={4}>
          <Card>
            <Statistic
              title="测试中"
              value={statistics.testing}
              valueStyle={{ color: '#13c2c2' }}
              prefix={<ExperimentOutlined />}
            />
          </Card>
        </Col>
        <Col span={4}>
          <Card>
            <Statistic
              title="观测中"
              value={statistics.observing}
              valueStyle={{ color: '#faad14' }}
              prefix={<EyeOutlined />}
            />
          </Card>
        </Col>
      </Row>

      {todayTotal > 0 && (
        <Card style={{ marginTop: 16, textAlign: 'center' }}>
          <Statistic
            title="今日项目支持次数"
            value={todayTotal}
            valueStyle={{ color: '#722ed1', fontSize: 32 }}
          />
        </Card>
      )}
    </>
  )
}

export default Statistics
