import { useQuery } from '@tanstack/react-query'
import dayjs from 'dayjs'
import type { CSSProperties } from 'react'
import { getRecentActivity } from '../api/activity'
import { queryKeys } from '../../../shared/api/queryKeys'
import type { CollaborationEvent } from '../../sync/api/eventStream'

type EventPayload = Record<string, unknown>

function payloadOf(event: CollaborationEvent): EventPayload {
  return event.payload && typeof event.payload === 'object' ? event.payload as EventPayload : {}
}

function actorName(actor?: string) {
  if (!actor) return '系统'
  const separator = actor.indexOf(':')
  return separator >= 0 ? actor.slice(separator + 1) : actor
}

function initials(name: string) {
  const characters = Array.from(name.trim())
  return characters.slice(0, 2).join('').toUpperCase() || 'SYS'
}

function activityCopy(event: CollaborationEvent) {
  const payload = payloadOf(event)
  const title = typeof payload.title === 'string'
    ? payload.title
    : typeof payload.displayName === 'string'
      ? payload.displayName
      : event.entityId

  if (event.type === 'issue.deleted') return { verb: '归档了工单', title, tone: 'danger' }
  if (event.type === 'issue.upserted' && event.entityRevision <= 1) return { verb: '创建了工单', title, tone: 'new' }
  if (event.type === 'issue.upserted') {
    const status = typeof payload.status === 'string' ? ` · ${payload.status}` : ''
    return { verb: '推进了工单', title: `${title}${status}`, tone: 'update' }
  }
  if (event.type === 'member.created') return { verb: '邀请了成员', title, tone: 'member' }
  if (event.type === 'member.disabled') return { verb: '停用了成员', title, tone: 'danger' }
  if (event.type === 'member.updated') return { verb: '调整了成员', title, tone: 'member' }
  return { verb: '更新了工作区', title, tone: 'update' }
}

function eventTime(value: string) {
  const date = dayjs(value)
  if (!date.isValid()) return '刚刚'
  const now = dayjs()
  if (now.diff(date, 'minute') < 1) return '刚刚'
  if (now.isSame(date, 'day')) return date.format('HH:mm')
  if (now.diff(date, 'day') < 7) return `周${'日一二三四五六'[date.day()]} ${date.format('HH:mm')}`
  return date.format('MM/DD HH:mm')
}

export function ActivityPulse({ isRealtime }: { isRealtime: boolean }) {
  const { data: events = [], isLoading } = useQuery({
    queryKey: queryKeys.activity,
    queryFn: () => getRecentActivity(8),
    staleTime: 10_000
  })

  return (
    <section className={`side-panel activity-pulse ${isRealtime ? 'is-live' : 'is-delayed'}`} aria-label="实时协作动态">
      <div className="activity-pulse-heading">
        <div>
          <div className="activity-pulse-kicker"><span /> Live operations</div>
          <div className="side-panel-title">协作脉冲</div>
        </div>
        <div className="activity-pulse-count">{events.length.toString().padStart(2, '0')}</div>
      </div>

      <div className="activity-tape" aria-live="polite">
        {isLoading ? <div className="activity-empty">正在接入事件流…</div> : null}
        {!isLoading && events.length === 0 ? <div className="activity-empty">下一次团队操作会从这里亮起。</div> : null}
        {events.map((event, index) => {
          const actor = actorName(event.actor)
          const copy = activityCopy(event)
          return (
            <article className={`activity-entry is-${copy.tone}`} key={event.cursor} style={{ '--activity-order': index } as CSSProperties}>
              <div className="activity-avatar" aria-hidden="true">{initials(actor)}</div>
              <div className="activity-entry-body">
                <div className="activity-entry-meta">
                  <strong>{actor}</strong>
                  <time dateTime={event.createdAt}>{eventTime(event.createdAt)}</time>
                </div>
                <div className="activity-entry-copy">{copy.verb}</div>
                <div className="activity-entry-title" title={copy.title}>{copy.title}</div>
              </div>
            </article>
          )
        })}
      </div>
      <div className="activity-pulse-foot">{isRealtime ? '实时连接' : '正在重连'} · 最近 {events.length} 次操作</div>
    </section>
  )
}
