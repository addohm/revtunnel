#!/usr/bin/env bash
# revtunnel for Linux, run on the TARGET (the computer you want to reach): keeps a reverse SSH tunnel from this
# computer to a RELAY (a machine with a fixed address, e.g. a VPS), so you can reach this computer through the
# relay even though nothing can connect to it directly (dynamic IP, NAT, firewall, ...).
#
#   sudo bash revtunnel-target-linux.sh [options]
#
# It guides you through every step; re-run it any time to see the tunnel's status or change something.
# See README.md for the whole workflow, including the relay step.
#
# Options (all optional; anything not given is asked, or its default used with --yes):
#   --name NAME           tunnel name (default "main"); several tunnels can run side by side
#   --target-port N       port on this computer the tunnel leads to (default 22 = SSH; e.g. 3389, 5900, 8080)
#   --relay HOST          the relay's IP or host name
#   --relay-ssh-port N    the relay's SSH port (default 22)
#   --relay-user USER     user on the relay that holds the tunnel (default "tunnel")
#   --tunnel-port N       port on the relay that leads to this computer (default 2222; one per target)
#                         (older names still work: --local-port, --server, --server-port, --server-user,
#                         --remote-port)
#   --retries N           reconnect attempts in a row before giving up (default 0 = never give up)
#   --login-user USER     user on this computer people log in as (default: the one running sudo)
#   --login-key KEY       a public SSH key allowed to log in to this computer (repeat for more; port 22 only)
#   --keep-awake          never suspend or hibernate
#   --no-vpn              turn off VPN connections and VPN/TUN interfaces, so the tunnel goes direct
#   --yes                 ask nothing: use the options and defaults (for scripts)
#   --status              only show the status of this computer's tunnels
#   --pause               pause the tunnel given by --name: stop it, also after a restart; keep its setup
#   --resume              resume it: start it now and from boot again (exits 0 once it's up, 1 if not yet)
#   --remove              remove the tunnel given by --name
#
# Files: /etc/revtunnel/NAME (settings, the tunnel's key; "paused" while paused), /var/log/revtunnel-NAME.log.
# The tunnel runs as the systemd service revtunnel-NAME, from boot (not while paused).
set -euo pipefail

ROOT=/etc/revtunnel
[ "$(id -u)" -eq 0 ] || { echo "revtunnel needs root; asking sudo ..."; exec sudo bash "$0" "$@"; }

NAME= LPORT_ARG= SERVER_ARG= SPORT_ARG= SUSER_ARG= RPORT_ARG= RETRIES_ARG= LOGIN_USER= YES= STATUS= REMOVE=
PAUSE= RESUME=
KEEP_AWAKE= NO_VPN= CHANGES=
LOGIN_KEYS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --name) NAME="$2"; shift ;;
        --target-port|--local-port) LPORT_ARG="$2"; CHANGES=1; shift ;;
        --relay|--server) SERVER_ARG="$2"; CHANGES=1; shift ;;
        --relay-ssh-port|--server-port) SPORT_ARG="$2"; CHANGES=1; shift ;;
        --relay-user|--server-user) SUSER_ARG="$2"; CHANGES=1; shift ;;
        --tunnel-port|--remote-port) RPORT_ARG="$2"; CHANGES=1; shift ;;
        --retries) RETRIES_ARG="$2"; CHANGES=1; shift ;;
        --login-user) LOGIN_USER="$2"; CHANGES=1; shift ;;
        --login-key) LOGIN_KEYS+=("$2"); CHANGES=1; shift ;;
        --keep-awake) KEEP_AWAKE=yes ;;  # extras only apply to a whole setup: no CHANGES, so presets get the menu
        --no-vpn) NO_VPN=yes ;;
        --yes) YES=1 ;;
        --status) STATUS=1 ;;
        --remove) REMOVE=1 ;;
        --pause) PAUSE=1 ;;
        --resume) RESUME=1 ;;
        -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit ;;
        *) echo "Unknown option: $1 (see --help)" >&2; exit 1 ;;
    esac
    shift
done

# ---- Output helpers ------------------------------------------------------------------------------------

LINE="$(printf '=%.0s' {1..78})"
say()  { printf '    %s\n' "$*"; }
dim()  { printf '    \033[2m%s\033[0m\n' "$*"; }
ok()   { printf '    \033[32m[ok]\033[0m   %s\n' "$*"; }
warn() { printf '    \033[33m[!]\033[0m    %s\n' "$*"; }
bad()  { printf '    \033[31m[x]\033[0m    %s\n' "$*"; }
STEP=0 STEPS=0
step() { STEP=$((STEP + 1)); printf '\n\033[36mStep %s of %s: %s\033[0m\n' "$STEP" "$STEPS" "$1"; shift; for l in "$@"; do dim "$l"; done; }
banner() {
    local title="$1"; shift
    printf '\n\033[33m%s\n  %s\n%s\033[0m\n' "$LINE" "$title" "$LINE"
    for l in "$@"; do printf '  %s\n' "$l"; done
    printf '\033[33m%s\033[0m\n' "$LINE"
}
ask() {  # ask VAR "question" default
    local a
    if [ -n "$YES" ]; then printf -v "$1" '%s' "$3"; return; fi
    read -r -p "    $2 [$3]: " a
    printf -v "$1" '%s' "${a:-$3}"
}
ask_int() {  # ask_int VAR "question" default min max
    local v
    while true; do
        ask v "$2" "$3"
        if [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge "$4" ] && [ "$v" -le "$5" ]; then printf -v "$1" '%s' "$v"; return; fi
        [ -z "$YES" ] || { bad "$2: '$v' is not a number from $4 to $5"; exit 1; }
        warn "Please enter a number from $4 to $5."
    done
}
ask_yn() {  # ask_yn "question" -> 0 for yes (default no)
    local a
    [ -z "$YES" ] || return 1
    while true; do
        read -r -p "    $1 [y/N]: " a
        case "${a,,}" in y|yes) return 0 ;; ""|n|no) return 1 ;; esac
    done
}

pkg_install() {  # pkg_install apt-name dnf-name zypper-name pacman-name
    if command -v apt-get >/dev/null; then DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$1" >/dev/null
    elif command -v dnf >/dev/null; then dnf install -y -q "$2" >/dev/null
    elif command -v yum >/dev/null; then yum install -y -q "$2" >/dev/null
    elif command -v zypper >/dev/null; then zypper -q install -y "$3" >/dev/null
    elif command -v pacman >/dev/null; then pacman -S --noconfirm --needed "$4" >/dev/null
    else return 1; fi
}

# ---- Tunnel state --------------------------------------------------------------------------------------

paths() { DIR="$ROOT/$1"; CONF="$DIR/tunnel.conf"; KEY="$DIR/id_ed25519"; LOOP="$DIR/tunnel.sh"
          LOG="/var/log/revtunnel-$1.log"; UNIT="revtunnel-$1"; STEPFILE="$DIR/relay-step.txt"; PAUSED="$DIR/paused"; }

meaning() {  # plain-language meaning of ssh's messages in $1
    local s="$1"
    case "$s" in
        *"gave up after"*) echo "The tunnel stopped retrying (the retry limit was reached): run this setup again, or reboot." ;;
        *"Permission denied"*) echo "The relay doesn't know this computer's tunnel key (yet): the relay step is needed." ;;
        *"remote port forwarding failed"*) echo "The relay refused the port: it's set up for another port for this key, or a tunnel that just dropped still holds it (it frees up within a minute)." ;;
        *"Could not resolve hostname"*) echo "The relay's name wasn't found: check the address." ;;
        *"Connection refused"*) echo "The relay was reached, but nothing answers on that SSH port: check the port." ;;
        *"timed out"*) echo "No answer from the relay: check the address and port, or a firewall / the network blocks it." ;;
        *"Network is unreachable"*|*"No route to host"*) echo "This computer has no network route to the relay: check the internet connection." ;;
        *"IDENTIFICATION HAS CHANGED"*|*"Host key verification failed"*) echo "The relay's identity changed (e.g. it was rebuilt): run this setup again to trust it again." ;;
        *) echo "" ;;
    esac
}

state() {  # sets STATE and DETAIL from the log
    STATE="not started" DETAIL=""
    if [ -f "$PAUSED" ]; then STATE=paused; DETAIL="paused since $(cat "$PAUSED"); to resume it, run this setup again (option 7)"; return; fi
    [ -f "$LOG" ] || return 0
    local n session previous when m
    n="$(grep -n 'connecting to ' "$LOG" | tail -1 | cut -d: -f1 || true)"
    [ -n "$n" ] || return 0
    session="$(tail -n "+$n" "$LOG")"
    when="$(head -c 19 <<<"$session" | tr T ' ')"
    if grep -q 'gave up after' <<<"$session"; then STATE=stopped; DETAIL="$(meaning "$session")"; return; fi
    if grep -q 'disconnected (exit' <<<"$session"; then
        STATE=down; DETAIL="$(meaning "$session")"; DETAIL="${DETAIL:-See the log: $LOG}"; return
    fi
    if grep -q 'Authenticated to' <<<"$session"; then STATE=up; DETAIL="connected since $when"; return; fi
    previous="$(awk -v n="$n" 'NR < n && /connecting to /{b=""} NR < n{b=b $0 "\n"} END{printf "%s", b}' "$LOG")"
    m="$(meaning "$previous")"
    if [ -n "$m" ]; then STATE=retrying; DETAIL="last attempt failed: $m"; else STATE=connecting; DETAIL="trying since $when"; fi
}

load() { HOST= PORT=22 TUSER=tunnel RPORT=2222 LPORT=22 RETRIES=0; [ -f "$CONF" ] && . "$CONF"; return 0; }
save() {
    mkdir -p "$DIR"; chmod 700 "$DIR"
    printf 'HOST=%q\nPORT=%q\nTUSER=%q\nRPORT=%q\nLPORT=%q\nRETRIES=%q\n' "$HOST" "$PORT" "$TUSER" "$RPORT" "$LPORT" "$RETRIES" > "$CONF"
}

tunnels() { [ -d "$ROOT" ] && for d in "$ROOT"/*/; do [ -f "$d/tunnel.conf" ] && basename "$d"; done; return 0; }

show_status() {
    local n
    [ $# -gt 0 ] || { say "No tunnels are set up on this computer yet."; return; }
    for n in "$@"; do
        paths "$n"; load; state
        case "$STATE" in up) c=32 ;; connecting|retrying) c=33 ;; paused) c=36 ;; *) c=31 ;; esac
        printf '\n    \033[%smTunnel %s: %s\033[0m\n' "$c" "'$n'" "${STATE^^}"
        [ -z "$DETAIL" ] || say "  $DETAIL"
        say "  relay $HOST (SSH port $PORT, user $TUSER); relay port $RPORT -> this computer's port $LPORT"
        say "  retries: $([ "$RETRIES" -gt 0 ] && echo "$RETRIES in a row" || echo "never gives up"); service: $(systemctl is-active "$UNIT" 2>/dev/null || true); log: $LOG"
    done
}

restart_tunnel() { systemctl stop "$UNIT" 2>/dev/null || true; [ -f "$LOG" ] && mv -f "$LOG" "$LOG.old"; systemctl start "$UNIT"; }
wait_tunnel() {
    local i
    for i in $(seq 35); do
        sleep 1
        if grep -q 'Authenticated to' "$LOG" 2>/dev/null; then sleep 3; break; fi
        grep -q 'disconnected (exit' "$LOG" 2>/dev/null && break
    done
    state
}

outcome() {  # say how a (re)connect went; 0 if the tunnel is up
    if [ "$STATE" = up ]; then ok "The tunnel is up ($DETAIL)."; return 0; fi
    if [[ "$DETAIL" == *"relay step"* ]]; then bad "$DETAIL"; relay_step
    else bad "The tunnel is not up: $DETAIL"; say "It keeps retrying in the background."; fi
    return 1
}

pause_tunnel() {
    systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
    date '+%F %R' > "$PAUSED"
    echo "$(date +%FT%T) paused" >> "$LOG"
    ok "Tunnel '$NAME' paused: it's stopped, and stays off after a restart. Its key and settings are kept."
    say "To resume it, run this setup again (option 7), or:  sudo bash $0 --name $NAME --resume"
}

resume_tunnel() {  # 0 if it came up
    rm -f "$PAUSED"
    systemctl enable "$UNIT" >/dev/null 2>&1 || true
    say "Connecting ..."; restart_tunnel; wait_tunnel
    outcome
}

relay_step() {
    local pub; pub="$(cat "$KEY.pub")"
    local lines=(
        "Do this on the RELAY ($HOST), not on this computer. It lets this computer's tunnel in."
        ""
        "1. Log in to the relay as root (or as a user who can use sudo)."
        "2. Put revtunnel-relay.sh there: it comes with revtunnel, next to this script. For example,"
        "   from the computer that has it:  scp revtunnel-relay.sh root@$HOST:"
        "3. On the relay, run this one line:"
        "     sudo bash revtunnel-relay.sh '$pub' $RPORT $TUSER"
        "   or just \"sudo bash revtunnel-relay.sh\" and paste this computer's key when it asks."
        "4. When the relay says \"Done\", come back to this computer."
        ""
        "This computer's tunnel key (one line):"
        "$pub"
    )
    printf '%s\n' "revtunnel - relay step for tunnel '$NAME' on $(hostname) (the target)" "" "${lines[@]}" > "$STEPFILE"
    banner "ACTION NEEDED - on the RELAY" "${lines[@]}" "" "(All of this is also in $STEPFILE)"
}

# ---- Which tunnel ----------------------------------------------------------------------------------------

mkdir -p "$ROOT"; chmod 700 "$ROOT"
echo
printf '\033[36m%s\033[0m\n' "revtunnel - reverse SSH tunnel from this computer to a relay"
mapfile -t EXISTING < <(tunnels)

if [ -n "$STATUS" ]; then if [ -n "$NAME" ]; then show_status "$NAME"; else show_status "${EXISTING[@]}"; fi; exit; fi

if [ -z "$NAME" ]; then
    if [ ${#EXISTING[@]} -gt 0 ] && [ -z "$YES" ]; then
        say "Tunnels already set up on this computer:"; show_status "${EXISTING[@]}"; echo
        say "To change one, type its name. To set up another one, type a new name."
    fi
    while true; do
        ask NAME "Tunnel name (letters, digits, - or _)" "${EXISTING[0]:-main}"
        [[ "$NAME" =~ ^[A-Za-z0-9_-]+$ ]] && break
    done
fi
[[ "$NAME" =~ ^[A-Za-z0-9_-]+$ ]] || { bad "Bad tunnel name: $NAME (letters, digits, - or _)"; exit 1; }
paths "$NAME"; load
NEW=; [ -f "$CONF" ] || NEW=1

if [ -n "$PAUSE" ] || [ -n "$RESUME" ]; then
    [ -z "$NEW" ] || { bad "There is no tunnel '$NAME' on this computer."; exit 1; }
    if [ -n "$PAUSE" ]; then
        if [ -f "$PAUSED" ]; then say "Tunnel '$NAME' is already paused (since $(cat "$PAUSED"))."; else pause_tunnel; fi
        exit 0
    fi
    [ -f "$PAUSED" ] || say "Tunnel '$NAME' isn't paused; reconnecting it."
    resume_tunnel && exit 0 || exit 1
fi

if [ -n "$REMOVE" ]; then
    [ -z "$NEW" ] || { say "There is no tunnel '$NAME' on this computer."; exit; }
    systemctl disable --now "$UNIT" 2>/dev/null || true
    rm -f "/etc/systemd/system/$UNIT.service"; systemctl daemon-reload
    rm -rf "$DIR" "$LOG" "$LOG.old"
    ok "Tunnel '$NAME' removed from this computer (service, key, settings and log)."
    say "On the relay ($HOST), remove its port too:  sudo bash revtunnel-relay.sh --remove $RPORT"
    exit
fi

# ---- Re-run menu -----------------------------------------------------------------------------------------

ACTION=all
if [ -z "$NEW" ] && [ -z "$YES" ] && [ -z "$CHANGES" ]; then
    show_status "$NAME"; echo
    IS_PAUSED=; [ ! -f "$PAUSED" ] || IS_PAUSED=1
    say "What would you like to do?"
    [ -n "$IS_PAUSED" ] || say "  1  Reconnect now (restart the tunnel)"
    say "  2  Change the relay address (or other relay details)"
    [ "$LPORT" != 22 ] || say "  3  Allow another key to log in to this computer"
    say "  4  Show the relay step again"
    say "  5  Go through the whole setup again"
    say "  6  Remove this tunnel"
    if [ -n "$IS_PAUSED" ]; then say "  7  Resume the tunnel (start it now, and from boot again)"
    else say "  7  Pause the tunnel (stop it, also after a restart; its setup stays for later)"; fi
    say "  8  Nothing (quit)"
    ask CHOICE "Choice" 8
    case "$CHOICE" in
        1) if [ -n "$IS_PAUSED" ]; then resume_tunnel || true
           else say "Connecting ..."; restart_tunnel; wait_tunnel; outcome || true; fi
           exit ;;
        2) ACTION=relay ;;
        3) ACTION=keys ;;
        4) relay_step; exit ;;
        5) ACTION=all ;;
        6) exec bash "$0" --name "$NAME" --remove ;;
        7) if [ -n "$IS_PAUSED" ]; then resume_tunnel || true; else pause_tunnel; fi; exit ;;
        *) exit ;;
    esac
fi

# ---- Plan the steps --------------------------------------------------------------------------------------

if [ "$ACTION" = all ]; then
    if [ -n "$LPORT_ARG" ]; then LPORT="$LPORT_ARG"
    elif [ -z "$YES" ]; then
        echo
        say "Where should the tunnel lead on this computer? 22 = SSH logins (the usual choice; sets up the"
        say "computer's SSH server). Another port forwards to that program instead, e.g. 5900 for VNC."
        ask_int LPORT "Port on this computer" "$LPORT" 1 65535
    fi
fi
DO_SSH=; DO_KEYS=; DO_EXTRAS=; DO_RELAY=
[ "$ACTION" = all ] && [ "$LPORT" = 22 ] && DO_SSH=1
{ [ "$ACTION" = all ] && [ "$LPORT" = 22 ]; } || [ "$ACTION" = keys ] && DO_KEYS=1
[ "$ACTION" = all ] && DO_EXTRAS=1
[ "$ACTION" = all ] || [ "$ACTION" = relay ] && DO_RELAY=1
STEPS=$(( ${DO_SSH:-0} + ${DO_KEYS:-0} + ${DO_EXTRAS:-0} + 2 * ${DO_RELAY:-0} ))

# the tunnel itself needs the ssh client
command -v ssh >/dev/null || pkg_install openssh-client openssh-clients openssh openssh || { bad "Could not install the ssh client; install it and run this again."; exit 1; }

# ---- SSH server on this computer -------------------------------------------------------------------------------

if [ -n "$DO_SSH" ]; then
    step "This computer's SSH server" "People log in to this computer with SSH through the tunnel, so this computer needs an SSH server." \
        "Its existing settings are kept (if it already accepts logins from your network, it still does)."
    command -v sshd >/dev/null || [ -x /usr/sbin/sshd ] || pkg_install openssh-server openssh-server openssh openssh ||
        { bad "Could not install the SSH server; install openssh-server and run this again."; exit 1; }
    systemctl enable --now sshd 2>/dev/null || systemctl enable --now ssh 2>/dev/null || true
    if ss -Htln 'sport = :22' | grep -q .; then ok "SSH server running on port 22"; else warn "The SSH server doesn't seem to listen on port 22; check it (systemctl status sshd)."; fi
fi

# ---- Who may log in --------------------------------------------------------------------------------------

if [ -n "$DO_KEYS" ]; then
    step "Who may log in to this computer" "Paste the PUBLIC SSH key of each machine people will log in FROM: usually your own computer" \
        "(with \"ssh -J\" through the relay), or the relay itself if you log in from there. This computer checks" \
        "the key of the machine that makes the last hop to it. A public key is one line starting with ssh-ed25519," \
        "ssh-rsa or ecdsa-, e.g. ~/.ssh/id_ed25519.pub (show it: cat ~/.ssh/id_ed25519.pub; make one:" \
        "ssh-keygen -t ed25519). Never paste a PRIVATE key (it starts with -----BEGIN)."
    if [ -z "$LOGIN_USER" ]; then ask LOGIN_USER "User on this computer they log in as" "${SUDO_USER:-root}"; fi
    id "$LOGIN_USER" &>/dev/null || { bad "There is no user '$LOGIN_USER' on this computer."; exit 1; }
    home="$(getent passwd "$LOGIN_USER" | cut -d: -f6)"; ak="$home/.ssh/authorized_keys"
    install -d -m 700 -o "$LOGIN_USER" -g "$(id -gn "$LOGIN_USER")" "$home/.ssh"; touch "$ak"
    [ -s "$ak" ] && say "Already allowed: $(awk '{print $NF}' "$ak" | paste -sd, - | sed 's/,/, /g')"
    if [ -z "$YES" ]; then
        say "Paste one key and press Enter; repeat for more. Press Enter on an empty line when done."
        while true; do
            read -r -p "    Key: " k
            k="$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<<"$k")"
            [ -n "$k" ] || break
            if [[ "$k" == *"PRIVATE KEY"* ]]; then bad "That is a PRIVATE key. Never share it; paste the .pub file instead."; continue; fi
            [[ "$k" =~ ^(ssh-|ecdsa-|sk-)[^\ ]+\ [^\ ]+ ]] || { warn "That is not a public SSH key (see above). Try again, or press Enter to finish."; continue; }
            LOGIN_KEYS+=("$k")
        done
    fi
    for k in "${LOGIN_KEYS[@]}"; do
        if grep -qxF "$k" "$ak"; then say "Already allowed: ${k##* }"; else echo "$k" >> "$ak"; ok "Added: ${k##* }"; fi
    done
    chown "$LOGIN_USER:" "$ak"; chmod 600 "$ak"; restorecon -R "$home/.ssh" 2>/dev/null || true
    if [ -s "$ak" ]; then ok "$(grep -c . "$ak") key(s) may log in as $LOGIN_USER"
    else warn "No keys yet, so nobody can log in with a key. Run this again and choose \"Allow another key\"."; fi
    [ "$ACTION" != keys ] || exit 0
fi

# ---- Extras ----------------------------------------------------------------------------------------------

if [ -n "$DO_EXTRAS" ]; then
    step "Optional extras" "Things that help when this computer runs unattended. Skip what you don't need."
    if [ -n "$KEEP_AWAKE" ] || ask_yn "Keep this computer awake? (a suspended computer drops the tunnel)"; then
        systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1 ||
            warn "Could not turn off suspend (systemctl mask failed)"
        ok "Suspend and hibernate are off (undo: systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target)"
    fi
    if [ -n "$NO_VPN" ] || ask_yn "Turn off VPNs? (a VPN can carry or break the tunnel)"; then
        found=
        if command -v nmcli >/dev/null; then
            while IFS=: read -r cname ctype; do
                [[ "$ctype" =~ vpn|wireguard ]] || continue
                nmcli connection down "$cname" >/dev/null && ok "Disconnected VPN connection '$cname'" && found=1
            done < <(nmcli -t -f NAME,TYPE connection show --active)
        fi
        for ifc in $(ip -o link show up | awk -F': ' '{print $2}' | cut -d@ -f1); do
            [[ "$ifc" =~ ^(tun|tap|wg|tailscale|zt|ppp|Meta|Mihomo|mihomo|clash|utun|nordlynx|proton) ]] || continue
            ip link set dev "$ifc" down && ok "Turned off network interface $ifc (undo: ip link set dev $ifc up)" && found=1
        done
        if [ -n "$found" ]; then warn "Also turn off the VPN in its own app (its \"TUN\" or auto-connect setting), or it comes back."
        else ok "No VPN found"; fi
    fi
fi

# ---- Relay details --------------------------------------------------------------------------------------

if [ -n "$DO_RELAY" ]; then
    step "The relay" "The relay is a computer with a fixed address that this computer can reach, e.g. a VPS. This computer" \
        "keeps a connection open to it, and you reach this computer from there. Press Enter to keep a value in [ ]."
    [ -z "$SERVER_ARG" ] || HOST="$SERVER_ARG"
    while true; do ask HOST "Relay address (IP or host name)" "$HOST"; HOST="${HOST#[}"; HOST="${HOST%]}"; [ -n "$HOST" ] && break
        [ -z "$YES" ] || { bad "No relay address: give --relay."; exit 1; }; done
    if [ -n "$SPORT_ARG" ]; then PORT="$SPORT_ARG"; else ask_int PORT "Relay's SSH port" "$PORT" 1 65535; fi
    if [ -n "$SUSER_ARG" ]; then TUSER="$SUSER_ARG"; else ask TUSER "User on the relay that holds the tunnel (the relay step creates it)" "$TUSER"; fi
    if [ -n "$RPORT_ARG" ]; then RPORT="$RPORT_ARG"; else ask_int RPORT "Port on the relay that leads to this computer (each target needs its own, e.g. 2222, 2223, ...)" "$RPORT" 1024 65535; fi
    if [ -n "$RETRIES_ARG" ]; then RETRIES="$RETRIES_ARG"; else ask_int RETRIES "Reconnect attempts before giving up (0 = never give up)" "$RETRIES" 0 1000000; fi
    save
    ok "Relay $HOST, port $RPORT there leads to port $LPORT here"

    step "Start the tunnel" "Makes this computer's own key for the tunnel (separate from the login keys), then connects." \
        "The first time, the relay does not know this computer yet: you will be asked to do the relay step."
    [ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -C "revtunnel-$NAME-$(hostname)" -f "$KEY"
    chmod 600 "$KEY"
    rm -f "$DIR/known_hosts"  # trust the relay's host key afresh (the relay or its address may have changed)
    cat > "$LOOP" <<'LOOP'
#!/usr/bin/env bash
# Written by revtunnel-target-linux.sh; run by the revtunnel-NAME service. Keeps the tunnel up.
dir="$(dirname "$(readlink -f "$0")")"; log="/var/log/revtunnel-$(basename "$dir").log"; fails=0
while true; do
    . "$dir/tunnel.conf"
    if [ -f "$log" ] && [ "$(stat -c %s "$log")" -gt 1048576 ]; then mv -f "$log" "$log.old"; fi
    echo "$(date +%FT%T) connecting to $TUSER@$HOST port $PORT" >> "$log"
    start=$(date +%s)
    ssh -N -E "$log" -i "$dir/id_ed25519" -p "$PORT" \
        -o BatchMode=yes -o IdentitiesOnly=yes -o ExitOnForwardFailure=yes -o LogLevel=VERBOSE \
        -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \
        -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$dir/known_hosts" \
        -R "127.0.0.1:$RPORT:127.0.0.1:$LPORT" "$TUSER@$HOST"
    code=$?
    [ $(( $(date +%s) - start )) -lt 60 ] || fails=0  # it was up: count failures afresh
    fails=$((fails + 1))
    if [ "$RETRIES" -gt 0 ] && [ "$fails" -gt "$RETRIES" ]; then
        echo "$(date +%FT%T) disconnected (exit $code); gave up after $RETRIES attempts (run setup again or reboot)" >> "$log"
        exit 0
    fi
    of=""; [ "$RETRIES" -gt 0 ] && of=" of $RETRIES"
    echo "$(date +%FT%T) disconnected (exit $code); reconnecting in 15 s (attempt $fails$of)" >> "$log"
    sleep 15
done
LOOP
    chmod 700 "$LOOP"
    cat > "/etc/systemd/system/$UNIT.service" <<UNIT
[Unit]
Description=revtunnel $NAME: reverse SSH tunnel to $HOST
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/bin/bash $LOOP
Restart=on-failure
RestartSec=60

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    rm -f "$PAUSED"  # a setup un-pauses
    systemctl enable "$UNIT" >/dev/null 2>&1

    say "Connecting ..."
    restart_tunnel; wait_tunnel
    shown=
    while [ "$STATE" != up ]; do
        if [[ "$DETAIL" == *"relay step"* ]]; then
            if [ -z "$shown" ]; then
                say "That's expected the first time: the relay doesn't know this computer yet."
                relay_step; shown=1
            else  # once is enough; then say what to check
                pub="$(cat "$KEY.pub")"; blob="$(cut -d' ' -f2 <<<"$pub")"
                bad "The relay still doesn't accept this computer's tunnel key (it ends in ...${blob: -8})."
                say "       On the relay, 'sudo bash revtunnel-relay.sh --list' shows the key it has for port $RPORT"
                say "       (named ${pub##* }). Same port and user on both sides? Option 4 of the re-run menu shows the step again."
            fi
        else
            bad "The tunnel is not up: $DETAIL"
        fi
        if [ -n "$YES" ]; then warn "The tunnel keeps retrying in the background; it connects once that is fixed."; break; fi
        read -r -p "    Press Enter here when that is done to try again (or type q to stop; the tunnel keeps retrying): " a
        [[ "$a" != q* ]] || break
        say "Connecting ..."; restart_tunnel; wait_tunnel
    done

    # ---- Summary -----------------------------------------------------------------------------------------
    lines=()
    if [ "$STATE" = up ]; then lines+=("The tunnel is UP: port $RPORT on $HOST leads to port $LPORT on this computer.")
    else lines+=("The tunnel is NOT up yet. It keeps retrying in the background and connects once fixed."); fi
    ss -Htln "sport = :$LPORT" | grep -q . || lines+=("Note: nothing on this computer listens on port $LPORT yet, so the tunnel leads nowhere until it does.")
    lines+=("")
    if [ "$LPORT" = 22 ]; then
        lu="${LOGIN_USER:-${SUDO_USER:-USER}}"
        lines+=("To log in to this computer: first log in to the relay, then run there:"
                "    ssh -p $RPORT $lu@127.0.0.1"
                "Or in one go from your own computer (not this computer), if it can log in to the relay as root:"
                "    ssh -J root@$HOST -p $RPORT $lu@127.0.0.1")
    else
        lines+=("To reach port $LPORT of this computer from your own computer (not this computer), open a forward through the relay:"
                "    ssh -L $LPORT:127.0.0.1:$RPORT root@$HOST"
                "and, while that runs, connect your program to localhost:$LPORT.")
    fi
    lines+=("" "It runs by itself from boot (service $UNIT) and reconnects every 15 s if it drops$([ "$RETRIES" -le 0 ] || echo " (gives up after $RETRIES failed attempts in a row)")."
            "Status, pausing, a new relay address, more login keys or removal: run this setup again."
            "Log: $LOG")
    if [ "$STATE" = up ]; then banner "DONE" "${lines[@]}"; rm -f "$STEPFILE"
    else banner "SET UP, BUT NOT CONNECTED YET" "${lines[@]}"; fi
fi
