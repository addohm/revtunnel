# Security

## Reporting a problem

Tell the repository owner privately (GitHub: addohm). Please don't open a public issue for a
vulnerability.

## What each side can do

- **The PC's tunnel key** (`C:\ProgramData\revtunnel\NAME\id_ed25519`, `/etc/revtunnel/NAME/id_ed25519`)
  can only do one thing on the server: open its own port on the server's 127.0.0.1. The server's
  `authorized_keys` line limits it (`restrict,port-forwarding,permitlisten="127.0.0.1:PORT"`), and an
  sshd `Match User` block allows that user remote forwards only: no shell, no terminal, no forwards *into*
  the server (`-L`, which `port-forwarding` alone would allow), no agent/X11/socket forwarding. The user
  has no password. Someone who steals the key can at most hold that port.
- **The forwarded port** listens on the server's 127.0.0.1 only, so only people who can log in to the
  server can use it.
- **Logging in to the PC** (SSH tunnels) needs one of the public keys added during setup.
  - Windows: setup makes the PC's SSH server listen on 127.0.0.1 only and turns password logins off, so
    the tunnel is the only way in. Keys of administrators live in
    `C:\ProgramData\ssh\administrators_authorized_keys` (owned by Administrators, readable by SYSTEM and
    Administrators only).
  - Linux: the SSH server's settings are left as they are (it may also accept logins from the local
    network, and passwords, if it did before). Keys go to the login user's `~/.ssh/authorized_keys`.

## Secrets

- The tunnel's **private key** never leaves the PC; only its public half is shown and copied to the
  server. Its folder is readable by SYSTEM and Administrators (Windows) or root (Linux) only, and the
  Windows tunnel runs as SYSTEM.
- Setup never asks for or stores passwords.
- To rotate the tunnel key: delete `id_ed25519*` in the tunnel's folder, run setup again ("whole setup"),
  and do the server step again (the new key replaces the old one for that port).
- Login keys: remove a line from the authorized keys file above to revoke it.

## Trust

- The server's host key is trusted on first connection (`accept-new`) and re-learned whenever setup runs
  (so a rebuilt server works again). After that, a changed host key stops the tunnel.
- Nothing is downloaded at run time except what the PC's own package manager installs on request
  (Windows: OpenSSH from Windows Update, Python via winget / the Python install manager; Linux: openssh
  packages).
