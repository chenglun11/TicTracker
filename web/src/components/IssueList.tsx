import { useMemo, useState } from 'react'
import {
  Button,
  Col,
  Descriptions,
  Divider,
  Empty,
  Input,
  Popconfirm,
  Row,
  Segmented,
  Select,
  Space,
  Table,
  Tag,
  Typography,
  message
} from 'antd'
import { DeleteOutlined, PlusOutlined, SearchOutlined } from '@ant-design/icons'
import type { ColumnsType } from 'antd/es/table'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import dayjs from 'dayjs'
import { deleteIssue, updateIssue } from '../api/client'
import type { TrackedIssue, UpdateIssueRequest } from '../types'
import { formatDate, formatRelativeTime, parseDate, statusColor, typeColor } from '../utils/format'
import CommentSection from './CommentSection'
import CreateIssueModal from './CreateIssueModal'
import FeishuTaskBinder from './FeishuTaskBinder'

const { Text } = Typography

interface IssueListProps {
  issues: TrackedIssue[]
  departments?: string[]
}

type QueueKey = 'pending' | 'scheduled' | 'testing' | 'observing' | 'newToday' | 'resolvedToday' | 'myReported' | 'tagged' | 'all'

function IssueList({ issues, departments }: IssueListProps) {
  const today = dayjs().format('YYYY-MM-DD')
  const [createModalOpen, setCreateModalOpen] = useState(false)
  const [updatingIds, setUpdatingIds] = useState<Set<string>>(new Set())
  const [queue, setQueue] = useState<QueueKey>('pending')
  const [keyword, setKeyword] = useState('')
  const queryClient = useQueryClient()

  const isResolved = (s: string) => s === '已修复' || s === '已忽略'
  const isMine = (issue: TrackedIssue) => Boolean(issue.reporterName || issue.reporterId)

  const groups = useMemo(() => {
    const resolvedToday = issues.filter(
      i => i.resolvedAt && parseDate(i.resolvedAt).format('YYYY-MM-DD') === today
    )
    return {
      pending: issues.filter(i => !isResolved(i.status) && !['观测中', '已排期', '测试中'].includes(i.status)),
      scheduled: issues.filter(i => i.status === '已排期'),
      testing: issues.filter(i => i.status === '测试中'),
      observing: issues.filter(i => i.status === '观测中'),
      newToday: issues.filter(i => i.dateKey === today && !isResolved(i.status)),
      resolvedToday,
      myReported: issues.filter(isMine),
      tagged: issues.filter(i => (i.issueTags || []).length > 0),
      all: issues
    } satisfies Record<QueueKey, TrackedIssue[]>
  }, [issues, today])

  const filteredIssues = useMemo(() => {
    const q = keyword.trim().toLowerCase()
    const source = groups[queue] || []
    if (!q) return source
    return source.filter((issue) => {
      const fields = [
        issue.title,
        issue.type,
        issue.status,
        issue.source,
        issue.assignee,
        issue.department,
        issue.reporterName,
        issue.linearKey,
        issue.linearProjectName,
        issue.jiraKey,
        issue.ticketURL,
        ...(issue.issueTags || [])
      ]
      return fields.some((field) => String(field || '').toLowerCase().includes(q))
    })
  }, [groups, keyword, queue])

  const mutation = useMutation({
    mutationFn: ({ id, data }: { id: string; data: UpdateIssueRequest }) =>
      updateIssue(id, data),
    onMutate: ({ id }) => {
      setUpdatingIds((prev) => new Set(prev).add(id))
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['issues'] })
      queryClient.invalidateQueries({ queryKey: ['status'] })
      message.success('更新成功')
    },
    onError: () => {
      message.error('更新失败')
    },
    onSettled: (_data, _error, { id }) => {
      setUpdatingIds((prev) => {
        const next = new Set(prev)
        next.delete(id)
        return next
      })
    }
  })

  const deleteMutation = useMutation({
    mutationFn: (id: string) => deleteIssue(id),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['issues'] })
      queryClient.invalidateQueries({ queryKey: ['status'] })
      message.success('删除成功')
    },
    onError: () => {
      message.error('删除失败')
    }
  })

  const statusOptions = ['待处理', '处理中', '测试中', '已排期', '观测中', '已修复', '已忽略']

  const handleStatusChange = (id: string, status: string) => {
    mutation.mutate({ id, data: { status } })
  }

  const handleAssigneeChange = (id: string, assignee: string) => {
    mutation.mutate({ id, data: { assignee } })
  }

  const renderExternalLink = (record: TrackedIssue) => {
    const url = record.linearUrl || record.ticketURL || record.jiraKey
    if (!url) return '-'
    if (url.startsWith('http')) {
      const label = record.linearKey || record.jiraKey || url.replace(/^https?:\/\//, '').split('/').pop() || url
      return <a href={url} target="_blank" rel="noopener noreferrer">{label}</a>
    }
    return <Text code>{url}</Text>
  }

  const columns: ColumnsType<TrackedIssue> = [
    {
      title: '问题',
      key: 'title',
      minWidth: 320,
      render: (_: unknown, record) => (
        <div className="issue-title">
          <div className="issue-title-main">#{record.issueNumber} {record.title}</div>
          <div className="issue-title-meta">
            <Tag color={typeColor(record.type)}>{record.type || 'Issue'}</Tag>
            <span>{record.source || '未标记来源'}</span>
            {record.linearProjectName ? <span>Linear: {record.linearProjectName}</span> : null}
            {record.reporterName ? <span>提交: {record.reporterName}</span> : null}
          </div>
        </div>
      )
    },
    {
      title: '项目',
      dataIndex: 'department',
      key: 'department',
      width: 110,
      render: (dept: string | undefined) => dept || '-'
    },
    {
      title: '状态',
      dataIndex: 'status',
      key: 'status',
      width: 124,
      render: (status: string, record) => {
        const readOnly = Boolean(record.feishuTaskGuid)
        return (
          <Select
            size="small"
            value={status}
            style={{ width: 108 }}
            onChange={(val) => handleStatusChange(record.id, val)}
            options={statusOptions.map(s => ({ label: s, value: s }))}
            variant="borderless"
            loading={updatingIds.has(record.id)}
            disabled={readOnly}
            labelRender={({ label }) => (
              <Tag color={statusColor(String(label))} style={{ margin: 0 }}>{label}</Tag>
            )}
          />
        )
      }
    },
    {
      title: '负责人',
      dataIndex: 'assignee',
      key: 'assignee',
      width: 116,
      render: (assignee: string | undefined, record) => (
        <Text
          editable={{
            onChange: (val) => {
              const trimmed = val.trim()
              if (trimmed !== (assignee || '')) {
                handleAssigneeChange(record.id, trimmed)
              }
            },
            tooltip: '点击编辑负责人'
          }}
        >
          {assignee || '未指定'}
        </Text>
      )
    },
    {
      title: 'Tag',
      dataIndex: 'issueTags',
      key: 'issueTags',
      width: 160,
      render: (tags: string[] | undefined) => tags?.length ? (
        <Space size={4} wrap>
          {tags.slice(0, 2).map(tag => <Tag key={tag}>{tag}</Tag>)}
          {tags.length > 2 ? <Tag>+{tags.length - 2}</Tag> : null}
        </Space>
      ) : '-'
    },
    {
      title: '创建',
      dataIndex: 'createdAt',
      key: 'createdAt',
      width: 118,
      render: (date: string | number) => formatRelativeTime(date)
    },
    {
      title: '',
      key: 'action',
      width: 56,
      render: (_: unknown, record) => (
        <Popconfirm
          title="确认删除此工单？"
          onConfirm={() => deleteMutation.mutate(record.id)}
          okText="删除"
          cancelText="取消"
        >
          <Button type="text" danger size="small" icon={<DeleteOutlined />} />
        </Popconfirm>
      )
    }
  ]

  const expandable = {
    expandedRowRender: (record: TrackedIssue) => (
      <div className="issue-detail">
        <Space direction="vertical" size={14} style={{ width: '100%' }}>
          <Space size={6} wrap>
            <Tag>{record.source || '未标记来源'}</Tag>
            {record.reporterName ? <Tag color="green">提交：{record.reporterName}</Tag> : null}
            {(record.issueTags || []).map(tag => <Tag key={tag} color="magenta">{tag}</Tag>)}
            {record.feishuTaskGuid ? <Tag color="cyan">飞书任务</Tag> : null}
            {record.linearKey ? <Tag color="blue">{record.linearKey}</Tag> : null}
          </Space>

          <Descriptions size="small" column={{ xs: 1, sm: 2, lg: 3 }} colon={false}>
            <Descriptions.Item label="创建时间">{formatDate(record.createdAt)}</Descriptions.Item>
            <Descriptions.Item label="外部链接">{renderExternalLink(record)}</Descriptions.Item>
            <Descriptions.Item label="飞书任务">{record.feishuTaskGuid ? <Text code>{record.feishuTaskGuid}</Text> : '-'}</Descriptions.Item>
            <Descriptions.Item label="提交人">{record.reporterName || '-'}</Descriptions.Item>
            <Descriptions.Item label="Linear Project">{record.linearProjectName || '-'}</Descriptions.Item>
          </Descriptions>

          <Divider style={{ margin: 0 }} />

          <Row gutter={[16, 16]}>
            <Col xs={24} xl={8}>
              <FeishuTaskBinder issue={record} />
            </Col>
            <Col xs={24} xl={16}>
              <Text type="secondary" style={{ display: 'block', marginBottom: 8 }}>沟通记录</Text>
              <CommentSection issueId={record.id} comments={record.comments} />
            </Col>
          </Row>
        </Space>
      </div>
    )
  }

  const queueOptions = [
    { label: `待处理 ${groups.pending.length}`, value: 'pending' },
    { label: `已排期 ${groups.scheduled.length}`, value: 'scheduled' },
    { label: `测试中 ${groups.testing.length}`, value: 'testing' },
    { label: `观测中 ${groups.observing.length}`, value: 'observing' },
    { label: `今日新建 ${groups.newToday.length}`, value: 'newToday' },
    { label: `今日解决 ${groups.resolvedToday.length}`, value: 'resolvedToday' },
    { label: `我提交 ${groups.myReported.length}`, value: 'myReported' },
    { label: `Tag ${groups.tagged.length}`, value: 'tagged' },
    { label: `全部 ${groups.all.length}`, value: 'all' }
  ]

  return (
    <>
      <div className="panel-heading">
        <div>
          <div className="panel-title">问题队列</div>
          <div className="panel-subtitle">按状态、提交人和重点标签追踪当天 bug 与团队问题</div>
        </div>
        <Button type="primary" icon={<PlusOutlined />} onClick={() => setCreateModalOpen(true)}>
          新建工单
        </Button>
      </div>

      <div className="issue-workbench">
        <div className="issue-toolbar">
          <Segmented
            className="issue-tabs"
            value={queue}
            onChange={(value) => setQueue(value as QueueKey)}
            options={queueOptions}
            block
          />
          <Input
            allowClear
            prefix={<SearchOutlined />}
            placeholder="搜索标题、来源、项目、Tag"
            value={keyword}
            onChange={(event) => setKeyword(event.target.value)}
            style={{ maxWidth: 280 }}
          />
        </div>

        <Table
          className="issue-table"
          columns={columns}
          dataSource={filteredIssues}
          rowKey="id"
          pagination={{ pageSize: 12, showSizeChanger: false }}
          locale={{ emptyText: <Empty description="没有符合条件的问题" /> }}
          expandable={expandable}
          scroll={{ x: 980 }}
        />
      </div>

      <CreateIssueModal open={createModalOpen} onClose={() => setCreateModalOpen(false)} departments={departments} />
    </>
  )
}

export default IssueList
