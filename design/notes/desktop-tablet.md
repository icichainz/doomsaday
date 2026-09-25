# Desktop and tablet boards (desktop-tablet round)

Boards the app already had as layouts but that were never drawn. Desktop boards are 1440×900 with the D1 sidebar (server scope, prod-eu-1), tablet boards are 834×1194 with the T1 rail. Each has a `Light` twin made with the README's dark→light token table. The sidebar copies D1's markup, so its brand is the Free/demo mint "D"; in the Pro build the brand row is P3's (deep-red tile, PRO badge).

| # | File | What it shows |
|---|---|---|
| D8 | DesktopStacks | Compose stacks: header with the 330 px segmented control (Compose stacks / Swarm services), cards in 2 columns |
| D9 | DesktopVolumes | Volumes table, same shell as D4 |
| D10 | DesktopNetworks | Networks table, same shell as D4 |
| D11 | DesktopAlerts | Alert cards in 2 columns, the resolved note, the rules as a table |
| D12 | DesktopSettings | Server settings in a 720 px column |
| D13 | DesktopRegistries | Registry credentials, cards in 2 columns |
| D14 | DesktopPair | The Pair dialog over "All servers", on its certificate step |
| D15 | DesktopPalette | Cmd+K over the Overview |
| T2 | TabletContainers | Containers at tablet width |
| T3 | TabletStacks | Compose stacks at tablet width |

## Shared desktop card density (D8, D11, D13)

Cards from 600 up: radius 16, padding 16 × 18, title 16 px (the phone keeps radius 20, padding 16, 17 px). Card buttons follow the density: **36 px, radius 10, 13 px** with a pointer (1100 and up), the phone's **44 px, radius 12, 14 px** on touch. Grids are 2 columns with a 16 px gap (14 on the tablet).

## D8 DesktopStacks

- Header "Stacks" / "Compose projects on prod-eu-1", segmented control on the right (30 px segments, as D4).
- Card: name, path (mono 12), pill "4 of 5 up" (accent all up, warning some, danger none), the segment meter, then **one row**: "Pull and redeploy" (flexes; filled accent when something is down, outline when all up), "Restart", "Down" (danger text).
- A stack with nothing up: danger border, the sentence "postgres-backup exited with code 1, 12 min ago." instead of the meter, then "Start stack" (flex) and "View logs".
- **Swarm services** (second segment, not drawn): the same grid and card. Pill "3 of 3 replicas" / "2 of 3 · converging" (warning border) / "Global · 3 nodes"; the row is the replica stepper, then "Update" and "Roll back" at 36 px. Empty states unchanged from the phone (not in a swarm, a worker node, no services).

## D9 DesktopVolumes and D10 DesktopNetworks

Same frame as D4: title and "n volumes · 46 GB · 2 not mounted" subtitle, segmented control, 320 px filter with the `/` hint, pill chips, "Prune unused" and the accent create button, the table (38 px header, 46 px rows, sortable headers with the arrow on the sorted column, ⋮ per row and the same menu on right-click), footer line.

- Volumes columns: **Name** (mono, flex, selectable) · **Size** (100, right, sorted biggest first) · **Driver** (90) · **Mounted by** (170; container names, "–" when none) · **Last used** (120, muted: "now" while mounted, "12 min ago", "in March" after 60 days, "never") · **Status** (Mounted accent / Not mounted warning). Chips: All · Mounted · Not mounted.
- Networks columns: **Name** (mono, sorted A–Z) · **Driver** (100) · **Subnet** (170, mono muted) · **Scope** (90, the real scope: local, swarm) · **Attached** (90, right) · **Status**: **Default** (neutral pill, the built-in `bridge`/`host`/`none`) / **In use** (accent) / **Unused** (warning). Chips: All · In use · Unused · Default. The subtitle's "unused" counts only what prune would remove, so a default network is not counted (the phone keeps "2 unused").
- Footer: "Showing 9 of 9 · right-click a row for Remove, Copy name and Show containers" (Networks adds "· default networks cannot be removed"). The same "Showing x of y" now applies to D4.

## D11 DesktopAlerts

- Header "Alerts" / "2 active on prod-eu-1 · sent as push notifications".
- Active alerts in 2 columns, critical first: 36 px tinted icon tile with the stroke warning triangle, title 15 px, detail 12.5 px, severity pill; buttons at 36 px — critical with a container: "View logs", "Restart" (both flex), "Mute 1 h"; warning: "Open container" (flex), "Mute 1 h".
- Resolved and muted alerts: one 44 px bordered note each, full width, tick in accent.
- "Rules checked by the agent" as a table **below** (the page is wide enough that a right column would squeeze the cards): **Rule** (flex; "Agent unreachable" carries "Needs the push relay; the agent never fires it itself") · **Threshold** (170: "Non-zero exit code", "3 restarts", "90%", "No heartbeat") · **Window** (130: "Immediately", "10 min", "5 min", "2 min") · **On** (60, the 46×28 switch). Rows 54 px. CPU and memory stay one row, "CPU or memory high", and the switch patches both.
- Footer: "Rules run on the agent, so they keep firing while this Mac is closed. A change applies to every device paired with prod-eu-1."
- **Fleet alerts** (`/all/alerts`, Pro; locked on Free per P1): the same page for every server, with the **Server** column added — the existing table: Alert (bold) · Server (130) · Detail · Severity, rows open the container or the server's alerts, an offline notice per unreachable server, and the line "Muting and resolving stay on the server that raised the alert; open it to act on one." No rules table there: rules belong to one agent.

## D12 DesktopSettings

Decision: **keep the 720 px column** (a two-column split reads no better: the content is short, and the column matches Preferences and every settings page on a Mac), but left-aligned under a standard desktop header instead of centred, so the title lines up with every other page.

- Agent card (warning border when an update exists) with "Update agent" at 36 px.
- Group: Agent URL, Certificate "Pinned · 9F:2C…A1:7E" (click copies the full fingerprint), Your role. Groups here have radius 16, 18 px sides, 44 px rows, faint dividers.
- Group of links: Registry credentials "2 signed in", Alert rules "4 active", Paired devices "**3 devices**" (the phone keeps "phones"), Activity log.
- Switches (56 px rows): "Fingerprint before risky actions", "Read-only on **this Mac**" (the device noun follows the platform everywhere now).
- Last, directly after the switches (not pinned to the window's bottom): a danger-bordered card "Unpair this server" / "Revokes this Mac's device key on the agent. Other paired devices keep working." with "Unpair…" (36 px, danger text), which opens the D3 confirm.

## D13 DesktopRegistries

- "‹ Server settings" (13 px muted link, 20 px) above the title — the phone's back link is not drawn beside a sidebar, so the sub-page names its way back here. Header action "Add a registry" (accent, 36 px, plus glyph).
- Cards in 2 columns: host (mono 15/500), "Signed in as …", status pill; buttons at 36 px: "Test login" (flex) · "Edit" · "Remove" (danger); an expiring or failed token makes the first button "Replace token" (accent) and the border warning/danger; an anonymous registry has one full-width "Sign in".
- The lock info note, full width, under the grid.

## D14 DesktopPair

The 560 px pair dialog over "All servers" (dim 0.72). Pairing is now **one dialog with two steps**: the form ("PAIR A SERVER · STEP 1 OF 2") and, after "Test connection and pair", the certificate check in the same dialog — no second dialog stacked on the first. Drawn state is step 2:

- Top line "PAIR A SERVER · STEP 2 OF 2" (11–12 px caps) and a 32 px close button.
- 44 px accent-tint tile with the shield, "Trust this certificate?" (22 px), "edge-1 · edge-1.example.com:8443".
- Sentence: "The agent answered, and the fingerprint it reported matches the certificate it presented. Compare it with what the agent printed on the host, then pin it. The app refuses the connection if it ever changes."
- Code block "SHA-256 FINGERPRINT": 4 lines of 8 bytes, each line in **two groups of four** 22 px apart, mono 14/500, selectable.
- Detail rows: Agent version, Your role, Device id (mono).
- "‹ Back" (to the form, fields kept) at the left; "Cancel" and "Pin and pair" (accent), 40 px, at the right. Return pins, Esc cancels.
- Below 600 the pushed screen and its bottom sheet are unchanged.

## D15 DesktopPalette

- Hangs from the top (110 px, or 12 % of a short window), 560 px, radius 16, over the Overview dimmed 0.72.
- Search row 54 px: stroke magnifier, 15 px field "Jump to a container, stack or server", `esc` keycap.
- Grouped results — **Servers**, **Containers**, **Stacks** — with an 11 px caps header per group, only groups that have rows. Rows 44 px: 28 px icon tile (servers, cube, stacks glyphs), name (14/600), a muted second text on the same line (host or image in mono, "4 of 5 up" for a stack), and on the right the **server name** (container and stack rows) or the server's state (current / "9 running" / "offline", an offline server dimmed). The current server comes first in every group. Nothing typed: three rows per group; with a query: up to eight per group.
- Selected row: icon-button fill, accent glyph on a border-coloured tile, and a `↵` keycap after the server name. ↑ ↓ move through all groups, Return opens, Esc closes. Hover highlights too, a click opens.
- Footer 40 px: `↑` `↓` move · `return` open · `esc` close, and on the right the scope: "Every server".
- **Free**: only the current server is searched (its own server row, containers and stacks); above the footer a bordered 44 px row "Search every server" with the PRO badge opens the Pro sheet; the footer's right says "prod-eu-1 only".

## T2 TabletContainers (600–1099)

- Rail (Containers active), 28 px page padding and 28 px title as T1: "Containers" / "16 on prod-eu-1".
- The filter is always shown — no search button as on the phone: a 44 px field (radius 12, 15 px text, no `/` hint) that takes the row, and the chips "All 16", "Running 14", "Stopped 2" (44 px) **on the same row**.
- List card radius 18 with faint dividers; **52 px rows**: 8 px state dot, name 14.5/600 over the image (mono 12), state and figures stacked on the right, then the 44 px stop/start button. The column is capped at 720 px (at 834 the page is narrower than that anyway).
- Tapping a row pushes the container screen, as on the phone.

## T3 TabletStacks

- Title, full-width 44 px segmented control, cards in 2 columns (14 px gap), card chrome as D8.
- A tablet card is about 300 px inside, too narrow for three touch-size buttons on one row, so **"Pull and redeploy" takes its own row** and "Restart" and "Down" share the row below, 44 px each. The down stack keeps "Start stack" and "View logs" on one row.

## Tablet pages in general

From 600 to 1099 every tab and pushed page now uses T1's **28 px** page padding (top and sides) and a **28 px** title, instead of the phone's 20 and 30.
