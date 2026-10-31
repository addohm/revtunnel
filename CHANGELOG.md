# Changelog

All notable changes to revtunnel. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- The relay step no longer downloads `revtunnel-relay.sh` from a GitHub URL (2026-10-31): the scripts name
  no site, server or repository. It says to copy the relay script, which comes with revtunnel, to the
  relay (with an `scp` example).

### Removed

- The test machines (2026-10-31): the test VPS and Windows VM are gone; CLAUDE.md says how to test
  without them, and what to ask for to test for real again.

- `setup-inspect.sh` and `ssh-host-user.sh` (2026-10-31), uploaded here on 2026-10-28 but not part of
  revtunnel: they belong to other projects.

### Added

- Pause and resume (2026-10-31): option 7 of the target's re-run menu, and `--pause` / `--resume`
  (`-Pause` / `-Resume` on Windows) for scripts. Paused, the tunnel is stopped and stays off after a
  restart (systemd unit / scheduled task disabled, a `paused` marker in the tunnel's folder) but keeps
  its key and settings; status shows PAUSED. Resume starts it and from boot again, and reports like
  "Reconnect now" (the relay step if the relay no longer has the key). A whole setup or relay change
  un-pauses. "Nothing (quit)" moves from 7 to 8. Linux flows tested against stubbed systemd; the
  Windows script parses (PowerShell 7's parser) but wasn't run (no Windows test machine at the time).

### Fixed

- Windows: the tunnel's key could be readable by the user who ran setup (Windows gives the creator of a
  ProgramData folder full control, inherited by the key), so ssh.exe refused it and the server never
  let the PC in. The folder and key now get a fixed SYSTEM + Administrators ACL. Status reports this as
  a problem with the PC's key file instead of "the server step is needed" (2026-10-16, first fresh
  install: Ubuntu VPS + Windows 11 PC).
- Server: keepalives only for the tunnel user (a `Match User` block), no longer for every login; the old
  `40-revtunnel.conf` is removed.

### Changed

- Wording by role, not by kind of machine (user, 2026-10-17): the **target** (the computer to reach, which
  opens the tunnel; "this computer" in its own setup) and the **relay** (the machine with a fixed address
  holding the other end), instead of "PC" and "server". Files renamed to match:
  `revtunnel-target-windows.cmd` / `.ps1`, `revtunnel-target-linux.sh`, `revtunnel-relay.sh`. New option
  names `-TargetPort`, `-Relay`, `-RelaySshPort`, `-RelayUser`, `-TunnelPort` (Linux `--target-port`,
  `--relay`, `--relay-ssh-port`, `--relay-user`, `--tunnel-port`); the old names still work. Existing
  tunnels keep working unchanged.
- The login-key step explains whose key to paste: the machine that makes the last hop to the target.
- README: how to reach the PC, illustrated: one command with `ssh -J` (your key on the PC) or two
  logins (the server's key on the PC), and which key the PC checks.
- The server step downloads `revtunnel-server.sh` with one `curl` line (the repository is public).
- The server script refuses a key that doesn't look like a PC's tunnel key (asks when run interactively).
- The server step's banner shows once; later failed checks say what to compare (key ending, `--list`).
- The Python question accepts `y` (3.13) and re-asks for anything that isn't a version.
- The summary says to log in from the server or your own computer, not from the PC.

### Added

- Standard docs: README, CLAUDE, CHANGELOG, DEPLOY and SECURITY (2026-10-16).
- Windows PC setup (`revtunnel-windows.ps1` + double-click `revtunnel-windows.cmd`) and Linux PC setup
  (`revtunnel-linux.sh`): guided steps that say what, why and where; named tunnels to any port on the
  PC; login keys; optional keep-awake, VPNs off and (Windows) Python; status in plain language; a
  re-run menu (reconnect, change server, add login key, show server step, whole setup, remove);
  every answer also an option, `-Yes`/`--yes` for scripts (2026-10-16).
- Presets can always pass the extras (`-KeepAwake`, `-NoVpn`, `-Python`, `-PythonPackages`; Linux
  `--keep-awake`, `--no-vpn`) and still get the re-run menu (2026-10-16).
- Server side (`revtunnel-server.sh`): asks for the PC's key if not given, `--list` (PCs, ports,
  connected or not), `--remove PORT` (2026-10-16).
- Based on a Windows tester's tunnel tooling (`setup-windows.ps1`, `tunnel-host.sh`), with its fixes from the first run on a real PC: the tunnel key owned by
  Administrators (ssh.exe as SYSTEM refused it), ssh logging through `cmd` (`ssh -E` locked the log).
