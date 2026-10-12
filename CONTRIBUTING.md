# Contributing to Strays

Thanks for helping. This covers how to build and test, the rules the tests
live by, and the contribution that needs no Swift at all: an agent profile.

## Building and testing

```bash
brew install xcodegen
make build   # generates Strays.xcodeproj from project.yml and builds the app
make test    # runs the StraysCore unit tests with SwiftPM
make run     # builds and launches; Strays appears in the menu bar
```

The Xcode project is generated and not committed. Change `project.yml`, not
the project.

- `StraysCore/` has all data collection, models, and actions. No UI code goes
  here, so the app and the CLI can share it and so it can be unit-tested.
- `Strays/` is the SwiftUI app.
- `strays-cli/` is the command-line tool.

Run the tests before you open a pull request. CI runs the same `make build`
and `make test`.

### Seeing the UI without recording your screen

```bash
make build
scripts/snapshots.sh /tmp/strays-snapshots
```

renders the popover and the dashboard to PNG files using made-up data, so no
screenshot ever contains something from a real machine. `make run ARGS=--demo`
runs the app itself on the same data.

## Two rules for tests

**Never touch what you did not start.** Tests that exercise the real machine
spawn their own throwaway processes (`python3 -m http.server` on a random
loopback port, a sleeper, a busy loop) and stop them afterwards. A test must
never signal, stop, or restart a process, container, or Homebrew service that
it did not create. Docker and Homebrew are tested against fakes
(`FakeDocker`, `FakeBrew`); the one test that drives a real Docker daemon is
opt-in and only ever acts on a container it creates.

**Do not depend on the machine.** A test should pass on a Mac with no Docker,
no Homebrew, and no AI agent installed, and should behave the same whether or
not the test run itself was started by an agent. Pass an explicit catalog or
resolver rather than relying on the defaults.

## Adding or verifying an agent

This is the most useful contribution, and it touches **one file**:
[`StraysCore/Sources/StraysCore/Resources/agents.json`](StraysCore/Sources/StraysCore/Resources/agents.json).

A profile looks like this:

```json
{
  "id": "my-agent",
  "displayName": "My Agent",
  "badgeColor": "#7C4DFF",
  "icon": "sparkle",
  "ancestorMatchers": {
    "executableNames": ["myagent"],
    "pathFragments": ["/@vendor/my-agent/"],
    "argumentPatterns": ["(^|/)myagent(\\.js)?(\\s|$)"]
  },
  "envMarkers": [
    { "name": "MY_AGENT", "value": "1", "verified": "2026-11-02: My Agent 3.1, macOS 26. Read from a background node process." }
  ],
  "sessionPIDVariable": "MY_AGENT_PID",
  "notes": "Anything a maintainer should know."
}
```

- `ancestorMatchers` recognise the agent's own process: by executable name
  (case-sensitive), by a fragment of its path, or by a regular expression on
  its command line (for agents that are a script run by `node` or `python`).
- `envMarkers` are variables the agent sets in the shells it spawns. They are
  what lets Strays recognise a process after the agent has exited.
- `sessionPIDVariable` is optional: a variable holding the agent's own PID,
  if it sets one. With it Strays can tell an orphan from a process that was
  merely detached while its session is still alive.
- `icon` is an SF Symbol name; `badgeColor` is `#RRGGBB`.

### The one rule

**Only list an environment marker you have seen yourself**, in the
environment of a background process started through the agent, and say when
and how in `verified`. A marker that is merely believed to exist goes in
`unverifiedEnvMarkers`, which Strays never matches on. A test enforces that
every shipped marker carries a verification note.

A wrong marker is worse than a missing one: it attributes processes to an
agent that never started them.

### How to verify a marker

1. Ask the agent to run a long-lived command in the background, such as
   `node -e "setTimeout(() => {}, 600000)"`. Use `node`, `python`, or another
   third-party runtime: recent versions of macOS can hide the environment of
   their own system binaries (`/bin/sleep`, `/bin/zsh`), and those may show
   nothing.
2. Find its PID and inspect it:

   ```bash
   swift run --package-path strays-cli strays inspect <pid>
   ```

   This prints the process's ancestors, flags any that match a profile, and
   lists the environment variables that look agent-related. Those are your
   candidates.
3. Check that the candidate is set by the agent and not by you. It should be
   absent from a process you start from a plain terminal.
4. Now quit the agent and inspect the process again. It should have been
   adopted by `launchd` (parent PID 1), and the marker should still be there.
   If the agent sets a variable holding its own PID, that PID should be gone.
5. Move the marker from `unverifiedEnvMarkers` to `envMarkers`, with a
   `verified` note saying the date, the agent's version, and what you did.

Run `make test`, and open a pull request that changes only `agents.json`
(and, if you like, the table in the README).

You can try a profile without rebuilding: put a file of the same shape at
`~/Library/Application Support/Strays/agents.json`. Entries with a matching
`id` replace the built-in ones.

## Adding a runtime

Which processes without a port count as dev processes is decided by
[`runtimes.json`](StraysCore/Sources/StraysCore/Resources/runtimes.json).
To add a runtime, add its executable names (or a pattern) to `runtimes`. To
stop a helper such as a language server from being listed, add a pattern to
`ignore.commandLinePatterns`.

## Style

- Match the code around you: naming, comment density, idiom.
- Comments explain why, not what.
- Keep functions small, and keep I/O at the edges so the logic in between can
  be tested with plain values.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/).

## Releasing

Maintainers: update `StraysCore.version`, `MARKETING_VERSION` in
`project.yml`, and `CHANGELOG.md`, then push a tag `vX.Y.Z`. The release
workflow builds a universal binary, signs and notarizes it, publishes the
GitHub release, and updates the Homebrew cask. The secrets it needs are
listed at the top of `.github/workflows/release.yml`.
