# herdr-review-queue — Spec

A Herdr mod plus a tiny CLI that shows a **"waiting for review" queue**: which coder agents
have reported back (`hc send` to their reviewer) and the reviewer hasn't looked at yet.

## 1. Problem

In a reviewer + coders workflow (one Claude Code PM, several agy / Claude coders in Herdr
panes), coders report with `hc send <reviewer> "done: ..."`. The message lands in the
reviewer agent's input, but the **person** has no overview: who reported, when, what about,
and which reports are already reviewed. Herdr's own `done` status flips to `idle` as soon as
someone glances at the pane, so it cannot be used as "reviewed".

`hc events` does not emit `send` events (verified with hc 0.1.21), so the mod cannot observe
messages. It **does** see terminal labels live (`terminals()` in the mod API, `labels` events
in `hc events`). So the queue is built on a **label contract**.

## 2. Label contract (the interface between #1 and #2 — do not deviate)

Labels live on the **coder's** terminal (set with `hc label <t> k=v`; `k=` removes a label).

| Label | Value | Set by |
|---|---|---|
| `review` | `ready` or `seen` (absent = not in the queue) | `ready`: coder · `seen`: reviewer/person |
| `review.summary` | one line, ≤ 200 chars, newlines replaced by spaces | coder |
| `review.at` | ms since epoch when it became `ready` (string of digits) | coder |
| `review.to` | reviewer address (e.g. `t15`) | coder |
| `review.seen_at` | ms since epoch when marked `seen` | reviewer/person |

Rules:
- Becoming `ready` again (a new round) overwrites `review.summary`, `review.at`, `review.to`
  and removes `review.seen_at`.
- `clear` removes all five labels.
- Addresses may be remote (`machine/t7`); pass them to `hc` unchanged.

## 3. Components

```
bin/hc-review                 # issue #1: POSIX sh CLI (needs hc + jq)
tests/hc-review.test.sh       # issue #1: tests with a fake hc on PATH
mods/review-queue/main.js     # issue #2: the Herdr mod
mods/review-queue/mod.json    # issue #2
install.sh                    # issue #3
README.md                     # issue #3
```

### 3.1 `bin/hc-review` (issue #1)

```
hc-review ready "<summary>" [--to <t>] [--no-send]
    Labels $HC_TERMINAL_ID per §2 (review=ready, summary, at=now ms, to).
    --to defaults to this terminal's parent (`hc get $HC_TERMINAL_ID --json` → .parent).
    Then `hc send <to> "[review-ready] <summary>"` unless --no-send.
    Errors (exit 2) if HC_TERMINAL_ID is unset or no reviewer can be found.
hc-review seen <t>      review=seen, review.seen_at=now ms
hc-review clear <t>     remove all review labels
hc-review ls [--all] [--json]
    From `hc ls --json`: terminals with review=ready, oldest first
    (--all: also seen). Text columns: ADDRESS  NAME  AGE  SUMMARY.
hc-review --help
```

- `HC_BIN` env var overrides the `hc` executable (used by tests).
- Summary longer than 200 chars is truncated with `…`; newlines/tabs become spaces.
- No bashisms (`sh -n` and, if installed, `shellcheck -s sh` clean).
- Tests: `tests/hc-review.test.sh` puts a fake `hc` first on PATH that logs its argv to a
  file and returns canned JSON for `get`/`ls`; asserts the exact `hc label` / `hc send` calls
  for every subcommand and the error cases. `sh tests/hc-review.test.sh` exits 0 on success.

### 3.2 `mods/review-queue` (issue #2)

A Herdr mod (see `~/.config/herdr-app/AGENTS.md` §Mods and `herdr.d.ts`).

- `mod.json`: `{ "place": "right", "size": 340, "title": "Review queue" }`.
- Data: `terminals()` (live; never poll it). Pending = `labels.review === "ready"`, oldest
  `review.at` first. Recently seen = `review === "seen"`, newest `review.seen_at` first,
  max 10, in a collapsible "Seen" section (collapsed by default).
- Header: "Review queue" + pending count badge (theme `done` color when > 0).
- Row: program icon (`program.icon`, `svg` if `tint` else `image`), name (or address),
  address in dim text, relative age ("just now", "3m", "2h"), summary (2 lines max, truncated),
  status dot using theme `working`/`blocked`/`done`/`idle`.
- Row actions:
  - click row / **Open**: `run("agent.focus", { terminal })`; if the terminal has no pane
    (`panes()` has no entry with that terminal) use `run("terminal.keep", { terminal, place: "right" })`.
  - **Seen**: `hc(["label", addr, "review=seen", "review.seen_at=<ms>"])`.
  - Seen rows get **Clear** (removes all review labels) and **Reopen** (`review=ready`).
- New report notification: when an address becomes `ready` (or its `review.at` changes) after
  the mod started, `notify({ title: "Ready for review", body: "<name>: <summary>", level:
  "info", action: { name: "agent.focus", args: { terminal } } })` once per (address, at).
  Do not notify for items already ready when the mod starts.
- Keyboard command via `nextCommand()`: `review-queue.next` opens the oldest pending item.
- Empty state: "Nothing waiting for review" + one-line hint about `hc-review ready`.
- Theme colors only (`theme()`); a single `cx.timer.every(30000, …)` only to refresh ages.
- Errors from `hc` are shown inline in the row for 5 s, never thrown.
- Must pass `herdr-app check <repo>/mods/review-queue`.

### 3.3 `install.sh` + README (issue #3)

- `install.sh [--dry-run] [--uninstall]`: symlink `mods/review-queue` →
  `~/.config/herdr-app/mods/review-queue` (respect `$HERDR_APP_HOME`) and `bin/hc-review` →
  `~/.local/bin/hc-review`; run `herdr-app check` on the installed mod. Never touch other mods.
- README: what/why, screenshot, install, the label contract, a ready-to-paste coder prompt
  line ("when done run `hc-review ready "<summary>"`"), how the reviewer marks seen.

## 4. Issues

| # | Title | Depends | Round |
|---|---|---|---|
| 1 | `hc-review` CLI + label contract + tests | – | 1 (pane A) |
| 2 | `review-queue` Herdr mod | – (contract §2) | 1 (pane B) |
| 3 | install.sh, README, end-to-end check | 1, 2 | 2 |

## 5. Definition of done

- #1: `sh tests/hc-review.test.sh` passes; `sh -n bin/hc-review` clean.
- #2: `herdr-app check mods/review-queue` passes; no edits to any other mod or Herdr setting.
- No files outside the issue's scope; no debug output; no secrets.
- Coders do not commit, push, or switch branches; the reviewer does.
