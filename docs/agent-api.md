# Server agent REST API (v1.1)

This is the API between the Doomsaday mobile app (`app/`) and the `agent_zero` service (`agent_zero/`) installed on each Docker host. It is derived screen by screen from the design canvas, so every endpoint below has a button or a list that needs it.

Status: `agent_zero` implements this document. The app talks to it through `HttpAgentApi` over pinned HTTPS, and keeps the mock as a demo mode. The section "Revision 1.1" at the end records what was decided once both sides were built, and what is still open. Field-level detail for every endpoint is in `agent_zero/API_NOTES.md`.

## Conventions

- **Base URL**: `https://<host>:8443/v1`. HTTPS only. The app pins the agent's certificate fingerprint at pairing time and refuses the connection if it changes.
- **Auth**: every call after pairing sends `Authorization: Bearer <device key>`. Device keys are per phone and can be revoked individually.
- **Roles**: `admin` can do everything, `operator` can start, stop, restart and redeploy, `viewer` is read-only. The agent enforces this; the app only hides buttons.
- **Format**: JSON in and out, UTF-8, timestamps in RFC 3339 UTC, sizes in bytes.
- **Errors**: `{"error": {"code": "container_not_found", "message": "...", "details": {}}}` with a matching HTTP status (400, 401, 403, 404, 409, 422, 500, 502 when the Docker daemon is unreachable).
- **Lists**: `?limit=` and `?cursor=`; the response carries `next_cursor` when there is more.
- **Long operations** (image pull, stack redeploy, prune, agent update) return `202` with `{"job_id": "..."}`. Poll `GET /jobs/{id}` or follow `GET /jobs/{id}/events` (Server-Sent Events) for progress lines and the final result.
- **Streams** (logs, live stats, Docker events) are Server-Sent Events. The interactive shell is the one WebSocket.
- **Risky actions**: stop, remove, prune, stack down and unpair accept an `X-Confirmed` header whose value is `biometric` or `typed` (typed is for a desktop client that had the user type the target's name instead of taking a fingerprint). When the server setting "fingerprint before risky actions" is on, the agent rejects these calls without it (`428`).
- **Audit**: every mutating call is written to the activity log with device, user, action, target and result.

## Pairing and devices

Screens: Servers, Pair an agent, Server settings.

| Method | Path | Purpose |
|---|---|---|
| POST | `/pair` | Exchange the one-time pairing token for a device key. Body: `token`, `device_name`, `push_token`. Returns `device_key`, `role`, `cert_fingerprint`. Unauthenticated, rate limited. |
| GET | `/me` | The calling device: `device_id`, `device_name`, `role`, `cert_fingerprint`, `paired_devices`, `agent_version`. Any authenticated role. |
| GET | `/devices` | Paired phones with last-seen time and role. |
| PATCH | `/devices/{id}` | Change role or push token. |
| DELETE | `/devices/{id}` | Revoke one phone. Deleting your own device is "Unpair this server". |

## Server overview

Screens: Servers (card figures), Server overview.

| Method | Path | Purpose |
|---|---|---|
| GET | `/health` | Cheap reachability check used for the online or offline badge. Unauthenticated, returns only `{"ok": true}`. |
| GET | `/system` | Host name, Docker version, agent version, uptime, CPU cores, memory and disk totals, Swarm role. |
| GET | `/system/stats` | Current CPU %, memory used, disk used, container counts by state. |
| GET | `/system/stats/stream` | Same figures as SSE, one event every few seconds. |
| GET | `/activity` | Recent activity and the full audit log (`?actor=`, `?since=`). |
| GET | `/events/stream` | Docker events as SSE, so lists refresh without polling. |

## Containers

Screens: Containers, Container detail, Confirm a risky action, Live logs.

| Method | Path | Purpose |
|---|---|---|
| GET | `/containers` | List. Filters: `?state=running\|exited\|restarting\|paused\|created\|dead`, `?stack=`, `?q=`. Each item carries name, image, state, health, uptime, CPU %, memory, restart count. |
| GET | `/containers/{id}` | Full detail: ports, networks, mounts, restart policy, stack, labels, environment variable **names only**. |
| GET | `/containers/{id}/env` | Environment values. Admin only, always audited. |
| GET | `/containers/{id}/stats/stream` | CPU, memory and network rates as SSE. |
| POST | `/containers/{id}/start` | |
| POST | `/containers/{id}/stop?timeout=10` | Risky. SIGTERM, then SIGKILL after the timeout. |
| POST | `/containers/{id}/restart?timeout=10` | |
| POST | `/containers/{id}/pause`, `/unpause` | |
| DELETE | `/containers/{id}?force=&volumes=` | Risky. |
| GET | `/containers/{id}/impact` | What the confirm sheet shows before a stop: published ports and containers that depend on this one. |
| GET | `/containers/{id}/logs` | `?since=`, `?until=`, `?tail=`, `?stream=stdout\|stderr`, `?q=`. Plain fetch, also used for download. |
| GET | `/containers/{id}/logs/stream` | Live tail as SSE. Each event has `ts`, `stream`, `line`. |
| WS | `/containers/{id}/exec` | Interactive shell. Admin only, session is audited. |

## Compose stacks

Screen: Compose stacks.

| Method | Path | Purpose |
|---|---|---|
| GET | `/stacks` | Compose projects found under the agent's configured stacks directory, with services up and total. |
| GET | `/stacks/{name}` | Services, their containers and the compose file path. |
| POST | `/stacks/{name}/up` | Start the stack. Job. |
| POST | `/stacks/{name}/redeploy` | Pull images, then `up -d`. Job. |
| POST | `/stacks/{name}/restart` | Job. |
| POST | `/stacks/{name}/down` | Risky. Job. |

## Swarm services

Screen: Swarm services. The `/services` endpoints return `409 not_a_manager` when the host is not a Swarm manager. `GET /swarm` always answers `200`, with `active: false` and `is_manager: false` on such a host, so the screen can say "not in a swarm" instead of showing an error.

| Method | Path | Purpose |
|---|---|---|
| GET | `/swarm` | Node list and this node's role. |
| GET | `/services` | Name, image, mode (replicated or global), running and desired tasks, update state. |
| GET | `/services/{id}/tasks` | Per-task node, state and error. |
| POST | `/services/{id}/scale` | Body: `replicas`. |
| POST | `/services/{id}/update` | Body: `image` (optional), `force`. Rolling update. Job. |
| POST | `/services/{id}/rollback` | Job. |

## Images, volumes, networks

Screens: Images, Volumes, Networks.

| Method | Path | Purpose |
|---|---|---|
| GET | `/images` | Tags, size, created, `in_use_by`. Summary block with total and reclaimable bytes. |
| POST | `/images/pull` | Body: `ref`. Uses stored registry credentials. Job with layer progress. |
| DELETE | `/images/{id}?force=` | Risky. `409` when a container uses it. |
| POST | `/images/prune` | Risky. Body: `dangling_only`. Job, returns bytes reclaimed. |
| GET | `/volumes` | Name, driver, size, `mounted_by`, last used. Summary block with `count`, `total_bytes` and `unmounted`. |
| POST | `/volumes` | Body: `name`, `driver`, `labels`. |
| DELETE | `/volumes/{name}` | Risky. `409` when mounted. |
| POST | `/volumes/prune` | Risky. Job. |
| GET | `/networks` | Name, driver, subnet, scope, attached container count, `is_default`. Summary block with `count` and `unused`. |
| POST | `/networks` | Body: `name`, `driver`, `subnet`, `attachable`. |
| DELETE | `/networks/{id}` | Risky. `409` when containers are attached or it is a default network. |
| POST | `/networks/prune` | Risky. |

## Alerts

Screens: Alerts and rules, the badge and "Needs attention" on the overview.

The agent evaluates rules locally and sends a push notification through the push relay when one fires. The phone never has to be connected for an alert to go out.

| Method | Path | Purpose |
|---|---|---|
| GET | `/alerts?state=active\|resolved` | Severity, target, message, first seen, last seen. |
| POST | `/alerts/{id}/mute` | Body: `minutes`. |
| POST | `/alerts/{id}/resolve` | Manual close. |
| GET | `/alert-rules` | Built-in rules with their thresholds and on or off state. |
| PATCH | `/alert-rules/{id}` | Body: `enabled`, `threshold`, `window_seconds`. |

Built-in rules in the design: container exits unexpectedly, restart loop (3 or more in 10 min), CPU or memory above 90% for 5 min, agent unreachable for 2 min. The last one cannot be detected by the agent itself and needs the push relay to watch a heartbeat.

## Registries

Screen: Registry credentials.

| Method | Path | Purpose |
|---|---|---|
| GET | `/registries` | Host, username, status, token expiry. Never returns the secret. |
| POST | `/registries` | Body: `host`, `username`, `secret`. Stored encrypted on the agent. |
| PATCH | `/registries/{id}` | Replace the token or username. |
| POST | `/registries/{id}/test` | Try a login and report the result. |
| DELETE | `/registries/{id}` | |

## Agent settings and update

Screen: Server settings.

| Method | Path | Purpose |
|---|---|---|
| GET | `/settings` | `require_biometric_for_risky`, stacks directory, push relay status. |
| PATCH | `/settings` | Admin only. |
| GET | `/agent/update` | Current and latest version, release notes link. |
| POST | `/agent/update` | Download, verify signature, restart. Job. The app should expect the connection to drop and retry `/health`. |
| GET | `/jobs/{id}`, `/jobs/{id}/events` | Status and progress for every long operation above. |

## Open decisions

1. **Push delivery.** The agent needs a small relay service that holds the Firebase and APNs keys, because those must not be shipped inside every agent. The relay also provides the heartbeat for the "agent unreachable" rule.
2. **Reachability.** The design assumes the phone can reach `https://host:8443` directly. Servers behind NAT would need either a VPN or an outbound tunnel from the agent to the relay.
3. **"Read-only on this phone"** is a client-side switch in the design. If it should be tamper-proof, make it a device role change (`PATCH /devices/{id}`) instead.
4. **Docker socket access.** The agent needs the socket, which is root-equivalent. Run it as a dedicated user in the `docker` group, never expose the socket itself, and keep the endpoint list above as an allow-list rather than proxying the Docker API.

## Revision 1.1: decisions after both sides were built

The app engineer listed what the screens needed and the draft did not say. The backend engineer listed what the draft left open and what Docker cannot answer. This section settles both. Where it disagrees with text above, this section wins.

### Settled

| Topic | Decision |
|---|---|
| List responses | `{"items": [...], "next_cursor": "...", "total": n}`. `next_cursor` is absent on the last page. Cursors are opaque. `total` counts after filtering and before paging. |
| Extra statuses | `201` for creates and `/pair`, `204` for deletes, `413`, `415`, and `429` with `Retry-After` for rate limits. Error codes follow `<resource>_not_found`; the full list is in API_NOTES section 4. Unknown JSON fields are rejected with `400`. |
| Display strings | The agent returns raw values and timestamps only (`state`, `started_at`, `cpu_percent`, `memory_bytes`, `created_at`, `status_at`, `token_expiry`). The app formats "Up 12 days", "pulled 3 days ago" and "Verified 2 h ago" itself. |
| Container counts | `GET /system/stats` returns `running`, `restarting`, `paused`, `exited`, `created`, `total` as separate numbers. The app shows running + restarting as "running" on the Servers card and the Running chip, and names the restarting ones separately on the overview. |
| Roles | Viewer: every `GET` except environment values. Operator: adds container start, stop, restart, pause and unpause, stack up, redeploy and restart, image pull, service scale, update and rollback, alert mute and resolve. Admin only: remove, exec, environment values, stack down, every prune, image, volume and network create and remove, devices, registries, settings, alert rules, agent update. |
| Pairing | First device to pair is `admin`, later ones are `operator`. The last admin cannot be demoted or revoked (`409`). The response adds `device_id` and `agent_version`. |
| "Read-only on this phone" | Open decision 3 is closed: it is the `viewer` role, set with `PATCH /devices/{id}`. It is no longer a client-side switch. |
| Risky actions | With the setting on (default on), `428 confirmation_required` without `X-Confirmed: biometric` or `X-Confirmed: typed` for: container stop and remove, image remove and prune, volume remove and prune, network remove and prune, stack down, device revoke. Restart and pause are not covered. The audit record of a risky call records which method confirmed it. |
| Stop impact | `GET /containers/{id}/impact` returns `published_ports`, `dependents` (from compose `depends_on`, shared network namespace and links; best effort) and `same_stack` (other containers in the compose project). Each entry has id, name and state. |
| Stacks list | `GET /stacks` already carries a `services` array with `running` and `total` per service, so the segmented health bar needs no second call. Stacks found only through container labels have `config_on_disk: false`, and actions on them return `409`. |
| Swarm | `scale` is synchronous (`200`). `update` and `rollback` are jobs. |
| Logs | `GET /containers/{id}/logs` returns JSON lines `{ts, stream, line}`, the same shape as the SSE stream. Download is done by the app from those lines. |
| Exec | WebSocket on `GET /containers/{id}/exec?shell=&cols=&rows=`. Binary frames carry terminal bytes, text frames carry JSON control messages (`stdin`, `resize`, `ping`, and `exit` from the agent). Shell is one of bash, sh or ash. |
| Alerts | `severity` is `critical` or `warning`. `state` is `active`, `resolved` or `muted`. `target` is a display name and `target_id` is the container id, absent for host-level alerts. The alert id is `<rule_id>|<target_id>`. |
| Alert rules | Five rule ids: `unexpected_exit`, `restart_loop`, `cpu_high`, `memory_high`, `agent_unreachable`. The design shows CPU and memory as one row; the app may keep one row that patches both rules. `agent_unreachable` ships disabled with `evaluated_locally: false` until a push relay exists. |
| Registries | `status` is `unknown`, `ok` or `failed`, with `status_at`, `status_error` and `token_expiry`. The app derives the three looks in the design: ok (green), expiry within 7 days or failed (amber or red), no stored credential (neutral). |
| Activity log | Records are `{id, time, device_id, device_name, role, action, target, result, status, remote_ip, details}`. `action` is the route pattern and `result` is `ok`, `started`, `denied` or `error`. |
| Host figures | Host CPU and memory come from `/proc` on Linux. Elsewhere they are the sum over containers, flagged by `cpu_source` and `memory_source`. `/system` returns both `agent_uptime_seconds` and `host_uptime_seconds`. |
| Volumes | `last_used` is the latest start time of a container that mounts the volume, and is absent when none does. `size` is only known for the `local` driver. |
| Paired servers | The Servers screen is phone-local state (name, URL, pinned fingerprint, device key per server). No endpoint lists "my servers". |
| Agent update | `GET /agent/update` reports `latest_version: "unknown"`. `POST` returns a job that fails with `not_configured`. Nothing is downloaded or executed until a signed release channel exists. |
| Added endpoint | `GET /jobs`, a paginated list of retained jobs (newest 200, one hour), for an app that reconnects and lost a job id. |
| `GET /me` | Built. Any authenticated role gets `device_id`, `device_name`, `role`, `cert_fingerprint`, `paired_devices` and `agent_version`. The role is read fresh on every call, so one an admin changed later is noticed; the fingerprint is the same string `POST /pair` returns, and is empty under `--insecure-http`. It is a read and is not audited. |
| Volume and network summaries | Built. `summary` sits beside `items` as it does on `/images`, computed over the whole host after filtering and before paging: `{count, total_bytes, unmounted}` on `/volumes`, where `unmounted` means an empty `mounted_by`, and `{count, unused}` on `/networks`, where `unused` means `attached_containers == 0` and default networks are counted too. Both endpoints also accept `?q=`. |
| Container times | Rows carry `created_at`, `started_at` and, for a container that is not running, `finished_at`. "Exited · 12 min ago" is formatted from `finished_at`. |
| Image age | Docker records no pull time. `created_at` on an image is its build time, and the app labels it "created 3 days ago", not "pulled". |
| 428 ordering | The confirmation check runs before the target is looked up, so a risky call on an id that does not exist answers `428`, not `404`. A `428` never means the object exists. |
| Network "unused" | `summary.unused` counts every network with no attached containers, default networks included. Whether a row can be removed is a separate question: never for `is_default` networks. |
| Optional fields | Empty optional values are omitted rather than sent empty: `health`, `started_at`, `finished_at`, `last_used`, `next_cursor`, `target_id`. `release_notes_url` may be `null`. Clients treat absent, `null` and a zero time alike. |

### Still open

1. **Push relay** (open decision 1): alerts are evaluated and logged by the agent but not delivered to phones, and the "agent unreachable" rule stays disabled until something outside the host watches a heartbeat.
2. **Reachability behind NAT** (open decision 2): the app must reach `https://host:8443` directly.
3. **Agent self-update**: needs a signed release channel before `POST /agent/update` does anything.
4. **On-device checks for the app**: the biometric prompt, secure storage against a real Keystore or Keychain, the terminal's column and row maths with the on-screen keyboard, and any iOS build. None of these can be verified without a phone or simulator.
5. **macOS signing**: an unsigned debug build has no keychain access group, so pairing on the Mac stops with a clear "secure storage unavailable" message instead of storing the device key. Set `DEVELOPMENT_TEAM` in `app/macos/Runner/Configs/AppInfo.xcconfig` (or pick the team in Xcode, Signing & Capabilities) and add the `keychain-access-groups` array to `app/macos/Runner/DebugProfile.entitlements`. Release already has it. Then check pairing, Touch ID, and the pinned self-signed connection under the sandbox.
