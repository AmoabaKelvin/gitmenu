# Research: GitHub notifications menu bar app (2026-08-25)

## Live probe (own account, `gh api`)

- `GET /notifications` returns `X-Poll-Interval: 60`, `Cache-Control: private, max-age=60`, `Last-Modified`, `ETag`.
- `If-Modified-Since` works: returns `304 Not Modified`.
- Rate limit 5000/hr. `X-Accepted-Oauth-Scopes: notifications, repo`.
- `per_page` max is 50 (docs); we asked for 100 and got 100 in practice, but do not rely on it.
- Reason/type mix in last 100: subscribed (Issue/PR/Release), state_change, author, mention, review_requested, assign, ci_activity (CheckSuite).
- `ci_activity` / CheckSuite: `subject.url` and `latest_comment_url` are both null. Title looks like
  `"<Workflow> workflow run failed for <branch> branch"`. Must parse title and link to Actions search.
- `review_requested` and `assign` often have `latest_comment_url: null`; open via `subject.url` -> `html_url`.

## API facts (docs.github.com/en/rest/activity/notifications)

- Params: `all`, `participating`, `since`, `before`, `page`, `per_page`.
- Thread: `id, unread, reason, updated_at, last_read_at, subject{title,url,latest_comment_url,type}, repository, url, subscription_url`.
- Reasons: approval_requested, assign, author, ci_activity, comment, invitation, manual, member_feature_requested,
  mention, review_requested, security_advisory_credit, security_alert, state_change, subscribed, team_mention.
- Subject types seen: Issue, PullRequest, Commit, Release, Discussion, CheckSuite, WorkflowRun,
  RepositoryVulnerabilityAlert, RepositoryInvitation.
- Mark read: `PATCH /notifications/threads/{id}`. Mark done: `DELETE /notifications/threads/{id}`.
  Mark all read: `PUT /notifications`. Mute: `PUT .../threads/{id}/subscription {ignored:true}`. Unsubscribe: `DELETE .../subscription`.
- 304 responses do not count against the rate limit. Obey `X-Poll-Interval` (can rise under load).
- No push channel: no webhooks per user, no public GraphQL notifications (schema appeared Jan 2025 and was pulled).
- Latency: undocumented; observed seconds to ~1 min. Server caches the endpoint 60s, so polling faster than 60s is pointless.
- Web deep link: append `?notification_referrer_id=` base64(`018:NotificationThread{id}:{userId}`) so github.com marks it read (Gitify does this).

## Auth

- Notifications endpoints only work with classic-scope tokens: OAuth App tokens or classic PATs.
  GitHub Apps and fine-grained PATs cannot read `/notifications` (confirmed against endpoint lists).
- Scope `notifications`: list + mark read + subscriptions. Reading private-repo issue/PR detail (state, reviews) needs `repo`.
- OAuth device flow: enable in app settings, only `client_id` needed, poll `interval` (5s), `slow_down` adds 5s, code expires 900s.
  Tokens do not expire unless the app opts into expiring tokens.
- GHES: base `https://HOST/api/v3`; OAuth app must be registered on that host, so offer PAT + custom host.
- SAML orgs: PAT must be SSO-authorized or those orgs' notifications are silently missing.

## Why other apps miss or delay notifications

1. `participating=true` hides watched-repo activity.
2. `since=last_sync` never surfaces read-state changes or threads that changed without a new unread event.
3. `Last-Modified` moves backwards when a thread is marked unread; naive If-Modified-Since then stalls (Gitify #2303 dropped it).
4. GHE HTTP caching returned stale lists until `Cache-Control: no-cache` (Gitify #1611).
5. One bad thread (deleted repo) crashed the whole list render (Gitify #1567).
6. Rate-limit blowups from re-enriching every thread every poll (Gitify #3065, #3101).
7. Electron idle cost: neat.run ~200MB idle, Electron animations drain battery while hidden (Gitify #318).
8. Trailer only sees watched repos, so it misses review requests entirely.
9. App Nap throttles hidden LSUIElement apps; timers drift across sleep.

## Stack decision: native Swift

| | Swift/SwiftUI | Tauri v2 | Electron |
|---|---|---|---|
| Idle RAM | tens of MB | 30-80 MB | 200-300 MB |
| Actionable notification buttons | yes (UNUserNotificationCenter) | no on macOS | no |
| Launch at login | SMAppService | plugin | setLoginItemSettings |
| Keychain, NWPathMonitor, sleep/wake | direct | via plugins | partial |
| Auto-update | Sparkle 2 | updater plugin | electron-updater |

Machine has Xcode 26.5 / Swift 6.3. Target macOS 14+.

## Background reliability on macOS

- Hold `ProcessInfo.processInfo.beginActivity(.userInitiatedAllowingIdleSystemSleep)` for app lifetime to defeat App Nap.
- Poll with `NSBackgroundActivityScheduler` (interval 60, tolerance ~10) or a tolerant Timer.
- Observe `NSWorkspace.didWakeNotification` and `screensDidWakeNotification`: poll immediately on wake.
- `NWPathMonitor`: poll immediately when path becomes satisfied; retry with backoff.

## Gitify enrichment approach (worth copying)

- Batch up to 100 threads into one merged GraphQL query (PR/issue/discussion): state, isDraft, merged, author, labels,
  reviews, review threads, latest comments. Cache by (id, updated_at); only enrich changed threads.
- Per-type handlers for URL resolution with a fallback to `repository.html_url`.
- Pick the comment/review closest to `updated_at` as the "what happened" line.

## Round 2 (2026-08-25): verification and alternatives

### Empirically verified with own token
- `per_page` is hard-capped at 50 on `/notifications` (asked 100 and 200, got 50). Gitify asks for 100.
- 304 via `If-Modified-Since` and via `If-None-Match` (ETag) both cost zero rate limit (X-Ratelimit-Used unchanged over 3 calls).
- `Last-Modified` differs per parameter set (`all=true` vs unread-only). Keep poll params identical.
- Inbox size: 16 pages unread, 21 pages with `all=true`. Must paginate via `Link` header and handle large backlogs.
- Event-to-thread lag (`latest_comment.created_at` vs `updated_at`): 20-35s when a comment is the trigger.
  Worst case with a 60s poll: ~95s. Typical: ~50s.
- GraphQL public schema: no `NotificationThread`, no notification fields on `Query` or `User`
  (introspected). The 2025 changelog entry mentioning `NotificationThread` refers to a non-public schema.
- Events API (`received_events`): `Cache-Control: max-age=300`, docs say 30s-6h latency. Reject.
- Search API: `is:pr review-requested:@me` works, 30 req/min, index is eventually consistent. Supplement only.
- `https://github.com/notifications` with `Accept: application/json` returns 404 without a web session. No JSON side door.

### Nothing new in 2025-Aug 2026
- REST notifications API unchanged; REST version 2026-03-10 has no notifications breaking changes.
- Fine-grained PATs GA (2025-03-18) still exclude Notifications. No classic PAT / OAuth App sunset announced.
- No user-scoped webhook: docs state webhooks cannot target "personal notifications or mentions".
- Web notification retention cut from 5 to 3 months (2026-04-24). `all=true` history is shorter now.
- GitHub's own Slack app lagged by hours in Apr 2026 (community #192430); email stayed instant.
- EMU enterprises can block classic PATs outright; accept that some enterprise users cannot use the app.

### Alternative channels: verdicts
| Channel | Verdict | Why |
|---|---|---|
| Poll `GET /notifications` (conditional, 60s) | primary | only supported inbox source; free 304s |
| GraphQL batched enrichment | supplement | PR state, reviews, CI, latest comment; fresh; ~1 point per batch |
| Search `review-requested:@me`, `assignee:@me` | supplement | reconciliation list "still waiting on me"; stale index |
| IMAP IDLE on GitHub email | opt-in later | seconds latency but needs mail creds; no thread id in email; not everyone gets email |
| GitHub App webhook relay | later, owned repos only | p50 ~28s per Mergify; needs relay server; cannot cover watched repos |
| Events API / Atom feeds | reject | 30s-6h latency, no "to me" filter |
| Mobile push / web cookie scraping | reject | private credentials, undocumented, AUP risk |
| gh-notify / gh-dash | nothing to copy | one-shot `gh api`, no conditional polling |

### Design consequences
- Poll `all=true`, `per_page=50`, follow `Link` until a page has no thread newer than our newest known `updated_at`
  (first run: full walk). Diff by `(id, updated_at, unread)`.
- Conditional GET per (params) pair; on 200, walk pages; every 10th poll do an unconditional fetch as a safety net
  (guards the Last-Modified regression on web mark-unread).
- Trigger extra polls on wake, network return, popover open, and after our own mutations (1s delay).
- Enrich only changed threads via batched GraphQL; cache by `(id, updated_at)`.
- Treat `updated_at` as event time when computing "2m ago"; show it, not arrival time.

### Why Discord gets events instantly and we cannot
Discord channels use repo/org webhooks (admin-installed, fire-and-forget POST within seconds). Webhooks are per-repo,
need admin, need a public endpoint, and carry no per-user inbox semantics or thread id. Notifications are a per-user
aggregate GitHub computes and only exposes by polling. v2 option: a GitHub App the user installs on own repos/orgs,
relayed to the Mac (~2-5s), reconciled against the next `/notifications` poll for thread id and read state.

### Where urgent notifications come from (own inbox, 200 threads, 2026-08-25)
198/200 threads and 16/16 urgent (mention/review_requested/assign) came from repos with admin access
(employer org + own repos). 2 from one external repo, both "subscribed". Hypothesis: for working developers, urgent = org + own.

### Hybrid plan
- v1 poller: source of truth (thread ids, read/done/mute, coverage of all repos). Required regardless.
- v1.5 GitHub App + relay (Cloudflare Worker/Durable Object WebSocket): seconds latency on installed repos; adds
  star/fork/push/repository.created which the inbox never shows. Events upsert into the same local store as provisional
  rows; next poll reconciles. Relay down => v1 behaviour. Relay must be forward-only, store nothing, self-hostable.
- Relevance from events: requested_reviewer == me, assignee == me, @me in body, or thread already in local inbox.
- Org installs need an org owner; own repos are self-serve. GitHub App tokens cannot read /notifications, so OAuth App sign-in stays.
