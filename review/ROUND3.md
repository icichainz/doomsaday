# Round 3: integration review

`phone-screens`, `states-and-dialogs` and `desktop-tablet` merged into `main`, fused, and compared again. Every board was rendered (`node review/tools/render_design.mjs`, 112 boards). All four harness files (`screens_test.dart` and `screens_{phone_screens,states_and_dialogs,desktop_tablet}_test.dart`) were run for both flavors. `node review/tools/make_pairs.mjs` composed 144 pairs (64 free, 80 pro) with no skips.

Verdicts are per board. The dark pair was examined for each; for the Light twins, PairConfirmLight, JobDoneLight and LockScreenProLight were checked, and those three agree with their dark verdicts. For boards captured in both flavors, the listed flavor was reviewed. The other flavor differs only in the brand tile and the PRO markers.

## New boards

| Board (+ Light) | Verdict | Note |
|---|---|---|
| Shell | match | Terminal, note, key row and input row are identical. |
| Devices | match | Rows, pills, more buttons and note all line up. |
| DeviceActions | match | The sheet sits about 25 px higher (its content is a few px taller); the content is the same. |
| Activity | match | Filter field is now 44/14, as on the board. |
| PairConfirm | match | Both board and app were updated at integration to the shared certificate step (colon groups, "Trust this certificate?"). |
| PairError | minor diff | The install command wraps at a different character (app "…/ install.sh", board "…/insta ll.sh"). |
| ContainerDetailEnv | minor diff | Env rows are about 1 px taller in the app, and there is more space around the mount arrow. The copy glyph now matches. |
| EmptyStates | minor diff | The board is a sheet of five examples; the app capture can only show the first one (Servers, nothing paired), which matches. |
| LoadingError | minor diff | The error part matches. The board's "while loading" strip is an annotation and is not part of the screen. |
| LoadingErrorLoading | **mismatch (capture)** | This pairs the LoadingError board against the Servers list while it loads, so two different screens are compared. The skeleton style (bars in real card chrome, no spinner) agrees with the board. |
| JobSheet | match | |
| JobDone | minor diff | The app keeps its last five progress lines, which starts one line earlier, and the long "Status:" line wraps. |
| DesktopJob | minor diff | The dialog matches. The table behind it is the demo's 6 images, where the board draws 10 of 23. |
| LockScreen / DesktopLock (Free) | match | |
| LockScreenPro / DesktopLockPro (Pro, new) | match | Deep-red tile with an ivory "D". |
| ProUpgrade (Free) | match | |
| MainDemo | match | |
| DesktopStacks | match | |
| DesktopVolumes | match | |
| DesktopNetworks | match | |
| DesktopAlerts | match | The resolved note shows the demo's live time. |
| DesktopSettings | match | |
| DesktopRegistries | match | |
| DesktopPair | minor diff | The dialog matches. The fleet table behind it lists different demo rows. |
| DesktopPalette | match (pro) / minor diff (free) | On Free, the harness's four ↓ presses select web-platform, because only one server row exists. The "Search every server" row and the "prod-eu-1 only" footer are as the notes say. |
| TabletContainers | match | In the Pro build the rail tile is red, following the edition rule. |
| TabletStacks | match | |

Totals across 29 board rows: **20 match, 8 minor diff, 1 mismatch** (LoadingErrorLoading, a capture problem rather than an app one). The 56 new board files include the 4 LockScreenPro/DesktopLockPro files added here.

## Regression spot-check (old boards)

I checked 10 old pairs: Main, Dashboard, Containers, Stacks, ServerSettings (free), DesktopOverview, DesktopContainers, DesktopResources, DesktopFleet (pro) and AppSettings (free). The fusion caused no regressions. ServerSettings now says "3 devices" on both the board and the app.

Found and fixed during the review:
- **Light-theme scrim**: sheets and dialogs dimmed with the dark scrim in the light theme. Added a `scrim` token, `rgba(21,32,30,0.45)` in light. It now drives `showAdaptiveModal`, the bottom-sheet theme, Preferences, the palette and the Pro panel. JobSheetLight, JobDoneLight and PairConfirmLight now match.
- **Copy button glyph**: the boards draw a stroke "copy" icon, but the app used a Material one. Added `StrokeGlyph.copy`, used on the environment sheet and the install command.
- **JobDone tick**: the board used a different tick path from the rest of the boards. It is now the shared `M5 12l5 5 9-10`.
- **The nine states-and-dialogs boards (plus their Light twins)**: `<title>` was "Container logs" and `<helmet>` was never closed. Both are fixed.

These differences existed before this round and are still there:
- The Images demo data shows 6 images under a subtitle that says 23 (DesktopResources, DesktopJob).
- ServerSettings (phone): the "Read-only on this phone" subtitle wraps to two lines, and the Unpair button border is neutral where the board draws it danger.
- The sidebar footer icon is Material `link`; the boards draw a key.

## What remains

- On desktop, Devices and Activity are centred 720 px pages with no "‹ Server settings" link, while DesktopRegistries and DesktopSettings are left-aligned. They have no desktop board yet.
- In demo mode the self device is called "This phone" on a Mac (seed data), while the activity sentences say "this Mac".
- `/pair` opened directly as a route from 600 up shows the bare pushed page, not the dialog (Preferences does show its dialog over a page). The sidebar and buttons do open the dialog.
- LoadingErrorLoading should capture the Overview of backup-nas while it loads, so it pairs against the same screen.
- Material icons remain where the stroke set has no glyph: play, stop, pause, trash, more, history, volumes, networks, and the context-menu actions.
