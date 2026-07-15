# Collaboration Sync v2

Status: implementation contract (2026-07-13)

## Source of truth

The online workspace is authoritative once a client connects to a server. Local SQLite/JSON data is a cache plus an offline outbox. A client must never overwrite a newer online Issue from a whole-snapshot upload.

The existing workspace `revision` and `/sync` endpoints remain available during migration for bootstrap, settings, reports, and old clients. Day-to-day Issue mutations use Issue-level conditional writes.

## Issue version contract

Every Issue has:

- `revision`: positive, monotonically increasing integer; legacy Issues are read as revision 1.
- `updatedAt`: last content change time.
- `updatedBy`: authenticated actor (`web:<username>`, `macOS:<client-id>`, scheduler, or integration).
- `deletedAt`: tombstone time. Deleted Issues remain syncable but are hidden from normal lists.

Any mutation of Issue content, comments, external bindings, assignment, or deletion advances the Issue revision. Server-side integrations use the same rule.

## HTTP concurrency

`PATCH /api/v1/issues/:id`, `POST /api/v1/issues/:id/comments`, and `DELETE /api/v1/issues/:id` require:

```http
If-Match: "<issue revision>"
```

Responses:

- `200`: mutation committed; response includes the current Issue and `ETag` with its new revision.
- `409 issue_revision_conflict`: nothing was written; `current` contains the authoritative online Issue.
- `410 issue_deleted`: nothing was written; `current` contains the tombstone.
- `428 issue_revision_required`: caller omitted `If-Match`.

`GET /api/v1/issues` hides tombstones. `GET /api/v1/issues?includeDeleted=true` includes them for migration and recovery.

## Offline outbox (next implementation slice)

Each queued mutation will carry a stable `operationId`, Issue ID, base revision, mutation type, payload, author, and client timestamp. The server will persist operation IDs so retries are idempotent. The client removes an item only after an acknowledged commit.

On `409`, the client stores both its pending version and `current` as a conflict snapshot. Safe, field-disjoint changes may be rebased automatically; overlapping fields require an explicit user choice. Comments are append-only and deduplicated by operation ID.

## Event cursor (next implementation slice)

The server event log will assign a workspace-scoped monotonically increasing cursor. SSE emits Issue upserts/tombstones and member changes. Reconnect uses `Last-Event-ID`; if the cursor is outside retention, the server returns a resync instruction and the client fetches an incremental snapshot.

Polling remains a temporary fallback, not a second source of truth.

## Rollout and rollback

1. Deploy additive schema fields and revision-aware reads. Old Issue JSON is normalized to revision 1; SQLite columns are added idempotently.
2. Deploy Web conditional writes. Keep full `/sync` for existing macOS/Tauri clients.
3. Deploy event log, idempotent mutation API, and SSE while clients still poll as fallback.
4. Deploy macOS and Tauri outbox/delta clients. Before first authoritative import, create a recoverable local snapshot.
5. After all supported clients advertise v2, reject Issue changes made through whole-snapshot `/sync`; retain it for non-Issue workspace data and disaster recovery.

Rollback never drops the additive columns or tombstones. A previous server can ignore unknown JSON fields. During rollback, v2 clients stop flushing their outbox and retain pending operations until a revision-aware server is restored.

## Security boundary

Revision checks prevent lost updates; they are not authorization. Member roles and per-action authorization must be enforced before public multi-user rollout. Shared bearer tokens are migration-only credentials and must not be treated as user identity.
