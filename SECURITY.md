# Security

## Reporting a problem

Tell the repository owner privately (GitHub: addohm). Please don't open a public issue for a
vulnerability.

## What each side can do

- **The target's tunnel key** (`C:\ProgramData\revtunnel\NAME\id_ed25519`, `/etc/revtunnel/NAME/id_ed25519`)
  can only do one thing on the relay: open its own port on the relay's 127.0.0.1. The relay's
  `authorized_keys` line limits it (`restrict,port-forwarding,permitlisten="127.0.0.1:PORT"`), and an
  sshd `Match User` block allows that user remote forwards only: no shell, no terminal, no forwards *into*
  the relay (`-L`, which `port-forwarding` alone would allow), no agent/X11/socket forwarding. The user
  has no password. Someone who steals the key can at most hold that port.
- **The forwarded port** listens on the relay's 127.0.0.1 only, so only people who can log in to the
  relay can use it.
- **Logging in to the target** (SSH tunnels) needs one of the public keys added during setup.
  - Windows: setup makes the target's SSH server listen on 127.0.0.1 only and turns password logins off, so
    the tunnel is the only way in. Keys of administrators live in
    `C:\ProgramData\ssh\administrators_authorized_keys` (owned by Administrators, readable by SYSTEM and
    Administrators only).
  - Linux: the SSH server's settings are left as they are (it may also accept logins from the local
    network, and passwords, if it did before). Keys go to the login user's `~/.ssh/authorized_keys`.

## Secrets

- The tunnel's **private key** never leaves the target; only its public half is shown and copied to the
  relay. Its folder is readable by SYSTEM and Administrators (Windows) or root (Linux) only, and the
  Windows tunnel runs as SYSTEM.
- Setup never asks for or stores passwords.
- To rotate the tunnel key: delete `id_ed25519*` in the tunnel's folder, run setup again ("whole setup"),
  and do the relay step again (the new key replaces the old one for that port).
- Login keys: remove a line from the authorized keys file above to revoke it.

## Trust

- The relay's host key is trusted on first connection (`accept-new`) and re-learned whenever setup runs
  (so a rebuilt relay works again). After that, a changed host key stops the tunnel.
- Nothing is downloaded at run time except what the target's own package manager installs on request
  (Windows: OpenSSH from Windows Update, Python via winget / the Python install manager; Linux: openssh
  packages).
