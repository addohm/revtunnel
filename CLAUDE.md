# CLAUDE.md

Orientation for Claude working on revtunnel. Read this first.

## What this is

A guided way to keep a reverse SSH tunnel from a target that nothing can connect to, to a relay you control,
so the target (its SSH server, or any port) is reachable from that relay. Started 2026-10-16 from the Windows
tester tooling of `mihomo-proxy-server-tests` (which now uses it as a preset), made generic at the user's
request. Plain OpenSSH on both ends; the scripts only set it up, explain it, and keep it running.

- Names (user, 2026-10-17): **target** = the computer to reach (opens the tunnel), **relay** = the machine
  with a fixed address holding the other end (e.g. a VPS), **your computer** = where you connect from. On
  the target itself the scripts say "this computer". Never "server"/"PC" (either can be either); "SSH
  server" still means the SSH software. Old option names stay as aliases.
- Target side: `revtunnel-target-windows.ps1` (+ `revtunnel-target-windows.cmd`, the double-click launcher) and
  `revtunnel-target-linux.sh`. Same flow and questions on both: tunnel name → port on the target → SSH server and
  login keys (port 22 only) → extras (keep awake, VPNs off, Python on Windows) → relay details → tunnel
  key, start, wait for the outcome → relay step if needed → summary. Re-running shows the status and a
  menu (reconnect, change relay, add login key, show relay step, whole setup, remove).
- Relay side: `revtunnel-relay.sh KEY [PORT] [USER]`, `--list`, `--remove PORT`.
- The tunnel itself: a loop (`tunnel.ps1` as a SYSTEM scheduled task / `tunnel.sh` as a systemd service)
  running `ssh -N -R 127.0.0.1:RPORT:127.0.0.1:LPORT` with keepalives (15 s × 4), ExitOnForwardFailure,
  reconnecting every 15 s; optional limit of failed attempts in a row (a connection that lasted 60 s
  resets the count; giving up exits 0 so the service/task isn't restarted).
- Status comes from the tunnel's log. Its fixed phrases are parsed: `connecting to ` (one line per
  attempt), `Authenticated to` (ssh, LogLevel VERBOSE), `disconnected (exit`, `gave up after`. Keep them
  identical in both loops and the parsers; ssh's error lines are mapped to plain meanings (`$Meanings` /
  `meaning()`), first match wins.

## Layout

```
revtunnel-target-windows.cmd   double-click launcher: runs the .ps1 next to it with -ExecutionPolicy Bypass
revtunnel-target-windows.ps1   Windows target setup/status/menu; writes C:\ProgramData\revtunnel\NAME\tunnel.ps1
revtunnel-target-linux.sh      Linux target setup/status/menu; writes /etc/revtunnel/NAME/tunnel.sh + a systemd unit
revtunnel-relay.sh             relay side: tunnel user, per-target key line, sshd drop-ins, --list, --remove
README.md               user workflow (quick start marks WHERE each step happens), DEPLOY.md: what goes where
```

## Decisions (user's, 2026-10-16)

- The user found the first version impossible to follow: every step must say what it does, why, and
  **where** the user must act (this computer / the relay), with an example; installer noise goes to a log.
- The relay step stays **manual but guided** (the target never logs in to the relay): banner on the target, the
  exact one-line command, the same text saved to a file (Desktop on Windows), and the relay script asks
  for the key if it's missing and ends with "go back to the target and press Enter".
- Re-runs: **status + menu**, not the whole setup again.
- Delivery: the `.cmd` launcher in the repo; the Windows files via `git clone` or GitHub's Raw button; the
  Linux target and relay scripts with one `curl` line (the repo is public since 2026-10-16).
- Generic and repeatable: any port on the target, named tunnels (several per target), Windows + Linux targets, every
  answer also an option, `-Yes`/`--yes` for scripts.

## Workflow

1. Start from the latest: pull before changing anything.
2. Make the change, then check it:
   - `bash -n revtunnel-target-linux.sh revtunnel-relay.sh`
   - the `.ps1` with **Windows PowerShell 5.1** on the Windows VM: `scp revtunnel-target-windows.ps1
     mihomo-winvm:rt/` (make `C:\Users\addohm\rt` first), then parse it there with
     `[System.Management.Automation.Language.Parser]::ParseFile`.
   - try the changed flow for real: on the VM with a throwaway tunnel (`-Name rtX -LocalPort 3389
     -RemotePort 229X -Relay <VPS address> -Yes`; never port 22 there, and never touch the tunnel named
     `main`, which is how we reach the VM), interactively via `ssh -tt` with piped answers, and on the VPS
     as both target and relay (`--relay 127.0.0.1`). Remove throwaways on both sides after.
3. **Update the docs in the same commit.** Every change updates the docs it affects:
   - README.md: setup and usage
   - CHANGELOG.md: an entry under *Unreleased*
   - DEPLOY.md: when what gets installed or changed on a machine changes
   - SECURITY.md: when keys, access or permissions change
   - this file: when the layout, workflow or conventions change
4. Commit and push.

Test machines (rebuilt from scratch 2026-10-16 for a fresh-install test; the earlier Fedora test server is
deleted, never connect to its old address): the VPS `sgp-vps` (Ubuntu 24.04 in Singapore, root), a
`/claude ssh` host of the mihomo-proxy-server-tests workspace: `/srv/claude/data/ssh/mihomo-proxy-server-tests/ssh
sgp-vps '...'` (scp: `-F /srv/claude/data/ssh/mihomo-proxy-server-tests/config`). It holds the tunnel `main`
(port 2222) of the Windows 11 VM in mainland China (`DESKTOP-BJUBIRD`, user `addohm`): `ssh mihomo-winvm`
(alias in `~/.ssh/config`, ProxyCommand through `sgp-vps`, the workspace key is the VM's login key; root on
the VPS has no key of its own). Keep addresses out of the repo.

## Conventions

- `.ps1`: **ASCII only** (5.1 reads BOM-less files as ANSI) and Windows PowerShell 5.1 compatible: no
  `??`, `?:`, `&&`; native stderr with `2>&1` under `$ErrorActionPreference = 'Stop'` throws (set it to
  `Continue` locally, see `Invoke-Logged`); empty native arguments vanish (use `Start-Process
  -ArgumentList` with a string, as for ssh-keygen); wrap results that may be one item in `@()`; use SIDs
  (`*S-1-5-32-544`, SDDL `BA`/`SY`), never localised group names; ssh.exe as SYSTEM refuses a key owned
  or readable by another account, and Windows gives the creator of a ProgramData folder an explicit
  full-control entry that `icacls /grant:r` keeps, so `Protect` sets a whole SDDL ACL (owner BA, SY + BA
  only, nothing inherited); `ssh -E` locks its log, so the loop logs through
  `cmd /c ... 2>>`.
- `.sh`: bash, `set -euo pipefail`: a failing `$(...)` in an assignment exits, so end such commands with
  `|| true`; no `sed q` behind a pipe (SIGPIPE).
- Output: `Step N of M: title` + one or two dim lines of why; `[ok]` / `[!]` / `[x]` lines; banners for
  "ACTION NEEDED - on the RELAY", "DONE", "SET UP, BUT NOT CONNECTED YET". Plain language, no jargon
  without an explanation.

## Don't

- Commit secrets (keys, the test machines' addresses, subscription URLs).
- Make the target log in to the relay, or add a non-OpenSSH dependency.
