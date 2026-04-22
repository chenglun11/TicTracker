import { Modal, Form, Input, Select, message } from 'antd'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { createIssue } from '../api/client'

interface CreateIssueModalProps {
  open: boolean
  onClose: () => void
}

function CreateIssueModal({ open, onClose }: CreateIssueModalProps) {
  const [form] = Form.useForm()
  const queryClient = useQueryClient()

  const mutation = useMutation({
    mutationFn: createIssue,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['issues'] })
      queryClient.invalidateQueries({ queryKey: ['status'] })
      message.success('工单创建成功')
      form.resetFields()
      onClose()
    },
    onError: () => {
      message.error('工单创建失败')
    }
  })

  return (
    <Modal
      title="新建工单"
      open={open}
      onCancel={onClose}
      onOk={() => form.submit()}
      confirmLoading={mutation.isPending}
    >
      <Form
        form={form}
        layout="vertical"
        onFinish={(values) => mutation.mutate(values)}
      >
        <Form.Item
          name="title"
          label="标题"
          rules={[{ required: true, message: '请输入工单标题' }]}
        >
          <Input placeholder="请输入工单标题" />
        </Form.Item>

        <Form.Item name="type" label="类型" initialValue="Bug">
          <Select
            options={[
              { label: 'Bug', value: 'Bug' },
              { label: 'Feature', value: 'Feature' },
              { label: 'Support', value: 'Support' }
            ]}
          />
        </Form.Item>

        <Form.Item name="department" label="部门">
          <Input placeholder="可选" />
        </Form.Item>
      </Form>
    </Modal>
  )
}

export default CreateIssueModal
