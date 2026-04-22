import dayjs from 'dayjs'
import customParseFormat from 'dayjs/plugin/customParseFormat'
import 'dayjs/locale/zh-cn'

dayjs.extend(customParseFormat)
dayjs.locale('zh-cn')

export const formatDate = (date: string | undefined): string => {
  if (!date) return '-'
  const d = dayjs(date)
  return d.isValid() ? d.format('YYYY-MM-DD HH:mm:ss') : date
}

export const formatRelativeTime = (date: string | undefined): string => {
  if (!date) return '-'
  const now = dayjs()
  const target = dayjs(date)
  const diffMinutes = now.diff(target, 'minute')

  if (diffMinutes < 1) return '刚刚'
  if (diffMinutes < 60) return `${diffMinutes}分钟前`

  const diffHours = now.diff(target, 'hour')
  if (diffHours < 24) return `${diffHours}小时前`

  const diffDays = now.diff(target, 'day')
  if (diffDays < 7) return `${diffDays}天前`

  return target.format('YYYY-MM-DD')
}

export const statusColor = (status: string): string => {
  const colorMap: Record<string, string> = {
    '待处理': 'orange',
    '处理中': 'blue',
    '测试中': 'cyan',
    '已排期': 'purple',
    '观测中': 'gold',
    '已修复': 'green',
    '已忽略': 'default'
  }
  return colorMap[status] || 'default'
}

export const typeColor = (type: string): string => {
  const colorMap: Record<string, string> = {
    'Bug': 'red',
    'Feature': 'blue',
    'Support': 'green',
    'Task': 'cyan',
    'Improvement': 'purple'
  }
  return colorMap[type] || 'default'
}
