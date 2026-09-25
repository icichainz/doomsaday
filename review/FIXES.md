# Doomsaday — what the review found, and what was done

Written against `review/REPORT.md`. Every finding in that report has a line
here. The pairs were regenerated after the work
(`review/pairs/free/`, `review/pairs/pro/`) and the design boards were
re-rendered last, so both halves are current.

---

## The stacking bug: one cause, fixed at the source

**A `Container` with an `alignment:` — and a `Center` — fills whatever bounded
width its parent offers.** `DoomButton` wrapped its label in `Center`, and both
chips (`FilterChipButton`, `PillChip`) used `alignment: Alignment.center`. In a
`Row` that is harmless: a `Row` hands its non-flexible children *unbounded*
main-axis constraints, so the `Align` shrink-wraps. A **`Wrap` hands every
child the wrap's full width**, so each button and each chip grew to the whole
line and landed on a run of its own — a column of full-width bars.

Every symptom the report clusters as "major" came from that one line of layout:
the Stacks and Services action rows, the filter chips in the 400 px containers
pane, the chips above the Images/Volumes/Networks tables, the fleet chips
(which is what pushed "Needs attention" off the right edge), and the desktop
logs toolbar.

Fixed in the three shared widgets:

* `lib/widgets/buttons.dart` — `DoomButton` drops the `Center`; the inner
  `Row(mainAxisSize: min)` is what hugs. `FilterChipButton` swaps
  `alignment:` for a min-size `Row` with a `Flexible` label.
* `lib/widgets/desktop.dart` — `PillChip`, the same.

With the chips and buttons hugging again, the rows were then made the shape the
boards draw:

* `ActionRow` (new, `lib/widgets/buttons.dart`) — the card action row the
  boards use everywhere: the primary flexes, the rest hug. Stacks and Services
  use it; no `Wrap` is left in a card.
* `CardGrid` drops to one column when two would be narrower than 320 px, so a
  600 px window does not squeeze three buttons into 227 px.
* The desktop logs toolbar is now one `Row` with three degradation tiers
  (labels → icon for "Open in log wall" → icon for the range and shrinking tab
  labels). It never wraps.

---

## Global

| Finding | Result |
|---|---|
| Resources icon reads as a list | **fixed** — `StrokeIcon` paints the board's database cylinder |
| Containers icon reads as a crosshair | **fixed** — the board's isometric cube |
| Overview icon is four filled squares | **fixed** — the board's four outlined rectangles |
| `->` renders as tofu in port mappings | **fixed** — painted glyph (see *Glyphs*) |
| Command glyph renders as tofu in the Cmd+K hint | **fixed** — painted glyph, "Ctrl K" off Apple |

`lib/widgets/stroke_icons.dart` is new: the boards' inline SVG paths
(overview, containers cube, stacks, resources cylinder, servers, alerts bell,
settings sliders, log-wall lines) drawn with a `CustomPainter` on the 24×24
viewBox, 2 px stroke, round caps and joins, colour from `IconTheme`. It is used
by the bottom bar, the rail, the sidebar and the two Overview header buttons.
No new packages.

### Glyphs, and what the real app does

The bundled faces are **subsets**: 226–232 glyphs each, Latin-1 plus a little
punctuation. None of the seven carries `U+2192 →` or `U+2318 ⌘` (checked by
dumping their `cmap` tables). So:

* **In the harness** there is no fallback at all — only those TTFs and
  `MaterialIcons` are registered — which is exactly the tofu the report saw.
* **In the real macOS app** the glyphs would have resolved: Flutter falls back
  through CoreText, and `SFNS.ttf`, `Apple Symbols.ttf` and `Menlo.ttc` all
  carry both codepoints (checked the same way). I launched the Pro build and
  confirmed the brand row, the footer and the stroke icons, but could not drive
  it to a screen carrying those two glyphs — synthetic clicks from AppleScript
  do not reach the Flutter view, and demo mode is not persisted — so this is
  reasoned from font coverage rather than observed.

Either way it is now moot: both glyphs are **painted**, not typed, so there is
no tofu in the harness or in any build. `⌘` additionally falls back to the text
"Ctrl K" where the platform is not Apple.

---

## Free, screen by screen

### Main (Servers)
* good — unchanged. Only demo chrome differs (expected).

### PairAgent
* QR-scan button — **left by decision 3** (the board is losing it).
* token placeholder, HTTPS note — **left by decision 3** (the board now matches
  the app's wording; verified against `design/PairAgent.dc.html`).
* prefilled "Server name" — expected difference.

### Dashboard (Overview)
* clipped subtitle — **fixed**: `Docker 27.1 · up 41 days`. The agent version
  now appears only in Server settings.
* `2 stopped · 1 restarti…` clipped — **fixed**: `StatCard` takes the phone
  board's own metrics at touch density (padding 16/14, radius 18, suffix 15),
  which is the 4 px the line needed.
* attention rows in the wrong order — **fixed**: `compareAlertsByUrgency`,
  critical → warning → most recent. (The board already draws that order.)
* attention row shape — **fixed**: bold container name, sentence beneath.
* `10m0s` — **fixed**: `10 min`. `humanizeDurations()` also rewrites any raw Go
  duration an agent puts in a message, as a safety net.
* missing chevron — **fixed**.
* activity wording — **fixed**: `nginx-proxy restarted from this phone`,
  `Image redis:7.2 pulled`, `Stack monitoring redeployed`. The acting device is
  appended as ` from <name>`, and this device is named after the hardware
  ("this Mac", "this phone").
* "All alerts" link on desktop/tablet — **left** (cosmetic, and useful there).

### Alerts
* switches vs checkboxes — **left by decision 1**.
* 4th rule off, with a subtitle — **left by decision 4**.
* resolved note repeats itself — **fixed**: `AlertInfo.note` is built once, and
  a resolved time is `resolved Tue 14:10` (weekday + clock inside the week, a
  date after it).
* alert titles/subtitles — **fixed**: `postgres-backup exited` /
  `Exit code 1 · 12 min ago · stack backups`, `worker-queue restart loop` /
  `4 restarts in 10 min · stack web-platform`. The exit code, the stack and the
  rule window are new optional `AlertInfo` fields, parsed out of the agent's
  message when an older agent does not send them.
* severity pill centres on a two-line title — **fixed**: the row is
  start-aligned, so the pill sits on the first line.

### Containers
* good — unchanged.
* filled stop square — **fixed**: `Icons.stop_outlined`, as the board draws it.
* list runs past the fold — expected (seed size).

### ContainerDetail
* broken arrow, and truncation in the pane — **fixed** (painted arrow; the pane
  line is one line with an ellipsis).
* chevrons not aligned — **fixed**: `NavRow` gives label+value the space left of
  the chevron, so every chevron lands at the card's right edge.
* Network stat card clips — **fixed**: `1.2 MB/s in` above `354 KB/s out`,
  which is what fits in a third of a 390 px row.
* `Running` vs `Running · healthy` — **fixed in code** (`ContainerSummary.pillLabel`,
  shared by the phone screen and the pane header). The seed still gives
  api-gateway no health, so the pair still reads `Running`; see *Still differs*.
* Network value wraps — **fixed**: one line with an ellipsis.
* "12 variables, values hidden" wraps — **fixed**: one line.
* "Remove container" not pinned to the bottom — **could not fix cheaply**: the
  button lives inside the detail body's async section, so pinning it would mean
  restructuring the screen; at 390 the content is taller than the viewport
  anyway, so the button is never at the fold.

### ConfirmStop
* switch vs checkbox, and its copy — **left by decision 1**.
* subtitle `server · stack` — **left by decision 6**.
* "2 other containers" — **fixed**: `Port 8080 stops answering, and 2
  containers in web-platform depend on it.` One shared
  `stopImpactSentence()` now writes it for the sheet and the dialog, and it
  degrades a clause at a time when there is no published port or no dependent.
  The desktop path used to skip the impact call entirely; both paths now go
  through one implementation.
* ~25 px taller — consequence of the decision above.

### Logs
* good — unchanged.

### Stacks
* three actions stacked — **fixed** (root cause + `ActionRow`). All three stack
  cards are on screen again.
* down segment coral where the board is amber — **fixed**: `StackService` now
  carries a `restarting` count, and the seed marks `worker` as restarting
  (which is what its container actually is), so the rule "restarting → amber,
  exited → danger" produces the board's bar.

### Services
* stacked stepper and buttons — **fixed**; "ingress" and its
  "One task on every node" line are back on screen.

### Images
* relative dates never roll up — **fixed**: `3 days ago` → `3 weeks ago` →
  `2 months ago` → `5 months ago` → `today 09:15`.
* verb "created" — **kept** as instructed (the agent only knows creation time).

### Volumes
* `last used 190 days ago` — **fixed**: `last used in March` past 60 days, with
  the year appended when it is not this one.

### Networks
* good — unchanged.

### ServerSettings
* switches — **left by decision 1**.
* APPEARANCE section, "Unpair this server" below the fold — **left by
  decision 2**; the screen scrolls and nothing is clipped (covered by the new
  overflow test at 390/800/1100/1440).
* values wrap — **fixed**: label and value share the row in proportion to their
  length, so both stay on one line; the host and the fingerprint lose their
  *middle* rather than their tail (`MiddleEllipsisText`, a small render object
  so it survives the intrinsic-height queries card grids make).
* chevrons at four different x — **fixed**.
* read-only subtitle — **left by decision 4**.

### Registries
* good — unchanged. "by the registry" wording left as is (cosmetic).

### MainLight / DashboardLight / ContainersLight
* carry the same fixes as their dark twins; tokens untouched.

### DesktopTablet
* missing "Busiest containers" table — **fixed**.
* title block — **fixed**: the pill sits beside the title at 600–1099, with the
  meta beneath. The phone keeps its own arrangement.
* bell badge and "All alerts" link — **left** (cosmetic).

### DesktopOverview
* `[]K` — **fixed** (painted ⌘, and the harness now runs the 1440 boards as
  macOS so the Mac wording is exercised).
* image column truncates earlier — **left**: column widths are the board's.
* three activity rows, restarting container showing figures — seed.
* footer `This phone · Admin · Free` — **fixed**: the footer names the hardware,
  so a Mac reads `This Mac · Admin`.

### DesktopContainers
* chips stacked — **fixed**.
* toolbar wrapped into three rows, full-width "Open in log wall" — **fixed**:
  one line, with the log-wall button collapsing to an icon + tooltip when the
  pane is genuinely too narrow (which it is at 1440: the board's own row does
  not fit either). The log surface gained back about 140 px.
* header pill shows uptime — **fixed**: the pill shows state, never uptime.
* `8080 [] 8080/tc` — **fixed**.
* `406 MB of 2.0 GB` — **fixed**: byte formatting drops a trailing `.0`
  (`2 GB`). The 2 GB limit itself is the seed's.

### DesktopConfirm
* body loses the specifics — **fixed** (same sentence as the sheet).
* subtitle — **left by decision 6**; hint — **fixed**: `This Mac has no Touch
  ID.` on macOS, the generic line elsewhere.
* dimmed page behind the dialog — **left** (the app's barrier).

### DesktopResources
* chips stacked — **fixed**.
* no row-more button — **fixed**: `DataTableView` adds a ⋮ column whenever a row
  menu exists, opening the same actions as right-click. The fleet table opts out
  because it draws its own trailing column.
* sort arrow points up for a descending sort — **fixed**.
* relative dates — **fixed**.
* chip counts vs header count — seed.

### DesktopFleet / DesktopLogWall (free)
* render ProLocked — expected.

### ProLocked
* `ALL SERVERS` — **fixed**: `ACROSS ALL SERVERS`.
* title wraps on the "All servers" variant, generic skeleton — **left**
  (cosmetic).

### ProLimit
* good.
* deep link to `/pair` was a pushed page — **fixed**: at the limit, `/pair`
  renders the Servers screen and opens the same P2 sheet (dialog from 600 up)
  the button opens; dismissing it leaves the route.

---

## Pro

* Every phone screen still matches the free build, so the fixes above apply to
  both.

### Sidebar brand, everywhere at 1440
* `Dooms…` — **fixed**. The Demo pill has left the brand row (it rides on the
  "Servers" heading in both editions) and the wordmark keeps its natural width
  with the PRO badge beside it, as P3 draws it. Covered by a test that asserts
  the paragraph is never cut, at 1100 and 1440, in Pro, with demo mode on.

### DesktopFleet (Pro)
* "Needs attention 2" clipped — **fixed** (root cause). The desktop page's
  gutter also moved inside the scroll view, so the scrollbar no longer rides
  over the last few pixels of the row.
* `ALL SERVERS` — **fixed**.
* `backup-nas unreachable` — **fixed**: `backup-nas unreachable for 2 h`. The
  fleet now uses the agent's own offline reason rather than a generic string.
* offline notice below the fold, unsorted table — **left** (seed size, and the
  table is sortable by any column).

### DesktopLogWall (Pro)
* pane badge reads `Live` for a restarting container — **fixed**: the badge
  reports the container (`Restarting`, amber) and `Live` only when it is
  running.
* extra footer line — **left** (it is true and useful).

### Real macOS launch
* "Pair a new server" twice in the Free empty state — **fixed**: the pinned
  bottom action steps aside while the list is empty. Confirmed in the relaunched
  Pro build.

---

## Tests

New `test/design_fidelity_test.dart`:

* stack and service actions on one row at 390, with the primary widest;
* the containers-pane chips on one row inside the 400 px column;
* the resource-table chips on one row above the table;
* the fleet chips and both state buttons on the filter row, inside the window;
* the desktop logs toolbar on one line at 1440, with the log surface right
  under it;
* the Pro brand row never truncated at 1100 and 1440 with demo mode on, and the
  Demo pill moved off that row;
* no overflow on eight (phone) or eleven (desktop) routes × two editions × two
  themes × 390/800/1100/1440.

`test/app_harness.dart` gained `loadAppFonts()`, and every widget suite now
calls it: the test binding otherwise measures each glyph as a square of the
font size, which makes "does this fit on one row?" meaningless.

`test/models_test.dart` gained table-driven coverage of the relative-date
ladder, the Go-duration rewriter, resolved times, month names and byte sizes,
plus the alert titles, meta lines, attention sentences and ordering, and the
activity sentences with and without this device.

`flutter analyze` is clean; `flutter test` is 169 tests green.

---

## Still differs in the regenerated pairs

Honest list, after the fixes:

1. **Live clock, drifting stats, seed volume** — all the expected differences
   from the report still apply.
2. **`Running` vs `Running · healthy`** on Container detail and the desktop
   pane header. The pill code is right; the seed gives `api-gateway` no health
   value, and giving it one would break the two boards that show `Up 3 days`
   for the same container in a list.
3. **Recent activity names the acting device** — `Image redis:7.2 pulled from
   Ops iPad` where the board writes `Image redis:7.2 pulled`. That is the rule
   as given ("when the acting device is another one, append ` from <device
   name>`"); the board's sample simply has no device on that row.
4. **Desktop and tablet subtitles drop the agent version** — the boards still
   show `Docker 27.1 · Agent 1.4.2 · up 41 days` on D1 and T1. Dropped
   everywhere per the instruction that the agent version belongs to Server
   settings.
5. **"Read-only on this phone" wraps to two lines** where the board fits one.
   The Material switch is a little wider than the board's control; the boards
   are being redrawn with switches, so this should settle then.
6. **"Open in log wall" is an icon** in the 1440 pane. The board draws the
   labelled button but clips it; the instruction was to collapse rather than
   wrap.
7. **Switches, the Appearance section, no QR button, "Needs attention" order**
   — the four decisions. The boards for switches are still the old ones.
