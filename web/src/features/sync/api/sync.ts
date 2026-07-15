import type { SyncMetaResponse } from '../../../types'
import { API_BASE, httpClient } from '../../../shared/api/http'

export const getSyncMeta = async (): Promise<SyncMetaResponse> => {
  const { data } = await httpClient.get<SyncMetaResponse>(`${API_BASE}/sync/meta`)
  return data
}
