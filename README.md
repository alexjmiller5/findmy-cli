# findmy

Read Apple Find My - **People, Devices and Items** - from the macOS app, as JSON.

No Apple account login, no iCloud web API, no anisette, no AirTag key export, no
cache decryption, no SIP or AMFI changes. It reads the running Find My app's
**accessibility tree**, which is the same data the app is already showing you.

Verified on macOS 26.6 (Mac mini, always-on console session). A snapshot
scrolls each list to its end and says whether every row was proven read; see
[Coverage](#coverage). It also runs as a collector that appends one coarse,
city-grade check per resolved friend to a [soma](https://github.com/alexjmiller5/soma)
stream (see [Collector](#collector)).

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

## Coverage

The Find My lists are **virtualized**: rows scrolled out of view are removed
from the accessibility tree. A snapshot therefore drives each list: it scrolls
the list container to the top (`AXScrollUpByPage`), then pages down
(`AXScrollDownByPage`), merging every settled page onto the sequence by row
title. Each page must continue the sequence it overlaps, in order; a gap, a
reorder mid-scroll or a duplicate title fails closed. Each end needs two
scrolls that change nothing *and* positive proof from the geometry: only at
the top does the first rendered row start inside the list's frame, only at the
bottom does the last row end inside it. (Two scrolls that change nothing alone
are not proof: another reader scrolling the other way looks the same.) A list
that fails is read once more, then reported in `incomplete`. One `findmy`
process drives the UI at a time: the others wait on a per-user lock in the
Darwin user temp directory.

`coverage: {"scope": "full_list", "complete": true}` means every tab was proven
read; otherwise `complete` is false, the unproven tabs are in `incomplete`,
stderr says so and the exit code is `5`. Partial or missing output never proves
a person departed.

### Requires the Find My window on the current Space

Find My must have an open window on the Space you are viewing; the
accessibility tree exists only where the window does. If it lives on another
Space, macOS switches you there when the tool touches it. Keep Find My on the
Space you work in, or assign it to all Spaces (Dock icon → Options → All
Desktops). If Find My is not running, the tool launches it with `open -g`,
which does not take focus but makes the window appear once.

### Paused friends and the notifications sheet

A Find My launched in the background shows **Paused** on nearly every friend a
few minutes later and stops refreshing them until it has been active. When at
least half of the visible located rows read Paused, the tool makes Find My
frontmost (`AXFrontmost`) until live ages return, holds it three seconds and
hands focus back to the app that had it; a single paused friend never triggers
this. The wake usually revives it within seconds but not always (3 of 24 reads
in the cadence measurement below); then the rows stay `paused`, which is what
gets recorded. Every launch also covers the window with a notifications pitch sheet
("Enable Notifications" / "Not Now"); the tool presses Not Now. Any other sheet
blocks the read and fails with exit `4`.

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
just build                    # development binary
nix build .#default            # installed-package build (runs --selftest)
nix run . -- --selftest        # packaged parser check
```

Run `just test` for the parser self-checks (no app needed). The Nix build uses
nixpkgs' Swift and SDK; where that SDK predates macOS 26, `--geocode` uses
`CLGeocoder` instead of `MKGeocodingRequest`.

The flake exports a Darwin package and two modules; make the flake's nixpkgs
input follow your own:

- `homeModules.default`: `programs.friend-location-collector.enable` installs
  the reader only.
- `darwinModules.default`: `services.friend-location-collector` runs the
  [collector](#collector) as a launchd user agent. It installs the reader as
  `/Applications/FriendLocationCollector.app` and re-signs it at every
  activation with one self-signed identity it creates once in the System
  keychain, so its Accessibility grant survives rebuilds.

**Accessibility permission.** Launched from a terminal, the binary inherits the
terminal's Accessibility grant. The collector app needs its own grant: on its
first run it adds itself to System Settings → Privacy & Security →
Accessibility, where a human switches it on (TCC state cannot be declared).

## Usage

```
findmy [all|people|devices|items]   snapshot a tab (default: all)
findmy detail <name>                full street address for one entry
findmy collect --hub URL --token-cmd CMD --handles FILE [--stream NAME] [--every SECONDS]
                                    append coarse city checks to a soma stream
findmy --selftest                   parser self-checks

  --geocode      with `detail`, resolve lat/lon locally via MapKit
  --text         human-readable instead of JSON
  --repair       restart Find My if the UI is unreadable or (collect) has stopped refreshing
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
  "coverage": {"scope": "full_list", "complete": true},
  "incomplete": [],
  "people":  [{"name": "Jane Doe", "location": "Cupertino, CA",
               "when": "5 min. ago", "distance": "0 mi", "raw": "...",
               "source_state": "available", "source_check_id": "...",
               "checked_at": "2026-08-20T17:02:29Z"}],
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

The original `raw` text remains private output. Distances keep their
thousands separators (`"2,470 mi"`).

`source_handle_key` is a SHA-256 key only when the displayed source identity
is an explicit international phone number or email address. Phone formatting
is normalized without guessing a country; email local-part case is preserved.
Names yield no key. This is not a canonical person ID or proof of identity:
resolve it through a unique confirmed contact/account binding, reject ambiguous
or missing matches, and recheck bindings after account changes. Keys do not
replace original private labels or source-time evidence.

Each native row read includes `source_check_id` and `checked_at`. These identify
the actual accessibility check and its collection time. Serializing the same
check does not renew either value. They are not location-fix identifiers or
measured source timestamps; source age remains the original displayed text.

`source_state` distinguishes `available`, `paused`, `unavailable`,
`not_shared` (the person sees your location but shares none of theirs) and
`unknown` (no place shown, including "Locating…").
Paused rows may retain a displayed city, but do not provide fresh presence or
a source timestamp. Unavailable placeholders are not locations. `fetched_at`
is collection time; a displayed relative `when` is preserved as text and never
promoted to a measured source timestamp. Geocoded coordinates do not belong in
a measured GPS stream.

Exit codes: `2` no Accessibility grant · `3` cannot launch Find My ·
`4` UI never became readable · `5` a tab not proven completely read ·
`6` a stream append failed · `64` bad usage or unreadable handle map ·
`65` the token command failed.

## Collector

`findmy collect` reads the whole People list, resolves rows to your own person
ids through a handle map and appends one JSON record per resolved row to a
soma stream with `POST <hub>/v1/streams/<stream>/append` (one request per
record, `Authorization: Bearer <token>`). `--every SECONDS` repeats forever;
without it, one collection runs and its exit code is returned. Each collection
prints one summary line (counts, the displayed-age histogram, any error; never
identities).

```json
{"age_seconds": 120, "age_text": "2 min. ago", "checked_at": 1791573278,
 "city": "Cupertino", "country": null, "location_text": "Cupertino, CA",
 "paused": false, "person_id": "<your person id>", "region": "CA",
 "run_complete": true, "run_rows": 33, "run_unresolved": 0,
 "source": "findmy_ax", "source_check_id": "<uuid>"}
```

- **Claim grade: coarse.** `city` / `region` / `country` split the displayed
  locality (`location_text`, verbatim): a trailing two-letter code is the
  region and the part before it the city (`Place, City, ST` names a
  neighbourhood first); otherwise the first part is the city and the last the
  country. No coordinates, ever.
- **Time.** `checked_at` (unix seconds) is when the row was read; `age_text`
  is the displayed age verbatim and `age_seconds` its exact value (`Now` = 0,
  sec./min./hr./day/wk. units; months, years and `Last …` are null). Neither is
  a location-fix timestamp. `paused: true` rows and null ages are not fresh.
- **Identity.** Only rows whose `source_handle_key` (an explicit phone/email
  handle) appears in the `--handles` JSON object `{ "<source_handle_key>":
  "<person id>" }` are written. Names never match. Rows that share a location
  but do not resolve are counted in `run_unresolved`, never written; the self
  row and `not_shared` rows are neither. `run_rows` = rows that share a
  location; `run_complete` = whether the list was proven read.
- **Token.** `--token-cmd` is run with `/bin/sh -c` before every collection;
  its stdout is the token, which needs exactly `streams:append:<stream>`.
- **Freshness (measured).** 24 complete reads of a 33-friend list every ~5
  minutes for 2 h 15 min on a weekday afternoon: of 792 friend row-reads, 69%
  showed `Now`, 13% 1-4 min, 3% 5-9 min and none older (p99 6 min, max 8 min);
  in 98% of consecutive read pairs a friend's location had updated in between.
  12.5% were `Paused` (three whole reads where Find My paused app-wide and the
  wake did not revive it; the next read was live) and 2.6% showed no place.
  Proposed cutoff: a check is fresh when `paused` is false and `age_seconds`
  is at most 600, and the check is at most 15 minutes old (one 10-minute
  collection interval plus slack). Night-time cadence was not measured.

On nix-darwin:

```nix
services.friend-location-collector = {
  enable = true;
  user = "alice";
  hubUrl = "https://soma.example.workers.dev";
  tokenCommand = "/usr/bin/security find-generic-password -s friend-location-collector -a soma-hub -w";
  # handles = "/Users/alice/.local/state/friend-location-collector/handles.json";  (default)
  # stream = "friend_city_checks"; interval = 600;                                 (defaults)
  # repair = false;  true on an unattended Mac: passes --repair                   (default)
};
```

The agent (`com.alexmiller.friend-location-collector`, `KeepAlive`, GUI
session only) logs to `~/Library/Logs/friend-location-collector/collector.log`.
Store the token where the command can read it from a launchd agent; for the
login keychain, add it with `security add-generic-password -A` from a GUI
session (`-A` lets the agent read it without a prompt).

## Other limits

- **A logged-in GUI session with a real display.** A headless Mac with no
  framebuffer cannot open a Find My window, so there is nothing to read. Check
  for a framebuffer (`system_profiler SPDisplaysDataType`); an Apple-silicon
  Mac mini creates a virtual display with nothing attached, older machines may
  need a dummy HDMI plug or DeskPad. The session must also stay unlocked.
- **`--repair` is opt-in.** Find My can end up running with zero windows, which
  makes it unreadable. `activate()` usually rebuilds the window quietly; if that
  fails, `--repair` kills and relaunches, which makes the window visibly pop up.
  A long-running Find My can also stop refreshing friends while staying
  readable (seen 2026-10-12 after three days up: every age grew by the
  collection interval for an hour). With `--repair`, `collect` restarts it when
  at least three friends show an exact age and even the freshest is over 20
  minutes, at most once an hour, and logs `"restarted": "stale"`.
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
database indefinitely. The collector keeps only city-grade text and the
displayed age, never coordinates; prefer on-demand reads, or a store that keeps
only the latest check per person, where you can.

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
- The list container itself (the `AXTabGroup` sibling) carries
  `AXScrollUpByPage` / `AXScrollDownByPage`; a page scroll keeps one or two rows
  of overlap, which is what proves no row was skipped.
- `NSRunningApplication.activate()` from a CLI does not bring Find My to the
  front; setting `AXFrontmost` on its application element does, and the same
  attribute on the previous app hands focus back.

## Prior art

- [omarshahine/findmy-cli](https://github.com/omarshahine/findmy-cli) - same
  goal, screenshot + Vision OCR instead of the AX tree. Well packaged (Homebrew,
  npm, a Claude Code plugin).
- [roelvangils/airtrackr](https://github.com/roelvangils/airtrackr) - the same
  AX-tree technique, wrapped in a FastAPI + Leaflet dashboard.
- No MCP server for Find My exists in any registry, by any technique.
