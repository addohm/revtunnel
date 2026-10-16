# Changelog

All notable changes to revtunnel. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

- Windows: the tunnel's key could be readable by the user who ran setup (Windows gives the creator of a
  ProgramData folder full control, inherited by the key), so ssh.exe refused it and the server never
  let the PC in. The folder and key now get a fixed SYSTEM + Administrators ACL. Status reports this as
  a problem with the PC's key file instead of "the server step is needed" (2026-10-16, first fresh
  install: Ubuntu VPS + Windows 11 PC).
- Server: keepalives only for the tunnel user (a `Match User` block), no longer for every login; the old
  `40-revtunnel.conf` is removed.

### Changed

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
- Based on the Windows tester tooling of mihomo-proxy-server-tests (`setup-windows.ps1`,
  `tunnel-host.sh`), with its fixes from the first run on a real PC: the tunnel key owned by
  Administrators (ssh.exe as SYSTEM refused it), ssh logging through `cmd` (`ssh -E` locked the log).
