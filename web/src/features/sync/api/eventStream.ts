import { API_BASE } from '../../../shared/api/http'

export interface CollaborationEvent {
  cursor: number
  type: 'issue.upserted' | 'issue.deleted' | string
  entityId: string
  entityRevision: number
  payload: unknown
  actor?: string
  createdAt: string
}

interface SubscribeOptions {
  signal: AbortSignal
  onEvent: (event: CollaborationEvent) => void
  onConnectionChange: (connected: boolean) => void
}

function cursorStorageKey(token: string) {
  let hash = 2166136261
  for (let i = 0; i < token.length; i += 1) {
    hash ^= token.charCodeAt(i)
    hash = Math.imul(hash, 16777619)
  }
  return `collaboration-event-cursor:${(hash >>> 0).toString(16)}`
}

function wait(ms: number, signal: AbortSignal) {
  return new Promise<void>((resolve) => {
    const timer = window.setTimeout(resolve, ms)
    signal.addEventListener('abort', () => {
      window.clearTimeout(timer)
      resolve()
    }, { once: true })
  })
}

function processEventBlock(block: string, onEvent: (event: CollaborationEvent) => void) {
  const lines = block.split('\n')
  const eventName = lines.find(line => line.startsWith('event:'))?.slice(6).trim()
  const id = lines.find(line => line.startsWith('id:'))?.slice(3).trim()
  const data = lines
    .filter(line => line.startsWith('data:'))
    .map(line => line.slice(5).trimStart())
    .join('\n')
  if (eventName === 'session.revoked') {
    localStorage.removeItem('token')
    window.location.reload()
    return undefined
  }
  if (!id || !data) return undefined
  try {
    const event = JSON.parse(data) as CollaborationEvent
    onEvent(event)
    return Number(id)
  } catch (error) {
    console.warn('ignored malformed collaboration event', error)
    return undefined
  }
}

export async function subscribeCollaborationEvents(options: SubscribeOptions) {
  const token = localStorage.getItem('token') || ''
  if (!token) return
  const storageKey = cursorStorageKey(token)
  const storedCursor = Number(localStorage.getItem(storageKey) || '0')
  let cursor = Number.isSafeInteger(storedCursor) && storedCursor >= 0 ? storedCursor : 0
  let retryMs = 1000

  while (!options.signal.aborted) {
    try {
      const response = await fetch(`${API_BASE}/events/stream?after=${cursor}`, {
        headers: { Authorization: `Bearer ${token}`, Accept: 'text/event-stream' },
        cache: 'no-store',
        signal: options.signal
      })
      if (response.status === 401) {
        localStorage.removeItem('token')
        window.location.reload()
        return
      }
      if (!response.ok || !response.body) {
        throw new Error(`event stream returned ${response.status}`)
      }
      options.onConnectionChange(true)
      retryMs = 1000
      const reader = response.body.getReader()
      const decoder = new TextDecoder()
      let buffer = ''
      while (!options.signal.aborted) {
        const { value, done } = await reader.read()
        if (done) break
        buffer += decoder.decode(value, { stream: true }).replace(/\r\n/g, '\n')
        let separator = buffer.indexOf('\n\n')
        while (separator >= 0) {
          const block = buffer.slice(0, separator)
          buffer = buffer.slice(separator + 2)
          const nextCursor = processEventBlock(block, options.onEvent)
          if (nextCursor !== undefined && Number.isFinite(nextCursor)) {
            cursor = nextCursor
            localStorage.setItem(storageKey, String(cursor))
          }
          separator = buffer.indexOf('\n\n')
        }
      }
    } catch (error) {
      if (options.signal.aborted) return
      console.warn('collaboration event stream disconnected', error)
    }
    options.onConnectionChange(false)
    await wait(retryMs, options.signal)
    retryMs = Math.min(retryMs * 2, 15000)
  }
}
