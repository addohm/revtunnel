#!/usr/bin/env bash
# revtunnel - server side: let a PC's reverse SSH tunnel in, and nothing else.
#
# Run on the server (any Linux with OpenSSH), as root or with sudo:
#
#   sudo bash revtunnel-server.sh                          asks for the PC's key and the port
#   sudo bash revtunnel-server.sh 'PC KEY' [PORT] [USER]   as the PC's setup shows it (port 2222, user tunnel)
#   sudo bash revtunnel-server.sh --list                   which PCs are set up, and which are connected
#   sudo bash revtunnel-server.sh --remove PORT [USER]     remove the PC on that port
#
# The PC's key is the one line its setup shows (and saves to its Desktop), starting with ssh-ed25519.
# Safe to re-run. The user (default "tunnel") gets no shell and no password; each PC's key may only open
# its own port, on this server's 127.0.0.1, so the PC is reachable from this server alone:
#   ssh -p PORT PC_USER@127.0.0.1
# A key added for a port replaces any earlier key for that port (e.g. a reinstalled PC).
set -euo pipefail

say()  { printf '    %s\n' "$*"; }
ok()   { printf '    \033[32m[ok]\033[0m   %s\n' "$*"; }
bad()  { printf '    \033[31m[x]\033[0m    %s\n' "$*" >&2; }
fail() { bad "$*"; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "Run it as root, or with sudo:  sudo bash $0 $*"
command -v sshd >/dev/null || [ -x /usr/sbin/sshd ] || fail "No OpenSSH server (sshd) on this server. Install it first (e.g. apt install openssh-server / dnf install openssh-server)."
PATH="$PATH:/usr/sbin:/sbin"

keys_file() { local home; home="$(getent passwd "$1" | cut -d: -f6)"; echo "$home/.ssh/authorized_keys"; }

list() {
    local tuser="${1:-tunnel}" f; f="$(keys_file "$tuser" 2>/dev/null || true)"
    if ! id "$tuser" &>/dev/null || [ ! -s "$f" ]; then say "No PCs set up for user '$tuser' yet."; return; fi
    say "PCs that may open a tunnel (user $tuser):"
    while read -r line; do
        port="$(sed -n 's/.*permitlisten="127\.0\.0\.1:\([0-9]*\)".*/\1/p' <<<"$line")"
        name="$(awk '{print $NF}' <<<"$line")"
        [ -n "$port" ] || continue
        if ss -Htln "sport = :$port" 2>/dev/null | grep -q .; then state=$'\033[32mconnected\033[0m'; else state=$'\033[33mnot connected\033[0m'; fi
        printf '      port %-6s %-45s %s\n' "$port" "$name" "$state"
    done < "$f"
    say "Log in to a connected PC from here:  ssh -p PORT PC_USER@127.0.0.1"
}

if [ "${1:-}" = "--list" ]; then list "${2:-tunnel}"; exit; fi

if [ "${1:-}" = "--remove" ]; then
    PORT="${2:?usage: revtunnel-server.sh --remove PORT [USER]}"; TUSER="${3:-tunnel}"
    f="$(keys_file "$TUSER")"
    [ -f "$f" ] && grep -qF "permitlisten=\"127.0.0.1:$PORT\"" "$f" || fail "No PC is set up on port $PORT for user $TUSER."
    grep -vF "permitlisten=\"127.0.0.1:$PORT\"" "$f" > "$f.new" || true
    mv "$f.new" "$f"; chown "$TUSER:" "$f"; chmod 600 "$f"; restorecon "$f" 2>/dev/null || true
    # drop that PC's tunnel now: the sshd process holding its port
    for pid in $(ss -Htlnp "sport = :$PORT" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u); do kill "$pid" 2>/dev/null || true; done
    ok "Removed the PC on port $PORT. Done."
    exit
fi

KEY="${1:-}"; PORT="${2:-}"; TUSER="${3:-tunnel}"
echo
echo "revtunnel - let a PC's tunnel in to this server"
if [ -z "$KEY" ]; then
    say "Paste the PC's tunnel key: the one line its setup showed under \"This PC's tunnel key\""
    say "(also in the text file revtunnel-NAME-server-step.txt on the PC's Desktop). It starts with ssh-ed25519."
    read -r -p "    Key: " KEY
fi
KEY="$(tr -d '\r' <<<"$KEY" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
[[ "$KEY" =~ ^(ssh-|ecdsa-|sk-)[^\ ]+\ [A-Za-z0-9+/=]+(\ .*)?$ ]] ||
    fail "That is not an SSH public key. Copy the whole line from the PC, starting with ssh-ed25519, and put it in single quotes."
if [[ "${KEY##* }" != revtunnel-* ]]; then
    bad "This doesn't look like a PC's TUNNEL key: those end in revtunnel-NAME-PCNAME (this one: ${KEY##* })."
    say "The tunnel key is the one the PC's setup shows under \"This PC's tunnel key\", not a personal key"
    say "such as ~/.ssh/id_ed25519.pub. Keys for logging in to the PC are pasted on the PC, not here."
    if [ -t 0 ]; then
        read -r -p "    Use this key anyway? [y/N]: " a
        [[ "${a,,}" == y* ]] || exit 1
    else
        exit 1
    fi
fi
if [ -z "$PORT" ]; then
    read -r -p "    Port on this server for that PC (as set on the PC) [2222]: " PORT
    PORT="${PORT:-2222}"
fi
[[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ] || fail "Bad port: $PORT (use 1024-65535, as set on the PC)."
[[ "$TUSER" =~ ^[a-z_][a-z0-9_-]*$ ]] || fail "Bad user name: $TUSER"
blob="$(cut -d' ' -f2 <<<"$KEY")"

id "$TUSER" &>/dev/null || { useradd --create-home --shell "$(command -v nologin || echo /sbin/nologin)" "$TUSER"; ok "Created user $TUSER (no shell, no password)"; }
usermod -p '*' "$TUSER"  # no password, but not "locked" (sshd refuses locked accounts even with a key)
f="$(keys_file "$TUSER")"
mkdir -p "$(dirname "$f")"
touch "$f"
{ grep -vF -e "$blob" -e "permitlisten=\"127.0.0.1:$PORT\"" "$f" || true
  echo "restrict,port-forwarding,permitlisten=\"127.0.0.1:$PORT\" $KEY"; } > "$f.new"
mv "$f.new" "$f"
chown -R "$TUSER:" "$(dirname "$f")"
chmod 700 "$(dirname "$f")"
chmod 600 "$f"
restorecon -R "$(dirname "$f")" 2>/dev/null || true
ok "The PC's key may open port $PORT (on this server's 127.0.0.1 only)"

grep -qiE '^\s*Include\s+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config ||
    fail "This server's /etc/ssh/sshd_config has no 'Include /etc/ssh/sshd_config.d/*.conf' line. Add it at the top, then run this again."
# Only for this user: remote forwards only (the key option "port-forwarding" would also allow forwards INTO
# this server, -L), and keepalives that free a dropped tunnel's port within a minute so the PC can
# reconnect (other logins keep the server's own settings). One file per user; a Match block ends with its
# file. Earlier versions set the keepalives for everyone in 40-revtunnel.conf.
rm -f /etc/ssh/sshd_config.d/40-revtunnel.conf
cat > "/etc/ssh/sshd_config.d/41-revtunnel-$TUSER.conf" <<CONF
Match User $TUSER
    ClientAliveInterval 15
    ClientAliveCountMax 4
    AllowTcpForwarding remote
    X11Forwarding no
    AllowAgentForwarding no
    AllowStreamLocalForwarding no
    PermitTTY no
CONF
sshd -t || fail "sshd rejected the configuration (see above); nothing was reloaded."
systemctl reload sshd 2>/dev/null || systemctl reload ssh
ok "SSH server settings for $TUSER in place (forwards only, keepalives)"

echo
say "Done. Now go back to the PC and press Enter there."
say "Once its tunnel is up, log in to the PC from this server with:  ssh -p $PORT PC_USER@127.0.0.1"
say "See all PCs and whether they're connected:  sudo bash $0 --list"
