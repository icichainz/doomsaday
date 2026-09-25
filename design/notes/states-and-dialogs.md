# States and dialogs

Boards for the states and dialogs the app already had but that were never drawn: empty states, the offline and loading states, job progress, the app lock, the Pro upgrade dialog and demo mode. Each board has a `Light` twin made with the README's dark to light token table (scrim `rgba(4, 7, 9, 0.72)` becomes `rgba(21, 32, 30, 0.45)`, text on accent becomes `#FFFFFF`).

| File | What it shows | Size |
|---|---|---|
| EmptyStates | The shared `EmptyView`: no servers paired, no Compose projects, nothing needs attention, not in a swarm, no filter results | 390×1400, a tall sheet of examples, not one screen |
| LoadingError | Overview of the offline `backup-nas`: header with the Offline pill, the shared `ErrorView`, and underneath the skeleton loading state of a stat card and a list row | 390×844 |
| JobSheet | Bottom sheet over `Images`: "Pulling redis:7.2" while it runs | 390×844 |
| JobDone | The same sheet once it has finished | 390×844 |
| DesktopJob | The job as a 500 px dialog over `DesktopResources` | 1440×900 |
| LockScreen / DesktopLock | The app lock | 390×844 / 1440×900 |
| ProUpgrade | What "Get Doomsaday Pro" opens today, as a sheet over `AppSettings` | 390×844 |
| MainDemo | The Servers screen in demo mode | 390×844 |

## Empty states (EmptyStates)

The `EmptyStates` board stacks five examples. The mono captions ("STACKS TAB · COMPOSE STACKS") are notes on the board, not part of the app.

- Card: surface fill, 1 px border, radius 20, padding 24/20/22, everything centred.
- Icon tile: 56 px, radius 18, icon-button fill (`#1A2429`) with a strong border (`#2A363C`), 24 px stroke icon in muted text. The **healthy** variant ("Nothing needs attention") uses the healthy tint and the accent icon, with no border, because nothing is wrong.
- Title 17/600, then one line of 14 px muted text, line height 1.5.
- An optional hint in mono (12 px) on a code-block chip: the stacks directory (`/opt/stacks`, taken from the agent's `stacks_dir`) or `docker swarm init`.
- At most two buttons. With a primary action, both fill the card: accent 52 px, radius 16, then outline 48 px, radius 16. A single secondary action ("Clear filter", "Clear search") is an outline 44 px button, sized to its label and centred.

Copy:
| Where | Title | Line | Buttons |
|---|---|---|---|
| Servers, nothing paired | No servers yet | Pair an agent, or look around with sample data. | Pair a new server, Explore with demo data |
| Stacks tab | No Compose projects on this server | Folders with a compose.yaml show up here. + `stacks_dir` | none |
| Overview "Needs attention", Alerts screen | Nothing needs attention | No alert rule has fired on this server. | none |
| Stacks tab, Swarm segment | This host is not in a swarm | Services appear once the host joins a swarm. + `docker swarm init` | none |
| Containers, search or chip leaves nothing | No matching containers | Nothing here matches that search. | Clear filter (resets both the chip and the search) |

On the Servers screen with nothing paired, the header reads "No paired agents yet". The search field is hidden, and so is the pinned "Pair a new server" bar, because the card already offers it. From 1100 up, the fleet route shows the same card, centred and at most 460 px wide.

## Error and loading (LoadingError)

- **Unreachable server**: the Overview shows the header (name, Offline pill, then `host:port` in mono where the Docker line normally goes) and **one** `ErrorView`, not one error per section. The same layout applies on desktop, in `DesktopPage` with the card capped at 560 px.
- **ErrorView**: danger-border card, radius 20. It has a 44 px danger-tint tile with the warning triangle, a title (17/600), and the agent's error code with its HTTP status in mono (`agent_unreachable · 502`). Below that is one reason line in the code/long-copy colour. Then come "Retry" (accent) and, where the fix may be in Server settings, "Server settings" (outline). The two buttons share the row, 48 px, radius 14.
  - Titles: "Agent unreachable", "Docker unavailable", "Not allowed" (401/403), "Not found", "Too many requests", otherwise "Something went wrong".
  - The reason drops any repeat of the title from the agent's message. For an unreachable agent it adds "Check that the agent is running and this device can reach the host."
- **Loading**: the shapes the content will take, as dimmed bars (`#243036`, faint bars `#1E282D`) inside the real card chrome. There is no spinner anywhere in the app; a busy button still shows its own small indicator.
  - Stat cards: label bar, figure bar and meter, in the same grid as the figures (2 columns below 1100, 4 at desktop).
  - List rows: a 36 px tile and two bars.
  - Log lines and cells: a single bar.

Every screen gets these through `AsyncSection` or the widgets themselves (`LoadingView`, `ErrorView`, `EmptyView` in `app/lib/widgets/state_views.dart`).

## Job progress (JobSheet, JobDone, DesktopJob)

- Heading: a 48 px tile (44 on desktop) and the job title in Bricolage 24 (22 on desktop). Under the title: `<server> · Running on the agent` (or Queued, Finished, Failed, Canceled).
- Tile: healthy tint with the download arrow while the job runs, the tick when it finishes, the danger tint with the warning triangle when it fails.
- Progress bar (6 px). Under it, the percentage on the left, but only when the agent reports one (otherwise "Working" or "Waiting"), and `m:ss elapsed` in mono on the right. Elapsed time counts from the job's `started_at` (or `created_at`) and stops at `finished_at`.
- Progress lines: the last five, in 12 px mono on the code-block fill, radius 16 (12 on desktop).
- Buttons while running: "Cancel" (outline) beside "Run in background" (accent). On the phone they share the row at 54 px; on desktop they are 40 px, aligned right. "Run in background" closes the sheet and the job carries on. The app keeps following it, refreshes the server's screens and shows a snackbar ("Pulling redis:7.2: done") when it ends.
- "Cancel" is shown only when the agent can cancel. The agent's job manager has `Cancel`, but API revision 1.1 has no HTTP route for it. So `HttpAgentApi.canCancelJobs` is false and a real agent shows "Run in background" alone, full width; demo mode can cancel. When the route exists, set `canCancelJobs` and implement `cancelJob`.
- **Finished** (JobDone): tick tile, `<server> · Finished`, a full bar, "Finished without errors" in accent where the percentage was, the elapsed time frozen, and one accent "Done".
- **Failed** (in these notes, not drawn): danger tile, `<server> · Failed`, a danger bar stopped where the job failed, and the agent's error code in mono danger where the percentage was (`registry_auth_failed`, `job_canceled`). Below that, a danger-tint note with the agent's message, then "Show details" (outline) and "Done" (accent). "Show details" swaps in every progress line, scrollable up to 260 px, and the button goes away.
- Desktop: the same content as a centred 500 px dialog (radius 20, strong border) from 600 up. The board draws it over `DesktopResources`, where a pull is started, rather than `DesktopOverview`.

## App lock (LockScreen, DesktopLock)

Nothing of the app is built behind it; the ground colour is all there is.

- In the centre: the 72 px brand tile (radius 20, "D" in Bricolage 40), then "Unlock Doomsaday" (Bricolage 24), then one line: "Your servers stay out of sight until you unlock."
- The brand tile follows the edition. `LockScreen` and `DesktopLock` draw Free's accent tile with a dark "D"; `LockScreenPro` and `DesktopLockPro` (added at integration, each with a `Light` twin) draw the Pro build's deep-red `#9E1B1B` tile with an ivory `#FAF3E8` "D", as P3 draws the Pro brand. Each build's capture pairs against its own boards.
- One accent button: "Unlock with fingerprint or face" on a phone (full width, 56 px, radius 18) and "Unlock with Touch ID" on a Mac or iPhone (320 px, 44 px, radius 12 on desktop).
- Refusal: if the prompt is cancelled or fails, the line becomes **"That did not unlock. Try again."** in danger colour, and the button stays.

## Pro upgrade (ProUpgrade)

This is what "Get Doomsaday Pro" and "Get Pro" open in the Free build today. It is a sheet below 600; from 600 up it is a centred **460 px dialog** (not drawn) with the same content, a 44 px tile, a 22 px title and a 40 px "Got it" on the right.

- The PRO tile: 48 px, deep red `#9E1B1B`, "PRO" in ivory, 12 px, weight 600. It stays the same in the light theme.
- Title "Doomsaday Pro is not on sale yet", then: "There is no store listing to send you to. When Pro arrives it adds these, and nothing you have paired changes."
- The feature list, each item with a 36 px icon tile, a 15/600 title and one muted line:
  - Unlimited servers (Free pairs two)
  - All servers
  - Log wall
  - Cross-server search
- A single accent **"Got it"**.
- The store buttons are **absent, not disabled**: a greyed-out "Buy" promises something that cannot be done. When the listings exist, "Get Doomsaday Pro" (accent) goes above "Got it", and "Got it" becomes "Not now" (outline). The one place to change is `openProUpgrade()` in `app/lib/edition/pro_badge.dart`.

## Demo mode (MainDemo)

- Header line: "Demo data · 3 sample agents · 2 online". It is too long to sit beside the two 48 px buttons, so in demo mode it runs full width **under** the title row. The normal "3 paired agents · 2 online" stays where `Main` has it.
- Bottom bar: "Pair a new server" (accent, fills the space) and "Leave demo" (outline, sized to its label, with the leave icon). Both are 56 px, radius 18, 8 px apart.
- Desktop (not drawn): the amber **Demo** pill (warning tint, warning text, 12/600, radius 999) sits on the sidebar's "Servers" label, where Free would otherwise say "· 2 of 2 on Free". Demo mode is not limited, so that count is not shown.

## Glyphs added to the stroke set

`search`, `checkCircle`, `check`, `nodes` (Swarm), `download`, `warning`, `fleet` (four equal squares), `leave`. Each glyph uses the same path in the boards and in `app/lib/widgets/stroke_icons.dart`. At integration `check` became the existing boards' tick (`M5 12l5 5 9-10`, as on Alerts and ProLocked), and the JobDone boards draw that path.
