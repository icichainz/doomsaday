# agent_zero

The agent that runs on a Docker host and serves the REST API in
`docs/agent-api.md` to the mobile app. One Go binary, no runtime dependencies
beyond the Docker socket and, for Compose stacks, the `docker` CLI.

It holds the Docker socket, which is root-equivalent on the host. Everything
below follows from that: the API is a closed allow-list, TLS is on by default,
device keys are hashed, secrets are encrypted, and every mutating call is
written to an audit log.

- **Contract**: `docs/agent-api.md` (not edited by this service).
- **Deviations and gaps**: [`API_NOTES.md`](API_NOTES.md). Read it before
  writing a client.

---

## Build

Go 1.25.4, no cgo.

```sh
make build                 # -> bin/agent_zero
make check                 # gofmt -l, go vet, go test ./... -race
make docker                # multi-stage image
```

Or directly:

```sh
go build -trimpath -ldflags "-s -w -X agent_zero/internal/version.Version=1.0.0" \
  -o bin/agent_zero ./cmd/agent_zero
```

## Run

```
agent_zero [serve] [flags]   run the agent (serve is the default)
agent_zero pair-token        ask the running agent for a pairing token
agent_zero version           print the version
```

| Flag | Environment variable | Default | Meaning |
|---|---|---|---|
| `--listen` | `AGENT_ZERO_LISTEN` | `:8443` | listen address |
| `--data-dir` | `AGENT_ZERO_DATA_DIR` | `/var/lib/agent_zero` | database, keys, certificate |
| `--stacks-dir` | `AGENT_ZERO_STACKS_DIR` | `/opt/stacks` | where Compose projects are looked for |
| `--docker-host` | `AGENT_ZERO_DOCKER_HOST` | environment default | e.g. `unix:///var/run/docker.sock` |
| `--docker-bin` | `AGENT_ZERO_DOCKER_BIN` | `docker` | CLI used for `docker compose` |
| `--tls-cert` | `AGENT_ZERO_TLS_CERT` | – | PEM certificate; self-signed generated when empty |
| `--tls-key` | `AGENT_ZERO_TLS_KEY` | – | PEM private key |
| `--insecure-http` | `AGENT_ZERO_INSECURE_HTTP` | `false` | plain HTTP, **development only** |
| `--log-level` | `AGENT_ZERO_LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |

Two more, for tuning: `AGENT_ZERO_PAIR_TOKEN_TTL` (default `15m`) and
`AGENT_ZERO_ALERTS_PERIOD` (default `15s`).

Flags beat environment variables; both beat the defaults.

### The data directory

Mode `0700`, holding:

| File | What |
|---|---|
| `agent_zero.db` | bbolt: devices, settings, registries, alert state, audit log |
| `secret.key` | 32 random bytes, mode `0600`, the AES-GCM key for registry secrets |
| `agent-cert.pem`, `agent-key.pem` | the generated self-signed certificate (key mode `0600`) |
| `control.sock` | local socket, mode `0600`, used only by `agent_zero pair-token` |

Keep a shortish path: `control.sock` is a unix socket and its full path has to
fit in about 100 bytes. The agent says so plainly if it does not.

### Local development

```sh
make run-dev      # plain HTTP on :8443, data in ./.devdata, debug logging
```

`--insecure-http` logs a loud warning on every start. Device keys travel in
clear text over it; never point a phone at it across a network.

### systemd

`deploy/agent_zero.service` runs a dedicated user in the `docker` group with
the usual hardening (`ProtectSystem=strict`, no capabilities, a
`SystemCallFilter`, a `StateDirectory`):

```sh
useradd --system --no-create-home --shell /usr/sbin/nologin agentzero
usermod -aG docker agentzero
install -m 0755 bin/agent_zero /usr/local/bin/agent_zero
install -m 0644 deploy/agent_zero.service /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now agent_zero
journalctl -u agent_zero -f      # the first-start pairing token is printed here
```

### Docker

The image carries the `docker` CLI so Compose stacks work. It needs the socket
and the host's `docker` group id:

```sh
docker run -d --name agent_zero \
  -p 8443:8443 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v agent_zero_data:/var/lib/agent_zero \
  -v /opt/stacks:/opt/stacks \
  --group-add "$(getent group docker | cut -d: -f3)" \
  agent_zero:latest
```

---

## Pairing walkthrough

On first start, with no device paired, the agent prints a one-time token and
the certificate fingerprint the app pins:

```
Certificate SHA-256 fingerprint (the app pins this):
  3D:9A:0C:...:7F

No device is paired yet. One-time pairing token:
  RFUS-N3EN-5KLF-E2GY-HJJV-C3AL
Valid until 2026-09-19T17:02:53+02:00
```

For a later device, ask the running agent (same user, same data dir):

```sh
$ agent_zero pair-token --data-dir /var/lib/agent_zero
Pairing token: I3AV-CZSB-K5IG-ZJYO-3KDV-C7T7
Valid until:   2026-09-19T17:17:53+02:00
It can be used once.
```

Exchange it for a device key. `--cacert` or `-k` is needed because the
certificate is self-signed; a real client pins the fingerprint above instead.

```sh
$ HOST=https://192.0.2.10:8443

$ curl -sk $HOST/v1/health
{"ok":true}

$ curl -sk -X POST $HOST/v1/pair \
    -H 'Content-Type: application/json' \
    -d '{"token":"RFUS-N3EN-5KLF-E2GY-HJJV-C3AL","device_name":"Pixel 8","push_token":""}'
{"device_key":"3E1_YIrY_rOCrjpPm7otSbP8fCK259wACGnJ41Jko1o",
 "device_id":"c5e2f5cfeb780d9bb9d4332f","role":"admin",
 "cert_fingerprint":"3D:9A:0C:...:7F","agent_version":"1.0.0"}
```

The **first** device to pair is `admin`; later ones are `operator`. The token
is burnt on use — a replay gets `401 pairing_failed`.

Then everything else carries the key:

```sh
$ KEY=3E1_YIrY_rOCrjpPm7otSbP8fCK259wACGnJ41Jko1o
$ AUTH="Authorization: Bearer $KEY"

$ curl -sk $HOST/v1/me -H "$AUTH"
{"device_id":"c5e2f5cfeb780d9bb9d4332f","device_name":"Pixel 8","role":"admin",
 "cert_fingerprint":"3D:9A:0C:...:7F","paired_devices":3,"agent_version":"1.0.0"}

$ curl -sk $HOST/v1/system -H "$AUTH"
{"hostname":"web-01","docker_version":"29.0.1","agent_version":"1.0.0",
 "cpu_cores":12,"memory_total":8217165824,"disk_total":994662584320,
 "swarm_role":"inactive","agent_uptime_seconds":53, ...}

$ curl -sk "$HOST/v1/containers?state=running&limit=20" -H "$AUTH"
{"items":[{"id":"bcde58e7...","name":"web","image":"nginx:alpine",
           "state":"running","health":"healthy","cpu_percent":0.14,
           "memory_usage":712704,"restart_count":0,"uptime_seconds":4210}],
 "next_cursor":"bzoyMA","total":31}

$ curl -sk -X POST "$HOST/v1/containers/$ID/restart?timeout=10" -H "$AUTH"
{"ok":true,"container_id":"bcde58e7...","action":"restart"}
```

Risky calls need the confirmation header once
`require_biometric_for_risky` is on (it is, by default):

```sh
$ curl -sk -X POST "$HOST/v1/containers/$ID/stop?timeout=10" -H "$AUTH"
{"error":{"code":"confirmation_required","message":"this action needs a biometric or typed confirmation",
          "details":{"header":"X-Confirmed","accepted":["biometric","typed"]}}}

$ curl -sk -X POST "$HOST/v1/containers/$ID/stop?timeout=10" \
    -H "$AUTH" -H 'X-Confirmed: biometric'
{"ok":true,"container_id":"bcde58e7...","action":"stop"}
```

`X-Confirmed: typed` is the other accepted value, for a desktop client that
had the user type the target's name instead of taking a fingerprint. Either
way, the method is written to the audit record as `details.confirmation`.

Streams are Server-Sent Events:

```sh
$ curl -skN "$HOST/v1/containers/$ID/logs/stream?tail=20" -H "$AUTH"
id: 1
event: log
data: {"line":"listening on :80","stream":"stdout","ts":"2026-09-19T16:37:58.331Z"}

$ curl -skN "$HOST/v1/system/stats/stream" -H "$AUTH"
$ curl -skN "$HOST/v1/events/stream" -H "$AUTH"
```

Long operations answer `202` with a job, followed on `/v1/jobs/{id}` or
`/v1/jobs/{id}/events`:

```sh
$ curl -sk -X POST $HOST/v1/images/pull -H "$AUTH" \
    -H 'Content-Type: application/json' -d '{"ref":"nginx:alpine"}'
{"job_id":"caa0983e5064fd730c7f36c7","job":{"status":"queued", ...}}

$ curl -skN "$HOST/v1/jobs/caa0983e5064fd730c7f36c7/events" -H "$AUTH"
event: progress
data: {"ts":"...","text":"a2abf6c4d29d: Pulling fs layer","percent":-1}
event: done
data: {"status":"succeeded","result":{"ref":"nginx:alpine","layers":6}, ...}
```

Making a phone read-only is a server-side role change, not a client toggle:

```sh
$ curl -sk -X PATCH $HOST/v1/devices/$DEVICE_ID -H "$AUTH" \
    -H 'Content-Type: application/json' -d '{"role":"viewer"}'
```

The phone that holds that key sees the new role on its next `GET /v1/me`.

Unpair a phone (risky, so it takes the header too):

```sh
$ curl -sk -X DELETE $HOST/v1/devices/$DEVICE_ID -H "$AUTH" -H 'X-Confirmed: biometric'
```

---

## Security model

**The threat.** The agent can do anything to the host, because the Docker
socket can. So the interesting question is not "what can the agent do" but
"what can a caller make it do".

**Allow-list, never a proxy.** The router registers exactly the endpoints in
the contract and nothing else; anything else is `404`. The only route to
Docker is the `dockerx.Client` interface, a closed list of operations. There is
no passthrough, no `/docker/*`, no way to reach an endpoint the contract does
not name.

**Transport.** HTTPS by default. With no certificate supplied, a self-signed
ECDSA P-256 certificate is generated into the data dir on first start and its
SHA-256 fingerprint printed; the app pins that, and `POST /v1/pair` returns
it so the pin can be checked at pairing time. Existing certificate files are
never regenerated, because that would break every paired phone. TLS 1.2 is the
floor. `--insecure-http` exists for local development and shouts about itself.

**Pairing and device keys.** A pairing token is 120 bits of `crypto/rand`,
lives for 15 minutes, works once, and is compared in constant time against
every live token. It buys a device key of 256 bits of `crypto/rand`. **The key
is never stored**: the database holds SHA-256 of it, lookups go through that
hash, and the comparison is `crypto/subtle`. No endpoint ever returns a key, a
key hash or a push token value. Revoking a device deletes both the device and
its key index.

**Roles.** Enforced server-side on every request, not by hiding buttons —
`admin` / `operator` / `viewer`, mapped per endpoint in
[API_NOTES §5](API_NOTES.md#5-which-role-may-call-what). Environment variable
*values* and the exec shell are admin-only and always audited. The last admin
device cannot be demoted or revoked, so the API cannot lock the host out of
itself.

**Rate limiting.** Per client IP: 5 pairing attempts refilling one per 30s, 20
failed authentications refilling one per 3s. Proxy headers are ignored on
purpose — the peer address is the only thing a caller cannot forge.

**Confirmation.** With `require_biometric_for_risky` on (the default), stop,
remove, prune, stack down and unpair need `X-Confirmed: biometric` or
`X-Confirmed: typed` and return `428` without it, before anything reaches
Docker. Which method confirmed the call is recorded in the audit record.

**Secrets at rest.** Registry secrets are sealed with AES-256-GCM, with the
registry id as additional authenticated data so a ciphertext cannot be moved
between records. The key is 32 random bytes in `secret.key`, mode `0600`, and
the agent refuses to start if that file is group or world readable. No
endpoint returns a secret, sealed or otherwise; the decrypted value goes to
one place only — the Docker client, for a login or a pull. Tests assert it is
absent from the API, the database and the log.

**Input.** Every identifier, name, image reference, subnet, driver, timeout,
limit and cursor is validated against a bounded pattern before use. Bodies are
capped at 1 MiB, must be JSON, must hold one document, and unknown fields are
rejected. Server timeouts are set, with streaming handlers clearing their own
write deadline so SSE and the exec WebSocket are not cut off.

**Compose.** `docker compose` is executed as an argument list, never through a
shell. No API value is ever used as a flag or a path: the caller supplies only
a project name, which must match `^[a-z0-9][a-z0-9_-]{0,62}$` *and* match a
project discovery already found on the host.

**Audit.** Every mutating call, and every call refused for role or missing
confirmation, is written with device, role, action, target, result, status,
time and peer address. Exec sessions get two records, one at each end. The
action recorded is the route pattern, so identifiers stay in `target`.

**What it deliberately will not do.** It does not download or execute an
update (`POST /v1/agent/update` fails with `not_configured`), does not ship
push credentials, does not accept an arbitrary exec command, and does not
proxy the Docker API.

---

## Layout

```
cmd/agent_zero/         main: flags, wiring, signals, subcommands
internal/
  config/               flags + AGENT_ZERO_* environment, validation
  store/                bbolt: JSON documents, an append-only log, transactions
  auth/                 pairing tokens, device keys, roles, per-IP rate limiting
  audit/                the activity log
  registry/             registry credentials, AES-GCM sealing, the key file
  settings/             the Server settings screen's state
  dockerx/              the narrow Docker interface + the real client
    fakedocker/         the in-memory fake the tests run against
  compose/              project discovery and `docker compose` execution
  jobs/                 the in-memory job manager behind every 202
  alerts/               rule storage, the evaluator loop, the Notifier seam
  sse/                  Server-Sent Events framing
  tlsx/                 self-signed certificate generation and fingerprints
  control/              the local socket behind `agent_zero pair-token`
  httpapi/              router, middleware, handlers per resource
  version/
deploy/agent_zero.service
```

Handlers depend on interfaces (`dockerx.Client`, `audit.Logger`,
`alerts.Notifier`), so the whole API is exercised in tests against
`fakedocker` with no daemon running.

## Tests

```sh
make check        # gofmt -l, go vet ./..., go test ./... -race
```

Covers pairing (single use, expiry, bad keys, rate limiting), role
enforcement, the 428 rule, the error envelope shape, pagination, container
actions, the job lifecycle and SSE framing, registry secrets never leaking,
alert rule evaluation over a simulated clock, and input validation.
