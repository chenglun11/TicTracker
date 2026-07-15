import { useMemo, useState } from 'react'
import {
  Button,
  Col,
  Descriptions,
  Divider,
  Empty,
  Alert,
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
import { claimIssue, deleteIssue, updateIssue } from '../features/issues/api/issues'
import { issueMutationConflict } from '../features/issues/model/conflicts'
import { IssueConflictModal, type RecoverableIssueConflict } from '../features/issues/ui/IssueConflictModal'
import { queryKeys } from '../shared/api/queryKeys'
import type { TrackedIssue, UpdateIssueRequest } from '../types'
import { formatDate, formatRelativeTime, parseDate, statusColor, typeColor } from '../utils/format'
import CommentSection from './CommentSection'
import CreateIssueModal from './CreateIssueModal'
import type { AuthUser } from '../entities/member/model/types'

const { Text } = Typography

interface IssueListProps {
  issues: TrackedIssue[]
  departments?: string[]
  currentUser: AuthUser
}

type QueueKey = 'pending' | 'scheduled' | 'testing' | 'observing' | 'newToday' | 'resolvedToday' | 'myReported' | 'tagged' | 'all'

function IssueList({ issues, departments, currentUser }: IssueListProps) {
  const today = dayjs().format('YYYY-MM-DD')
  const [createModalOpen, setCreateModalOpen] = useState(false)
  const [updatingIds, setUpdatingIds] = useState<Set<string>>(new Set())
  const [queue, setQueue] = useState<QueueKey>('pending')
  const [keyword, setKeyword] = useState('')
  const [conflict, setConflict] = useState<RecoverableIssueConflict | null>(null)
  const queryClient = useQueryClient()
  const canWrite = currentUser.role === 'admin'
  const canSubmit = currentUser.role !== 'viewer'

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
    mutationFn: ({ id, revision, data }: { id: string; revision: number; data: UpdateIssueRequest }) =>
      updateIssue(id, revision, data),
    onMutate: ({ id }) => {
      setUpdatingIds((prev) => new Set(prev).add(id))
    },
    onSuccess: () => {
    queryClient.invalidateQueries({ queryKey: queryKeys.issues.all })
    queryClient.invalidateQueries({ queryKey: queryKeys.status })
      message.success('更新成功')
    },
    onError: (error, variables) => {
      queryClient.invalidateQueries({ queryKey: queryKeys.issues.all })
      const issueConflict = issueMutationConflict(error)
      if (issueConflict) {
        setConflict({ kind: 'update', current: issueConflict.current, attempted: variables.data })
        return
      }
      message.error('更新未保存，请检查网络后重试')
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
    mutationFn: ({ id, revision }: { id: string; revision: number }) => deleteIssue(id, revision),
    onSuccess: () => {
    queryClient.invalidateQueries({ queryKey: queryKeys.issues.all })
    queryClient.invalidateQueries({ queryKey: queryKeys.status })
      message.success('删除成功')
    },
    onError: (error) => {
      queryClient.invalidateQueries({ queryKey: queryKeys.issues.all })
      const issueConflict = issueMutationConflict(error)
      if (issueConflict) {
        setConflict({ kind: 'delete', current: issueConflict.current })
        return
      }
      message.error('删除未执行，请检查网络后重试')
    }
  })

  const claimMutation = useMutation({
    mutationFn: (issue: TrackedIssue) => claimIssue(issue.id, issue.revision),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: queryKeys.issues.all })
      void queryClient.invalidateQueries({ queryKey: queryKeys.status })
      message.success('已认领，其他成员会实时看到负责人')
    },
    onError: (error) => {
      void queryClient.invalidateQueries({ queryKey: queryKeys.issues.all })
      const latest = issueMutationConflict(error)?.current
      message.warning(latest?.assignee ? `认领未成功，${latest.assignee} 已先认领` : '认领未成功，工单状态已变化')
    }
  })

  const statusOptions = ['待处理', '处理中', '测试中', '已排期', '观测中', '已修复', '已忽略']

  const handleStatusChange = (issue: TrackedIssue, status: string) => {
    mutation.mutate({ id: issue.id, revision: issue.revision, data: { status } })
  }

  const handleAssigneeChange = (issue: TrackedIssue, assignee: string) => {
    mutation.mutate({ id: issue.id, revision: issue.revision, data: { assignee } })
  }

  const acceptOnlineConflict = () => {
    setConflict(null)
    void queryClient.invalidateQueries({ queryKey: queryKeys.issues.all })
  }

  const retryConflict = () => {
    if (!conflict?.current) return
    if (conflict.kind === 'delete') {
      deleteMutation.mutate(
        { id: conflict.current.id, revision: conflict.current.revision },
        { onSuccess: () => setConflict(null) }
      )
      return
    }
    mutation.mutate(
      { id: conflict.current.id, revision: conflict.current.revision, data: conflict.attempted || {} },
      { onSuccess: () => setConflict(null) }
    )
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
        const readOnly = false
        return (
          <Select
            size="small"
            value={status}
            style={{ width: 108 }}
            onChange={(val) => handleStatusChange(record, val)}
            options={statusOptions.map(s => ({ label: s, value: s }))}
            variant="borderless"
            loading={updatingIds.has(record.id)}
            disabled={readOnly || !canWrite}
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
          editable={canWrite ? {
            onChange: (val) => {
              const trimmed = val.trim()
              if (trimmed !== (assignee || '')) {
                handleAssigneeChange(record, trimmed)
              }
            },
            tooltip: '点击编辑负责人'
          } : false}
        >
          {assignee || (canWrite ? (
            <Button
              type="link"
              size="small"
              className="claim-button"
              loading={claimMutation.isPending && claimMutation.variables?.id === record.id}
              onClick={(event) => {
                event.stopPropagation()
                claimMutation.mutate(record)
              }}
            >
              认领
            </Button>
          ) : '未指定')}
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
        canWrite ? (
        <Popconfirm
          title="确认删除此工单？"
          onConfirm={() => deleteMutation.mutate({ id: record.id, revision: record.revision })}
          okText="删除"
          cancelText="取消"
        >
          <Button type="text" danger size="small" icon={<DeleteOutlined />} />
        </Popconfirm>
        ) : null
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
            {record.linearKey ? <Tag color="blue">{record.linearKey}</Tag> : null}
          </Space>

          <Descriptions size="small" column={{ xs: 1, sm: 2, lg: 3 }} colon={false}>
            <Descriptions.Item label="创建时间">{formatDate(record.createdAt)}</Descriptions.Item>
            <Descriptions.Item label="外部链接">{renderExternalLink(record)}</Descriptions.Item>
            <Descriptions.Item label="提交人">{record.reporterName || '-'}</Descriptions.Item>
            <Descriptions.Item label="Linear Project">{record.linearProjectName || '-'}</Descriptions.Item>
          </Descriptions>

          <Divider style={{ margin: 0 }} />

          <Row gutter={[16, 16]}>
            <Col xs={24}>
              <Text type="secondary" style={{ display: 'block', marginBottom: 8 }}>沟通记录</Text>
              <CommentSection issueId={record.id} revision={record.revision} comments={record.comments} readOnly={!canWrite} />
            </Col>
          </Row>
        </Space>
      </div>
    )
  }

  const queueOptions = [
    { label: <span className="queue-tab-label"><span>待处理</span><b>{groups.pending.length}</b></span>, value: 'pending' },
    { label: <span className="queue-tab-label"><span>已排期</span><b>{groups.scheduled.length}</b></span>, value: 'scheduled' },
    { label: <span className="queue-tab-label"><span>测试中</span><b>{groups.testing.length}</b></span>, value: 'testing' },
    { label: <span className="queue-tab-label"><span>观测中</span><b>{groups.observing.length}</b></span>, value: 'observing' },
    { label: <span className="queue-tab-label"><span>今日新建</span><b>{groups.newToday.length}</b></span>, value: 'newToday' },
    { label: <span className="queue-tab-label"><span>今日解决</span><b>{groups.resolvedToday.length}</b></span>, value: 'resolvedToday' },
    { label: <span className="queue-tab-label"><span>我提交</span><b>{groups.myReported.length}</b></span>, value: 'myReported' },
    { label: <span className="queue-tab-label"><span>有标签</span><b>{groups.tagged.length}</b></span>, value: 'tagged' },
    { label: <span className="queue-tab-label"><span>全部</span><b>{groups.all.length}</b></span>, value: 'all' }
  ]

  return (
    <>
      <div className="panel-heading">
        <div>
          <div className="panel-title">问题队列</div>
          <div className="panel-subtitle">按状态、提交人和重点标签追踪当天 bug 与团队问题</div>
        </div>
        {canSubmit ? (
          <Button type="primary" icon={<PlusOutlined />} onClick={() => setCreateModalOpen(true)}>
            新建工单
          </Button>
        ) : <Tag>只读模式</Tag>}
      </div>

      <div className="issue-workbench">
        <Alert
          className="linear-readonly-banner"
          type="info"
          showIcon
          message={currentUser.role === 'admin' ? '管理员维护视图' : currentUser.role === 'member' ? '成员提交视图' : '只读汇总视图'}
          description={currentUser.role === 'admin'
            ? 'Linear 是团队问题的来源；管理员可在此维护汇总状态并触发同步。'
            : currentUser.role === 'member'
              ? '你可以提交新的问题并触发同步；已有 Issue 的状态、负责人和评论由管理员或 Linear 维护。'
              : 'Issue 数据来自 Linear 汇总；当前账号没有提交或编辑权限。'}
        />
        <div className="issue-toolbar">
          <div className="queue-tabs-scroll">
            <Segmented
              className="issue-tabs"
              value={queue}
              onChange={(value) => setQueue(value as QueueKey)}
              options={queueOptions}
            />
          </div>
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

      {canSubmit ? <CreateIssueModal open={createModalOpen} onClose={() => setCreateModalOpen(false)} departments={departments} /> : null}
      <IssueConflictModal
        conflict={conflict}
        retrying={mutation.isPending || deleteMutation.isPending}
        onRetry={retryConflict}
        onAcceptOnline={acceptOnlineConflict}
      />
    </>
  )
}

export default IssueList
