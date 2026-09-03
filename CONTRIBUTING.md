# Contributing to Clipy

欢迎使用中文或英文提交 Issue 和 Pull Request。

## Before making changes

- Read [Development](docs/DEVELOPMENT.md) for setup and validation commands.
- Use the [Architecture map](docs/ARCHITECTURE.md) to locate the owning module.
- Discuss large features, protocol changes, and data migrations in an issue first.
- Report vulnerabilities according to [SECURITY.md](SECURITY.md), not a public
  issue containing private clipboard contents or exploit details.
- Review [third-party provenance](THIRD_PARTY_NOTICES.md) before importing code.

## Workflow

1. Create a focused branch from the current default branch.
2. Keep behavior changes separate from large formatting or file moves where practical.
3. Add regression tests for changed logic. Update both protocol implementations
   and `docs/PROTOCOL.md` when changing the wire contract.
4. Run `bash scripts/check.sh all`; build the affected native platform as described
   in the development guide. List unrun device tests explicitly.
5. Open a PR describing the problem, solution, test results and migration impact.

## Code conventions

- Honor `.editorconfig`; format Dart with the pinned SDK's `dart format`.
- Keep entrypoints small. Put UI in feature folders, orchestration in managers,
  persistence in repositories, and wire codecs in the sync module.
- Keep Dart state classes private. Dispose subscriptions, controllers, timers,
  sockets and file handles in the owning lifecycle.
- Prefer explicit failure results and bounded retries/timeouts. Do not silently
  log credentials, clipboard bodies or notification text.
- Swift UI mutations belong on the main thread. Do not call a `syncQueue.sync`
  wrapper from code already running on that queue.
- Preserve public bundle IDs, channel names, preference keys and database schemas
  unless the change includes an upgrade/migration plan.
- Use existing localization mechanisms instead of embedding new user-facing strings.
- No personal absolute paths, SDK caches, generated packages, signing keys or
  live-user test data in commits. Commit `pubspec.lock` for this application.

The project currently compiles Swift in language mode 5 with a modern SDK.
Swift 6 concurrency warnings are migration work, not a reason to hide all warnings
or blanket-annotate types as `@unchecked Sendable`.

## Respectful collaboration

Keep discussion constructive, focus on behavior and code, and respect privacy.
Describe limitations honestly; passing a build is not equivalent to device or
security testing. Contributors retain attribution for their work.
