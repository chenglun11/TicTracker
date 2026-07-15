import { useState } from 'react'
import { Button, Drawer, Form, Input, Modal, Select, Space, Switch, Table, Tag, Typography, message } from 'antd'
import { KeyOutlined, PlusOutlined, SafetyCertificateOutlined, TeamOutlined } from '@ant-design/icons'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import type { ColumnsType } from 'antd/es/table'
import type {
  AuthUser,
  CreateMemberRequest,
  WorkspaceMember,
  WorkspaceRole
} from '../entities/member/model/types'
import { createMember, getMembers, updateMember } from '../features/members/api/members'
import { queryKeys } from '../shared/api/queryKeys'

const { Text, Title } = Typography

const roleMeta: Record<WorkspaceRole, { label: string; color: string; note: string }> = {
  admin: { label: '管理员', color: 'red', note: '成员、配置与全部工单权限' },
  member: { label: '协作成员', color: 'blue', note: '可认领、编辑和评论工单' },
  viewer: { label: '只读观察', color: 'default', note: '只能查看实时工作台' }
}

interface MemberManagementProps {
  open: boolean
  currentUser: AuthUser
  onClose: () => void
}

function MemberManagement({ open, currentUser, onClose }: MemberManagementProps) {
  const [createOpen, setCreateOpen] = useState(false)
  const [resetTarget, setResetTarget] = useState<WorkspaceMember | null>(null)
  const [form] = Form.useForm<CreateMemberRequest>()
  const [resetForm] = Form.useForm<{ password: string; confirmPassword: string }>()
  const queryClient = useQueryClient()
  const membersQuery = useQuery({
    queryKey: queryKeys.members,
    queryFn: getMembers,
    enabled: open
  })
  const createMutation = useMutation({
    mutationFn: createMember,
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: queryKeys.members })
      form.resetFields()
      setCreateOpen(false)
      message.success('成员账号已创建')
    },
    onError: () => message.error('创建失败，请检查账号是否重复')
  })
  const updateMutation = useMutation({
    mutationFn: ({ username, changes }: { username: string; changes: Parameters<typeof updateMember>[1] }) =>
      updateMember(username, changes),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: queryKeys.members })
      message.success('成员权限已更新')
    },
    onError: () => message.error('更新失败；工作区必须保留至少一位管理员')
  })

  const columns: ColumnsType<WorkspaceMember> = [
    {
      title: '成员',
      key: 'member',
      render: (_, member) => (
        <div className="member-identity">
          <div className="member-avatar">{member.displayName.slice(0, 1).toUpperCase()}</div>
          <div>
            <div className="member-name">{member.displayName}</div>
            <Text type="secondary">@{member.username}</Text>
          </div>
        </div>
      )
    },
    {
      title: '角色',
      dataIndex: 'role',
      width: 150,
      render: (role: WorkspaceRole, member) => member.username === currentUser.username ? (
        <Tag color={roleMeta[role].color}>{roleMeta[role].label} · 当前账号</Tag>
      ) : (
        <Select
          value={role}
          style={{ width: 132 }}
          options={(Object.keys(roleMeta) as WorkspaceRole[]).map(value => ({ value, label: roleMeta[value].label }))}
          onChange={(value) => updateMutation.mutate({ username: member.username, changes: { role: value } })}
        />
      )
    },
    {
      title: '登录',
      width: 170,
      render: (_, member) => (
        <Space size={8}>
          <Switch
            checked={!member.disabledAt}
            disabled={member.username === currentUser.username}
            checkedChildren="启用"
            unCheckedChildren="停用"
            onChange={(enabled) => updateMutation.mutate({ username: member.username, changes: { disabled: !enabled } })}
          />
          <Button size="small" icon={<KeyOutlined />} onClick={() => { resetForm.resetFields(); setResetTarget(member) }}>重置密码</Button>
        </Space>
      )
    }
  ]

  return (
    <>
      <Drawer
        title={null}
        width={720}
        open={open}
        onClose={onClose}
        className="member-drawer"
      >
        <div className="member-drawer-head">
          <div>
            <div className="dashboard-kicker">Workspace Access</div>
            <Title level={3}>成员与角色</Title>
            <Text type="secondary">账号身份决定服务端权限；停用后已有会话会立即失效。</Text>
          </div>
          <Button type="primary" icon={<PlusOutlined />} onClick={() => setCreateOpen(true)}>添加成员</Button>
        </div>

        <div className="role-ledger">
          {(Object.keys(roleMeta) as WorkspaceRole[]).map(role => (
            <div className="role-ledger-item" key={role}>
              <SafetyCertificateOutlined />
              <div><strong>{roleMeta[role].label}</strong><span>{roleMeta[role].note}</span></div>
            </div>
          ))}
        </div>

        <Table
          rowKey="username"
          columns={columns}
          dataSource={membersQuery.data || []}
          loading={membersQuery.isLoading || updateMutation.isPending}
          pagination={false}
          locale={{ emptyText: '暂无工作区成员' }}
        />
      </Drawer>

      <Modal
        title={<Space><TeamOutlined />创建协作账号</Space>}
        open={createOpen}
        onCancel={() => setCreateOpen(false)}
        onOk={() => form.submit()}
        confirmLoading={createMutation.isPending}
        okText="创建并启用"
      >
        <Form
          form={form}
          layout="vertical"
          initialValues={{ role: 'member' }}
          onFinish={(values) => createMutation.mutate(values)}
        >
          <Form.Item name="displayName" label="显示名称" rules={[{ required: true }]}>
            <Input placeholder="例如：陈同学" maxLength={80} />
          </Form.Item>
          <Form.Item name="username" label="登录账号" rules={[{ required: true, pattern: /^[A-Za-z0-9._-]{2,64}$/ }]}>
            <Input addonBefore="@" placeholder="chen" autoComplete="off" />
          </Form.Item>
          <Form.Item name="role" label="角色" rules={[{ required: true }]}>
            <Select options={(Object.keys(roleMeta) as WorkspaceRole[]).map(value => ({ value, label: `${roleMeta[value].label} — ${roleMeta[value].note}` }))} />
          </Form.Item>
          <Form.Item name="password" label="初始密码" rules={[{ required: true, min: 8, max: 200 }]}>
            <Input.Password placeholder="至少 8 位，请通过安全渠道发送" autoComplete="new-password" />
          </Form.Item>
        </Form>
      </Modal>

      <Modal
        title={<span><KeyOutlined /> 重置成员密码</span>}
        open={Boolean(resetTarget)}
        onCancel={() => setResetTarget(null)}
        onOk={() => resetForm.submit()}
        confirmLoading={updateMutation.isPending}
        okText="保存新密码"
      >
        <Text type="secondary">为 @{resetTarget?.username} 设置新密码；该成员的其他会话会立即失效。</Text>
        <Form
          form={resetForm}
          layout="vertical"
          style={{ marginTop: 18 }}
          onFinish={(values) => updateMutation.mutate({ username: resetTarget!.username, changes: { password: values.password } }, { onSuccess: () => setResetTarget(null) })}
        >
          <Form.Item name="password" label="新密码" rules={[{ required: true, min: 8, max: 200, message: '密码需要 8-200 个字符' }]}>
            <Input.Password autoComplete="new-password" />
          </Form.Item>
          <Form.Item name="confirmPassword" label="确认新密码" dependencies={['password']} rules={[{ required: true, message: '请再次输入密码' }, ({ getFieldValue }) => ({ validator(_, value) { return !value || getFieldValue('password') === value ? Promise.resolve() : Promise.reject(new Error('两次密码不一致')) } })]}>
            <Input.Password autoComplete="new-password" />
          </Form.Item>
        </Form>
      </Modal>
    </>
  )
}

export default MemberManagement
