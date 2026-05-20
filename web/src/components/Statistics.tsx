import {
  CalendarOutlined,
  CheckCircleOutlined,
  ClockCircleOutlined,
  ExperimentOutlined,
  EyeOutlined,
  PlusCircleOutlined
} from '@ant-design/icons'
import type { StatusResponse } from '../types'

interface StatisticsProps {
  status: StatusResponse
}

function Statistics({ status }: StatisticsProps) {
  const { statistics, todayTotal } = status

  const metrics = [
    { label: '今日新建', value: statistics.newToday, icon: <PlusCircleOutlined />, color: 'var(--tt-green)', note: '当天新增未关闭' },
    { label: '今日解决', value: statistics.resolvedToday, icon: <CheckCircleOutlined />, color: 'var(--tt-blue)', note: '当天完成' },
    { label: '待处理', value: statistics.pending, icon: <ClockCircleOutlined />, color: 'var(--tt-red)', note: '当前阻塞池' },
    { label: '已排期', value: statistics.scheduled, icon: <CalendarOutlined />, color: '#76559a', note: '进入计划' },
    { label: '测试中', value: statistics.testing, icon: <ExperimentOutlined />, color: 'var(--tt-cyan)', note: '等待验证' },
    { label: '观测中', value: statistics.observing, icon: <EyeOutlined />, color: 'var(--tt-gold)', note: todayTotal > 0 ? `支持 ${todayTotal} 次` : '持续观察' }
  ]

  return (
    <div className="metric-strip">
      {metrics.map((metric) => (
        <div className="metric-cell" key={metric.label}>
          <div className="metric-label" style={{ color: metric.color }}>
            {metric.icon}
            <span>{metric.label}</span>
          </div>
          <div className="metric-value">{metric.value}</div>
          <div className="metric-note">{metric.note}</div>
        </div>
      ))}
    </div>
  )
}

export default Statistics
