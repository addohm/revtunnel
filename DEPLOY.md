# How revtunnel is installed and runs

There is no service of our own to deploy: the scripts are copied to the machines and run there (see the
README's quick start). This page lists what they install and change.

## Windows target (`revtunnel-target-windows.ps1`)

- `C:\ProgramData\revtunnel\` (SYSTEM + Administrators only): `setup.log` (installer output), and per
  tunnel `NAME\`: `tunnel.json` (settings), `id_ed25519[.pub]` (the tunnel's key), `known_hosts`,
  `tunnel.ps1` (the reconnect loop), `tunnel.log`, and `paused` (the time it was paused) while paused.
- Scheduled task **revtunnel NAME**: runs `tunnel.ps1` as SYSTEM at startup (restarted if it crashes);
  disabled while the tunnel is paused.
- SSH tunnels (port 22): the OpenSSH Server Windows capability; `sshd` set to automatic; a block marked
  `# revtunnel: begin/end` at the top of `C:\ProgramData\ssh\sshd_config` (ListenAddress 127.0.0.1,
  PasswordAuthentication no); PowerShell as the SSH default shell (`HKLM\SOFTWARE\OpenSSH\DefaultShell`);
  `administrators_authorized_keys`.
- Extras, when chosen: power plan (no sleep/hibernate on AC); disconnected VPN connections and disabled
  VPN/TUN adapters (setup prints how to re-enable each); Python via the Python install manager.
- A relay-step text file on the Desktop while the tunnel isn't up yet.

## Linux target (`revtunnel-target-linux.sh`)

- `/etc/revtunnel/NAME/` (root only): `tunnel.conf`, `id_ed25519[.pub]`, `known_hosts`, `tunnel.sh`,
  `relay-step.txt` (until the tunnel is up), `paused` (the time it was paused) while paused. Log:
  `/var/log/revtunnel-NAME.log`.
- systemd service **revtunnel-NAME** (enabled; restarted on failure; disabled while paused).
- SSH tunnels: the openssh server package if missing (settings untouched); keys in the login user's
  `~/.ssh/authorized_keys`.
- Extras, when chosen: `systemctl mask` of the sleep targets; VPN connections (NetworkManager) and
  VPN/TUN interfaces brought down.

## Relay (`revtunnel-relay.sh`)

- A user (default `tunnel`) with no shell and no password; one line per target in its
  `~/.ssh/authorized_keys`.
- `/etc/ssh/sshd_config.d/41-revtunnel-USER.conf`: a `Match User` block for that user only: remote
  forwards only, and keepalives (15 s × 4) so a dropped tunnel frees its port within a minute. Other
  logins keep the relay's own settings. Needs sshd_config to include `sshd_config.d` (the default on
  current distributions). sshd is reloaded, not restarted. (Earlier versions also wrote
  `40-revtunnel.conf` with the keepalives for every login; the script now removes it.)

## Changing the scripts

1. Edit, then check: `bash -n *.sh`; for the `.ps1`, parse it with Windows PowerShell 5.1 (see CLAUDE.md).
2. Try the changed flow on a real machine (scripted with `-Yes` / `--yes`, and interactively).
3. Update the README / these docs and CHANGELOG in the same commit, then push. Users download the new
   files with Raw; re-running setup picks up the changes.
