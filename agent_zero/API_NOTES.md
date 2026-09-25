# API notes

Everything here is a place where `docs/agent-api.md` was silent, ambiguous, or
asked for something the Docker daemon cannot answer. For each one: what the
contract says, what this agent does, and why. `docs/agent-api.md` itself is
unchanged.

The mobile app can treat every "added" field as optional and ignore it.

---

## 1. List envelope

**Contract**: "`?limit=` and `?cursor=`; the response carries `next_cursor`
when there is more." The shape around `next_cursor` is not given.

**Here**: every list answers

```json
{ "items": [ ... ], "next_cursor": "bzo1MA", "total": 137 }
```

`next_cursor` is omitted when there is no further page. `total` is the number
of items after filtering, before paging, so the app can show "12 of 137".
`GET /v1/images` adds a `summary` object next to `items` (see §12), and so do
`GET /v1/volumes` and `GET /v1/networks` (see §34).

**Why**: the contract needs a place to hang `next_cursor`, and a bare JSON
array has none.

## 2. Cursors are opaque

**Contract**: silent on the cursor format.

**Here**: `cursor` is base64url of an internal position and must be echoed
back untouched. It is an offset for Docker-backed lists and a log sequence
number for `GET /v1/activity`. A malformed cursor is `422 validation_failed`.

## 3. Status codes beyond the contract's list

**Contract**: "a matching HTTP status (400, 401, 403, 404, 409, 422, 500, 502)",
plus `428` for the confirmation rule.

**Here**, additionally, always in the same error envelope:

| Status | Code | When |
|---|---|---|
| 201 | – | `POST /v1/pair`, `POST /v1/volumes`, `POST /v1/networks`, `POST /v1/registries` |
| 202 | – | every job endpoint, as the contract asks |
| 204 | – | every `DELETE` that succeeded |
| 413 | `payload_too_large` | request body over 1 MiB |
| 415 | `bad_request` | a body that is not `application/json` |
| 429 | `rate_limited` | `/v1/pair` and repeated failed authentication, with `Retry-After` |

**Why**: the contract asks for rate limiting on `/pair` but gives it no status;
429 is the only sensible one.

## 4. Error codes

**Contract**: gives `container_not_found` as the only example.

**Here**, the full set. 404s follow the `<resource>_not_found` pattern from the
example: `container_not_found`, `image_not_found`, `volume_not_found`,
`network_not_found`, `service_not_found`, `stack_not_found`,
`registry_not_found`, `alert_not_found`, `alert_rule_not_found`,
`device_not_found`, `job_not_found`, `system_not_found`, plus a plain
`not_found` for an unknown endpoint.

Others: `bad_request`, `unauthorized`, `forbidden`, `conflict`,
`validation_failed`, `internal_error`, `docker_unavailable` (502),
`not_a_manager` (409), `confirmation_required` (428), `rate_limited` (429),
`pairing_failed` (401), `not_configured`, `unsupported`, `payload_too_large`.

`error.details` is always present, as `{}` when there is nothing to add.
`validation_failed` carries `{"field": "<name>"}`.

## 5. Which role may call what

**Contract**: "`admin` can do everything, `operator` can start, stop, restart
and redeploy, `viewer` is read-only." That leaves most endpoints unassigned.

**Here** the server enforces:

- **viewer**: every `GET` except `/v1/containers/{id}/env`. That includes
  `GET /v1/me` (§33), which every authenticated role may call.
- **operator**: everything a viewer can do, plus container start, stop,
  restart, pause, unpause; stack up, redeploy, restart; image pull; service
  scale, update, rollback; alert mute and resolve.
- **admin**: everything, and *only* admin for: container remove, container
  exec, environment values, stack down, image remove, image prune, volume
  create, remove and prune, network create, remove and prune, every
  `/v1/devices` write, every `/v1/registries` write, `PATCH /v1/settings`,
  `PATCH /v1/alert-rules/{id}`, `POST /v1/agent/update`.

**Why**: the contract lists operator's abilities as "start, stop, restart and
redeploy", so anything destructive that is not one of those is admin.
"Read-only on this phone" (open decision 3) is therefore tamper-proof: make
the device a `viewer` with `PATCH /v1/devices/{id}`.

## 6. Pairing details

**Contract**: "`POST /pair`. Body: `token`, `device_name`, `push_token`.
Returns `device_key`, `role`, `cert_fingerprint`."

**Here**:

- Status is **201**, not 200.
- `push_token` is optional; `device_name` defaults to `phone`.
- The response adds `device_id` and `agent_version`.
- The **first** device to pair becomes `admin`; every later device is created
  as `operator` and can be changed with `PATCH /v1/devices/{id}`.
- The **last admin device cannot be demoted or revoked** — `409 conflict`.
  Without this an admin can lock the host out of its own agent through the
  API. Revoking your own device is still allowed ("Unpair this server") as
  long as another admin remains.
- `GET /v1/devices` never returns the key, the key hash, or the push token
  value; it returns `has_push_token` instead.

## 7. `agent_zero pair-token` uses a local control socket

**Contract**: not covered.

**Here**: pairing tokens live in the running process's memory, and the
embedded database is locked by that process, so a second `agent_zero` process
cannot mint one. The running agent therefore listens on
`<data-dir>/control.sock`, mode `0600`, and `agent_zero pair-token` asks it
for a token over that socket. If the agent is not running the command says so.

## 8. `/system` "uptime" is two numbers

**Contract**: "`GET /system`: Host name, Docker version, agent version,
uptime, CPU cores, memory and disk totals, Swarm role."

**Here**: `agent_uptime_seconds` (always) and `host_uptime_seconds` (read from
`/proc/uptime`; **0 on anything that is not Linux**, including a daemon inside
a VM such as Docker Desktop). "uptime" was ambiguous and both are cheap.

## 9. Host CPU and memory are not in the Docker API

**Contract**: "`GET /system/stats`: Current CPU %, memory used, disk used,
container counts by state."

**Here**: the Docker API exposes host *totals* but no host *utilisation*. So:

- On Linux the agent reads `/proc/stat` and `/proc/meminfo`.
- Everywhere else it falls back to the sum of running containers' CPU and
  memory, with CPU divided by the core count.

The response carries `cpu_source` and `memory_source`, each `"host"` or
`"containers"`, so the app can label an approximation honestly. Nothing else
in the shape changes.

## 10. Disk totals

`disk_total` and `disk_used` come from `statfs` on Docker's root directory.
When that path does not exist on the machine running the agent — again, a
VM-backed daemon — the agent falls back to `statfs` on `/` and reports the
agent's own filesystem. `GET /v1/images` still reports Docker's own usage
exactly, from `/system/df`.

## 11. Per-row CPU and memory in `GET /v1/containers`

**Contract**: "Each item carries name, image, state, health, uptime, CPU %,
memory, restart count."

**Here**: a truthful CPU percentage needs two samples per container, so the
agent fills CPU and memory **only for the rows on the page actually returned**
and only for running containers. Non-running rows report zero. With the
default `limit=50` this costs about a second on a busy host; use a smaller
`limit` on the list screen if that matters.

## 12. `GET /v1/images` summary

**Contract**: "Summary block with total and reclaimable bytes."

**Here**: `summary` sits beside `items`:

```json
{ "items": [...], "next_cursor": "", "total": 42,
  "summary": { "count": 42, "total_bytes": 1234, "reclaimable_bytes": 567 } }
```

`in_use_by` holds container **names**, matched on both image id and image tag.

## 13. `GET /v1/containers/{id}/impact` is best effort

**Contract**: "What the confirm sheet shows before a stop: published ports and
containers that depend on this one."

**Here**: Docker keeps no runtime dependency graph. The agent reports:

- `published_ports`: exact.
- `dependents`: derived from the `com.docker.compose.depends_on` label and
  from containers sharing this one's network namespace or linking to it.
  Accurate when present, but a plain `docker run` dependency is invisible.
- `same_stack`: every other container in the same Compose project, which is
  what the confirm sheet can usefully show when `dependents` is empty.

## 14. Log fetch shape

**Contract**: "`GET /containers/{id}/logs`. Plain fetch, also used for
download."

**Here**: the response is JSON, `{"container_id": ..., "lines": [{"ts",
"stream", "line"}], "count": n}` — not `text/plain` — so the app parses one
format for both the fetch and the SSE stream. There is no separate download
endpoint; the app formats the lines it already has.

`?q=` is a case-insensitive substring filter applied to the line text after
retrieval. `?tail=` is capped at 10000 and defaults to 200 (100 when
following).

## 15. The exec WebSocket

**Contract**: "`WS /containers/{id}/exec`. Interactive shell. Admin only,
session is audited."

**Here**:

- Registered as `GET /v1/containers/{id}/exec`, because a WebSocket handshake
  *is* an HTTP GET. Same URL.
- Query parameters: `shell` (only `/bin/bash`, `/bin/sh` or `/bin/ash`),
  `cols` (10–500, default 80), `rows` (5–200, default 24).
- With no `shell`, the agent runs one fixed, compile-time command —
  `/bin/sh -c 'if command -v bash …; then exec bash; else exec sh; fi'` — so
  an image with bash gets bash and an alpine image gets its own `sh`. Docker
  accepts an exec for a binary that does not exist and only fails when it
  starts it, so the agent also checks 200 ms later whether the process died
  with 126 or 127 and falls back to `/bin/ash`, `/bin/bash` and
  `/bin/busybox sh` in turn. An explicit `shell` is used as given, and its
  failure is reported rather than worked around.
- Frames: **binary** frames are raw bytes in both directions — terminal input
  up, terminal output down. **Text** frames are JSON control messages from the
  app: `{"type":"stdin","data":"..."}`, `{"type":"resize","cols":N,"rows":N}`,
  `{"type":"ping"}`. On exit the agent sends one text frame
  `{"type":"exit","code":N}` and closes.
- A TTY is always allocated, the container must be running (`409` otherwise),
  and a session is capped at 4 hours.
- Two audit records are written: one when the session starts, one when it ends
  with its duration.

**Why the shell allow-list**: an arbitrary command would make the audit record
useless and the endpoint harder to reason about. It is still remote code
execution by design, which is why it is admin only and always audited.

## 16. Compose stacks

**Contract**: "Compose projects found under the agent's configured stacks
directory."

**Here**: discovery reads **both** the stacks directory (one level deep, any
of `compose.yaml`, `compose.yml`, `docker-compose.yaml`,
`docker-compose.yml`) **and** the `com.docker.compose.project` labels on
running containers, then merges them by project name. Each stack reports
`source` (`directory` or `labels`) and `config_on_disk`.

A stack action on a project with `config_on_disk: false` returns
`409 conflict`: the agent has nothing to run `docker compose` against.

`docker compose` is always invoked as an argument list with `--project-name`,
`--file` and `--project-directory` — never through a shell, and no value from
the API is ever used as a flag. The only thing the API supplies is the project
name, which must match a project discovery already found and must match
`^[a-z0-9][a-z0-9_-]{0,62}$`.

## 17. `GET /v1/swarm` answers on a non-manager

**Contract**: "Swarm services. All of these return `409 not_a_manager` when
the host is not a Swarm manager" — under a heading that includes `/swarm`.

**Here**: `GET /v1/swarm` returns **200** with
`{"active": false, "node_role": "inactive"|"worker", "is_manager": false,
"nodes": []}`. Only `/v1/services`, `/v1/services/{id}/tasks`, and the three
service writes return `409 not_a_manager`.

**Why**: the Swarm screen needs to tell "this host is not in a swarm" apart
from "the agent is broken", and a 409 on the one endpoint that reports the
node's own role makes that impossible.

## 18. Which Swarm calls are jobs

**Contract**: marks `update` and `rollback` as jobs, and says nothing about
`scale`.

**Here**: `POST /v1/services/{id}/scale` is synchronous and returns 200;
`update` and `rollback` return 202 with a job. Scaling is one API call, a
rolling update is not.

## 19. Prune bodies and defaults

- `POST /v1/images/prune` takes `{"dangling_only": bool}`, **defaulting to
  true**, and an empty body is accepted.
- `POST /v1/volumes/prune` and `POST /v1/networks/prune` take no body. The
  contract marks the network prune risky but does not say it is a job; it is
  one here, for the same shape as the other two.

## 20. `DELETE /v1/networks/{id}` pre-checks

The contract asks for `409` when containers are attached or the network is a
default one. The agent checks both itself before calling Docker, so the
message and `details` are useful (`{"network": "...", "attached_containers":
3}`) rather than a passed-through daemon string.

## 21. Volume "last used"

**Contract**: "`GET /volumes`: Name, driver, size, `mounted_by`, last used."

**Here**: Docker records no last-used time for a volume. `last_used` is the
most recent start time among containers that mount it, and is **absent** when
no container mounts it. `size` is only reported by the `local` driver; others
report 0.

## 22. Alert identifiers and the built-in rules

- An alert id is `<rule_id>|<target_id>`, so the same problem on the same
  container keeps one identity across agent restarts, and `first_seen`,
  `last_seen` and `count` accumulate.
- Rule ids are `unexpected_exit`, `restart_loop`, `cpu_high`, `memory_high`,
  `agent_unreachable`. The contract describes "CPU or memory above 90% for 5
  min" as one rule; it is **two** here, so each threshold can be tuned
  separately. Both default to 90% over 300s.
- `restart_loop` defaults to 3 restarts in 600s, counted from restart-count
  deltas observed by the evaluator, so restarts spread wider than the window
  do not fire it.
- `cpu_high` and `memory_high` fire only after the value has stayed above the
  threshold for the whole window, and resolve as soon as it drops.
- Every rule carries `evaluated_locally`.

## 23. "Agent unreachable" cannot be evaluated by the agent

**Contract**: "agent unreachable for 2 min. The last one cannot be detected by
the agent itself and needs the push relay to watch a heartbeat."

**Here**: this is stated explicitly and repeated in the API. The rule exists
so the screen can show it, but it ships **disabled**, with
`"evaluated_locally": false` and a description saying why. **The agent never
fires it.** An agent that is down cannot report that it is down; only
something outside the host can, and that something is the push relay in open
decision 1, which is not part of this service.

## 24. Push delivery is a seam, not an implementation

**Contract**: "The agent evaluates rules locally and sends a push notification
through the push relay when one fires."

**Here**: rule evaluation is real. Delivery is the `alerts.Notifier`
interface, and the only implementation shipped is `LogNotifier`, which writes
the alert to the agent log. `GET /v1/settings` therefore always reports
`"push_relay_status": "not_configured"`. A relay client implements `Notifier`
and is passed to the evaluator; nothing else changes.

## 25. `/v1/settings`

**Contract**: "`require_biometric_for_risky`, stacks directory, push relay
status."

**Here**: `GET` returns exactly those three plus an optional
`push_relay_url`. `PATCH` accepts `require_biometric_for_risky` and
`stacks_dir` (must be an absolute path to an existing directory).

**`require_biometric_for_risky` defaults to `true`** on a fresh install. The
contract does not give a default and the safe one is on.

## 26. Which calls the confirmation rule covers

**Contract**: "stop, remove, prune, stack down and unpair accept an
`X-Confirmed: biometric` header."

**Here**, when the setting is on, `428 confirmation_required` is returned
without an accepted header (see §37 for which values are accepted) for:
`POST /v1/containers/{id}/stop`,
`DELETE /v1/containers/{id}`, `DELETE /v1/images/{id}`,
`POST /v1/images/prune`, `DELETE /v1/volumes/{name}`,
`POST /v1/volumes/prune`, `DELETE /v1/networks/{id}`,
`POST /v1/networks/prune`, `POST /v1/stacks/{name}/down`,
`DELETE /v1/devices/{id}`.

Restart and pause are **not** covered: the contract does not list them, and
they are reversible.

## 27. Agent update does nothing

**Contract**: "`POST /agent/update`: Download, verify signature, restart."

**Here**: `GET /v1/agent/update` reports the running version, `latest_version:
"unknown"` and `self_update_status: "not_configured"`. `POST` returns a job
that immediately fails with `not_configured`. **The agent never downloads or
executes anything.** A self-updater needs a signed release channel and a
verified public key; inventing one would be the single most dangerous piece of
code in a service that already holds the Docker socket.

## 28. `GET /v1/jobs`

Added, not in the contract: a paginated list of retained jobs. Read-only, and
useful when the app reconnects and has lost a job id. Jobs are kept in memory:
the newest 200, for one hour.

## 29. Rate limiting and client addresses

- `POST /v1/pair`: 5 attempts per IP, refilling one every 30 seconds.
- Failed authentication: 20 per IP, refilling one every 3 seconds. Successful
  calls are not charged.
- `X-Forwarded-For` and friends are **deliberately ignored**; the peer address
  is used. The app reaches the agent directly, and honouring a proxy header
  would let any caller forge an address and walk past the limiter.

## 30. TLS and pinning

- With no `--tls-cert`, the agent generates a self-signed **ECDSA P-256**
  certificate into the data dir on first start, valid for ten years, and
  prints its SHA-256 fingerprint in `AA:BB:...` form. That is the string the
  app pins and the one `POST /v1/pair` returns as `cert_fingerprint`.
- Existing files are never regenerated, because that would break every paired
  phone.
- `--tls-cert` / `--tls-key` use a real certificate; then `cert_fingerprint`
  is that certificate's.
- `--insecure-http` serves plain HTTP for local development and logs a loud
  warning on every start. Device keys travel in clear text; never use it on a
  reachable host.

## 31. Request hygiene

- Bodies are capped at 1 MiB.
- Unknown JSON fields are rejected with `400 bad_request`, so an app typo
  fails loudly instead of silently doing nothing.
- A body must hold exactly one JSON document.
- `ReadHeaderTimeout` 10s, `ReadTimeout` 60s, `IdleTimeout` 120s. The
  server-wide write timeout is off and streaming handlers clear their own
  deadlines, which is what lets SSE and the exec WebSocket stay open.

## 32. Audit log shape

`GET /v1/activity` returns records of
`{id, time, device_id, device_name, role, action, target, result, status,
remote_ip, details}`. `action` is the matched **route pattern**
(`POST /v1/containers/{id}/stop`), never the raw path, so identifiers stay in
`target` and the log groups cleanly. `result` is one of `ok`, `started`
(a job was queued, or an exec session opened), `denied` (role or confirmation
refused) or `error`. Refused calls are audited too. The log is capped at
20000 records.

## 33. `GET /v1/me`

**Contract**: Revision 1.1, still open 1. Server settings shows the caller's
role, the pinned fingerprint and the number of paired phones, and a role an
admin changed later was never noticed by the phone that holds it.

**Here**: any authenticated role may call it and gets

```json
{ "device_id": "c5e2f5cfeb780d9bb9d4332f", "device_name": "Pixel 8",
  "role": "admin", "cert_fingerprint": "3D:9A:0C:...:7F",
  "paired_devices": 3, "agent_version": "1.0.0" }
```

- `role` is read from the database on every call, through the same lookup that
  authenticates the request, so a `PATCH /v1/devices/{id}` by an admin is
  visible to the affected phone on its next call.
- `cert_fingerprint` is **the same string `POST /v1/pair` returns**, so the app
  can compare it against the pin it stored. It is the empty string when the
  agent runs with `--insecure-http`, because then there is no certificate.
- `paired_devices` counts every device that is not revoked, the same set
  `GET /v1/devices` lists.
- It is a read: no audit record is written, and `agent_version` is added so a
  phone that paired against an older agent notices an upgrade.

## 34. `GET /v1/volumes` and `GET /v1/networks` summaries

**Contract**: Revision 1.1, still open 2. The screens show
"9 volumes · 46 GB · 2 not mounted" and "7 networks · 2 unused" above a paged
list.

**Here**: `summary` sits beside `items`, exactly as on `GET /v1/images`, and is
computed over the **whole host after filtering and before paging** — it is the
figure for the header line, never for the page:

```json
{ "items": [...], "total": 9,
  "summary": { "count": 9, "total_bytes": 49392123904, "unmounted": 2 } }

{ "items": [...], "total": 7,
  "summary": { "count": 7, "unused": 2 } }
```

- Volumes: `unmounted` counts volumes whose `mounted_by` is empty.
  `total_bytes` sums the sizes that are known, which per §21 means the `local`
  driver; other drivers report 0 and add nothing.
- Networks: `unused` counts networks with `attached_containers == 0`, and
  **default networks are counted like any other**, because the screen shows
  every network in the list.
- Both endpoints now also accept `?q=`, a case-insensitive substring match on
  the name (a network also matches on an id prefix), so the filter and the
  summary agree with each other.

## 35. `GET /v1/stacks` carries the per-service counts

**Contract**: Revision 1.1 settled, "Stacks list": the list already carries a
`services` array with `running` and `total` per service, so the segmented
health bar needs no second call.

**Here**: it does now. Each list row has `services`, an array of
`{"name", "running", "total"}`, beside the aggregate `services_running` and
`services_total` it already had. Containers are not repeated in the list —
`GET /v1/stacks/{name}` is still the call for those.

## 36. Open decisions in the contract

1. **Push delivery** — out of scope, see §24.
2. **Reachability** — unchanged: the agent listens on `:8443` and expects to
   be reached directly. No tunnel or relay client is implemented.
3. **"Read-only on this phone"** — implemented as a real server-side role.
   `PATCH /v1/devices/{id}` with `{"role": "viewer"}`, see §5.
4. **Docker socket access** — followed exactly. The agent talks to the socket,
   the endpoint list in this API is a closed allow-list (`internal/dockerx`'s
   `Client` interface is the only way to reach Docker), the raw Docker API is
   never proxied, and the shipped systemd unit runs a dedicated user in the
   `docker` group with the socket never exposed.

## 37. Confirmation methods, and the method in the audit record

**Contract**: "an `X-Confirmed: biometric` header."

**Here**: `X-Confirmed` accepts **`biometric`** or **`typed`**, and nothing
else. `typed` exists for the macOS app: many Macs have no Touch ID, so there
the user types the target's name instead, which is the same deliberate act by
the person at the keyboard. The phone still sends `biometric`.

- Matching ignores case and surrounding whitespace: `  TYPED ` is accepted.
- Any other value, an empty value, and **more than one `X-Confirmed` header**
  are all refused. Two header lines are not merged into one accepted value.
- The `428` body names both, so a client can discover what it may send:

```json
{ "error": { "code": "confirmation_required",
             "message": "this action needs a biometric or typed confirmation",
             "details": { "header": "X-Confirmed",
                          "accepted": ["biometric", "typed"] } } }
```

- Every risky call that goes through carries `"confirmation"` in its audit
  record's `details` (§32): `"biometric"`, `"typed"`, or `"none"` when
  `require_biometric_for_risky` is off and no accepted header was sent. The
  record's top-level shape is unchanged.
- A refused call is still audited as `denied` with status `428`, as before,
  and carries no `confirmation` detail: nothing confirmed it.

Which endpoints the rule covers (§26), the setting's name and its default
(§25) are unchanged.
