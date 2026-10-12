# Changelog

All notable changes to Strays are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0]

The first release.

### Added

- Menu bar item with a live count, a pulse when something new appears, and a
  dot when something is stale or orphaned.
- Popover grouped by project, with open, copy URL, and stop.
- Dashboard with cards, a sortable table, and a timeline; an inspector with
  the full command, masked environment, process tree, ports, and live CPU
  and memory; search; and a command palette on ⌘K.
- Listening ports from libproc, with an `lsof` fallback and `netstat` for
  listeners owned by root. Ports reachable from the network are marked.
- Dev processes without a port, by data-driven runtime rules.
- Project inference from the nearest marker file.
- Docker containers over the Engine API: start, stop, restart, remove, logs,
  and stopping a whole compose project.
- Homebrew services: start, stop, restart.
- Attribution to AI coding agents: Claude Code, Codex, Gemini CLI, Aider, and
  Cursor Agent by ancestry; Claude Code also by verified environment markers,
  which lets its orphans be recognised.
- Stale detection, with opt-in notifications that default to one a day.
- Stacks, hide rules, launch at login, and a choice of editor and terminal.
- A daily, notify-only check for new releases.
- `strays`, a command-line tool on the same engine.

### Safety

- Every signal re-checks that the PID still has the recorded start time.
- A protected list that is never signalled; a `sudo kill` command to copy,
  instead of escalating, for processes owned by others.
