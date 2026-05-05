import { useState } from 'react'
import { Tabs, Table, Tag, Empty, Select, Typography, Button, message, Popconfirm, Space } from 'antd'
import { PlusOutlined, DeleteOutlined } from '@ant-design/icons'
import type { ColumnsType } from 'antd/es/table'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import type { TrackedIssue, UpdateIssueRequest } from '../types'
import { formatDate, statusColor, typeColor, parseDate } from '../utils/format'
import { updateIssue, deleteIssue } from '../api/client'
import CommentSection from './CommentSection'
import CreateIssueModal from './CreateIssueModal'
import FeishuTaskBinder from './FeishuTaskBinder'
import dayjs from 'dayjs'

const { Text } = Typography

interface IssueListProps {
  issues: TrackedIssue[]
  departments?: string[]
}

function IssueList({ issues, departments }: IssueListProps) {
  const today = dayjs().format('YYYY-MM-DD')
  const [createModalOpen, setCreateModalOpen] = useState(false)
  const [updatingIds, setUpdatingIds] = useState<Set<string>>(new Set())
  const queryClient = useQueryClient()

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

  const handleStatusChange = (id: string, status: string) => {
    mutation.mutate({ id, data: { status } })
  }

  const handleAssigneeChange = (id: string, assignee: string) => {
    mutation.mutate({ id, data: { assignee } })
  }

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

  const isResolved = (s: string) => s === '已修复' || s === '已忽略'
  const pendingIssues = issues.filter(i => !isResolved(i.status) && i.status !== '观测中' && i.status !== '已排期' && i.status !== '测试中')
  const scheduledIssues = issues.filter(i => i.status === '已排期')
  const testingIssues = issues.filter(i => i.status === '测试中')
  const observingIssues = issues.filter(i => i.status === '观测中')
  const newTodayIssues = issues.filter(i => i.dateKey === today && !isResolved(i.status))
  const resolvedTodayIssues = issues.filter(
    i => i.resolvedAt && parseDate(i.resolvedAt).format('YYYY-MM-DD') === today
  )

  const columns: ColumnsType<TrackedIssue> = [
    {
      title: '编号',
      dataIndex: 'issueNumber',
      key: 'issueNumber',
      width: 70,
      render: (num: number) => `#${num}`
    },
    {
      title: '标题',
      dataIndex: 'title',
      key: 'title',
      ellipsis: true
    },
    {
      title: '类型',
      dataIndex: 'type',
      key: 'type',
      width: 90,
      render: (type: string) => <Tag color={typeColor(type)}>{type}</Tag>
    },
    {
      title: '项目',
      dataIndex: 'department',
      key: 'department',
      width: 100,
      render: (dept: string | undefined) => dept || '-'
    },
    {
      title: '状态',
      dataIndex: 'status',
      key: 'status',
      width: 120,
      render: (status: string, record: TrackedIssue) => {
        const readOnly = !!record.feishuTaskGuid
        return (
          <Select
            size="small"
            value={status}
            style={{ width: 100 }}
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
      title: '来源',
      dataIndex: 'source',
      key: 'source',
      width: 140,
      render: (source: string, record: TrackedIssue) => {
        if (!source) return '-'
        return (
          <Space size={4} wrap>
            <Tag>
              {source}
            </Tag>
            {record.feishuTaskGuid ? <Tag color="cyan">已绑定飞书任务</Tag> : null}
          </Space>
        )
      }
    },
    /* PLACEHOLDER_COLUMNS */
    {
      title: '负责人',
      dataIndex: 'assignee',
      key: 'assignee',
      width: 110,
      render: (assignee: string | undefined, record: TrackedIssue) => {
        return (
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
            {assignee || ''}
          </Text>
        )
      }
    },
    {
      title: '链接',
      key: 'ticketURL',
      width: 110,
      render: (_: unknown, record: TrackedIssue) => {
        const url = record.ticketURL || record.jiraKey
        if (!url) return '-'
        if (url.startsWith('http')) {
          const label = url.replace(/^https?:\/\//, '').split('/').pop() || url
          return <a href={url} target="_blank" rel="noopener noreferrer">{label}</a>
        }
        return url
      }
    },
    {
      title: '创建时间',
      dataIndex: 'createdAt',
      key: 'createdAt',
      width: 170,
      render: (date: string) => formatDate(date)
    },
    {
      title: '操作',
      key: 'action',
      width: 60,
      render: (_: unknown, record: TrackedIssue) => {
        return (
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
    }
  ]
  /* PLACEHOLDER_REST2 */

  const expandable = {
    expandedRowRender: (record: TrackedIssue) => (
      <>
        <FeishuTaskBinder issue={record} />
        <CommentSection issueId={record.id} comments={record.comments} />
      </>
    )
  }

  const renderTable = (dataSource: TrackedIssue[], emptyDescription: string) => (
    <Table
      columns={columns}
      dataSource={dataSource}
      rowKey="id"
      pagination={{ pageSize: 10 }}
      locale={{ emptyText: <Empty description={emptyDescription} /> }}
      expandable={expandable}
    />
  )

  const tabBarExtraContent = (
    <Button type="primary" icon={<PlusOutlined />} onClick={() => setCreateModalOpen(true)}>
      新建工单
    </Button>
  )

  const tabItems = [
    { key: 'pending', label: `待处理 (${pendingIssues.length})`, children: renderTable(pendingIssues, '暂无待处理工单') },
    { key: 'scheduled', label: `已排期 (${scheduledIssues.length})`, children: renderTable(scheduledIssues, '暂无已排期工单') },
    { key: 'testing', label: `测试中 (${testingIssues.length})`, children: renderTable(testingIssues, '暂无测试中工单') },
    { key: 'observing', label: `观测中 (${observingIssues.length})`, children: renderTable(observingIssues, '暂无观测中工单') },
    { key: 'newToday', label: `今日新建 (${newTodayIssues.length})`, children: renderTable(newTodayIssues, '今日暂无新建工单') },
    { key: 'resolvedToday', label: `今日解决 (${resolvedTodayIssues.length})`, children: renderTable(resolvedTodayIssues, '今日暂无解决工单') },
  ]

  return (
    <>
      <Tabs items={tabItems} defaultActiveKey="pending" tabBarExtraContent={tabBarExtraContent} />
      <CreateIssueModal open={createModalOpen} onClose={() => setCreateModalOpen(false)} departments={departments} />
    </>
  )
}

export default IssueList
