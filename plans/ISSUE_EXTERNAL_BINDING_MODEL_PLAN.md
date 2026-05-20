# Issue External Binding Model Plan

## Summary

Use one unified external binding model for Jira, Meta Direct Support, Feishu Task, and Linear. Keep the current single primary source for sync ownership, and allow other sources to remain as secondary read-only references.

## Key Changes

- Add an `externalBindings` collection per issue while preserving legacy fields during migration.
- Keep `source` or a future `primarySource` as the sync owner; only the primary binding drives remote writes.
- Convert source switches into binding moves instead of deleting useful reference data.
- Keep local `department` independent from Linear Project.
- Preserve Linear Project and Issue as a parent-child remote relationship.

## Compatibility

- Existing `jiraKey`, `ticketURL`, `feishuTaskGuid`, and Linear fields remain readable.
- New writes should prefer the unified binding model once implemented.
- Old data should migrate lazily on load and encode in the new shape after save.

## Test Plan

- Existing issues load without data loss.
- Switching primary source does not erase secondary references.
- Linear Project filtering does not block issue selection when no project is chosen.
- Sync writes only to the primary source.
