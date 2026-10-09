# findmy-cli

A macOS CLI that reads Find My (People / Devices / Items) out of the Find My
app's accessibility tree and prints JSON, and a collector (`findmy collect`)
that appends one city-grade check per resolved friend to a soma stream. Single
Swift file, no dependencies. The installed package and app are named
`friend-location-collector`.

## Layout

- `findmy.swift` - the entire program (parser, AX reader, enumeration, collector)
- `nix/package.nix` - Darwin package; its check phase runs `--selftest`
- `nix/home-module.nix` - `programs.friend-location-collector.enable`: reader only
- `nix/darwin-module.nix` - `services.friend-location-collector`: signed app at
  `/Applications/FriendLocationCollector.app` plus the launchd collector agent
- `justfile` - `build`, `test`, `check`, `run`

## Working on it

- `just test` compiles with `-Onone` so assertions remain enabled, then runs
  `--selftest` (parser, enumeration merge, age, place and record checks; does
  not touch the app). Mutation-test in a scratch copy, never in this checkout.
- Testing anything else needs Find My running with a window on the current
  Space of an unlocked console session (the Mac mini qualifies).
- The binary is gitignored; build it, don't commit it. Build outside iCloud
  folders when the checkout is dataless.
- `nix build .#default` builds with nixpkgs' Swift/SDK; keep code compiling
  there (`#if compiler(>=6.2)` guards macOS 26-only APIs).

## Rules specific to this project

- **Never widen a read to the whole window.** Rows come only from the container
  that is the sibling of the `AXTabGroup`; a whole-window read pulls in detail
  panes and never settles during tab transitions.
- **Never `hide()` the Find My app** - a hidden app tears down its AX tree.
  Waking a paused app makes it frontmost via `AXFrontmost` and hands focus back
  to the previous app; never hide or quit to do that.
- **A tab's rows must be confirmed distinct from the previous tab's** before
  being recorded, or a no-op tab press files one tab's rows under another's name.
- **Complete means proven.** A list is complete only from a proven top, with
  every page overlapping the sequence in order, to a proven bottom. An end is
  two no-change scrolls plus the edge geometry (first row starts / last row
  ends inside the list frame); no-change alone is what a concurrent scroller
  fakes. Gaps, reorders and duplicate titles fail closed. UI-driving runs hold
  the per-user `findmy-cli.lock`; test aids that scroll the list do not, so
  never run them while a collector or cadence read is in flight.
- **Prefer failing loudly over guessing.** Unproven tabs go into `incomplete`
  with a stderr warning and exit 5. Any new failure mode should do the same.
  Only the exact "Enable Notifications" / "Not Now" sheet is dismissed (Not
  Now); any other sheet fails the read.
- Read one `HomeElementCell` at a time. Compact and expanded AX labels differ;
  title/subtitle/distance fragments never become independent people. Preserve
  exact labels in `raw_fields`, with `raw` the assembled parsing representation.
- Detail lookups require a unique source label and successful native actions.
  Addresses come only from a unique scoped popover, never all window labels.
- Each actual row read has an immutable `source_check_id` and `checked_at`.
  Serialization preserves both; a replay is not a second source check. These
  describe AX collection, never distinct sensor fixes or measured `tst`.
- `fetched_at` / `checked_at` are collection time. Preserve displayed age as
  text; never invent a measured timestamp. Stream records never carry
  coordinates; geocoding exists only for `detail --geocode`.
- `source_handle_key` recognizes only explicit international phones/emails.
  It is a lookup key, never a person id. The collector resolves it only through
  the user's handle map; names never resolve, unresolved rows are counted and
  never written. No inferred country or email local-part case folding.
- The app holds no knowledge of any credential store: the token arrives through
  `--token-cmd`, the person ids through `--handles`.
- Run as a compiled binary; `swift findmy.swift` fails on the launch path.

## Packaging

`flake.nix` exports the package, `homeModules.default` (reader) and
`darwinModules.default` (collector). The Nix build is verified and runs the
selftest. The collector app needs a one-time Accessibility grant; the stable
self-signed identity in the System keychain keeps that grant valid across
rebuilds. No deploy workflow exists; consumers pin the flake.
