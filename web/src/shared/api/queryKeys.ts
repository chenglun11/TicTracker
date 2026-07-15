export const queryKeys = {
  auth: {
    status: ['auth-status'] as const,
    me: ['auth', 'me'] as const
  },
  members: ['members'] as const,
  setup: ['setup'] as const,
  status: ['status'] as const,
  issues: {
    all: ['issues'] as const,
    list: (status?: string) => ['issues', { status: status ?? 'all' }] as const
  },
  sync: {
    meta: ['sync', 'meta'] as const,
    admin: ['sync', 'admin'] as const
  }
}
