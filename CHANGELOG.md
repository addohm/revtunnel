# Changelog

All notable changes to revtunnel. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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
