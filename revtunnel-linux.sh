#!/usr/bin/env bash
# revtunnel for Linux: keeps a reverse SSH tunnel from this PC to a server, so you can reach this PC from
# that server even though nothing can connect to the PC directly (dynamic IP, NAT, firewall, ...).
#
#   sudo bash revtunnel-linux.sh [options]
#
# It guides you through every step; re-run it any time to see the tunnel's status or change something.
# See README.md for the whole workflow, including the server step.
#
# Options (all optional; anything not given is asked, or its default used with --yes):
#   --name NAME           tunnel name (default "main"); several tunnels can run side by side
#   --local-port N        port on this PC the tunnel leads to (default 22 = SSH; e.g. 3389, 5900, 8080)
#   --server HOST         the server's IP or host name
#   --server-port N       the server's SSH port (default 22)
#   --server-user USER    user on the server that holds the tunnel (default "tunnel")
#   --remote-port N       port on the server that leads to this PC (default 2222; one per PC)
#   --retries N           reconnect attempts in a row before giving up (default 0 = never give up)
#   --login-user USER     user on this PC people log in as (default: the one running sudo)
#   --login-key KEY       a public SSH key allowed to log in to this PC (repeat for more; port 22 only)
#   --keep-awake          never suspend or hibernate
#   --no-vpn              turn off VPN connections and VPN/TUN interfaces, so the tunnel goes direct
#   --yes                 ask nothing: use the options and defaults (for scripts)
#   --status              only show the status of this PC's tunnels
#   --remove              remove the tunnel given by --name
#
# Files: /etc/revtunnel/NAME (settings, the tunnel's key), /var/log/revtunnel-NAME.log. The tunnel runs as
# the systemd service revtunnel-NAME, from boot.
set -euo pipefail

ROOT=/etc/revtunnel
[ "$(id -u)" -eq 0 ] || { echo "revtunnel needs root; asking sudo ..."; exec sudo bash "$0" "$@"; }

NAME= LPORT_ARG= SERVER_ARG= SPORT_ARG= SUSER_ARG= RPORT_ARG= RETRIES_ARG= LOGIN_USER= YES= STATUS= REMOVE=
KEEP_AWAKE= NO_VPN= CHANGES=
LOGIN_KEYS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --name) NAME="$2"; shift ;;
        --local-port) LPORT_ARG="$2"; CHANGES=1; shift ;;
        --server) SERVER_ARG="$2"; CHANGES=1; shift ;;
        --server-port) SPORT_ARG="$2"; CHANGES=1; shift ;;
        --server-user) SUSER_ARG="$2"; CHANGES=1; shift ;;
        --remote-port) RPORT_ARG="$2"; CHANGES=1; shift ;;
        --retries) RETRIES_ARG="$2"; CHANGES=1; shift ;;
        --login-user) LOGIN_USER="$2"; CHANGES=1; shift ;;
        --login-key) LOGIN_KEYS+=("$2"); CHANGES=1; shift ;;
        --keep-awake) KEEP_AWAKE=yes ;;  # extras only apply to a whole setup: no CHANGES, so presets get the menu
        --no-vpn) NO_VPN=yes ;;
        --yes) YES=1 ;;
        --status) STATUS=1 ;;
        --remove) REMOVE=1 ;;
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
          LOG="/var/log/revtunnel-$1.log"; UNIT="revtunnel-$1"; STEPFILE="$DIR/server-step.txt"; }

meaning() {  # plain-language meaning of ssh's messages in $1
    local s="$1"
    case "$s" in
        *"gave up after"*) echo "The tunnel stopped retrying (the retry limit was reached): run this setup again, or reboot." ;;
        *"Permission denied"*) echo "The server doesn't know this PC's tunnel key (yet): the server step is needed." ;;
        *"remote port forwarding failed"*) echo "The server refused the port: it's set up for another port for this key, or a tunnel that just dropped still holds it (it frees up within a minute)." ;;
        *"Could not resolve hostname"*) echo "The server's name wasn't found: check the address." ;;
        *"Connection refused"*) echo "The server was reached, but nothing answers on that SSH port: check the port." ;;
        *"timed out"*) echo "No answer from the server: check the address and port, or a firewall / the network blocks it." ;;
        *"Network is unreachable"*|*"No route to host"*) echo "This PC has no network route to the server: check the internet connection." ;;
        *"IDENTIFICATION HAS CHANGED"*|*"Host key verification failed"*) echo "The server's identity changed (e.g. it was rebuilt): run this setup again to trust it again." ;;
        *) echo "" ;;
    esac
}

state() {  # sets STATE and DETAIL from the log
    STATE="not started" DETAIL=""
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
    [ $# -gt 0 ] || { say "No tunnels are set up on this PC yet."; return; }
    for n in "$@"; do
        paths "$n"; load; state
        case "$STATE" in up) c=32 ;; connecting|retrying) c=33 ;; *) c=31 ;; esac
        printf '\n    \033[%smTunnel %s: %s\033[0m\n' "$c" "'$n'" "${STATE^^}"
        [ -z "$DETAIL" ] || say "  $DETAIL"
        say "  server $HOST (SSH port $PORT, user $TUSER); server port $RPORT -> this PC's port $LPORT"
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

server_step() {
    local pub; pub="$(cat "$KEY.pub")"
    local lines=(
        "Do this on the SERVER ($HOST), not on this PC. It lets this PC's tunnel in."
        ""
        "1. Log in to the server as root (or as a user who can use sudo)."
        "2. Download the server script there:"
        "     curl -fsSLO https://raw.githubusercontent.com/addohm/revtunnel/main/revtunnel-server.sh"
        "3. On the server, run this one line:"
        "     sudo bash revtunnel-server.sh '$pub' $RPORT $TUSER"
        "   or just \"sudo bash revtunnel-server.sh\" and paste this PC's key when it asks."
        "4. When the server says \"Done\", come back to this PC."
        ""
        "This PC's tunnel key (one line):"
        "$pub"
    )
    printf '%s\n' "revtunnel - server step for tunnel '$NAME' on PC $(hostname)" "" "${lines[@]}" > "$STEPFILE"
    banner "ACTION NEEDED - on the SERVER" "${lines[@]}" "" "(All of this is also in $STEPFILE)"
}

# ---- Which tunnel ----------------------------------------------------------------------------------------

mkdir -p "$ROOT"; chmod 700 "$ROOT"
echo
printf '\033[36m%s\033[0m\n' "revtunnel - reverse SSH tunnel from this PC to a server"
mapfile -t EXISTING < <(tunnels)

if [ -n "$STATUS" ]; then if [ -n "$NAME" ]; then show_status "$NAME"; else show_status "${EXISTING[@]}"; fi; exit; fi

if [ -z "$NAME" ]; then
    if [ ${#EXISTING[@]} -gt 0 ] && [ -z "$YES" ]; then
        say "Tunnels already set up on this PC:"; show_status "${EXISTING[@]}"; echo
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

if [ -n "$REMOVE" ]; then
    [ -z "$NEW" ] || { say "There is no tunnel '$NAME' on this PC."; exit; }
    systemctl disable --now "$UNIT" 2>/dev/null || true
    rm -f "/etc/systemd/system/$UNIT.service"; systemctl daemon-reload
    rm -rf "$DIR" "$LOG" "$LOG.old"
    ok "Tunnel '$NAME' removed from this PC (service, key, settings and log)."
    say "On the server ($HOST), remove its port too:  sudo bash revtunnel-server.sh --remove $RPORT"
    exit
fi

# ---- Re-run menu -----------------------------------------------------------------------------------------

ACTION=all
if [ -z "$NEW" ] && [ -z "$YES" ] && [ -z "$CHANGES" ]; then
    show_status "$NAME"; echo
    say "What would you like to do?"
    say "  1  Reconnect now (restart the tunnel)"
    say "  2  Change the server address (or other server details)"
    [ "$LPORT" != 22 ] || say "  3  Allow another key to log in to this PC"
    say "  4  Show the server step again"
    say "  5  Go through the whole setup again"
    say "  6  Remove this tunnel"
    say "  7  Nothing (quit)"
    ask CHOICE "Choice" 7
    case "$CHOICE" in
        1) say "Connecting ..."; restart_tunnel; wait_tunnel
           if [ "$STATE" = up ]; then ok "The tunnel is up ($DETAIL)."
           elif [[ "$DETAIL" == *"server step"* ]]; then bad "$DETAIL"; server_step
           else bad "The tunnel is not up: $DETAIL"; say "It keeps retrying in the background."; fi
           exit ;;
        2) ACTION=server ;;
        3) ACTION=keys ;;
        4) server_step; exit ;;
        5) ACTION=all ;;
        6) exec bash "$0" --name "$NAME" --remove ;;
        *) exit ;;
    esac
fi

# ---- Plan the steps --------------------------------------------------------------------------------------

if [ "$ACTION" = all ]; then
    if [ -n "$LPORT_ARG" ]; then LPORT="$LPORT_ARG"
    elif [ -z "$YES" ]; then
        echo
        say "Where should the tunnel lead on this PC? 22 = SSH logins (the usual choice; sets up the"
        say "PC's SSH server). Another port forwards to that program instead, e.g. 5900 for VNC."
        ask_int LPORT "Port on this PC" "$LPORT" 1 65535
    fi
fi
DO_SSH=; DO_KEYS=; DO_EXTRAS=; DO_SERVER=
[ "$ACTION" = all ] && [ "$LPORT" = 22 ] && DO_SSH=1
{ [ "$ACTION" = all ] && [ "$LPORT" = 22 ]; } || [ "$ACTION" = keys ] && DO_KEYS=1
[ "$ACTION" = all ] && DO_EXTRAS=1
[ "$ACTION" = all ] || [ "$ACTION" = server ] && DO_SERVER=1
STEPS=$(( ${DO_SSH:-0} + ${DO_KEYS:-0} + ${DO_EXTRAS:-0} + 2 * ${DO_SERVER:-0} ))

# the tunnel itself needs the ssh client
command -v ssh >/dev/null || pkg_install openssh-client openssh-clients openssh openssh || { bad "Could not install the ssh client; install it and run this again."; exit 1; }

# ---- SSH server on this PC -------------------------------------------------------------------------------

if [ -n "$DO_SSH" ]; then
    step "This PC's SSH server" "People log in to this PC with SSH through the tunnel, so the PC needs an SSH server." \
        "Its existing settings are kept (if it already accepts logins from your network, it still does)."
    command -v sshd >/dev/null || [ -x /usr/sbin/sshd ] || pkg_install openssh-server openssh-server openssh openssh ||
        { bad "Could not install the SSH server; install openssh-server and run this again."; exit 1; }
    systemctl enable --now sshd 2>/dev/null || systemctl enable --now ssh 2>/dev/null || true
    if ss -Htln 'sport = :22' | grep -q .; then ok "SSH server running on port 22"; else warn "The SSH server doesn't seem to listen on port 22; check it (systemctl status sshd)."; fi
fi

# ---- Who may log in --------------------------------------------------------------------------------------

if [ -n "$DO_KEYS" ]; then
    step "Who may log in to this PC" "Everyone who should log in to this PC needs an SSH key pair. Paste the PUBLIC half here:" \
        "one line that starts with ssh-ed25519, ssh-rsa or ecdsa-. Where to find it: on their computer or" \
        "server, in ~/.ssh/id_ed25519.pub (show it with: cat ~/.ssh/id_ed25519.pub; make one with:" \
        "ssh-keygen -t ed25519). Never paste a PRIVATE key (it starts with -----BEGIN)."
    if [ -z "$LOGIN_USER" ]; then ask LOGIN_USER "User on this PC they log in as" "${SUDO_USER:-root}"; fi
    id "$LOGIN_USER" &>/dev/null || { bad "There is no user '$LOGIN_USER' on this PC."; exit 1; }
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
    step "Optional extras" "Things that help when the PC runs unattended. Skip what you don't need."
    if [ -n "$KEEP_AWAKE" ] || ask_yn "Keep this PC awake? (a suspended PC drops the tunnel)"; then
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

# ---- Server details --------------------------------------------------------------------------------------

if [ -n "$DO_SERVER" ]; then
    step "The server" "The server is a computer with a fixed address that this PC can reach, e.g. a VPS. This PC" \
        "keeps a connection open to it, and you reach this PC from there. Press Enter to keep a value in [ ]."
    [ -z "$SERVER_ARG" ] || HOST="$SERVER_ARG"
    while true; do ask HOST "Server address (IP or host name)" "$HOST"; HOST="${HOST#[}"; HOST="${HOST%]}"; [ -n "$HOST" ] && break
        [ -z "$YES" ] || { bad "No server address: give --server."; exit 1; }; done
    if [ -n "$SPORT_ARG" ]; then PORT="$SPORT_ARG"; else ask_int PORT "Server's SSH port" "$PORT" 1 65535; fi
    if [ -n "$SUSER_ARG" ]; then TUSER="$SUSER_ARG"; else ask TUSER "User on the server that holds the tunnel (the server step creates it)" "$TUSER"; fi
    if [ -n "$RPORT_ARG" ]; then RPORT="$RPORT_ARG"; else ask_int RPORT "Port on the server that leads to this PC (each PC needs its own, e.g. 2222, 2223, ...)" "$RPORT" 1024 65535; fi
    if [ -n "$RETRIES_ARG" ]; then RETRIES="$RETRIES_ARG"; else ask_int RETRIES "Reconnect attempts before giving up (0 = never give up)" "$RETRIES" 0 1000000; fi
    save
    ok "Server $HOST, port $RPORT there leads to port $LPORT here"

    step "Start the tunnel" "Makes this PC's own key for the tunnel (separate from the login keys), then connects." \
        "The first time, the server does not know this PC yet: you will be asked to do the server step."
    [ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -C "revtunnel-$NAME-$(hostname)" -f "$KEY"
    chmod 600 "$KEY"
    rm -f "$DIR/known_hosts"  # trust the server's host key afresh (the server or its address may have changed)
    cat > "$LOOP" <<'LOOP'
#!/usr/bin/env bash
# Written by revtunnel-linux.sh; run by the revtunnel-NAME service. Keeps the tunnel up.
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
    systemctl enable "$UNIT" >/dev/null 2>&1

    say "Connecting ..."
    restart_tunnel; wait_tunnel
    shown=
    while [ "$STATE" != up ]; do
        if [[ "$DETAIL" == *"server step"* ]]; then
            if [ -z "$shown" ]; then
                say "That's expected the first time: the server doesn't know this PC yet."
                server_step; shown=1
            else  # once is enough; then say what to check
                pub="$(cat "$KEY.pub")"; blob="$(cut -d' ' -f2 <<<"$pub")"
                bad "The server still doesn't accept this PC's tunnel key (it ends in ...${blob: -8})."
                say "       On the server, 'sudo bash revtunnel-server.sh --list' shows the key it has for port $RPORT"
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
    if [ "$STATE" = up ]; then lines+=("The tunnel is UP: port $RPORT on $HOST leads to port $LPORT on this PC.")
    else lines+=("The tunnel is NOT up yet. It keeps retrying in the background and connects once fixed."); fi
    ss -Htln "sport = :$LPORT" | grep -q . || lines+=("Note: nothing on this PC listens on port $LPORT yet, so the tunnel leads nowhere until it does.")
    lines+=("")
    if [ "$LPORT" = 22 ]; then
        lu="${LOGIN_USER:-${SUDO_USER:-USER}}"
        lines+=("To log in to this PC: first log in to the server, then run there:"
                "    ssh -p $RPORT $lu@127.0.0.1"
                "Or in one go from your own computer (not this PC), if it can log in to the server as root:"
                "    ssh -J root@$HOST -p $RPORT $lu@127.0.0.1")
    else
        lines+=("To reach port $LPORT of this PC from your own computer (not this PC), open a forward through the server:"
                "    ssh -L $LPORT:127.0.0.1:$RPORT root@$HOST"
                "and, while that runs, connect your program to localhost:$LPORT.")
    fi
    lines+=("" "It runs by itself from boot (service $UNIT) and reconnects every 15 s if it drops$([ "$RETRIES" -le 0 ] || echo " (gives up after $RETRIES failed attempts in a row)")."
            "Status, a new server address, more login keys or removal: run this setup again."
            "Log: $LOG")
    if [ "$STATE" = up ]; then banner "DONE" "${lines[@]}"; rm -f "$STEPFILE"
    else banner "SET UP, BUT NOT CONNECTED YET" "${lines[@]}"; fi
fi
