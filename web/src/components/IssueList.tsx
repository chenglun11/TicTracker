import { useState } from 'react'
import { Tabs, Table, Tag, Empty, Select, Typography, Button, message } from 'antd'
import { PlusOutlined } from '@ant-design/icons'
import type { ColumnsType } from 'antd/es/table'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import type { TrackedIssue, UpdateIssueRequest } from '../types'
import { formatDate, statusColor, typeColor } from '../utils/format'
import { updateIssue } from '../api/client'
import CommentSection from './CommentSection'
import CreateIssueModal from './CreateIssueModal'
import dayjs from 'dayjs'

const { Text } = Typography

interface IssueListProps {
  issues: TrackedIssue[]
}

function IssueList({ issues }: IssueListProps) {
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

  const statusOptions = ['待处理', '处理中', '测试中', '已排期', '观测中', '已修复', '已忽略']

  const isResolved = (s: string) => s === '已修复' || s === '已忽略'
  const pendingIssues = issues.filter(i => !isResolved(i.status) && i.status !== '观测中')
  const observingIssues = issues.filter(i => i.status === '观测中')
  const newTodayIssues = issues.filter(i => i.dateKey === today && !isResolved(i.status))
  const resolvedTodayIssues = issues.filter(
    i => i.resolvedAt && dayjs(i.resolvedAt).format('YYYY-MM-DD') === today
  )

  const columns: ColumnsType<TrackedIssue> = [
    {
      title: '编号',
      dataIndex: 'issueNumber',
      key: 'issueNumber',
      width: 80,
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
      width: 100,
      render: (type: string) => (
        <Tag color={typeColor(type)}>{type}</Tag>
      )
    },
    {
      title: '状态',
      dataIndex: 'status',
      key: 'status',
      width: 120,
      render: (status: string, record: TrackedIssue) => (
        <Select
          size="small"
          value={status}
          style={{ width: 100 }}
          onChange={(val) => handleStatusChange(record.id, val)}
          options={statusOptions.map(s => ({ label: s, value: s }))}
          variant="borderless"
          loading={updatingIds.has(record.id)}
          labelRender={({ label }) => (
            <Tag color={statusColor(String(label))} style={{ margin: 0 }}>
              {label}
            </Tag>
          )}
        />
      )
    },
    {
      title: '负责人',
      dataIndex: 'assignee',
      key: 'assignee',
      width: 120,
      render: (assignee: string | undefined, record: TrackedIssue) => (
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
    },
    {
      title: '创建时间',
      dataIndex: 'createdAt',
      key: 'createdAt',
      width: 180,
      render: (date: string) => formatDate(date)
    }
  ]

  const expandable = {
    expandedRowRender: (record: TrackedIssue) => (
      <CommentSection issueId={record.id} comments={record.comments} />
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
    <Button
      type="primary"
      icon={<PlusOutlined />}
      onClick={() => setCreateModalOpen(true)}
    >
      新建工单
    </Button>
  )

  const tabItems = [
    {
      key: 'pending',
      label: `待处理 (${pendingIssues.length})`,
      children: renderTable(pendingIssues, '暂无待处理工单')
    },
    {
      key: 'observing',
      label: `观测中 (${observingIssues.length})`,
      children: renderTable(observingIssues, '暂无观测中工单')
    },
    {
      key: 'newToday',
      label: `今日新建 (${newTodayIssues.length})`,
      children: renderTable(newTodayIssues, '今日暂无新建工单')
    },
    {
      key: 'resolvedToday',
      label: `今日解决 (${resolvedTodayIssues.length})`,
      children: renderTable(resolvedTodayIssues, '今日暂无解决工单')
    }
  ]

  return (
    <>
      <Tabs items={tabItems} defaultActiveKey="pending" tabBarExtraContent={tabBarExtraContent} />
      <CreateIssueModal open={createModalOpen} onClose={() => setCreateModalOpen(false)} />
    </>
  )
}

export default IssueList
