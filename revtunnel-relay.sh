#!/usr/bin/env bash
# revtunnel, run on the RELAY (the machine with a fixed address, e.g. a VPS): let a TARGET's reverse SSH tunnel
# in (the target being the computer you want to reach), and nothing else.
#
# Run on the relay (any Linux with OpenSSH), as root or with sudo:
#
#   sudo bash revtunnel-relay.sh                              asks for the target's key and the port
#   sudo bash revtunnel-relay.sh 'TARGET KEY' [PORT] [USER]   as the target's setup shows it (2222, tunnel)
#   sudo bash revtunnel-relay.sh --list                       which targets are set up, which are connected
#   sudo bash revtunnel-relay.sh --remove PORT [USER]         remove the target on that port
#
# The target's key is the one line its setup shows (and saves to its Desktop), starting with ssh-ed25519.
# Safe to re-run. The user (default "tunnel") gets no shell and no password; each target's key may only open
# its own port, on this relay's 127.0.0.1, so the target is reachable from this relay alone:
#   ssh -p PORT TARGET_USER@127.0.0.1
# A key added for a port replaces any earlier key for that port (e.g. a reinstalled target).
set -euo pipefail

say()  { printf '    %s\n' "$*"; }
ok()   { printf '    \033[32m[ok]\033[0m   %s\n' "$*"; }
bad()  { printf '    \033[31m[x]\033[0m    %s\n' "$*" >&2; }
fail() { bad "$*"; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "Run it as root, or with sudo:  sudo bash $0 $*"
command -v sshd >/dev/null || [ -x /usr/sbin/sshd ] || fail "No OpenSSH server (sshd) on this relay. Install it first (e.g. apt install openssh-server / dnf install openssh-server)."
PATH="$PATH:/usr/sbin:/sbin"

keys_file() { local home; home="$(getent passwd "$1" | cut -d: -f6)"; echo "$home/.ssh/authorized_keys"; }

list() {
    local tuser="${1:-tunnel}" f; f="$(keys_file "$tuser" 2>/dev/null || true)"
    if ! id "$tuser" &>/dev/null || [ ! -s "$f" ]; then say "No targets set up for user '$tuser' yet."; return; fi
    say "Targets that may open a tunnel (user $tuser):"
    while read -r line; do
        port="$(sed -n 's/.*permitlisten="127\.0\.0\.1:\([0-9]*\)".*/\1/p' <<<"$line")"
        name="$(awk '{print $NF}' <<<"$line")"
        [ -n "$port" ] || continue
        if ss -Htln "sport = :$port" 2>/dev/null | grep -q .; then state=$'\033[32mconnected\033[0m'; else state=$'\033[33mnot connected\033[0m'; fi
        printf '      port %-6s %-45s %s\n' "$port" "$name" "$state"
    done < "$f"
    say "Log in to a connected target from here:  ssh -p PORT TARGET_USER@127.0.0.1"
}

if [ "${1:-}" = "--list" ]; then list "${2:-tunnel}"; exit; fi

if [ "${1:-}" = "--remove" ]; then
    PORT="${2:?usage: revtunnel-relay.sh --remove PORT [USER]}"; TUSER="${3:-tunnel}"
    f="$(keys_file "$TUSER")"
    [ -f "$f" ] && grep -qF "permitlisten=\"127.0.0.1:$PORT\"" "$f" || fail "No target is set up on port $PORT for user $TUSER."
    grep -vF "permitlisten=\"127.0.0.1:$PORT\"" "$f" > "$f.new" || true
    mv "$f.new" "$f"; chown "$TUSER:" "$f"; chmod 600 "$f"; restorecon "$f" 2>/dev/null || true
    # drop that target's tunnel now: the sshd process holding its port
    for pid in $(ss -Htlnp "sport = :$PORT" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u); do kill "$pid" 2>/dev/null || true; done
    ok "Removed the target on port $PORT. Done."
    exit
fi

KEY="${1:-}"; PORT="${2:-}"; TUSER="${3:-tunnel}"
echo
echo "revtunnel - let a target's tunnel in to this relay"
if [ -z "$KEY" ]; then
    say "Paste the target's tunnel key: the one line its setup showed under \"This computer's tunnel key\""
    say "(also in the text file revtunnel-NAME-relay-step.txt on the target's Desktop). It starts with ssh-ed25519."
    read -r -p "    Key: " KEY
fi
KEY="$(tr -d '\r' <<<"$KEY" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
[[ "$KEY" =~ ^(ssh-|ecdsa-|sk-)[^\ ]+\ [A-Za-z0-9+/=]+(\ .*)?$ ]] ||
    fail "That is not an SSH public key. Copy the whole line from the target, starting with ssh-ed25519, and put it in single quotes."
if [[ "${KEY##* }" != revtunnel-* ]]; then
    bad "This doesn't look like a target's TUNNEL key: those end in revtunnel-NAME-COMPUTERNAME (this one: ${KEY##* })."
    say "The tunnel key is the one the target's setup shows under \"This computer's tunnel key\", not a personal key"
    say "such as ~/.ssh/id_ed25519.pub. Keys for logging in to the target are pasted on the target, not here."
    if [ -t 0 ]; then
        read -r -p "    Use this key anyway? [y/N]: " a
        [[ "${a,,}" == y* ]] || exit 1
    else
        exit 1
    fi
fi
if [ -z "$PORT" ]; then
    read -r -p "    Port on this relay for that target (as set on the target) [2222]: " PORT
    PORT="${PORT:-2222}"
fi
[[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ] || fail "Bad port: $PORT (use 1024-65535, as set on the target)."
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
ok "The target's key may open port $PORT (on this relay's 127.0.0.1 only)"

grep -qiE '^\s*Include\s+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config ||
    fail "This relay's /etc/ssh/sshd_config has no 'Include /etc/ssh/sshd_config.d/*.conf' line. Add it at the top, then run this again."
# Only for this user: remote forwards only (the key option "port-forwarding" would also allow forwards INTO
# this relay, -L), and keepalives that free a dropped tunnel's port within a minute so the target can
# reconnect (other logins keep the relay's own settings). One file per user; a Match block ends with its
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
say "Done. Now go back to the target and press Enter there."
say "Once its tunnel is up, log in to the target from this relay with:  ssh -p $PORT TARGET_USER@127.0.0.1"
say "See all targets and whether they're connected:  sudo bash $0 --list"
