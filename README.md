# revtunnel

Reach a computer that nothing can connect to (dynamic IP, NAT, a strict firewall, another country) by having
it keep a connection open to a machine you control. Three machines take part; this README calls them:

- **target**: the computer you want to reach. It opens the tunnel.
- **relay**: a machine with a fixed address that the target can reach, e.g. a small VPS. It holds the
  tunnel's other end; you reach the target through it.
- **your computer**: where you connect from.

The target keeps a tunnel open to the relay; a port on the relay leads back through it to the target:
usually the target's SSH server, or any other port (Remote Desktop, VNC, a web UI).

```
your computer --ssh--> relay, port 2222 (its own 127.0.0.1 only) ==tunnel==> target, port 22
```

- **Target:** Windows 10/11 or Linux. A guided setup that you can re-run any time to see the status or
  change something. The tunnel runs from startup, also with nobody signed in, and reconnects by itself.
- **Relay:** any Linux machine with OpenSSH. One command per target.
- Plain OpenSSH, nothing else to install. The target is reachable from the relay alone; the relay user that
  holds the tunnels can do nothing but hold them.

| File | Runs on | What it is |
|---|---|---|
| `revtunnel-target-windows.cmd` | Windows target | Double-click this. It starts the `.ps1` next to it |
| `revtunnel-target-windows.ps1` | Windows target | The Windows setup |
| `revtunnel-target-linux.sh` | Linux target | The Linux setup |
| `revtunnel-relay.sh` | the relay | Lets a target's tunnel in; lists and removes targets |

## Quick start

You need: the target, a relay (with root or sudo on it), and about ten minutes. Each step says **where** it happens.

### 1. Get the files

- **Windows target:** `revtunnel-target-windows.cmd` **and** `revtunnel-target-windows.ps1`, in the same folder. Either
  `git clone https://github.com/addohm/revtunnel.git`, or open each file on GitHub and use the **Raw**
  button (or the download button), then save it. Saving the normal GitHub page gives you an HTML file
  that won't run.
- **Linux target:** `curl -fsSLO https://raw.githubusercontent.com/addohm/revtunnel/main/revtunnel-target-linux.sh`
- **The relay:** nothing yet; the target's setup tells you when (step 3).

### 2. On the target: run the setup

- **Windows:** double-click `revtunnel-target-windows.cmd` (or run it from a PowerShell window) and allow it to
  make changes. If Windows says it "protected your PC", choose **More info → Run anyway**. Setup continues
  in a new administrator window. Running `revtunnel-target-windows.ps1` directly fails on a fresh Windows
  ("running scripts is disabled"): always start the `.cmd`.
- **Linux:** `sudo bash revtunnel-target-linux.sh`

It goes step by step and explains each one. You'll be asked for:

| Question | What to answer |
|---|---|
| Tunnel name | Enter (`main`), unless the target gets several tunnels |
| Port on this computer (the target) | Enter (22, SSH logins), or the port of the program to reach, e.g. 3389 for Remote Desktop |
| Keys allowed to log in | The *public* SSH key (one line, starting `ssh-ed25519`) of each machine that will make the last hop to the target: usually **your own computer's** (`cat ~/.ssh/id_ed25519.pub` there; see step 5 for why). Enter on an empty line when done |
| Extras | Keep awake, turn VPNs off, install Python (Windows): yes to what an unattended target needs |
| Relay address, SSH port, user | The relay's IP or name; Enter for 22 and `tunnel` |
| Port on the relay | Enter (2222) for the first target; every target on the same relay needs its own (2223, ...) |
| Reconnect attempts | Enter (0 = never give up), or a number of failed attempts in a row before it stops |

### 3. On the relay: let the target in

The first time, the target stops with **ACTION NEEDED - on the RELAY** and shows what to run there (also
saved in a text file on the target's Desktop, or in `/etc/revtunnel/NAME/relay-step.txt` on Linux):

```bash
curl -fsSLO https://raw.githubusercontent.com/addohm/revtunnel/main/revtunnel-relay.sh
sudo bash revtunnel-relay.sh 'ssh-ed25519 AAAA... revtunnel-main-MYTARGET' 2222 tunnel
```

Or run `sudo bash revtunnel-relay.sh` and paste the target's key when it asks. It ends with **Done**.

**Two kinds of key, don't mix them up:**
- the target's **tunnel key** (ends in `revtunnel-NAME-COMPUTERNAME`): made by the target's setup, goes to the
  **relay** in this step. It lets the target hold its tunnel, nothing else.
- **login keys** (e.g. `~/.ssh/id_ed25519.pub` of a person or of the relay): pasted **on the target** in
  step 2. They let someone log in to the target through the tunnel (whose key: see step 5).

### 4. On the target: press Enter

Setup connects and ends with **DONE** and how to reach the target, or explains what is still wrong.

### 5. From your own computer: reach the target

**The rule:** the target only checks the key of the machine that makes the **last hop** to it. That key must be
one of the target's login keys (step 2, or "Allow another key" later). Never run these on the target itself.

**Option A, one command (recommended):** your computer makes both hops, so only **your** key is needed:
on the relay (as you already log in there) and on the target.

```
  your computer ───ssh (your key)───> relay ──tunnel, port 2222──> target
        │                                                           ▲
        └──────────────── ssh -J: your key again ───────────────────┘
                     (the last hop is from YOUR computer)
```

```bash
ssh -J root@RELAY -p 2222 TARGET_USER@127.0.0.1
```

Or put it in `~/.ssh/config` on your computer, then just `ssh mytarget`:

```
Host mytarget
    HostName 127.0.0.1
    Port 2222
    User TARGET_USER
    ProxyJump root@RELAY
```

**Option B, two logins:** you log in to the relay, and **the relay** makes the last hop, so the target needs
**the relay's** key (make one there with `ssh-keygen -t ed25519`; add its `~/.ssh/id_ed25519.pub` on the
target).

```
  your computer ───ssh (your key)───> relay ───ssh (RELAY's key)───> target
                                       │                                ▲
                                       └──── tunnel, port 2222 ─────────┘
```

```bash
ssh root@RELAY                       # on your computer: log in to the relay
ssh -p 2222 TARGET_USER@127.0.0.1    # then, on the relay: log in to the target
```

Option A keeps one key in one place and none on the relay; option B is handy when you are on the relay
anyway, or for things that run there.

`TARGET_USER` is the user setup showed (on Windows, the account that ran it). Only the keys added in step 2
work: passwords are off on Windows, and on Linux the target's SSH settings are left as they were.

For a port other than SSH, open a forward through the relay and point your program at `localhost`:
`ssh -L 3389:127.0.0.1:2222 root@RELAY`, then connect to `localhost:3389`.

## Later

Run the setup on the target again (double-click the `.cmd`, or `sudo bash revtunnel-target-linux.sh`). It shows the
status of the tunnel and offers:

1. **Reconnect now**
2. **Change the relay address**, e.g. when the relay got a new IP: enter the new one, Enter for the
   rest. A *different* relay also needs step 3; setup asks for it if so.
3. **Allow another key to log in** (SSH tunnels)
4. **Show the relay step again**
5. **Go through the whole setup again**
6. **Remove this tunnel**
7. **Pause the tunnel**, or **Resume** it when it's paused. Paused, the tunnel is stopped and stays off
   after a restart, but keeps its key, settings and relay step, so resuming takes seconds. Handy when
   the tunnel is only wanted now and then. While it's paused, "Reconnect now" isn't offered (Resume is).
   The relay needs nothing: it keeps the target's key, which can only open its port there.

On the relay:

```bash
sudo bash revtunnel-relay.sh --list          # every target, its port, and whether it is connected now
sudo bash revtunnel-relay.sh --remove 2222   # remove the target on that port
```

## When it doesn't connect

The target's setup (and its status) translates the tunnel's log into plain language. The usual causes:

| Status says | What to do |
|---|---|
| the relay step is needed | step 3 is missing, or was done with another key, port or user: `revtunnel-relay.sh --list` on the relay shows which key it has for each port |
| Windows refused this computer's own tunnel key file (shown on the target) | a permissions problem on the target, not the relay: run the setup again and choose "Go through the whole setup again" |
| the relay refused the port | the target and the relay disagree on the port; or wait a minute after a drop |
| no answer from the relay | wrong address or SSH port, or a firewall / the network blocks it |
| nothing answers on that SSH port | right relay, wrong SSH port |
| the relay's identity changed | the relay was rebuilt: re-run the target's setup to trust it again |
| stopped retrying | the retry limit was reached: choose "Reconnect now", or restart the target |

Logs: `C:\ProgramData\revtunnel\NAME\tunnel.log` (Windows), `/var/log/revtunnel-NAME.log` (Linux).
Installer output on Windows: `C:\ProgramData\revtunnel\setup.log`.

## Unattended targets

- The tunnel starts at boot, signed in or not. Programs you want to reach through it may only start when
  someone signs in: set Windows to sign in automatically if they need to run unattended.
- Choose **Keep awake** so the target doesn't sleep, and **turn VPNs off** if a VPN could carry the tunnel
  (it should go straight to the relay, not through a VPN that may change or stop).

## Scripted setup

Every question is also an option, and `-Yes` / `--yes` asks nothing (missing answers use the defaults):

```powershell
revtunnel-target-windows.cmd -Name lab -Relay 203.0.113.5 -TunnelPort 2223 -LoginKey "ssh-ed25519 AAAA... me" -KeepAwake -NoVpn -Yes
```

```bash
sudo bash revtunnel-target-linux.sh --name lab --relay 203.0.113.5 --tunnel-port 2223 --login-key "ssh-ed25519 AAAA... me" --keep-awake --yes
```

All options: the header of each script (`bash revtunnel-target-linux.sh --help`). `-Status` / `--status` shows
the status only; `-Pause` / `--pause` and `-Resume` / `--resume` with a name pause or resume that tunnel
(resume exits 0 once it's up, 1 if not yet); `-Remove` / `--remove` with a name removes that tunnel. A scripted setup that still needs
the relay step says so and leaves the tunnel retrying; it connects by itself once the step is done.

## Docs

- [SECURITY.md](SECURITY.md): what each side can do, keys, and what to keep private
- [DEPLOY.md](DEPLOY.md): what gets installed where, and how it runs
- [CHANGELOG.md](CHANGELOG.md): what changed
- [CLAUDE.md](CLAUDE.md): notes for Claude working on it
