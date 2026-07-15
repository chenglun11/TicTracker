import { useState } from 'react'
import { Form, Input, Modal, Typography, message } from 'antd'
import { KeyOutlined } from '@ant-design/icons'
import { changePassword } from '../api/client'
import type { AuthUser } from '../entities/member/model/types'

const { Text } = Typography

interface AccountSecurityModalProps {
  open: boolean
  user: AuthUser
  onClose: () => void
  onTokenChanged: (token: string) => void
}

export default function AccountSecurityModal({ open, user, onClose, onTokenChanged }: AccountSecurityModalProps) {
  const [form] = Form.useForm()
  const [saving, setSaving] = useState(false)

  const submit = async () => {
    try {
      const values = await form.validateFields()
      setSaving(true)
      const result = await changePassword({ currentPassword: values.currentPassword, newPassword: values.newPassword })
      localStorage.setItem('token', result.token)
      onTokenChanged(result.token)
      form.resetFields()
      message.success('密码已更新，其他设备的会话已失效')
      onClose()
    } catch (error: any) {
      if (error?.errorFields) return
      message.error(error?.response?.data?.error || '密码更新失败，请稍后重试')
    } finally {
      setSaving(false)
    }
  }

  return (
    <Modal
      title={<span><KeyOutlined /> 账户安全</span>}
      open={open}
      onCancel={onClose}
      onOk={() => void submit()}
      okText="更新密码"
      confirmLoading={saving}
      destroyOnClose
    >
      <div className="account-security-intro">
        <strong>{user.displayName}</strong>
        <Text type="secondary">@{user.username} · 修改后其他设备需要重新登录</Text>
      </div>
      <Form form={form} layout="vertical" requiredMark="optional" autoComplete="off">
        <Form.Item name="currentPassword" label="当前密码" rules={[{ required: true, message: '请输入当前密码' }]}>
          <Input.Password autoComplete="current-password" />
        </Form.Item>
        <Form.Item name="newPassword" label="新密码" rules={[{ required: true, min: 8, max: 200, message: '新密码需要 8-200 个字符' }]}>
          <Input.Password autoComplete="new-password" />
        </Form.Item>
        <Form.Item
          name="confirmPassword"
          label="确认新密码"
          dependencies={['newPassword']}
          rules={[{ required: true, message: '请再次输入新密码' }, ({ getFieldValue }) => ({ validator(_, value) { return !value || getFieldValue('newPassword') === value ? Promise.resolve() : Promise.reject(new Error('两次密码不一致')) } })]}
        >
          <Input.Password autoComplete="new-password" />
        </Form.Item>
      </Form>
    </Modal>
  )
}
