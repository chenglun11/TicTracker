import type { CollaborationEvent } from '../../sync/api/eventStream'
import { API_BASE, httpClient } from '../../../shared/api/http'

interface ActivityResponse {
  events: CollaborationEvent[]
}

export async function getRecentActivity(limit = 8): Promise<CollaborationEvent[]> {
  const { data } = await httpClient.get<ActivityResponse>(`${API_BASE}/activity`, { params: { limit } })
  return data.events
}
