# findmy-cli

A macOS CLI that reads Find My (People / Devices / Items) out of the Find My
app's accessibility tree and prints JSON. Single Swift file, no dependencies.

Status: **spike**. It works, but see the Known bugs section in README.md -
virtualized lists mean output is a lower bound. Snapshots explicitly declare
visible-only incomplete coverage and exit 5. Paused rows are never fresh fixes.

## Layout

- `findmy.swift` - the entire program
- `justfile` - `build`, `test`, `check`, `run`

## Working on it

- `just test` compiles with `-Onone` so assertions remain enabled, then runs
  `--selftest` (parser checks; does not touch the app)
- Testing anything else needs Find My running with a window on the current Space
- The binary is gitignored; build it, don't commit it

## Rules specific to this project

- **Never widen a read to the whole window.** Rows come only from the container
  that is the sibling of the `AXTabGroup`; a whole-window read pulls in detail
  panes and never settles during tab transitions.
- **Never `hide()` the Find My app** - a hidden app tears down its AX tree.
- **A tab's rows must be confirmed distinct from the previous tab's** before
  being recorded, or a no-op tab press files one tab's rows under another's name.
- **Prefer failing loudly over guessing.** Unreadable tabs go into `incomplete`
  with a stderr warning and exit 5. Any new failure mode should do the same.
- Every parsed row keeps its `raw` label so a parser bug never loses data.
- `fetched_at` is collection time. Preserve displayed age as text; never invent
  a measured timestamp or put geocoded coordinates in a measured GPS stream.
- Run as a compiled binary; `swift findmy.swift` fails on the launch path.
