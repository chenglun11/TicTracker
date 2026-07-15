import { useEffect, useRef, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { queryKeys } from '../../../shared/api/queryKeys'
import { getSyncMeta } from '../api/sync'
import { subscribeCollaborationEvents } from '../api/eventStream'

export function useSyncMonitor() {
  const queryClient = useQueryClient()
  const observedRevision = useRef<number | null>(null)
  const realtimeConnected = useRef(false)
  const [isRealtime, setIsRealtime] = useState(false)
  const query = useQuery({
    queryKey: queryKeys.sync.meta,
    queryFn: getSyncMeta,
    refetchInterval: isRealtime ? 30000 : 5000,
    refetchIntervalInBackground: true
  })

  useEffect(() => {
    const revision = query.data?.revision
    if (revision === undefined) return

    if (observedRevision.current !== null && observedRevision.current !== revision) {
      void queryClient.invalidateQueries({ queryKey: queryKeys.issues.all })
      void queryClient.invalidateQueries({ queryKey: queryKeys.status })
    }
    observedRevision.current = revision
  }, [query.data?.revision, queryClient])

  useEffect(() => {
    const controller = new AbortController()
    void subscribeCollaborationEvents({
      signal: controller.signal,
      onConnectionChange: (connected) => {
        if (connected && !realtimeConnected.current) {
          void queryClient.invalidateQueries({ queryKey: queryKeys.issues.all })
          void queryClient.invalidateQueries({ queryKey: queryKeys.status })
          void queryClient.invalidateQueries({ queryKey: queryKeys.sync.meta })
        }
        realtimeConnected.current = connected
        setIsRealtime(connected)
      },
      onEvent: (event) => {
        if (event.type.startsWith('member.')) {
          void queryClient.invalidateQueries({ queryKey: queryKeys.members })
          void queryClient.invalidateQueries({ queryKey: queryKeys.auth.me })
        }
        void queryClient.invalidateQueries({ queryKey: queryKeys.issues.all })
        void queryClient.invalidateQueries({ queryKey: queryKeys.status })
        void queryClient.invalidateQueries({ queryKey: queryKeys.sync.meta })
      }
    })
    return () => controller.abort()
  }, [queryClient])

  return {
    revision: query.data?.revision,
    lastModified: query.data?.lastModified,
    lastModifiedBy: query.data?.lastModifiedBy,
    isConnected: query.isSuccess,
    isChecking: query.isFetching,
    isRealtime,
    error: query.error
  }
}
