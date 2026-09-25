# Design source

Exported from the design canvas: https://claude.ai/artifact/84qKgXLQmEDG1bG4SW9mG7

Each `*.dc.html` file is one 390×844 phone screen written as plain HTML with inline styles, so exact sizes, paddings, radii and colours can be read straight from the markup. `X.dc.html` is the dark theme and `XLight.dc.html` is the same screen in the light theme. `canvas.json` holds the screen order and titles. Sample data for list screens sits in the `renderVals()` script at the bottom of the file.

## Screens

| # | File | Screen | Reached from |
|---|---|---|---|
| 1 | Main | Servers | App start, Servers tab |
| 2 | PairAgent | Pair an agent | Servers: add button |
| 3 | Dashboard | Server overview | Servers: tap a server, Overview tab |
| 4 | Alerts | Alerts and rules | Overview: bell, "All alerts" |
| 5 | Containers | Containers | Containers tab |
| 6 | ContainerDetail | Container detail | Containers: tap a row |
| 7 | ConfirmStop | Confirm a risky action (bottom sheet) | Container detail: Stop |
| 8 | Logs | Live logs | Container detail: Logs |
| 9 | Stacks | Compose stacks | Stacks tab |
| 10 | Services | Swarm services | Stacks tab: second segment |
| 11 | Images | Images | Resources tab |
| 12 | Volumes | Volumes | Resources tab: second segment |
| 13 | Networks | Networks | Resources tab: third segment |
| 14 | ServerSettings | Server settings | Overview: settings button |
| 15 | Registries | Registry credentials | Server settings |

Tab bar (inside a server): Overview, Containers, Stacks, Resources, Servers.

## Tokens

Type: Bricolage Grotesque 700 for titles and big figures, IBM Plex Sans 400/500/600 for text, IBM Plex Mono 400/500 for IDs, image names, commands and logs.

| Role | Dark | Light |
|---|---|---|
| Ground | `#0E1417` | `#F3F5F4` |
| Surface (cards) | `#161E22` | `#FFFFFF` |
| Tab bar | `#121A1E` | `#FFFFFF` |
| Icon button fill | `#1A2429` | `#E9EEEC` |
| Code block, log area | `#0A0F11` | `#E9EEEC` |
| Info note fill | `#131B1F` | `#EAF0EE` |
| Text | `#E8EEF0` | `#15201E` |
| Muted text | `#9AAAB1` | `#55656B` |
| Code and long copy | `#C9D6DB` | `#2B3A3F` |
| Faint divider | `#1E282D` | `#E4E9E8` |
| Border, progress track | `#243036` | `#DCE3E1` |
| Strong border, active segment | `#2A363C` | `#CFD8D6` |
| Outline button border | `#3A4A52` | `#B5C2BF` |
| Accent, healthy | `#5BE3B0` | `#0B7A5C` |
| Text on accent | `#0E1417` | `#FFFFFF` |
| Healthy tint | `#15302A` | `#D9F2E8` |
| Warning / tint / border | `#F2B45A` / `#33290F` / `#4A3B17` | `#8A5200` / `#FBEBC8` / `#E8CF94` |
| Danger / tint / border | `#FF8A7D` / `#3A1C19` / `#4A2521` | `#B3261E` / `#FCE1DD` / `#EBB5AE` |
| Text on danger fill | `#1A0B09` | `#FFFFFF` |
| Info (log INFO level) | `#6CB8FF` | `#1F5FBF` |

Radii: cards 20, small cards 16 to 18, buttons 12 to 18, pills 999. Screen side padding 20. Minimum touch target 44.

Toggles are switches (46×28 track, 22 px knob; accent track when on, `#2A363C` when off), not checkboxes. "Needs attention" lists critical items first, then warnings, then most recent. The Pair screen has no QR button, since the agent prints a token, not a QR code.

## Desktop and tablet (adaptive layout)

Files `Desktop*.dc.html` (dark) and `Desktop*Light.dc.html` (light). Desktop boards are 1440×900, the tablet board is 834×1194. Same tokens and type as the phone.

| # | File | What it shows |
|---|---|---|
| D1 | DesktopOverview | Sidebar shell and the server overview: 4 stat cards in a row, busiest-containers table, needs attention and recent activity in a right column |
| D2 | DesktopContainers | Split view: container list (400 px) on the left, selected container on the right with actions, 4 mini stats, and Logs / Details / Environment / Shell as tabs in the pane |
| D3 | DesktopConfirm | Risky action as a centred 500 px dialog. No Touch ID on this Mac, so the user types the container name; the request shows `X-Confirmed: typed` |
| D4 | DesktopResources | Images as a sortable table with filter, chips, Prune unused and Pull image |
| D5 | DesktopFleet | "All servers": fleet stat cards and one container table across every paired server, with a Server column and an offline-server notice |
| D6 | DesktopLogWall | Log wall: 2×2 grid of live log panes from different containers and servers, each with pause and close |
| T1 | DesktopTablet | Tablet: 92 px icon rail instead of the bottom bar, 2×2 stat cards, two-column sections, a compact table |

### Breakpoints (by window width, not by platform)

| Width | Navigation | Content |
|---|---|---|
| under 600 | Bottom bar (phone design) | Single column, pushed screens, bottom sheets |
| 600 to 1099 | 92 px rail with icon and label (T1) | Single column capped at about 720 px, stat cards 2×2, two-column sections where they fit, sheets become centred dialogs |
| 1100 and up | 264 px sidebar (D1) | Split views, tables, dialogs, desktop extras |

### Sidebar (1100 and up)

Brand, then **Servers**: "All servers" (with "2 of 3" online), one row per paired server with a status dot and running count, "Pair a server". Below that the sections of the selected scope. For one server: Overview, Containers, Stacks, Resources, Alerts (count badge), Settings. For "All servers": Containers, Log wall, Alerts. Footer: this device and its role. The phone's separate Servers start screen is not used at this width.

### Desktop behaviour

- Compact density with a pointer: rows 44 to 52 px, buttons 36 px, icon buttons 32 to 36 px. Touch sizes (44 px minimum) stay below 1100.
- Hover state on rows and buttons, visible keyboard focus, right-click context menu on table and list rows (the same actions as the row's more button).
- Shortcuts: Cmd+K opens "Jump to a container, stack or server", `/` focuses the screen's filter field, Esc closes a dialog or clears the selection, Return confirms a dialog.
- Logs, IDs, image names and commands are selectable text.
- Pushed phone screens become in-place panes or dialogs: container detail is the right pane, logs and shell are tabs in it, confirm sheets and job progress are centred dialogs.

## Editions: Free and Pro (two flavors of one app)

Boards: `IconFree`, `IconProIvory` (the chosen Pro icon; `IconProDark` and `IconProMint` were rejected alternatives), `IconSizes`, `ProLocked` (P1), `ProLimit` (P2), `ProBrand` (P3).

| | Free | Pro |
|---|---|---|
| Name under the icon and in the app | Doomsaday | Doomsaday Pro |
| Icon background | `#0E1417` | deep red `#9E1B1B` |
| Icon mark | mint `#5BE3B0` | ivory `#FAF3E8` |
| Same mark geometry | yes, `app/tool/generate_icon.py` | yes |

**Pro red is for the icon and brand tile (sidebar brand, app lock), the PRO badge, the lock tile and the Pro upgrade tile only.** The interface accent stays mint in both editions, and coral stays reserved for danger, so "Pro" never reads as "error".

**PRO badge**: small rounded rectangle, radius 6, fill `#9E1B1B`, text `#FAF3E8`, 10.5 px, weight 600, letter-spacing 0.6, text "PRO". Same colours in the light theme.

### What Free limits

| Capability | Free | Pro |
|---|---|---|
| Paired servers | 2 | unlimited |
| All servers view (fleet containers and fleet alerts) | locked | yes |
| Log wall | locked | yes |
| Cmd+K palette | current server only | every server |
| Everything else (all management, security, themes, desktop layout) | yes | yes |

Demo mode is not limited: it may show all three sample servers in either edition.

### How Free shows what Pro adds (locked features stay visible)

- **Sidebar (P1)**: "All servers", the "Across all servers" items and "Pair a server" (once 2 are paired) carry the PRO badge. The server label reads "Servers · 2 of 2 on Free". The footer adds "· Free".
- **Opening a locked feature (P1)**: the page renders its header with a PRO badge, a dimmed skeleton of the feature behind, and a centred 460 px panel: deep-red lock tile, "<Feature> is part of Doomsaday Pro", the reassurance line "Your servers and containers stay fully usable on Free.", three bullets, and two buttons, "Get Doomsaday Pro" (accent) and "Not now".
- **Pairing a third server (P2)**: the pair action opens a sheet (dialog from 600 px) "Free covers 2 servers" naming the two paired servers, with "Get Doomsaday Pro" and "Not now", and the hint that unpairing one makes room.
- **Pro build (P3)**: the sidebar brand is the deep-red "D" tile, "Doomsaday", and the PRO badge. Nothing is locked.

## App preferences (app-wide, not per server)

Boards: `AppSettings` (phone, 390×1320, the screen scrolls) and `DesktopPreferences` (D7, dialog), each with a `Light` twin. **Server settings** is about one agent (version, certificate, registries, alert rules, devices, fingerprint rule, read-only, unpair). **Preferences** is about this app on this device, across every server. The theme switch lives in Preferences only; Server settings no longer has an Appearance section.

Entry points, always a cog icon labelled "Preferences":
- Phone: a 48 px icon button in the Servers screen header, left of the add button.
- Tablet (600 to 1099): a rail item "Preferences" under "Servers".
- Desktop (1100 and up): a 32 px icon button at the right of the sidebar footer, in every scope. On macOS also the standard app-menu item "Settings…" with Cmd+, .
- Below 600 it is a pushed screen with a back link to Servers. From 600 it is a dialog (680×520 on the board): section list on the left (Appearance, Security, Live data, General, About), the selected section on the right, close button and Esc.

Contents:
| Section | Setting | Values (default first) |
|---|---|---|
| Appearance | Theme | System, Light, Dark |
| Appearance | Density | Automatic, Comfortable, Compact. Automatic = compact at 1100 and up with a pointer, comfortable otherwise |
| Security | Unlock with fingerprint or face (Touch ID on a Mac) | Off, On. Asked when the app opens and after 5 min in the background. Hidden when the device has no biometrics |
| Live data | Refresh stats every | 5 s, 2 s, 10 s |
| Live data | Log lines kept per stream | 2,000, 500, 10,000 |
| General | Open the app on | Last server, Servers list |
| General | Demo data | Off, On (same as "Explore with demo data" and "Leave demo") |
| Edition | Doomsaday Free with "n of 2 servers paired" and a "Get Pro" button; in Pro just "Doomsaday Pro" | |
| About | Version and agent API version; open-source licences | |

## Round 3: the screens and states that had no board

Three rounds drew what the app already did but no board showed, then aligned the app to the boards. Every board below has a `Light` twin. Full detail per board (copy, states, measurements) is in `notes/phone-screens.md`, `notes/states-and-dialogs.md` and `notes/desktop-tablet.md`; this section is the summary and the rules the three now share.

### Phone screens (390×844)

| # | File | Screen | Reached from |
|---|---|---|---|
| 16 | Shell | Container shell, connected (key row, input row, session pill) | Container detail: Shell (admin, running) |
| 17 | Devices | Paired devices | Server settings: Paired devices |
| 18 | DeviceActions | Role and revoke sheet, last-admin rule drawn | Devices: a row's more button |
| 19 | Activity | Activity log grouped by day, filter and chips | Server settings: Activity log |
| 20 | PairConfirm | Certificate step as a sheet over Pair | Pair: "Test connection and pair" succeeded |
| 21 | PairError | Pair with the red failure card and "Try again" | Pair: failed |
| 22 | ContainerDetailEnv | Environment and volumes sheet | Container detail: Environment or Volumes |

### States and dialogs

| File | What it shows | Size |
|---|---|---|
| EmptyStates | The shared `EmptyView`, five examples (a tall sheet, not one screen) | 390×1400 |
| LoadingError | Offline server: one `ErrorView`, and the skeleton loading state | 390×844 |
| JobSheet / JobDone | Job progress sheet, running and finished | 390×844 |
| DesktopJob | The job as a 500 px dialog over D4 | 1440×900 |
| LockScreen / DesktopLock | App lock, Free build (mint tile) | 390×844 / 1440×900 |
| LockScreenPro / DesktopLockPro | App lock, Pro build (deep-red tile, ivory "D") | 390×844 / 1440×900 |
| ProUpgrade | "Doomsaday Pro is not on sale yet" sheet (460 px dialog from 600) | 390×844 |
| MainDemo | Servers in demo mode, "Leave demo" | 390×844 |

### Desktop (1440×900) and tablet (834×1194)

| # | File | What it shows |
|---|---|---|
| D8 | DesktopStacks | Compose stacks, cards in 2 columns, segmented control for Swarm |
| D9 | DesktopVolumes | Volumes table in D4's frame |
| D10 | DesktopNetworks | Networks table in D4's frame, Default / In use / Unused |
| D11 | DesktopAlerts | Alert cards in 2 columns, resolved notes, rules table below |
| D12 | DesktopSettings | Server settings in a left-aligned 720 px column |
| D13 | DesktopRegistries | Registry cards in 2 columns, "‹ Server settings" link |
| D14 | DesktopPair | The 560 px pair dialog on step 2 of 2, the certificate |
| D15 | DesktopPalette | Cmd+K hanging from the top, grouped results (Free: current server, "Search every server" row) |
| T2 | TabletContainers | Containers at tablet width, filter and chips on one row, 52 px rows |
| T3 | TabletStacks | Stacks at tablet width, "Pull and redeploy" on its own row |

From 600 to 1099 every page uses T1's 28 px padding and 28 px title.

### Rules the three rounds share

- **State views.** Every screen uses the one set in `app/lib/widgets/state_views.dart`: `LoadingView` (skeleton bars in the real card chrome; no spinner anywhere except inside a busy button), `ErrorView` (one per screen, danger-border card, "Retry", "Server settings" where it helps), `EmptyView` (56 px tile, title, one line, optional mono hint, at most two buttons; the healthy tone for "Nothing needs attention").
- **No-results copy.** A filter or search that leaves nothing reads "No matching <things>" / "Nothing here matches that search." (Containers, Servers, Images, Volumes, Networks, fleet containers, Activity), with "Clear filter" where there is state to reset. Logs keep their own line, which quotes the text.
- **Filter field.** One widget (`FilterField`): 36 px, radius 10, 13 px text and the `/` hint with a pointer (D2, D4, D9, D10); 44 px, radius 12 on touch, with 14 px text, 12 px sides and a 16 px glyph on the phone (Logs, Activity) and 15 px text, 14 px sides and a 17 px glyph on the tablet (T2). No `/` hint on touch.
- **Icons.** The stroke set (`StrokeIcon`) wherever a glyph exists, with the same paths as the boards: the nav glyphs, `cog`, `sun`, `lock`, `pulse`, `info`, `arrowRight`, `command`, `search`, `checkCircle`, `check`, `nodes`, `download`, `warning`, `fleet`, `leave`, `shield`, `shieldCheck`, `shieldX`, `close`, `chevronLeft`, `plus`, `copy`, `arrowUp`, `arrowDown`, `returnKey`. Material icons remain only where the set has none (play, stop, pause, trash, more, history, volumes, networks and a few others).
- **Sheets and dialogs.** Below 600 a bottom sheet (radius 28 top, handle); from 600 a centred dialog: 500 px for confirms, prompts and job progress (D3, DesktopJob), 460 px for the Pro panels (P1, P2, ProUpgrade), 560 px for the pair dialog and the palette, 680×520 for Preferences.
- **Scrim.** Under every sheet, dialog and the palette: `rgba(4, 7, 9, 0.72)` dark, `rgba(21, 32, 30, 0.45)` light (the `scrim` token).
- **Card density.** From 600 up cards are radius 16, padding 16 × 18, title 16 px; card buttons are 36 px, radius 10, 13 px with a pointer and 44 px, radius 12, 14 px on touch.
- **Pairing.** One certificate step on every width: "Trust this certificate?", the same sentence, the fingerprint exactly as the agent prints it (four lines of two colon groups, selectable), then Agent version, Your role, Device id. The phone shows it as a sheet (PairConfirm), from 600 as step 2 of the one pair dialog (DesktopPair). Failures use PairError's titles on every width. In demo mode "Pin and pair" adds a sample server.
- **Device nouns.** "This phone" / "this Mac" follows the platform everywhere; counts say "devices" ("3 devices" on Server settings).
- **Editions.** The brand tile follows the edition wherever it appears (sidebar, app lock): mint in Free, deep red with an ivory "D" in Pro.
