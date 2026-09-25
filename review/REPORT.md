# Doomsaday — visual design review

First pass, app vs design boards, both flavors. Nothing in the app was changed.

* Design boards rendered to PNG: `review/design/<Board>.png`
* App captures: `review/app/free/<Board>.png`, `review/app/pro/<Board>.png`
* Side-by-side pairs (what this report is written from): `review/pairs/free/`, `review/pairs/pro/`
* Real macOS launches: `review/real/free.png`, `review/real/pro.png`

Severity: **major** = a designer would reject it · **minor** = wrong but shippable
· **cosmetic** = a nudge.

---

## Expected differences (not mismatches)

These show up on nearly every pair and are not counted below.

* **Live clock and relative times.** The boards were drawn at 09:42; the app
  stamps the real time (11:15 in these captures). Every log timestamp, activity
  time and "x min ago" differs for this reason alone.
* **Drifting stats.** CPU reads 34% on the boards and 33-35% in the app,
  memory 9.8/9.9 GB, container memory 402-412 MB. The mock streams jitter.
* **No fake status bar.** The boards have no phone status bar either, so the
  phone pairs line up, but the app has no safe-area inset in the harness.
* **Sample-data volume.** The boards draw a hand-picked subset (7 containers, 6
  images, 6 volumes); the mock seed returns the full set (16 containers, 9
  volumes, 7 networks), so app lists run past the fold where the board's card
  ends with white space.
* **Locked pages in `free`.** `DesktopFleet` and `DesktopLogWall` render the PRO
  panel in the free build. That is the intended behaviour, and those two pairs
  are only meaningful against the `ProLocked` board (they match it).
* **Demo mode.** The captures run on the three sample servers, so the Servers
  screen adds "Demo data ·" and a "Leave demo" button, and the sidebar carries a
  "Demo" pill. The boards draw the paired state.

---

## Global: icons

The app draws Material icons where the design drew custom 2 px stroke icons.
Most read fine and this is noted **once** rather than per screen. Three glyphs
are misleading enough to call out individually:

* **Resources** (bottom bar, rail and sidebar) — the design draws a database
  cylinder, the app draws three horizontal bars that read as a list/filter.
  **minor**
* **Containers** (bottom bar, rail and sidebar) — the design draws a cube, the
  app draws a box inside a circle that reads as a target/crosshair. **minor**
* **Overview** — the design draws four outlined rectangles of different sizes,
  the app draws four equal filled squares. **cosmetic**

---

## Global: two broken glyphs

Both appear in several places and both render as an empty box (tofu).

* **`->` arrow in port mappings** (`PortMapping.label`, `lib/data/models.dart:638`)
  — shows as `8080 [] 8080/tcp` on Container detail and in the Desktop
  containers sub-header. The mono face in use has no U+2192. **major**
* **Command glyph in the Cmd+K hint** (`overview_screen.dart:218`,
  `filter_field.dart`) — the desktop search chip shows `[]K` instead of the
  command symbol + K. **minor**

---

# Free

Screen by screen against `review/pairs/free/`.

### Main (Servers) — good
Layout, card geometry, radii, pills, progress bars and both accent buttons match
the board. Only the demo-mode chrome differs (see expected differences).

### PairAgent
* **major** — the **QR-scan button beside the "Pairing token" field is missing**.
  The board puts a 48x48 scan button to the right of the field; the app has the
  field alone at full width.
* **minor** — token placeholder copy: board `Printed by the agent after install`,
  app `Run agent_zero pair-token on the host`.
* **minor** — the HTTPS note is two lines longer in the app (it adds "- the app
  refuses the connection if it ever changes"), which grows the note card by
  ~46 px and eats the gap above the submit button.
* cosmetic — "Server name" is prefilled on the board and empty (placeholder
  "e.g. prod-eu-1") in the app; that is an empty-vs-filled state, not a bug.

### Dashboard (Overview)
* **major** — the subtitle is **clipped**: board `Docker 27.1 · up 41 days`,
  app `Docker 27.1 · Agent 1.4.2 ...` cut with an ellipsis. The app packs one
  more field into the same width.
* **major** — "2 stopped · 1 restarti..." in the Containers stat card is
  **clipped**. The board fits it; the app's stat cards are narrower because the
  grid gap/padding is larger.
* **minor** — the two "Needs attention" rows are in the opposite order (board:
  worker-queue then postgres-backup; app: postgres-backup then worker-queue).
* **minor** — the board splits each attention row into a bold name and a
  sentence (`worker-queue` / `Restarted 4 times in the last 10 min`); the app
  puts the whole sentence in the bold line and the metadata underneath
  (`worker-queue restarted 4 times in 10m0s` / `2 min ago · worker-queue ·
  4 times`), which wraps to two lines and makes the card taller.
* **minor** — `10m0s` is a raw duration; the board says `10 min`.
* **minor** — the board's attention rows have a right chevron; the app's have
  none, so the rows do not read as tappable.
* **minor** — Recent activity is reworded and re-ordered: board
  `nginx-proxy restarted from this phone` / `Image redis:7.2 pulled` /
  `Stack monitoring redeployed`; app `Restarted nginx-proxy · This phone` /
  `Pulled image redis:7.2 · Ops iPad` / `Redeployed stack monitoring · This phone`.
* cosmetic — the app adds an "All alerts" link beside NEEDS ATTENTION on desktop
  and tablet as well; the board only has it on the phone.

### Alerts
* **major** — the rules list uses **switches where the board uses checkboxes**
  (four mint check squares). Different control, different affordance.
* **minor** — the fourth rule ("Agent unreachable for 2 min") is **off** in the
  app and checked on the board, and the app adds a subtitle the board does not
  have: "Needs the push relay; the agent never fires it itself".
* **minor** — the resolved note duplicates its own text: app reads
  `Disk above 80% on staging-1 · resolved 2 days ago · Disk above 80% on
  staging-1`. Board: `Disk above 80% on staging-1 · resolved Tue 14:10`.
* **minor** — alert titles/subtitles reworded, same pattern as Dashboard:
  board `postgres-backup exited` + `Exit code 1 · 12 min ago · stack backups`;
  app `postgres-backup exited with code 1` + `12 min ago · postgres-backup`.
  The stack name is dropped and the title wraps to two lines.
* cosmetic — with a two-line title the severity pill centres vertically in the
  app; the board keeps it on the first line.

### Containers — good
Chips, row height (66), status colours, mono image line, truncation and the
bottom bar all match.
* cosmetic — the row action is a small filled square in the app and an outlined
  stop square on the board.
* cosmetic — the list runs off the bottom edge mid-row with no rounded card
  bottom (the board's card ends after 7 rows). A consequence of the seed size.

### ContainerDetail
* **major** — `8080 [] 8080/tcp`: the broken arrow glyph (global note), and in
  the desktop pane the same string is also truncated to `8080/tc`.
* **major** — the chevrons in the Environment/Volumes card are **not aligned**:
  Environment's sits at the card's right edge, Volumes' sits immediately after
  "2 mounts", ~80 px further left.
* **minor** — the Network stat card clips: `in · 354 KB/s ...`. (The board's own
  markup overlaps "in"/"out" here, so the board is not a clean target either.)
* **minor** — the status pill reads `Running` where the board reads
  `Running · healthy`; the seed gives api-gateway no health value.
* **minor** — Network row value: board `backend`, app `web-platform_backend`,
  which wraps to two lines and grows the row.
* **minor** — "12 variables, values hidden" wraps to two lines in the app.
* **minor** — "Remove container" sits directly under the card in the app; the
  board pins it to the bottom of the screen with ~90 px of space above.

### ConfirmStop
* **major** — the confirmation control is a **switch**; the board draws a
  **checkbox**. Copy also differs: board `Confirm with fingerprint on production
  servers` (one line), app `Confirm with fingerprint` + `This agent requires it
  for risky actions`.
* **minor** — subtitle: board `prod-eu-1 · production`, app
  `prod-eu-1 · web-platform`.
* **minor** — body copy: board `...and 2 containers in web-platform depend on
  it.`, app `...and 2 other containers in web-platform depend on it.`
* cosmetic — the sheet is ~25 px taller in the app because of the extra
  subtitle line.

### Logs — good
Close to pixel-exact: header, filter row, "Last 15 min", the log surface, the
INFO/WARN/ERR colours, the footer row and the accent download button all match.
Only the timestamps, the line count (`15 lines` vs `1,204 lines`) and a slightly
looser line height differ.

### Stacks
* **major** — the three stack actions are **stacked vertically at full width**
  (Pull and redeploy / Restart / Down) where the board has them in one row. Each
  card is ~2.5x taller, so the third stack ("backups") is pushed off-screen and
  its "Start stack"/"View logs" state is never seen.
* **minor** — the down service's bar segment is danger coral `#FF8A7D`; the
  board uses warning amber `#F2B45A` (verified by pixel sample).

### Services
* **major** — same vertical button stack: the replica stepper, "Update" and
  "Roll back" are three full-width rows instead of one row. "ingress" is pushed
  off-screen, along with its "One task on every node" line.

### Images — good
Header, summary line, segmented control, both action buttons, rows and status
pills all match.
* **minor** — relative dates never roll up: board `pulled 2 months ago` /
  `3 weeks ago` / `5 months ago` / `today 09:15`; app `created 62 days ago` /
  `21 days ago` / `150 days ago` / `5 h ago`. Also the verb changed from
  "pulled" to "created".

### Volumes — good
Same as Images. Only `last used in March` -> `last used 190 days ago`. **minor**

### Networks — good
A very close match; the app simply has one more seeded row.

### ServerSettings
* **major** — the two toggles are **switches**; the board draws **checkboxes**.
* **major** — the app adds an **APPEARANCE** section (System/Light/Dark) that is
  not on the board, and it pushes the destructive **"Unpair this server"** button
  off-screen. The board ends the screen with that button.
* **minor** — values wrap where the board fits one line: `agent.example.com:` /
  `8443`, `Pinned · 9F:2C...` / `A1:7E`, `Who did what, and` / `when`.
* **minor** — the four row chevrons are at four different x positions (they
  follow the value text); the board right-aligns all of them.
* **minor** — "Read-only on this phone" subtitle: board `Hide every action that
  changes the server`, app `Sets this device to the viewer role on the agent`.

### Registries — good
Cards, pills, buttons, the lock note and the bottom action all match.
* cosmetic — `Anonymous pulls, rate limited by Docker Hub` -> `...by the
  registry`, and the note wraps to four lines instead of three.

### MainLight / DashboardLight / ContainersLight
The light tokens are exact — ground `#F3F5F4`, surface `#FFFFFF`, sidebar
`#FFFFFF` sampled identical to the boards. All three carry the same findings as
their dark twins and nothing new.

### DesktopTablet (834x1194)
* **major** — the **"Busiest containers" table is missing**. The board's tablet
  layout is stat cards -> two columns -> compact table; the app stops after the
  two columns and leaves ~600 px of empty page.
* **minor** — the title block differs: board puts `prod-eu-1` and the `Online`
  pill on one line with the meta beneath; the app puts the title alone on line 1
  and the pill + meta on line 2.
* cosmetic — the app adds a red "2" badge on the bell and an "All alerts" link
  the tablet board does not have.

### DesktopOverview (1440x900) — good structure
Sidebar width, the four stat cards, the table and the right column all land
where the board puts them.
* **minor** — `[]K` instead of the command glyph in the jump field (global note).
* **minor** — the Image column truncates earlier than the board
  (`registry.example.com/api:2....`) because the CPU column is wider.
* cosmetic — Recent activity has three rows to the board's four, and the
  restarting container shows `2% / 128 MB` where the board shows a dash.
* cosmetic — footer reads `This phone · Admin · Free`; the board says
  `This Mac · Admin`. That string is the mock agent's device name, not a layout
  bug, but it is what a Mac user will see in demo mode.

### DesktopOverviewLight — good
Same as the dark board, tokens exact.

### DesktopContainers
* **major** — the three filter chips are **stacked vertically at full width** in
  the 400 px list column instead of sitting in one row of pills.
* **major** — the detail pane's toolbar **wraps into three extra rows**:
  "Last 15 min" becomes a full-width block, the pause and download buttons drop
  onto their own row, and a full-width **"Open in log wall"** button (not on the
  board) is added below. The board keeps tabs, filter, range, pause and download
  on one line and puts the log surface immediately underneath, so the app loses
  ~140 px of log area.
* **minor** — the header pill reads `Up 3 days` where the board reads
  `Running · healthy`; the pane shows uptime where the board shows state.
* **minor** — `8080 [] 8080/tc` — broken arrow plus truncation.
* cosmetic — Memory card: board `412 MB of 1 GB`, app `406 MB of 2.0 GB`
  (seed limit, plus a trailing `.0` the board never shows).

### DesktopConfirm — good
The dialog geometry, the request block, the typed-name field, the hint line and
both buttons match the board closely.
* **minor** — the body loses the specifics: board `Port 8080 stops answering,
  and 2 containers in web-platform depend on it.`, app `Anything talking to it
  stops getting answers.`
* **minor** — subtitle `prod-eu-1 · web-platform` vs `prod-eu-1 · production`;
  hint `This device has no biometric unlock.` vs `This Mac has no Touch ID.`
* cosmetic — the app dims the page behind the dialog; the board does not.

### DesktopResources
* **major** — same chip stacking: "All 6 / In use 4 / Unused 2" are three
  full-width rows above the filter field, where the board has filter + three
  pills in one row with the actions on the right.
* **minor** — the table rows have **no row-more (three-dot) button**; the board
  gives every row one at the far right.
* **minor** — the sort arrow points **up** on SIZE for a biggest-first sort; the
  board points down.
* **minor** — relative dates again (`62 days ago` vs `2 months ago`, etc).
* cosmetic — the chips count the 6 returned rows while the header says
  "23 images"; that inconsistency is in the seed, not the layout.

### DesktopFleet / DesktopLogWall (free)
Both render the locked PRO page. Expected — see ProLocked.

### ProLocked — very good
The lock tile, the title, the reassurance line, the three bullets, both buttons,
the header PRO badge, the dimmed 2x2 skeleton, the sidebar badges and
`SERVERS · 2 OF 2 ON FREE` all match the board.
* **minor** — the sidebar section heading reads **`ALL SERVERS`**; the board (and
  `design/README.md`) say **`ACROSS ALL SERVERS`**.
* cosmetic — on the "All servers" variant the title wraps to two lines
  ("All servers is part of Doomsaday" / "Pro"), which the board never shows.
* cosmetic — the skeleton is generic grey bars in a single card rather than a
  skeleton of the feature itself.

### ProLimit — very good
The sheet over the dimmed Servers list, the red lock tile, the PRO badge, the
title, "You have paired prod-eu-1 and staging-1.", the body sentence and both
buttons all match.
* cosmetic — the board dims the list behind more heavily and shows a compact
  one-line server card; the app keeps its normal three-column card. That is the
  board simplifying, not an app fault.
* Note: a **deep link to `/pair`** renders the same content as a full pushed
  page with a back bar rather than as a sheet. That is deliberate
  (`ServerLimitBody`'s doc comment says so) but it does not match P2.

---

# Pro

Every phone screen is **byte-identical** to the free build
(`Main`, `MainLight`, `PairAgent`, `Alerts`, `Containers`, `ContainersLight`,
`ContainerDetail`, `ConfirmStop`, `Images`, `Volumes`, `Networks`, `Stacks`,
`Services`, `Registries`, `ServerSettings` — verified by hash), so **every
finding above applies unchanged**. `Dashboard`, `DashboardLight` and `Logs`
differ only by the live clock.

The desktop and tablet screens differ from free only in the sidebar. Their
layout findings above (stacked chips, wrapped pane toolbar, missing tablet
table, the broken command glyph, missing row-more) are identical in Pro.

Pro-only findings:

### ProBrand — good
Deep-red tile, ivory "D", "Doomsaday", PRO badge — colours and geometry match
P3. Only the count differs (`2 of 2` vs the board's `3 of 3`, because the
harness pairs two mocks).

### Sidebar brand, everywhere at 1440
(DesktopOverview, DesktopContainers, DesktopConfirm, DesktopResources,
DesktopFleet, DesktopLogWall)

* **major** — the brand name is **truncated to "Dooms..."** whenever the PRO
  badge and the "Demo" pill are both present in the 264 px sidebar. Confirmed in
  the real macOS launch, so it is not a harness artefact. Free shows "Doomsaday"
  in full because it has no PRO badge there.

### DesktopFleet (Pro)
* **major** — the "Needs attention 2" button **overflows the right edge** of the
  content area and is clipped. It is pushed there by the same stacked-chip bug:
  the three scope chips take a full-width column and the two state buttons stay
  on the filter row.
* **minor** — sidebar heading `ALL SERVERS` vs the board's `ACROSS ALL SERVERS`.
* **minor** — offline copy: board `backup-nas unreachable for 2 h`, app
  `backup-nas unreachable` (duration dropped).
* cosmetic — the board's bottom "backup-nas is offline..." notice with a Retry
  button is below the fold in the app because the table has 23 rows.
* cosmetic — the fleet table is unsorted in the app; the board groups by server.

### DesktopLogWall (Pro) — very good
Pane grid, headers, dot colours, Live pills, pause/close buttons, the filter
field, "Pause all" and "Add pane" all match the board.
* **minor** — the worker-queue pane's badge reads **`Live`** (mint) where the
  board reads **`Restarting`** (amber). The status dot *is* amber, so the pane
  badge is showing stream state rather than container state.
* cosmetic — the app adds a footer line ("Every pane holds one stream open...")
  that the board does not have.

---

## Real macOS launches

| | `free` | `pro` |
|---|---|---|
| Window title | `Doomsaday` | `Doomsaday Pro` |
| Menu bar app name | `Doomsaday` | `Doomsaday Pro` |
| Bundle id | `dev.doomsaday.doomsaday` | `dev.doomsaday.doomsaday.pro` |

Both launched, both named themselves correctly, both quit cleanly.
`screencapture -x -l <window id>` worked (Screen Recording is granted), so
`review/real/*.png` hold just the app window and nothing else from the desktop.

Two things only the real launch showed:

* **free, empty state** — "Pair a new server" appears **twice**: once inside the
  "No servers yet" card and again as the pinned bottom action. **minor**
* **pro** — the truncated "Dooms..." brand, confirming the sidebar finding above.

---

## Count

| Severity | Free | Pro (additional) |
|---|---|---|
| major | 14 | 3 |
| minor | 27 | 3 |
| cosmetic | 15 | 2 |

The majors cluster in three places: **rows of buttons and chips that the app
stacks vertically** (Stacks, Services, DesktopContainers, DesktopResources,
DesktopFleet), **checkbox vs switch** (Alerts, ConfirmStop, ServerSettings), and
**content that is clipped or missing** (Dashboard subtitle, the tablet table, the
pairing QR button, "Unpair this server", the arrow glyph).
