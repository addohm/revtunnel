# revtunnel

Reach a PC that nothing can connect to (dynamic IP, NAT, a strict firewall, another country) by having
**the PC** keep a connection open to a server you control. Through that connection, a port on the server
leads back to the PC: usually its SSH server, or any other port (Remote Desktop, VNC, a web UI).

```
you --ssh--> server, port 2222 (its own 127.0.0.1 only) ==tunnel==> PC, port 22
```

- **PC side:** Windows 10/11 or Linux. A guided setup that you can re-run any time to see the status or
  change something. The tunnel runs from startup, also with nobody signed in, and reconnects by itself.
- **Server side:** any Linux server with OpenSSH, e.g. a small VPS. One command per PC.
- Plain OpenSSH, nothing else to install. The PC is reachable from the server alone; the server user that
  holds the tunnels can do nothing but hold them.

| File | Runs on | What it is |
|---|---|---|
| `revtunnel-windows.cmd` | Windows PC | Double-click this. It starts the `.ps1` next to it |
| `revtunnel-windows.ps1` | Windows PC | The Windows setup |
| `revtunnel-linux.sh` | Linux PC | The Linux setup |
| `revtunnel-server.sh` | the server | Lets a PC's tunnel in; lists and removes PCs |

## Quick start

You need: the PC, a server with a fixed address that the PC can reach (as root or with sudo), and about
ten minutes. Each step says **where** it happens.

### 1. Get the files

- **Windows PC:** `revtunnel-windows.cmd` **and** `revtunnel-windows.ps1`, in the same folder. Either
  `git clone https://github.com/addohm/revtunnel.git`, or open each file on GitHub and use the **Raw**
  button (or the download button), then save it. Saving the normal GitHub page gives you an HTML file
  that won't run.
- **Linux PC:** `curl -fsSLO https://raw.githubusercontent.com/addohm/revtunnel/main/revtunnel-linux.sh`
- **The server:** nothing yet; the PC's setup tells you when (step 3).

### 2. On the PC: run the setup

- **Windows:** double-click `revtunnel-windows.cmd` (or run it from a PowerShell window) and allow it to
  make changes. If Windows says it "protected your PC", choose **More info → Run anyway**. Setup continues
  in a new administrator window. Running `revtunnel-windows.ps1` directly fails on a fresh Windows
  ("running scripts is disabled"): always start the `.cmd`.
- **Linux:** `sudo bash revtunnel-linux.sh`

It goes step by step and explains each one. You'll be asked for:

| Question | What to answer |
|---|---|
| Tunnel name | Enter (`main`), unless this PC gets several tunnels |
| Port on this PC | Enter (22, SSH logins), or the port of the program to reach, e.g. 3389 for Remote Desktop |
| Keys allowed to log in | The *public* SSH key (one line, starting `ssh-ed25519`) of each machine that will make the last hop to this PC: usually **your own computer's** (`cat ~/.ssh/id_ed25519.pub` there; see step 5 for why). Enter on an empty line when done |
| Extras | Keep awake, turn VPNs off, install Python (Windows): yes to what an unattended PC needs |
| Server address, SSH port, user | The server's IP or name; Enter for 22 and `tunnel` |
| Port on the server | Enter (2222) for the first PC; every PC on the same server needs its own (2223, ...) |
| Reconnect attempts | Enter (0 = never give up), or a number of failed attempts in a row before it stops |

### 3. On the server: let the PC in

The first time, the PC stops with **ACTION NEEDED - on the SERVER** and shows what to run there (also
saved in a text file on the PC's Desktop, or in `/etc/revtunnel/NAME/server-step.txt` on Linux):

```bash
curl -fsSLO https://raw.githubusercontent.com/addohm/revtunnel/main/revtunnel-server.sh
sudo bash revtunnel-server.sh 'ssh-ed25519 AAAA... revtunnel-main-MYPC' 2222 tunnel
```

Or run `sudo bash revtunnel-server.sh` and paste the PC's key when it asks. It ends with **Done**.

**Two kinds of key, don't mix them up:**
- the PC's **tunnel key** (ends in `revtunnel-NAME-PCNAME`): made by the PC's setup, goes to the
  **server** in this step. It lets the PC hold its tunnel, nothing else.
- **login keys** (e.g. `~/.ssh/id_ed25519.pub` of a person or of the server): pasted **on the PC** in
  step 2. They let someone log in to the PC through the tunnel (whose key: see step 5).

### 4. On the PC: press Enter

Setup connects and ends with **DONE** and how to reach the PC, or explains what is still wrong.

### 5. From your own computer: reach the PC

**The rule:** the PC only checks the key of the machine that makes the **last hop** to it. That key must be
one of the PC's login keys (step 2, or "Allow another key" later). Never run these on the PC itself.

**Option A, one command (recommended):** your computer makes both hops, so only **your** key is needed:
on the server (as you already log in there) and on the PC.

```
  your computer ───ssh (your key)───> server ──tunnel, port 2222──> PC
        │                                                            ▲
        └──────────────── ssh -J: your key again ────────────────────┘
                     (the last hop is from YOUR computer)
```

```bash
ssh -J root@SERVER -p 2222 PC_USER@127.0.0.1
```

Or put it in `~/.ssh/config` on your computer, then just `ssh mypc`:

```
Host mypc
    HostName 127.0.0.1
    Port 2222
    User PC_USER
    ProxyJump root@SERVER
```

**Option B, two logins:** you log in to the server, and **the server** makes the last hop, so the PC needs
**the server's** key (make one there with `ssh-keygen -t ed25519`; add its `~/.ssh/id_ed25519.pub` on the
PC).

```
  your computer ───ssh (your key)───> server ───ssh (SERVER's key)───> PC
                                        │                               ▲
                                        └──── tunnel, port 2222 ────────┘
```

```bash
ssh root@SERVER                    # on your computer: log in to the server
ssh -p 2222 PC_USER@127.0.0.1      # then, on the server: log in to the PC
```

Option A keeps one key in one place and none on the server; option B is handy when you are on the server
anyway, or for things that run there.

`PC_USER` is the user setup showed (on Windows, the account that ran it). Only the keys added in step 2
work: passwords are off on Windows, and on Linux the PC's SSH settings are left as they were.

For a port other than SSH, open a forward through the server and point your program at `localhost`:
`ssh -L 3389:127.0.0.1:2222 root@SERVER`, then connect to `localhost:3389`.

## Later

Run the setup on the PC again (double-click the `.cmd`, or `sudo bash revtunnel-linux.sh`). It shows the
status of the tunnel and offers:

1. **Reconnect now**
2. **Change the server address**, e.g. when the server got a new IP: enter the new one, Enter for the
   rest. A *different* server also needs step 3; setup asks for it if so.
3. **Allow another key to log in** (SSH tunnels)
4. **Show the server step again**
5. **Go through the whole setup again**
6. **Remove this tunnel**

On the server:

```bash
sudo bash revtunnel-server.sh --list           # every PC, its port, and whether it is connected now
sudo bash revtunnel-server.sh --remove 2222    # remove the PC on that port
```

## When it doesn't connect

The PC's setup (and its status) translates the tunnel's log into plain language. The usual causes:

| Status says | What to do |
|---|---|
| the server step is needed | step 3 is missing, or was done with another key, port or user: `revtunnel-server.sh --list` on the server shows which key it has for each port |
| Windows refused this PC's own tunnel key file | a permissions problem on the PC, not the server: run the setup again and choose "Go through the whole setup again" |
| the server refused the port | the PC and the server disagree on the port; or wait a minute after a drop |
| no answer from the server | wrong address or SSH port, or a firewall / the network blocks it |
| nothing answers on that SSH port | right server, wrong SSH port |
| the server's identity changed | the server was rebuilt: re-run the PC's setup to trust it again |
| stopped retrying | the retry limit was reached: choose "Reconnect now", or restart the PC |

Logs: `C:\ProgramData\revtunnel\NAME\tunnel.log` (Windows), `/var/log/revtunnel-NAME.log` (Linux).
Installer output on Windows: `C:\ProgramData\revtunnel\setup.log`.

## Unattended PCs

- The tunnel starts at boot, signed in or not. Programs you want to reach through it may only start when
  someone signs in: set Windows to sign in automatically if they need to run unattended.
- Choose **Keep awake** so the PC doesn't sleep, and **turn VPNs off** if a VPN could carry the tunnel
  (it should go straight to the server, not through a VPN that may change or stop).

## Scripted setup

Every question is also an option, and `-Yes` / `--yes` asks nothing (missing answers use the defaults):

```powershell
revtunnel-windows.cmd -Name lab -Server 203.0.113.5 -RemotePort 2223 -LoginKey "ssh-ed25519 AAAA... me" -KeepAwake -NoVpn -Yes
```

```bash
sudo bash revtunnel-linux.sh --name lab --server 203.0.113.5 --remote-port 2223 --login-key "ssh-ed25519 AAAA... me" --keep-awake --yes
```

All options: the header of each script (`bash revtunnel-linux.sh --help`). `-Status` / `--status` shows
the status only; `-Remove` / `--remove` with a name removes that tunnel. A scripted setup that still needs
the server step says so and leaves the tunnel retrying; it connects by itself once the step is done.

## Docs

- [SECURITY.md](SECURITY.md): what each side can do, keys, and what to keep private
- [DEPLOY.md](DEPLOY.md): what gets installed where, and how it runs
- [CHANGELOG.md](CHANGELOG.md): what changed
- [CLAUDE.md](CLAUDE.md): notes for Claude working on it
