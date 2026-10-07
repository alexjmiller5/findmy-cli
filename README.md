# findmy

Read Apple Find My - **People, Devices and Items** - from the macOS app, as JSON.

No Apple account login, no iCloud web API, no anisette, no AirTag key export, no
cache decryption, no SIP or AMFI changes. It reads the running Find My app's
**accessibility tree**, which is the same data the app is already showing you.

Built as a spike. Verified on macOS 26.1 (build 25B78). **Read the Known bugs
section before trusting its output** - snapshots cover visible rows only and explicitly report incomplete coverage.

```console
$ findmy --text
People:
  Me, Cupertino, CA
  Jane Doe, Cupertino, CA , 1 min. ago, 0 mi
Devices:
  Sam's iPhone, Infinite Loop, Cupertino , Now, 0 mi
Items:
  Keys, Home , Last mo., 30 mi

$ findmy detail "Sam's iPhone" --geocode --text
Sam's iPhone
  Sam's iPhone, Infinite Loop, Cupertino , Now, 0 mi
  address: 1 Infinite Loop, Cupertino, CA 95014
  coords:  37.3317504, -122.0301353
```

## Known bugs

### 1. Only reads what is currently rendered

The Find My list is **virtualized**: rows scrolled out of view are removed from
the accessibility tree entirely, and rows below the fold were never in it. A
snapshot therefore returns only the visible window of each list. It reports
`coverage: {"scope": "visible_only", "complete": false}`, lists the requested
tabs in `incomplete`, warns on stderr and exits `5` even when those rows are readable.

Measured on a People list with at least 31 entries: a fresh read returned 16
rows; scrolling to the bottom returned 15 rows that were *entirely different*
(the first 16 had disappeared from the tree). The explicit coverage fields distinguish this lower bound from a complete list.

This affects every tab, and it scales with window height - a taller window shows
more. **Any count this tool reports should be treated as a lower bound.**

Fixing it means driving the list: read, `AXScrollDownByPage` on the list
container, re-read, and union the rows until the set stops growing - with
de-duplication, since a row's `when`/`distance` text changes between reads.

### 2. Requires the Find My window on the current Space, and will pull you to it

Find My must have an open window, and that window must be on the Space you are
currently viewing. If it lives on another Space (or a fullscreen desktop), macOS
switches you to that Space when the tool touches the window - a jarring, visible
context switch in the middle of whatever you were doing.

There is no per-Space read that avoids this: the accessibility tree only exists
where the window does. Mitigations are all placement-based - keep Find My on the
Space you work in, or assign it to all Spaces (Dock icon → Options → All
Desktops).

Related, and separate: if Find My is not running at all, the tool launches it
with `open -g`, which does not take keyboard focus but does make the window
visibly appear once.

## Why this approach

Everything else that reads Find My has a worse tradeoff:

| Approach | People? | Cost |
|---|---|---|
| **This (accessibility tree)** | yes | Accessibility grant; needs a visible window; truncates (bug #1) |
| FindMy.py / pyicloud | **no** | Apple login, anisette, account-ban risk |
| findmy-cli (screenshot + OCR) | yes | Screen Recording grant, steals focus, awake display, OCR errors |
| Decrypt `LocalStorage.db` | yes, with true GPS | one-time SIP + AMFI disable |

The library routes cannot see shared-people locations at all. The decrypt route
gets richer data (true lat/lon, speed, motion) but costs a recovery-mode reboot.
Notably it also has no truncation problem, since it reads a database rather than
a rendered list.

## Build & install

```sh
just build                    # or: swiftc -O findmy.swift -o findmy
cp findmy ~/.local/bin/       # anywhere on PATH
```

Run `just test` for the parser self-checks (no app needed).

**Accessibility permission.** Launched from a terminal, the binary inherits the
terminal's existing Accessibility grant and needs no setup. Run from launchd or
any non-granted parent, it needs its own grant in System Settings → Privacy &
Security → Accessibility - TCC state that cannot be declared in nix, and which is
per-binary, so it must be re-granted if the path changes. On macOS 26.1 bare Unix
executables reportedly may not appear in that pane at all
([Apple Forums 807323](https://developer.apple.com/forums/thread/807323)), in
which case the binary needs wrapping in a signed `.app` bundle.

## Usage

```
findmy [all|people|devices|items]   snapshot a tab (default: all)
findmy detail <name>                full street address for one entry
findmy --selftest                   parser self-checks

  --geocode      with `detail`, resolve lat/lon locally via MapKit
  --text         human-readable instead of JSON
  --repair       restart Find My if the UI is unreadable
  --launch=no    never launch Find My; fail if it is not ready
```

`detail` prefers an exact label, then accepts a unique name prefix, case- and
apostrophe-insensitive. Ambiguous prefixes fail without selecting an entry.
Selection and detail-opening must succeed; address labels come only from one
scoped detail popover. Missing or changed native UI fails without reading an
address from the list or another pane.

### Output

```json
{
  "fetched_at": "2026-08-20T17:02:31Z",
  "people":  [{"name": "Jane Doe", "location": "Cupertino, CA",
               "when": "5 min. ago", "distance": "0 mi", "raw": "..."}],
  "devices": [...],
  "items":   [...]
}
```

Each output record belongs to one native `HomeElementCell`. Compact and
expanded accessibility trees are supported: expanded title, subtitle and
distance fields are assembled only within that cell. `raw_fields` preserves
those exact source labels; `raw` is their assembled parsing representation.
Nested text fragments and unrelated panes are not extra people. A duplicate
field makes that row unreadable; snapshots remain explicitly incomplete.

Visible-list snapshots always declare incomplete coverage and exit `5`.
Unreadable tabs also produce a specific warning. Partial or missing output must
never prove a person departed. The original `raw` text remains private output.

`source_handle_key` is a SHA-256 key only when the displayed source identity
is an explicit international phone number or email address. Phone formatting
is normalized without guessing a country; email local-part case is preserved.
Names yield no key. This is not a canonical person ID or proof of identity:
resolve it through a unique confirmed contact/account binding, reject ambiguous
or missing matches, and recheck bindings after account changes. Keys do not
replace original private labels or source-time evidence.

`source_state` distinguishes `available`, `paused`, `unavailable` and `unknown`.
Paused rows may retain a displayed city, but do not provide fresh presence or
a source timestamp. Unavailable placeholders are not locations. `fetched_at`
is collection time; a displayed relative `when` is preserved as text and never
promoted to a measured source timestamp. Geocoded coordinates do not belong in
a measured GPS stream.

Exit codes: `2` no Accessibility grant · `3` cannot launch Find My ·
`4` UI never became readable · `5` incomplete visible-list coverage or unread tabs.

## Other limits

- **A logged-in GUI session with a real display.** A headless Mac with no
  framebuffer cannot open a Find My window, so there is nothing to read. Check
  with `ioreg -c AppleDisplay -r | grep -c AppleDisplay` (must be ≥ 1); a ~$10
  dummy HDMI plug or DeskPad solves it. Untested on the mini.
- **`--repair` is opt-in.** Find My can end up running with zero windows, which
  makes it unreadable. `activate()` usually rebuilds the window quietly; if that
  fails, `--repair` kills and relaunches, which makes the window visibly pop up.
- **Addresses, not GPS.** `detail` gives a street address and `--geocode` turns
  it into building-level coordinates. That is not a GPS fix.
- **Some entries have no address.** Find My intermittently reports "Address
  Unavailable" / "No location found"; `detail` reports that rather than inventing
  a location.
- **Apple can break this** by restructuring the Find My UI. It fails loudly. AX
  labels survive redesigns better than OCR, but they are not an API.

## Privacy

This surfaces other people's live locations. They consented to you seeing them in
the Find My app; that is not the same as consenting to being logged into a
database indefinitely. Prefer on-demand reads, or keep only the latest row per
person rather than a history.

## Implementation notes

Load-bearing and non-obvious, kept so they are not rediscovered the hard way:

- Launch must go through `open -g`. `NSWorkspace.openApplication(activates:
  false)` starts the process but never builds a window, leaving a permanently
  empty AX tree.
- Never `hide()` the app to hand focus back - a hidden app tears down its AX tree
  and the next run reads nothing.
- Each tab must be confirmed selected (`AXValue == 1`) *and* its rows must differ
  from the previous tab's before being recorded. A press that silently no-ops
  otherwise files the previous tab's rows under the next tab's name.
- Rows are read only from the container that is the sibling of the `AXTabGroup`.
  Reading the whole window pulls an open detail pane's labels in as extra rows.
  Do not fall back to a whole-window read when that container is missing - during
  a tab transition it briefly vanishes, and the larger set never settles.
- Back-to-back invocations can catch the UI mid-transition; a failed tab is
  retried once after bouncing to another tab.
- Run it as a compiled binary. The same code as `swift findmy.swift` fails on the
  launch path with `-25204 cannotComplete`.

## Prior art

- [omarshahine/findmy-cli](https://github.com/omarshahine/findmy-cli) - same
  goal, screenshot + Vision OCR instead of the AX tree. Well packaged (Homebrew,
  npm, a Claude Code plugin).
- [roelvangils/airtrackr](https://github.com/roelvangils/airtrackr) - the same
  AX-tree technique, wrapped in a FastAPI + Leaflet dashboard.
- No MCP server for Find My exists in any registry, by any technique.
