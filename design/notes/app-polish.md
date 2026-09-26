# App polish (app-polish round)

The items round 3 left open (`review/ROUND3.md`, "What remains" and "still there"): two new desktop boards, one name for this device, `/pair` as a dialog from 600 up, the loading capture, the rest of the stroke glyphs, the Images demo figures and two details of the phone Server settings. Desktop boards are 1440×900 with the D1 sidebar in server scope (prod-eu-1, Settings current), each with a `Light` twin made with the README's dark→light token table.

| # | File | What it shows |
|---|---|---|
| D16 | DesktopDevices | Paired devices as a table under a "‹ Server settings" header |
| D17 | DesktopActivity | The activity log, filter and chips on one row, one 46 px line per record |

Existing boards changed: `Images`, `DesktopResources` (+ Light; `DesktopJob` imports it), `DesktopFleet` (+ Light), `ServerSettings` (+ Light).

## D16 DesktopDevices

- The sub-page frame of D13 DesktopRegistries: left-aligned `<main>` (26 × 32 padding, 20 gap), "‹ Server settings" link (13 px muted, 15 px chevron) above the 28 px title "Paired devices", subtitle "3 devices hold a key for prod-eu-1". No header button: a device is paired from the device itself.
- Table in the D4 shell (radius 16, 38 px header, 46 px rows, 16 px column gap, 18 px side padding): **Device** (flex, 13 px semibold; this device adds "This device" in the accent, 12 px semibold, 10 px after the name) · **Role** (130, the status pill: Admin accent, Operator/Viewer neutral) · **Last seen** (150, muted: "just now", "1 day ago") · **Push** (90: "On" in text, "Off" muted) · the 32 px ⋮ button (36 column), which opens DeviceActions as a dialog.
- Footer line under the table (12.5 px muted): "Right-click a row to change its role or revoke it". The right-click menu is Make admin / Make operator / Make viewer / Revoke (unlink glyph, danger), with the last-admin rule disabling what the agent would refuse.
- Then the Devices info note (shield glyph), full width.
- A device without the admin role sees neither the ⋮ column nor the footer, as on the phone.

## D17 DesktopActivity

- Same header frame: "‹ Server settings", "Activity log", "Who did what on prod-eu-1, and when".
- One row: the 320 px filter field ("Filter by container, device or action", `/` hint) then the 32 px pill chips All · Denied · Errors · Mine (6 px gap).
- Day sections (TODAY, YESTERDAY: 13 px uppercase muted, 8 px above the card, 16 px between days). Each day is a bordered card (radius 16); each record is a 46 px line: time (52 px, mono 12 muted) · the sentence (13 px, one line, ellipsis) · who (200 px, 12.5 muted, "This Mac · admin") · the result pill right-aligned in 72 px (ok neutral, denied warning, error danger).
- The six records are the phone board's; this device is "this Mac" in the sentence and "This Mac" in the who column.

## This device's name

"This Mac" on macOS, "This iPad" on an iOS device whose screen's short side is 600 pt or more, "This phone" on other iOS and Android devices ("This PC" on Windows). One helper (`thisDeviceLabel`, `app/lib/data/this_device.dart`) names it for the sidebar footer, the activity sentences and who column, the Devices list and actions, Server settings ("Read-only on this Mac") and the demo seed, which pairs this device under that name. The 1440 boards say "This Mac", the phone boards "This phone".

## `/pair` from 600 up

Opened as a route (a link, a restored URL), `/pair` draws the default page (the Servers list below 1100, the fleet from 1100) and opens the pair dialog over it, exactly as the sidebar and the buttons do; at the edition's limit it opens P2 instead. Dismissing it goes back to `/`; a finished pairing goes to the new server's Overview. Below 600 it stays the pushed screen.

## Stroke glyphs

Every icon in the app is now a 24×24, 2 px stroke glyph (round caps and joins), and no Material icon is left. Where a board draws the icon, the path is the board's: more (three dots, stroke 3), play `M6 4l14 8-14 8z`, pause `M8 5v14M16 5v14`, stop (rect 5,5 14×14 r2), trash `M3 6h18M8 6V4h8v2M6 6l1 14h10l1-14`, restart `M3 12a9 9 0 1 0 3-6.7` + `M3 4v5h5`, terminal `M4 17l6-5-6-5M12 19h8`, phone (rect 7,3 10×18 r2 + `M11 18h2`), key (circle 8,15 r4 + `M11 12l9-9M16 7l3 3`), chevron right, minus. New ones drawn in the same style: history (restart + clock hands `M12 8v4l3 2`), clock, volumes (the Resources cylinder cut into three slices), networks (three nodes on one bus), link and unlink, prune (scissors), person, monitor, offline (signal arcs, struck through), bell-off. The sidebar footer draws the key.

## Images figures

The demo seed has six images; the summary is computed from them: "6 images · 1.9 GB · 597 MB unused". `Images` and `DesktopResources` (and `DesktopJob` behind its dialog) now draw those six rows and figures: chips All 6 · In use 4 · Unused 2, "Showing 6 of 6". D5's "Unused images" card reads 597 MB.

## Server settings (phone)

- The read-only switch's subtitle is "Viewer role on the agent", one line at 390 (the desktop row keeps "Sets this device to the viewer role on the agent").
- "Unpair this server" is outlined in the danger border token (`#4A2521` / light `#EBB5AE`), as drawn; so are DesktopSettings' "Unpair…" and the pane's Stop in DesktopContainers. Other danger buttons (Remove, Down, Revoke) keep the neutral outline the boards give them.

## Loading state (LoadingError)

The Overview header's pill says "Connecting" (neutral) until the agent has answered, then Online or Offline, so a slow agent is never called online before it has said anything. The `LoadingErrorLoading` capture is backup-nas's Overview with its answers held open.
