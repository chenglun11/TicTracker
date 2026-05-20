import { useEffect } from 'react'
import { Button, Col, Form, Input, Row, Space, Switch, Typography, message } from 'antd'
import { CheckCircleOutlined, KeyOutlined, TeamOutlined } from '@ant-design/icons'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { getSetup, initSystem, saveSetup } from '../api/client'
import type { SetupRequest } from '../types'

const { Text } = Typography

interface InitPageProps {
  firstRun?: boolean
  onInitialized?: (token: string) => void
  onDone: () => void
}

function listToText(values?: string[]) {
  return (values || []).join('\n')
}

function textToList(value?: string) {
  return (value || '')
    .split(/\n|,/)
    .map(item => item.trim())
    .filter(Boolean)
}

function parseTime(value?: string) {
  const [hour, minute] = (value || '18:00').split(':').map(Number)
  return {
    hour: Number.isFinite(hour) ? Math.min(Math.max(hour, 0), 23) : 18,
    minute: Number.isFinite(minute) ? Math.min(Math.max(minute, 0), 59) : 0
  }
}

function InitPage({ firstRun = false, onInitialized, onDone }: InitPageProps) {
  const [form] = Form.useForm()
  const queryClient = useQueryClient()
  const { data, isLoading } = useQuery({
    queryKey: ['setup'],
    queryFn: getSetup,
    enabled: !firstRun
  })

  useEffect(() => {
    if (!firstRun) return
    form.setFieldsValue({
      username: 'admin',
      feishuEnabled: false,
      sendTime: '18:00',
      focusIssueTag: '今日Bug',
      linearEnabled: false
    })
  }, [firstRun, form])

  useEffect(() => {
    if (!data) return
    form.setFieldsValue({
      departments: listToText(data.departments),
      teamMembers: listToText(data.teamMembers),
      currentMemberName: data.currentMemberName,
      feishuEnabled: data.feishu.enabled,
      sendTime: data.feishu.sendTime || '18:00',
      focusIssueTag: data.feishu.focusIssueTag || '今日Bug',
      appID: data.feishu.appID,
      tasklistGUID: data.feishu.tasklistGUID,
      linearEnabled: data.linear.enabled,
      teamId: data.linear.teamId,
      teamName: data.linear.teamName,
      projectId: data.linear.projectId,
      projectName: data.linear.projectName
    })
  }, [data, form])

  const mutation = useMutation({
    mutationFn: async (payload: SetupRequest & { username?: string; password?: string }) => {
      if (firstRun) {
        const result = await initSystem({
          username: payload.username || '',
          password: payload.password || '',
          setup: payload
        })
        return { token: result.token }
      }
      const saved = await saveSetup(payload)
      return { setup: saved }
    },
    onSuccess: (saved) => {
      if ('setup' in saved && saved.setup) {
        queryClient.setQueryData(['setup'], saved.setup)
      }
      queryClient.invalidateQueries({ queryKey: ['setup'] })
      queryClient.invalidateQueries({ queryKey: ['auth-status'] })
      queryClient.invalidateQueries({ queryKey: ['status'] })
      queryClient.invalidateQueries({ queryKey: ['issues'] })
      message.success(firstRun ? '账号和工作台已初始化' : '初始化配置已保存')
      if ('token' in saved && saved.token) {
        onInitialized?.(saved.token)
        return
      }
      onDone()
    },
    onError: () => {
      message.error(firstRun ? '初始化失败，请检查账号密码和服务端状态' : '保存失败，请检查登录状态或服务端状态')
    }
  })

  const handleFinish = (values: any) => {
    const time = parseTime(values.sendTime)
    const payload: SetupRequest & { username?: string; password?: string } = {
      username: values.username?.trim() || '',
      password: values.password || '',
      departments: textToList(values.departments),
      teamMembers: textToList(values.teamMembers),
      currentMemberName: values.currentMemberName?.trim() || '',
      feishu: {
        enabled: Boolean(values.feishuEnabled),
        webhookURL: values.webhookURL?.trim() || '',
        webhookSecret: values.webhookSecret?.trim() || '',
        sendHour: time.hour,
        sendMinute: time.minute,
        focusIssueTag: values.focusIssueTag?.trim() || '今日Bug',
        appID: values.appID?.trim() || '',
        appSecret: values.appSecret?.trim() || '',
        verificationToken: values.verificationToken?.trim() || '',
        encryptKey: values.encryptKey?.trim() || '',
        tasklistGUID: values.tasklistGUID?.trim() || ''
      },
      linear: {
        enabled: Boolean(values.linearEnabled),
        teamId: values.teamId?.trim() || '',
        teamName: values.teamName?.trim() || '',
        projectId: values.projectId?.trim() || '',
        projectName: values.projectName?.trim() || ''
      }
    }
    mutation.mutate(payload)
  }

  return (
    <div className="init-page">
      <div className="init-hero">
        <div>
          <div className="dashboard-kicker">Workspace Init</div>
          <h2 className="dashboard-title">{firstRun ? '首次启动配置' : '初始化工作台'}</h2>
          <div className="dashboard-subtitle">
            {firstRun
              ? '先创建管理员账号，再把成员、飞书日报和 Linear 范围一起配好。'
              : '把成员、项目、飞书日报和 Linear 范围先配好，后面提交当天 bug 就不会散。'}
          </div>
        </div>
        <Space wrap>
          <span className="status-pill"><KeyOutlined /> {firstRun ? '创建账号登录' : '账号会话已验证'}</span>
          {data?.initialized ? <span className="status-pill"><CheckCircleOutlined /> 已有配置</span> : null}
        </Space>
      </div>

      <Form
        form={form}
        layout="vertical"
        onFinish={handleFinish}
        disabled={isLoading}
        className="init-form"
      >
        {firstRun ? (
          <section className="init-section">
            <div className="init-section-head">
              <KeyOutlined />
              <div>
                <div className="side-panel-title">管理员账号</div>
                <div className="side-panel-copy">以后网页端使用这个账号登录，不再需要手动保存 Web Token。</div>
              </div>
            </div>
            <Row gutter={16}>
              <Col xs={24} md={12}>
                <Form.Item
                  label="账号"
                  name="username"
                  rules={[{ required: true, message: '请输入账号' }]}
                >
                  <Input autoComplete="username" placeholder="admin" />
                </Form.Item>
              </Col>
              <Col xs={24} md={12}>
                <Form.Item
                  label="密码"
                  name="password"
                  rules={[
                    { required: true, message: '请输入密码' },
                    { min: 8, message: '密码至少 8 位' }
                  ]}
                >
                  <Input.Password autoComplete="new-password" placeholder="至少 8 位" />
                </Form.Item>
              </Col>
            </Row>
          </section>
        ) : null}

        <section className="init-section">
          <div className="init-section-head">
            <TeamOutlined />
            <div>
              <div className="side-panel-title">团队与本地工作台</div>
              <div className="side-panel-copy">这里决定“我提交的”和本地项目维度。每行一个成员或项目。</div>
            </div>
          </div>
          <Row gutter={16}>
            <Col xs={24} md={12}>
              <Form.Item label="本地项目 / 部门" name="departments">
                <Input.TextArea rows={5} placeholder={'支付\n账号\n内容安全'} />
              </Form.Item>
            </Col>
            <Col xs={24} md={12}>
              <Form.Item label="团队成员" name="teamMembers">
                <Input.TextArea rows={5} placeholder={'Max\nAlice\nBob'} />
              </Form.Item>
              <Form.Item label="我是谁" name="currentMemberName">
                <Input placeholder="用于日报里的「我今日提交」" />
              </Form.Item>
            </Col>
          </Row>
        </section>

        <section className="init-section">
          <div className="init-section-head">
            <span className="data-flow-dot">飞</span>
            <div>
              <div className="side-panel-title">飞书日报主出口</div>
              <div className="side-panel-copy">定时日报会统计当天完整数据，重点 Tag 只额外高亮。</div>
            </div>
          </div>
          <Row gutter={16}>
            <Col xs={24} md={8}>
              <Form.Item label="启用飞书日报" name="feishuEnabled" valuePropName="checked">
                <Switch />
              </Form.Item>
            </Col>
            <Col xs={24} md={8}>
              <Form.Item label="发送时间" name="sendTime">
                <Input placeholder="18:00" />
              </Form.Item>
            </Col>
            <Col xs={24} md={8}>
              <Form.Item label="日报重点 Tag" name="focusIssueTag">
                <Input placeholder="今日Bug" />
              </Form.Item>
            </Col>
            <Col xs={24}>
              <Form.Item label="Webhook URL" name="webhookURL">
                <Input placeholder="https://open.feishu.cn/open-apis/bot/v2/hook/..." />
              </Form.Item>
            </Col>
            <Col xs={24} md={12}>
              <Form.Item label="Webhook Secret" name="webhookSecret">
                <Input.Password placeholder={data?.feishu.webhookSecretConfigured ? '已配置，留空则保留现状' : '签名 Secret，可选'} />
              </Form.Item>
            </Col>
            <Col xs={24} md={12}>
              <Form.Item label="飞书任务清单 GUID" name="tasklistGUID">
                <Input placeholder="用于任务事件回流，可选" />
              </Form.Item>
            </Col>
            <Col xs={24} md={12}>
              <Form.Item label="App ID" name="appID">
                <Input placeholder="cli_xxxx" />
              </Form.Item>
            </Col>
            <Col xs={24} md={12}>
              <Form.Item label="App Secret" name="appSecret">
                <Input.Password placeholder={data?.feishu.appSecretConfigured ? '已配置，留空则保留现状' : '用于 Tasks API，可选'} />
              </Form.Item>
            </Col>
            <Col xs={24} md={12}>
              <Form.Item label="Verification Token" name="verificationToken">
                <Input.Password placeholder="飞书事件订阅校验，可选" />
              </Form.Item>
            </Col>
            <Col xs={24} md={12}>
              <Form.Item label="Encrypt Key" name="encryptKey">
                <Input.Password placeholder={data?.feishu.encryptKeyPresent ? '已配置，留空则保留现状' : '飞书事件加密 Key，可选'} />
              </Form.Item>
            </Col>
          </Row>
        </section>

        <section className="init-section">
          <div className="init-section-head">
            <span className="data-flow-dot">L</span>
            <div>
              <div className="side-panel-title">Linear 范围</div>
              <div className="side-panel-copy">Web 初始化只保存 Team / Project 范围；Linear API Token 仍建议放在 macOS Keychain。</div>
            </div>
          </div>
          <Row gutter={16}>
            <Col xs={24} md={6}>
              <Form.Item label="启用 Linear" name="linearEnabled" valuePropName="checked">
                <Switch />
              </Form.Item>
            </Col>
            <Col xs={24} md={9}>
              <Form.Item label="Team ID" name="teamId">
                <Input placeholder="Linear team uuid" />
              </Form.Item>
            </Col>
            <Col xs={24} md={9}>
              <Form.Item label="Team 名称" name="teamName">
                <Input placeholder="Support" />
              </Form.Item>
            </Col>
            <Col xs={24} md={12}>
              <Form.Item label="Project ID" name="projectId">
                <Input placeholder="留空表示 Team 下全部 issues" />
              </Form.Item>
            </Col>
            <Col xs={24} md={12}>
              <Form.Item label="Project 名称" name="projectName">
                <Input placeholder="可选" />
              </Form.Item>
            </Col>
          </Row>
        </section>

        <div className="init-actions">
          <Text type="secondary">敏感字段不会在初始化页回显；留空会尽量保留已有 secret。</Text>
          <Space>
            {firstRun ? null : <Button onClick={onDone}>稍后再说</Button>}
            <Button type="primary" htmlType="submit" loading={mutation.isPending}>
              {firstRun ? '创建账号并进入工作台' : '保存并进入工作台'}
            </Button>
          </Space>
        </div>
      </Form>
    </div>
  )
}

export default InitPage
