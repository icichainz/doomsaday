# Phone screens that existed in the app but had no board

Seven phone boards, 390×844, each with a `Light` twin made with the README's dark→light table. All of them are pushed screens or sheets below 600 px; from 600 up the sheets become centred dialogs (`showAdaptiveModal`) and the pages are capped at about 720 px, as every screen without its own desktop board. At 1100 and up the Shell is the Shell tab of the containers split view (D2), which reuses the same terminal view without the key row.

| File | Screen | Reached from |
|---|---|---|
| Shell | Container shell, connected | Container detail: Shell (admin only, running containers only) |
| Devices | Paired devices | Server settings: Paired devices |
| DeviceActions | Role and revoke sheet over Devices | Devices: a row's more button (or right-click / long-press) |
| Activity | Activity log | Server settings: Activity log |
| PairConfirm | Certificate check sheet over Pair | Pair: "Test connection and pair" succeeded |
| PairError | Pair screen with a failure | Pair: "Test connection and pair" failed |
| ContainerDetailEnv | Environment and volumes sheet over Container detail | Container detail: Environment or Volumes row |

## Shell

- Back link "api-gateway" (the container name), title "Shell" 30 px with the session pill on the title line, mono subtitle `4f2a9c1e7b3d · prod-eu-1`. Side padding 16, like Logs, so the terminal gets the width.
- Pill: `Connecting` (warning), `Connected` (accent), `Exited 0` (neutral, any exit code), `Disconnected` (neutral, the socket closed without an exit frame), `Failed` (danger, the error view replaces the terminal). All with the leading dot.
- Terminal surface: log-area style, `#0A0F11` fill, `#1E282D` border, radius 16, padding 12, IBM Plex Mono 12.5 on 1.5 lines, `#C9D6DB`, selectable. Raw shell output only: no colouring of the prompt, no drawn cursor, no banner (ANSI is stripped).
- Note row, 12 px muted with a shield: "Admin only. Opening and closing it is in the Activity log."
- Key row (below 1100 only; a physical keyboard has these keys): five equal 44 px keys, radius 12, surface fill, border `#243036`, mono 13. Tab (sends the typed text plus a tab, for completion), Ctrl+C (`\x03`), ↑ (`ESC [A`), ↓ (`ESC [B`), Esc.
- Input row, 44 px: mono field with an accent `$`, placeholder "Type a command", border `#2A363C`; accent "Send" button with a return glyph. Return in the field sends too.
- Exited state (not drawn): the key row and input row are replaced by "The shell exited with code 0." and an outline "Open again" button; "The session ended." for Disconnected.

## Devices and DeviceActions

- Header "Paired devices", subtitle "3 devices hold a key for prod-eu-1".
- One card, rows 66 px (Containers row style, no icon tile): name 15/600; second line 13 muted "Last seen 1 day ago · push on"; this device leads with an accent "This device · " and continues "last seen just now". Role pill: Admin accent, Operator and Viewer neutral. 44 px more button (vertical dots) labelled "Actions for <name>", admins only; viewers and operators see the list without it.
- Below: the info note on the pairing roles and the last-admin rule.
- DeviceActions is a bottom sheet (ConfirmStop geometry: radius 28 top, handle, padding 12/20/28): 48 px tile with a phone glyph, the device name 24 px, its meta line. "ROLE" caption and a radio group (rows 58 px, 20 px radio, label 15/600, one-line summary 12 muted):
  - Admin: "Everything, including shell, environment values and devices"
  - Operator: "Start, stop, restart, pull and redeploy"
  - Viewer: "Read only"
  Choosing a role closes the sheet and sends `PATCH /v1/devices/{id}`. Buttons: "Close" (outline) and "Revoke device" (danger outline), which opens the usual risky confirm (`DELETE /v1/devices/{id}`, fingerprint if the agent asks).
- Last-admin rule (the drawn case, since prod-eu-1 has one admin): the other roles are dimmed to 45 %, "Revoke device" is disabled, and a warning card says "The only admin on prod-eu-1 — The agent refuses to demote or revoke the last admin (409). Make another device admin first." If a `409` still comes back (another admin was demoted meanwhile) the agent's message is shown as a danger toast.

## Activity

- Header "Activity log", subtitle "Who did what on prod-eu-1, and when".
- Filter field "Filter by container, device or action" (matches the sentence, the device, the action and the target), then chips All, Denied, Errors, Mine (Mine = records carrying this device's id).
- Records grouped by day, newest first. Headings: TODAY, YESTERDAY, then the weekday within the week, then `12 Sep` (plus the year when it is not this one).
- Row: time `09:41` mono 12 muted in a 44 px column; the board sentence 14 px ("nginx-proxy restarted from this phone", "Stack monitoring brought down from On-call pixel"); under it "device · role" 12 muted and the result pill on the right: `ok` neutral, `denied` warning, `error` danger. The sentence no longer carries " · denied"; the pill does.
- Empty log: "Nothing recorded yet". Nothing matching: "Nothing matches — Try another filter, or clear the text."
- The list scrolls; the board clips it at 844.

## PairConfirm

- Sheet over the Pair screen: accent-tint tile with a shield-check, "Check the certificate", mono host `agent.example.com:8443`.
- Copy: "Compare with the fingerprint the agent printed on the host. If every group matches, pin it: from then on the app refuses this server if the certificate changes."
- Fingerprint block: code-block fill, caption "SHA-256 FINGERPRINT", the 64 hex characters as eight 8-character groups in a 4×2 grid, Plex Mono 14/500. The agent prints the same bytes as `A4:E9:7C:10:…`; each group is four of those pairs without the colons.
- Rows (44 px, bordered, radius 16): Agent version, Role for this phone (this Mac on a Mac), Device id.
- Buttons: "Cancel" (outline) and "Pin and pair" (accent), 54 px, radius 16. Nothing is stored before "Pin and pair".

## PairError

The Pair screen as filled in, with the HTTPS note replaced by a red card (danger tint, danger border, radius 16, shield-x icon, title 14/600 danger, body 13 `#C9D6DB`), and the main button reading "Try again". Drawn: the certificate mismatch. The other messages:

| Code from the agent or the app | Title | Body |
|---|---|---|
| `certificate_mismatch` | Certificate doesn't match | The certificate the agent presented is not the one it reported, so nothing was pinned or saved. Something may sit between this phone and the host. |
| `pairing_failed` with 401 | Token not accepted | The agent says the pairing token is not valid or has expired. Run agent_zero pair-token on the host for a fresh one. |
| `agent_unreachable` | Agent not reachable | Nothing answered at <URL>. Check the address and port, and that the agent is running on the host. |
| `secure_storage_unavailable` | Secure storage unavailable | The device key can't be stored in this Mac's secure storage, so nothing was saved. On a Mac this happens in an unsigned build; use a signed one. |
| `insecure_transport` | HTTPS required | the app's message |
| `validation_failed` | Check the details | the app's message |
| `conflict` | Already paired | the app's message |
| anything else | Pairing failed | the agent's message |

## ContainerDetailEnv

- Both rows on Container detail open one sheet; Volumes opens it scrolled to the Volumes section. The rows are enabled for every role now: variable names come with `GET /containers/{id}` and are not secret.
- Title "Environment", subtitle "api-gateway · Reveal and Copy are audited" (for non-admins "api-gateway · values are admin only", with no Reveal or Copy).
- "12 VARIABLES · VALUES HIDDEN": rows 40 px, name mono 13/500, `••••••`, a "Reveal" text button (accent, 13/600) and a 32 px copy button. Revealed: "Hide", and the value under the name, mono 12.5, selectable. The first Reveal or Copy makes the one audited call `GET /v1/containers/{id}/env`; later ones reuse it. Copy puts the value on the clipboard with a toast "Value of LOG_LEVEL copied".
- "VOLUMES · 2 MOUNTS": rows 52 px, `api_config → /etc/api` mono 13 (arrow painted, see GlyphText), "Named volume" / "Bind mount" / "tmpfs" under it, a neutral `read-write` or `read-only` pill.
- Twelve variables make the sheet nearly full height; it scrolls, never overflows.
