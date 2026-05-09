#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    else
        if [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ]; then
            echo "ERROR: bash not found and not root. Install bash first." >&2
            exit 1
        fi
        if   command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y bash
        elif command -v dnf     >/dev/null 2>&1; then dnf install -y bash
        elif command -v yum     >/dev/null 2>&1; then yum install -y bash
        else echo "ERROR: Unsupported package manager." >&2; exit 1
        fi
        exec bash "$0" "$@"
    fi
fi

# Re-exec from a real file when piped via stdin, so heredocs & traps survive.
if [ "${0}" = "bash" ] || [ "${0}" = "-bash" ] || [ "${0}" = "/bin/bash" ] || [ "${0}" = "/usr/bin/bash" ]; then
    if [ ! -t 0 ] && [ -z "${CRYVETH_REEXEC:-}" ]; then
        _self_tmp="$(mktemp -t cryveth.XXXXXX.sh 2>/dev/null || echo "/tmp/cryveth.$$.sh")"
        cat >"$_self_tmp"
        chmod 755 "$_self_tmp" 2>/dev/null || true
        export CRYVETH_REEXEC=1
        exec bash "$_self_tmp" "$@"
    fi
fi

if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: bash >= 4.0 required (current: $BASH_VERSION)" >&2
    exit 1
fi

set -uo pipefail
shopt -s extglob 2>/dev/null || true
umask 022

# ---------- GLOBAL CONSTANTS -------------------------------------------------
readonly SCRIPT_VERSION="2.0.0-prod"
readonly SCRIPT_NAME="CryVeth Pterodactyl Installer"
readonly PANEL_DIR="/var/www/pterodactyl"
readonly WINGS_DIR="/etc/pterodactyl"
readonly BACKUP_DIR="/root/nortex-backups"
readonly CRED_DIR="/root/nortex-credentials"
readonly LOCK_FILE="/var/lock/cryveth-installer.lock"

LOG_FILE="/var/log/nortex-installer.log"
PHP_VER="${PHP_VER:-8.3}"
TIMEZONE="${TIMEZONE_OVERRIDE:-Asia/Jakarta}"
ASSUME_YES="${ASSUME_YES:-0}"
DEBUG="${DEBUG:-0}"

# Detect non-interactive (pipe/curl) usage and auto-enable yes
if [ ! -t 0 ] || [ ! -t 1 ]; then
    ASSUME_YES=1
fi

# ---------- COLOR -----------------------------------------------------------
if [ -t 1 ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    CYAN=$'\033[0;36m'; BLUE=$'\033[0;34m'; MAGENTA=$'\033[0;35m'
    BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BLUE=''; MAGENTA=''
    BOLD=''; DIM=''; NC=''
fi

OS_ID=""; OS_VER=""; OS_CODENAME=""; OS_FAMILY=""; ARCH=""

# ---------- LOGGING ENGINE ---------------------------------------------------
init_log() {
    if ! mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || ! ( :>>"$LOG_FILE" ) 2>/dev/null; then
        LOG_FILE="/tmp/nortex-installer.log"
        mkdir -p /tmp 2>/dev/null || true
        :>>"$LOG_FILE" 2>/dev/null || true
    fi
    chmod 600 "$LOG_FILE" 2>/dev/null || true
    {
        echo "==============================================================="
        echo "  $SCRIPT_NAME v$SCRIPT_VERSION"
        echo "  Started : $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "  Args    : $*"
        echo "  PID     : $$  TTY: $([ -t 0 ] && echo yes || echo no)"
        echo "==============================================================="
    } >>"$LOG_FILE" 2>&1
    mkdir -p "$BACKUP_DIR" "$CRED_DIR" 2>/dev/null || true
    chmod 700 "$BACKUP_DIR" "$CRED_DIR" 2>/dev/null || true
}

_ts()       { date '+%Y-%m-%d %H:%M:%S'; }
_log_raw()  { echo "[$(_ts)] $*" >>"$LOG_FILE" 2>/dev/null || true; }
log_info()  { _log_raw "INFO    $*"; printf '  %b[INFO]%b    %s\n'    "$CYAN"   "$NC" "$*"; }
log_ok()    { _log_raw "SUCCESS $*"; printf '  %b[OK]%b      %s\n'    "$GREEN"  "$NC" "$*"; }
log_warn()  { _log_raw "WARN    $*"; printf '  %b[WARN]%b    %s\n'    "$YELLOW" "$NC" "$*"; }
log_error() { _log_raw "ERROR   $*"; printf '  %b[ERROR]%b   %s\n'    "$RED"    "$NC" "$*" >&2; }
log_fatal() { _log_raw "FATAL   $*"; printf '  %b[FATAL]%b   %s\n'    "$RED"    "$NC" "$*" >&2; exit 1; }
log_step()  { _log_raw "STEP    $*"; printf '\n  %b%b▶ %s%b\n'        "$BOLD"   "$BLUE" "$*" "$NC"; }
log_debug() { [[ "${DEBUG:-0}" == "1" ]] && printf '  %b[DEBUG]   %s%b\n' "$DIM" "$*" "$NC"; _log_raw "DEBUG   $*"; }

on_error() {
    local ec=$? line=$1
    if [ "$ec" -ne 0 ]; then
        log_error "Trap on line ${line} (exit=${ec}). Log: ${LOG_FILE}"
    fi
}
trap 'on_error $LINENO' ERR

cleanup_exit() {
    local ec=$?
    [ -f "$LOCK_FILE" ] && rm -f "$LOCK_FILE" 2>/dev/null || true
    exit "$ec"
}
trap cleanup_exit EXIT INT TERM

acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local oldpid
        oldpid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
            log_fatal "Another installer (PID=$oldpid) is running. Lock: $LOCK_FILE"
        fi
        rm -f "$LOCK_FILE" 2>/dev/null || true
    fi
    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
    echo "$$" >"$LOCK_FILE" 2>/dev/null || true
}

# ---------- RETRY / SAFE EXECUTION LAYER -------------------------------------
retry() {
    local n=1 max="${RETRY_MAX:-5}" delay="${RETRY_DELAY:-3}" max_delay=60
    local desc="${RETRY_DESC:-cmd}"
    while true; do
        if "$@"; then return 0; fi
        if [ "$n" -ge "$max" ]; then
            log_error "Retry exhausted after ${n} attempts: ${desc}"
            return 1
        fi
        log_warn "Attempt ${n}/${max} failed for ${desc}. Sleeping ${delay}s..."
        sleep "$delay"
        n=$((n+1))
        delay=$((delay*2))
        [ "$delay" -gt "$max_delay" ] && delay="$max_delay"
    done
}

ensure_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || return 1
    done
    return 0
}

require_cmd() {
    local c missing=()
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        log_fatal "Missing required commands: ${missing[*]}"
    fi
}

require_var() {
    local name val
    for name in "$@"; do
        val="${!name:-}"
        [ -z "$val" ] && log_fatal "Required variable '$name' is empty/unset"
    done
}

# ---------- BANNER ----------------------------------------------------------
show_banner() {
    [ -t 1 ] && clear 2>/dev/null || true
    printf '%b%b' "$CYAN" "$BOLD"
    cat <<'BANNER'
  ███╗   ██╗ ██████╗ ██████╗ ████████╗███████╗██╗  ██╗
  ████╗  ██║██╔═══██╗██╔══██╗╚══██╔══╝██╔════╝╚██╗██╔╝
  ██╔██╗ ██║██║   ██║██████╔╝   ██║   █████╗   ╚███╔╝
  ██║╚██╗██║██║   ██║██╔══██╗   ██║   ██╔══╝   ██╔██╗
  ██║ ╚████║╚██████╔╝██║  ██║   ██║   ███████╗██╔╝ ██╗
  ╚═╝  ╚═══╝ ╚═════╝ ╚═╝  ╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝
BANNER
    printf '%b\n' "$NC"
    printf '  %bPterodactyl Production Installer v%s%b %b— Credits: @NortexZ%b\n' \
        "$BOLD" "$SCRIPT_VERSION" "$NC" "$CYAN" "$NC"
    printf '  %b━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n\n' "$BLUE" "$NC"
}

# ---------- PRE-FLIGHT VALIDATION -------------------------------------------
check_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        log_fatal "Script must be run as root. Use: sudo bash $0"
    fi
}

detect_os() {
    [ -f /etc/os-release ] || log_fatal "/etc/os-release missing. Unsupported OS."
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VER="${VERSION_ID:-unknown}"
    OS_CODENAME="${VERSION_CODENAME:-}"
    case "$OS_ID" in
        ubuntu|debian|raspbian|linuxmint|pop)        OS_FAMILY="debian" ;;
        almalinux|rocky|centos|rhel|fedora)          OS_FAMILY="rhel" ;;
        *)
            if [[ "${ID_LIKE:-}" == *debian* ]]; then OS_FAMILY="debian"
            elif [[ "${ID_LIKE:-}" == *rhel*  || "${ID_LIKE:-}" == *fedora* ]]; then OS_FAMILY="rhel"
            else log_fatal "Unsupported OS: $OS_ID $OS_VER"
            fi ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64)   ARCH="amd64" ;;
        aarch64|arm64)  ARCH="arm64" ;;
        *) log_fatal "Unsupported CPU arch: $(uname -m)" ;;
    esac
    log_ok "OS detected: ${OS_ID} ${OS_VER} (${OS_FAMILY}, ${ARCH})"
}

check_internet() {
    local ok=0 host
    for host in 1.1.1.1 8.8.8.8 9.9.9.9; do
        if ping -c 1 -W 3 "$host" >/dev/null 2>&1; then ok=1; break; fi
    done
    if [ $ok -eq 0 ] && command -v curl >/dev/null 2>&1; then
        curl -fsS --max-time 5 https://1.1.1.1 >/dev/null 2>&1 && ok=1
    fi
    [ $ok -eq 0 ] && log_fatal "No internet connection!"
    log_ok "Internet connection OK"
}

check_disk_space() {
    local need_mb="${1:-3000}" avail_mb
    avail_mb=$(df -Pm / 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ -z "$avail_mb" || "$avail_mb" -lt "$need_mb" ]]; then
        log_warn "Disk root < ${need_mb}MB free (avail=${avail_mb:-?}MB)."
    else
        log_ok "Disk root available: ${avail_mb}MB"
    fi
}

check_ram() {
    local need_mb="${1:-1024}" total_mb
    total_mb=$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}')
    if [[ -z "$total_mb" || "$total_mb" -lt "$need_mb" ]]; then
        log_warn "RAM total < ${need_mb}MB (total=${total_mb:-?}MB)."
    else
        log_ok "RAM total: ${total_mb}MB"
    fi
}

# ---------- IP / DOMAIN / EMAIL HELPERS --------------------------------------
get_local_ip() {
    local IP=""
    IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    [[ -z "$IP" ]] && IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$IP" ]] && IP="127.0.0.1"
    echo "$IP"
}

is_local_target() {
    local TARGET="${1:-}"
    [[ -z "$TARGET" || "$TARGET" == "-" ]] && return 0
    [[ "$TARGET" == "127.0.0.1" || "$TARGET" == "localhost" ]] && return 0
    local LOCAL_IP; LOCAL_IP=$(get_local_ip)
    [[ "$TARGET" == "$LOCAL_IP" ]] && return 0
    if ip -4 addr show 2>/dev/null | grep -Eq "inet ${TARGET//./\\.}/"; then
        return 0
    fi
    return 1
}

validate_ip() {
    local ip="${1:-}"
    [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    local IFS_OLD=$IFS; IFS='.'
    local -a oct=($ip); IFS=$IFS_OLD
    local o
    for o in "${oct[@]}"; do (( o >= 0 && o <= 255 )) || return 1; done
    return 0
}

validate_domain() {
    [[ "${1:-}" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

validate_email() {
    [[ "${1:-}" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

gen_password() {
    local len="${1:-24}"
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$len" || \
    openssl rand -base64 48 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c "$len"
}

confirm() {
    local PROMPT="$1" DEFAULT="${2:-n}" ANS
    [[ "${ASSUME_YES:-0}" == "1" ]] && return 0
    if [[ "$DEFAULT" == "y" ]]; then printf '  %b%s [Y/n]: %b' "$YELLOW" "$PROMPT" "$NC"
    else                              printf '  %b%s [y/N]: %b' "$YELLOW" "$PROMPT" "$NC"; fi
    read -r ANS </dev/tty 2>/dev/null || ANS=""
    ANS=${ANS:-$DEFAULT}
    [[ "$ANS" =~ ^[Yy]$ ]]
}

# ---------- SAFE PACKAGE / SERVICE LAYER -------------------------------------
ensure_sshpass() {
    command -v sshpass >/dev/null 2>&1 && return 0
    log_info "Installing sshpass..."
    if [[ "$OS_FAMILY" == "debian" ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >>"$LOG_FILE" 2>&1 || true
        retry env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sshpass >>"$LOG_FILE" 2>&1 || true
    else
        retry sh -c 'yum install -y -q sshpass || dnf install -y -q sshpass' >>"$LOG_FILE" 2>&1 || true
    fi
    command -v sshpass >/dev/null 2>&1
}

# Safe SSH executor — passes script via stdin, NEVER through arg expansion.
exec_cmd() {
    local IP="${1:-}" PW="${2:--}" CMD="${3:-}"
    [ -z "$CMD" ] && { log_error "exec_cmd called with empty CMD"; return 2; }

    if is_local_target "$IP"; then
        printf '%s\n' "$CMD" | bash -s
        return $?
    fi

    if ! ensure_sshpass; then
        log_error "sshpass not available; cannot connect remotely."
        return 127
    fi

    local SSH_OPTS=(
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o LogLevel=ERROR
        -o ConnectTimeout=20
        -o ServerAliveInterval=30
        -o ServerAliveCountMax=4
        -o BatchMode=no
        -o PubkeyAuthentication=no
        -o PreferredAuthentications=password
        -o NumberOfPasswordPrompts=1
    )

    if [ "$PW" = "-" ] || [ -z "$PW" ]; then
        log_error "Remote target requires password (PW='-' invalid for $IP)"
        return 4
    fi

    printf '%s\n' "$CMD" | sshpass -p "$PW" ssh "${SSH_OPTS[@]}" "root@$IP" "bash -s"
    return $?
}

pkg_update() {
    if [[ "$OS_FAMILY" == "debian" ]]; then
        retry env DEBIAN_FRONTEND=noninteractive apt-get update -y >>"$LOG_FILE" 2>&1 || true
    else
        retry sh -c 'yum makecache -q || dnf makecache -q' >>"$LOG_FILE" 2>&1 || true
    fi
}

pkg_install() {
    if [[ "$OS_FAMILY" == "debian" ]]; then
        retry env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" "$@"
    else
        retry sh -c "yum install -y -q $* || dnf install -y -q $*" >>"$LOG_FILE" 2>&1
    fi
}

# ---------- REMOTE HELPER LIBRARY (injected once into every remote payload) --
remote_lib() {
    cat <<'RLIB_EOF'
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8 2>/dev/null || true
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

_r_ts()   { date '+%Y-%m-%d %H:%M:%S'; }
r_info()  { echo "[$(_r_ts)] [INFO]    $*"; }
r_ok()    { echo "[$(_r_ts)] [OK]      $*"; }
r_warn()  { echo "[$(_r_ts)] [WARN]    $*" >&2; }
r_error() { echo "[$(_r_ts)] [ERROR]   $*" >&2; }
r_fatal() { echo "[$(_r_ts)] [FATAL]   $*" >&2; exit 1; }

r_retry() {
    local n=1 max=5 delay=3 max_delay=60
    while true; do
        if "$@"; then return 0; fi
        if [ "$n" -ge "$max" ]; then
            r_error "Retry exhausted after ${n}: $*"
            return 1
        fi
        r_warn "Attempt ${n}/${max} failed: $*. Sleep ${delay}s"
        sleep "$delay"; n=$((n+1)); delay=$((delay*2))
        [ "$delay" -gt "$max_delay" ] && delay="$max_delay"
    done
}

r_apt_lock_wait() {
    local i=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
       || fuser /var/lib/apt/lists/lock     >/dev/null 2>&1 \
       || fuser /var/lib/dpkg/lock          >/dev/null 2>&1; do
        i=$((i+1))
        [ $i -gt 60 ] && { r_warn "apt lock still held after 5min, continuing"; break; }
        sleep 5
    done
}

r_apt_install() {
    r_apt_lock_wait
    r_retry env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" "$@"
}

r_apt_update() {
    r_apt_lock_wait
    r_retry env DEBIAN_FRONTEND=noninteractive apt-get update -y
}

r_svc_enable_start() {
    local svc="$1"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable "$svc" >/dev/null 2>&1 || true
    systemctl restart "$svc" 2>/dev/null || systemctl start "$svc" 2>/dev/null || true
    sleep 2
    if ! systemctl is-active --quiet "$svc"; then
        r_error "Service '$svc' failed to start"
        systemctl status "$svc" --no-pager -l 2>&1 | head -n 30 || true
        journalctl -u "$svc" -n 40 --no-pager 2>&1 | tail -n 40 || true
        return 1
    fi
    r_ok "Service '$svc' active"
    return 0
}

r_wait_port() {
    local port="$1" host="${2:-127.0.0.1}" timeout="${3:-30}" i=0
    while [ $i -lt "$timeout" ]; do
        if (echo > "/dev/tcp/$host/$port") >/dev/null 2>&1; then
            return 0
        fi
        sleep 1; i=$((i+1))
    done
    return 1
}

r_php_fpm_socket() {
    local v="$1" cand
    for cand in "/run/php/php${v}-fpm.sock" "/var/run/php/php${v}-fpm.sock" "/run/php-fpm/www.sock"; do
        [ -S "$cand" ] && { echo "$cand"; return 0; }
    done
    cand=$(ls /run/php/php*-fpm.sock 2>/dev/null | head -1)
    [ -n "$cand" ] && { echo "$cand"; return 0; }
    return 1
}
RLIB_EOF
}

# Wrap a payload with remote_lib + safe header. Always pipe via stdin.
wrap_remote() {
    {
        remote_lib
        echo ""
        cat
    }
}

# ---------- PHP REPO (REMOTE) ------------------------------------------------
setup_php_repo_remote() {
cat <<'PHPREPO_EOF'
. /etc/os-release || r_fatal "/etc/os-release missing"
r_apt_update
r_apt_install ca-certificates curl gnupg lsb-release apt-transport-https

case "$ID" in
  ubuntu)
    r_apt_install software-properties-common
    if ! grep -rqs 'ondrej/php' /etc/apt/sources.list.d/ 2>/dev/null; then
        r_retry env LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
    fi
    ;;
  debian|raspbian)
    install -d -m 0755 /usr/share/keyrings
    if [ ! -s /usr/share/keyrings/sury-php.gpg ]; then
        r_retry curl -fsSL https://packages.sury.org/php/apt.gpg \
            -o /tmp/sury-php.gpg.armored
        gpg --dearmor < /tmp/sury-php.gpg.armored > /usr/share/keyrings/sury-php.gpg
        rm -f /tmp/sury-php.gpg.armored
        chmod 644 /usr/share/keyrings/sury-php.gpg
    fi
    CODENAME=$(lsb_release -sc 2>/dev/null || echo "${VERSION_CODENAME:-bookworm}")
    echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ ${CODENAME} main" \
      > /etc/apt/sources.list.d/sury-php.list
    ;;
  *)
    r_warn "PHP repo helper not configured for $ID — assuming distro-provided PHP"
    ;;
esac

r_apt_update
PHPREPO_EOF
}

# =============================================================================
#  WINGS INSTALL
# =============================================================================
install_wings() {
    local IP="${1:-}" PW="${2:--}" TOKEN_CMD="${3:-}"
    [[ -z "$IP" ]] && { echo "Format: bash $0 wings <ip> <pwvps> [token]"; exit 1; }
    [[ -z "$PW" ]] && PW="-"

    show_banner
    log_step "🚀 Install Wings Pterodactyl"

    local WINGS_ARCH="amd64"
    [[ "$ARCH" == "arm64" ]] && WINGS_ARCH="arm64"

    local TOKEN_CMD_B64=""
    if [[ -n "$TOKEN_CMD" ]]; then
        TOKEN_CMD_B64=$(printf '%s' "$TOKEN_CMD" | base64 -w0 2>/dev/null || printf '%s' "$TOKEN_CMD" | base64 | tr -d '\n')
    fi

    local PAYLOAD
    PAYLOAD=$( { remote_lib; cat <<REMOTE_WINGS
WINGS_ARCH='${WINGS_ARCH}'
TOKEN_B64='${TOKEN_CMD_B64}'

if ! command -v curl >/dev/null 2>&1; then
    r_apt_update
    r_apt_install curl ca-certificates
fi

if ! command -v docker >/dev/null 2>&1; then
    r_info "Installing Docker..."
    r_retry curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    [ -s /tmp/get-docker.sh ] || r_fatal "Docker installer empty"
    sh /tmp/get-docker.sh >/dev/null 2>&1 || r_fatal "Docker install failed"
    rm -f /tmp/get-docker.sh
fi
r_svc_enable_start docker || r_fatal "docker service not active"

install -d -m 0755 /etc/pterodactyl

r_retry curl -fL --retry 5 --retry-delay 5 \
    -o /usr/local/bin/wings.new \
    "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_\${WINGS_ARCH}"
[ -s /usr/local/bin/wings.new ] || r_fatal "wings binary empty"
chmod +x /usr/local/bin/wings.new
mv -f /usr/local/bin/wings.new /usr/local/bin/wings

cat >/etc/systemd/system/wings.service <<'SVC_EOF'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service network-online.target
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
SVC_EOF

systemctl daemon-reload
systemctl enable wings >/dev/null 2>&1 || true

if [ -n "\$TOKEN_B64" ]; then
    r_info "Running panel auto-deploy token..."
    cd /etc/pterodactyl
    DECODED=\$(echo "\$TOKEN_B64" | base64 -d 2>/dev/null) || r_fatal "Token base64 decode failed"
    [ -n "\$DECODED" ] || r_fatal "Decoded token empty"
    bash -c "\$DECODED" || r_warn "Token command failed — verify panel token"
fi

if [ -f /etc/pterodactyl/config.yml ]; then
    r_svc_enable_start wings || r_warn "Wings did not become active (check token/config)"
else
    r_warn "config.yml not present yet — start wings after configuring node"
fi
REMOTE_WINGS
} )

    exec_cmd "$IP" "$PW" "$PAYLOAD" || log_fatal "Wings installation failed!"
    log_ok "Wings installed."
}

# =============================================================================
#  OFFICIAL INSTALLER
# =============================================================================
install_official() {
    show_banner
    log_step "🚀 Install Pterodactyl via Official Installer"
    log_warn "This runs a third-party script. Make sure you trust the source."
    confirm "Continue official installation?" "n" || { log_warn "Cancelled."; exit 0; }
    retry bash -c 'bash <(curl -fsSL https://pterodactyl-installer.se)' \
        || log_fatal "Official installation failed!"
    log_ok "Official installation finished."
}

# =============================================================================
#  SSL STANDALONE
# =============================================================================
install_ssl() {
    local IP="${1:-}" PW="${2:--}" DOMAIN="${3:-}" EMAIL="${4:-}"

    [[ -z "$IP" || -z "$DOMAIN" || -z "$EMAIL" ]] && {
        log_error "Missing parameters!"
        printf '  %bFormat:%b bash %s ssl <ip> <pwvps> <domain> <email>\n' "$YELLOW" "$NC" "$0"
        exit 1
    }
    validate_ip "$IP"          || log_fatal "Invalid IP: $IP"
    validate_domain "$DOMAIN"  || log_fatal "Invalid domain: $DOMAIN"
    validate_email "$EMAIL"    || log_fatal "Invalid email: $EMAIL"
    [[ -z "$PW" ]] && PW="-"

    show_banner
    log_step "🔒 Install SSL Let's Encrypt (Standalone)"
    log_info "Target IP : $IP"
    log_info "Domain    : $DOMAIN"
    log_info "Email     : $EMAIL"
    confirm "Continue SSL installation?" "y" || { log_warn "Cancelled."; exit 0; }

    local OS_FAMILY_REMOTE="$OS_FAMILY"
    local PAYLOAD
    PAYLOAD=$( { remote_lib; cat <<REMOTE_SSL
OS_FAMILY_REMOTE='${OS_FAMILY_REMOTE}'
DOMAIN_R='${DOMAIN}'
EMAIL_R='${EMAIL}'

if [ "\$OS_FAMILY_REMOTE" = "debian" ]; then
    r_apt_update
    r_apt_install certbot
elif [ "\$OS_FAMILY_REMOTE" = "rhel" ]; then
    r_retry sh -c "yum install -y -q epel-release || dnf install -y -q epel-release" || true
    r_retry sh -c "yum install -y -q certbot || dnf install -y -q certbot"
fi
command -v certbot >/dev/null 2>&1 || r_fatal "certbot not installed"

NGINX_WAS=0; APACHE_WAS=0
systemctl is-active --quiet nginx   2>/dev/null && { NGINX_WAS=1;  systemctl stop nginx   || true; }
systemctl is-active --quiet apache2 2>/dev/null && { APACHE_WAS=1; systemctl stop apache2 || true; }

if ! r_retry certbot certonly --standalone --non-interactive --agree-tos \
    -m "\$EMAIL_R" -d "\$DOMAIN_R"; then
    r_error "Certbot failed."
    [ "\$NGINX_WAS"  = 1 ] && systemctl start nginx   || true
    [ "\$APACHE_WAS" = 1 ] && systemctl start apache2 || true
    exit 1
fi

[ "\$NGINX_WAS"  = 1 ] && systemctl start nginx   || true
[ "\$APACHE_WAS" = 1 ] && systemctl start apache2 || true

CRON_TMP=\$(mktemp)
(crontab -l 2>/dev/null | grep -v 'certbot renew' || true) > "\$CRON_TMP"
echo '0 3 * * * certbot renew --quiet --post-hook "systemctl reload nginx 2>/dev/null || systemctl reload apache2 2>/dev/null || true"' >> "\$CRON_TMP"
crontab "\$CRON_TMP"
rm -f "\$CRON_TMP"

r_ok "SSL installed and auto-renew configured."
REMOTE_SSL
} )

    exec_cmd "$IP" "$PW" "$PAYLOAD" || log_fatal "SSL installation failed!"
    log_ok "SSL finished."
}

# =============================================================================
#  HACKBACK PANEL
# =============================================================================
hackback_panel() {
    local IP="${1:-}" PW="${2:--}" NEW_EMAIL="${3:-admin@localhost.local}" NEW_PASS="${4:-}"
    [[ -z "$NEW_PASS" ]] && NEW_PASS="$(gen_password 14)"
    [[ -z "$IP" ]] && { log_error "Format: bash $0 hackback-panel <ip> <pwvps> [new_email] [new_password]"; exit 1; }
    [[ -z "$PW" ]] && PW="-"

    show_banner
    log_step "🔧 HACKBACK PANEL — Reset admin user"
    log_info "Target IP        : $IP"
    log_info "New admin email  : $NEW_EMAIL"
    log_info "New password     : $NEW_PASS"
    confirm "Continue panel hackback?" "n" || { log_warn "Cancelled."; exit 0; }

    local PAYLOAD
    PAYLOAD=$( { remote_lib; cat <<REMOTE_HBP
PANEL_DIR='${PANEL_DIR}'
BACKUP_DIR='${BACKUP_DIR}'
NEW_EMAIL='${NEW_EMAIL}'
NEW_PASS='${NEW_PASS}'

TS=\$(date +%Y%m%d-%H%M%S)
install -d -m 0700 "\$BACKUP_DIR"

[ -d "\$PANEL_DIR" ] || r_fatal "Panel directory \$PANEL_DIR not found"

if [ -f "\$PANEL_DIR/.env" ]; then
    cp -a "\$PANEL_DIR/.env" "\$BACKUP_DIR/panel.env.\${TS}.bak"
    r_info ".env backup saved."
fi
if command -v mysqldump >/dev/null 2>&1; then
    mysqldump -u root panel > "\$BACKUP_DIR/panel-db.\${TS}.sql" 2>/dev/null && \
        r_info "Database backup saved." || r_warn "DB backup skipped"
fi

cd "\$PANEL_DIR" || r_fatal "cd \$PANEL_DIR failed"

php artisan p:user:make \
    --email="\$NEW_EMAIL" \
    --username='admin' \
    --name-first='Admin' \
    --name-last='NortexZ' \
    --password="\$NEW_PASS" \
    --admin=1 \
    --no-interaction || r_fatal "Failed to create/reset admin user"

php artisan cache:clear  || true
php artisan config:clear || true
php artisan view:clear   || true
r_ok "Admin user reset."
REMOTE_HBP
} )

    exec_cmd "$IP" "$PW" "$PAYLOAD" || log_fatal "Panel hackback failed!"

    local CRED_FILE="${CRED_DIR}/hackback-panel-${IP}-$(date +%Y%m%d-%H%M%S).txt"
    cat >"$CRED_FILE" <<EOF
========================================
  PTERODACTYL PANEL HACKBACK CREDENTIALS
  Generated : $(date)
========================================
New admin email : ${NEW_EMAIL}
Username        : admin
New password    : ${NEW_PASS}
Server backup   : ${BACKUP_DIR}
EOF
    chmod 600 "$CRED_FILE" 2>/dev/null || true

    printf '\n  %b━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n' "$BLUE" "$NC"
    printf '  %b%b✅  PANEL HACKBACK SUCCESS!%b\n' "$GREEN" "$BOLD" "$NC"
    printf '  %b━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n\n' "$BLUE" "$NC"
    printf '  %b📧 Admin Email   :%b %s\n' "$BOLD" "$NC" "$NEW_EMAIL"
    printf '  %b👤 Username      :%b admin\n' "$BOLD" "$NC"
    printf '  %b🔑 New Password  :%b %s\n' "$BOLD" "$NC" "$NEW_PASS"
    printf '  %b📁 Credentials   :%b %s\n' "$BOLD" "$NC" "$CRED_FILE"
    printf '  %b📦 Backups       :%b %s\n\n' "$BOLD" "$NC" "$BACKUP_DIR"
}

# =============================================================================
#  HACKBACK WINGS
# =============================================================================
hackback_wings() {
    local IP="${1:-}" PW="${2:--}" NEW_TOKEN="${3:-}"
    [[ -z "$IP" ]] && { log_error "Format: bash $0 hackback-wings <ip> <pwvps> [token_curl_command]"; exit 1; }
    [[ -z "$PW" ]] && PW="-"

    show_banner
    log_step "🔧 HACKBACK WINGS — Reset Wings configuration"
    log_info "Target IP : $IP"
    confirm "Continue wings hackback?" "n" || { log_warn "Cancelled."; exit 0; }

    local STAGE1
    STAGE1=$( { remote_lib; cat <<REMOTE_HBW1
WINGS_DIR='${WINGS_DIR}'
BACKUP_DIR='${BACKUP_DIR}'
TS=\$(date +%Y%m%d-%H%M%S)
install -d -m 0700 "\$BACKUP_DIR"
systemctl stop wings 2>/dev/null || true
if [ -d "\$WINGS_DIR" ] && [ -f "\$WINGS_DIR/config.yml" ]; then
    cp -a "\$WINGS_DIR/config.yml" "\$BACKUP_DIR/wings-config.\${TS}.yml.bak"
    r_info "config.yml backup saved."
fi
install -d -m 0755 "\$WINGS_DIR"
REMOTE_HBW1
} )
    exec_cmd "$IP" "$PW" "$STAGE1" || log_warn "Partial backup."

    if [[ -n "$NEW_TOKEN" ]]; then
        log_info "Running auto-deploy token..."
        local TOKEN_B64
        TOKEN_B64=$(printf '%s' "$NEW_TOKEN" | base64 -w0 2>/dev/null || printf '%s' "$NEW_TOKEN" | base64 | tr -d '\n')
        local STAGE2
        STAGE2=$( { remote_lib; cat <<REMOTE_HBW2
cd '${WINGS_DIR}' || r_fatal "cd ${WINGS_DIR} failed"
DECODED=\$(echo '${TOKEN_B64}' | base64 -d 2>/dev/null) || r_fatal "Token base64 decode failed"
[ -n "\$DECODED" ] || r_fatal "Decoded token empty"
bash -c "\$DECODED" || r_fatal "Auto-deploy token command failed"
REMOTE_HBW2
} )
        exec_cmd "$IP" "$PW" "$STAGE2" || log_error "Auto-deploy token failed."
    else
        log_warn "Token not provided — copy auto-deploy command from panel."
        printf '  %bHow: Panel → Admin → Nodes → select node → Configuration tab → Generate Token%b\n' "$YELLOW" "$NC"
    fi

    local STAGE3
    STAGE3=$( { remote_lib; cat <<'REMOTE_HBW3'
systemctl daemon-reload
systemctl enable wings >/dev/null 2>&1 || true
r_svc_enable_start wings || r_warn "Wings did not become active"
systemctl status wings --no-pager 2>&1 | head -n 12 || true
REMOTE_HBW3
} )
    exec_cmd "$IP" "$PW" "$STAGE3" || log_warn "Wings restart issue."

    printf '\n  %b%b✅  WINGS HACKBACK DONE!%b\n' "$GREEN" "$BOLD" "$NC"
    printf '  %bℹ️  Check log: journalctl -u wings -f%b\n\n' "$CYAN" "$NC"
}

# =============================================================================
#  PANEL INSTALL — Step 1..9
# =============================================================================
install_panel() {
    local IP="${1:-}" PW="${2:-}" DOMAIN="${3:-}" NODE_DOMAIN="${4:-}" RAM="${5:-2048}" USE_SSL="${6:-no}"

    [[ -z "$IP" || -z "$DOMAIN" ]] && {
        log_error "Missing parameters!"
        echo "Format: bash $0 panel <ip> <pwvps> <domain> <nodedomain> <ram> [yes|no]"
        exit 1
    }
    validate_ip "$IP"          || log_fatal "Invalid IP: $IP"
    validate_domain "$DOMAIN"  || log_fatal "Invalid domain: $DOMAIN"

    PW="${PW:-}"; [[ -z "$PW" ]] && PW="-"
    NODE_DOMAIN="${NODE_DOMAIN:-$DOMAIN}"
    validate_domain "$NODE_DOMAIN" || { log_warn "NODE_DOMAIN invalid → fallback to DOMAIN"; NODE_DOMAIN="$DOMAIN"; }

    [[ "$RAM" =~ ^[0-9]+$ ]] || { log_warn "RAM not numeric → fallback 2048"; RAM=2048; }
    USE_SSL=$(echo "$USE_SSL" | tr '[:upper:]' '[:lower:]')

    DOMAIN="$(echo "$DOMAIN" | tr -d '[:space:]')"
    local ADMIN_EMAIL="${ADMIN_EMAIL:-admin@${DOMAIN}}"
    ADMIN_EMAIL="$(echo "$ADMIN_EMAIL" | tr -d '[:space:]')"
    validate_email "$ADMIN_EMAIL" || ADMIN_EMAIL="admin@${DOMAIN}"

    local ADMIN_PASSWORD="${ADMIN_PASSWORD:-}" DB_PASSWORD="${DB_PASSWORD:-}"
    [[ -z "$ADMIN_PASSWORD" ]] && ADMIN_PASSWORD="$(gen_password 18)"
    [[ -z "$DB_PASSWORD"    ]] && DB_PASSWORD="$(gen_password 24)"

    local APP_URL
    if [[ "$USE_SSL" == "yes" ]]; then APP_URL="https://${DOMAIN}"
    else                               APP_URL="http://${DOMAIN}"; fi

    require_var IP DOMAIN NODE_DOMAIN ADMIN_EMAIL ADMIN_PASSWORD DB_PASSWORD APP_URL PHP_VER TIMEZONE

    # ---------- STEP 1 ----------
    log_step "Step 1/9 — System bootstrap"
    local S1
    S1=$( { remote_lib; cat <<'REMOTE_S1'
dpkg --configure -a 2>/dev/null || true
r_apt_lock_wait
apt-get -f install -y >/dev/null 2>&1 || true
apt-get clean        >/dev/null 2>&1 || true
rm -rf /var/lib/apt/lists/* 2>/dev/null || true
r_apt_update
r_retry env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y --allow-downgrades --allow-change-held-packages || \
    r_warn "apt upgrade non-fatal failure"
r_apt_install curl wget git unzip tar sudo cron jq openssl ca-certificates gnupg lsb-release \
    apt-transport-https software-properties-common dnsutils netcat-openbsd ufw
r_apt_install mariadb-server mariadb-client
r_svc_enable_start mariadb || r_fatal "mariadb not active"
REMOTE_S1
} )
    exec_cmd "$IP" "$PW" "$S1" || log_fatal "Step 1 failed!"
    log_ok "Step 1 done."

    # ---------- STEP 2 ----------
    log_step "Step 2/9 — Install PHP ${PHP_VER} + extensions"
    local PHP_REPO_SCRIPT PHP_REPO_B64
    PHP_REPO_SCRIPT="$(setup_php_repo_remote)"
    PHP_REPO_B64=$(printf '%s' "$PHP_REPO_SCRIPT" | base64 -w0 2>/dev/null || printf '%s' "$PHP_REPO_SCRIPT" | base64 | tr -d '\n')

    local S2
    S2=$( { remote_lib; cat <<REMOTE_S2
PHP_VER='${PHP_VER}'
PHP_REPO_B64='${PHP_REPO_B64}'

REPO_DECODED=\$(echo "\$PHP_REPO_B64" | base64 -d 2>/dev/null) || r_fatal "PHP repo b64 decode failed"
[ -n "\$REPO_DECODED" ] || r_fatal "PHP repo script empty"
bash -c "\$REPO_DECODED" || r_fatal "PHP repo configuration failed"

r_apt_install \
    "php\${PHP_VER}" "php\${PHP_VER}-cli" "php\${PHP_VER}-gd" "php\${PHP_VER}-mysql" \
    "php\${PHP_VER}-pdo" "php\${PHP_VER}-mbstring" "php\${PHP_VER}-tokenizer" \
    "php\${PHP_VER}-bcmath" "php\${PHP_VER}-xml" "php\${PHP_VER}-fpm" \
    "php\${PHP_VER}-curl" "php\${PHP_VER}-zip" "php\${PHP_VER}-intl" \
    "php\${PHP_VER}-readline" "php\${PHP_VER}-sqlite3"

command -v "php\${PHP_VER}" >/dev/null 2>&1 || r_fatal "php\${PHP_VER} not installed"

r_svc_enable_start "php\${PHP_VER}-fpm" || r_fatal "php-fpm not active"

SOCK=\$(r_php_fpm_socket "\$PHP_VER" || true)
[ -n "\$SOCK" ] || r_fatal "PHP-FPM socket not found for php\${PHP_VER}"
r_ok "PHP-FPM socket OK: \$SOCK"
REMOTE_S2
} )
    exec_cmd "$IP" "$PW" "$S2" || log_fatal "Step 2 failed!"
    log_ok "PHP ${PHP_VER} installed."

    # ---------- STEP 3 ----------
    log_step "Step 3/9 — Configure MariaDB & create database"
    local S3
    S3=$( { remote_lib; cat <<REMOTE_S3
DB_PASSWORD='${DB_PASSWORD}'

r_svc_enable_start mariadb || r_fatal "mariadb not active"

i=0
until mysqladmin ping -u root --silent 2>/dev/null; do
    i=\$((i+1)); [ \$i -ge 30 ] && r_fatal "MariaDB ping timeout"
    sleep 2
done
r_ok "MariaDB ready"

mysql -u root <<SQL
CREATE USER IF NOT EXISTS 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '\${DB_PASSWORD}';
ALTER USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '\${DB_PASSWORD}';
CREATE DATABASE IF NOT EXISTS panel CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL

mysql -u pterodactyl -p"\$DB_PASSWORD" -h 127.0.0.1 -e "USE panel;" 2>/dev/null \
    || r_fatal "DB user/auth verification failed"
r_ok "Database 'panel' + user 'pterodactyl' verified"
REMOTE_S3
} )
    exec_cmd "$IP" "$PW" "$S3" || log_fatal "Step 3 failed!"
    log_ok "MariaDB & database OK."

    # ---------- STEP 4 ----------
    log_step "Step 4/9 — Install Redis & Composer"
    local S4
    S4=$( { remote_lib; cat <<'REMOTE_S4'
r_apt_install redis-server
r_svc_enable_start redis-server || r_fatal "redis-server not active"
r_wait_port 6379 127.0.0.1 30 || r_fatal "redis port 6379 not reachable"

if ! command -v composer >/dev/null 2>&1; then
    command -v curl >/dev/null 2>&1 || r_apt_install curl
    EXPECTED_SIG=$(curl -fsSL https://composer.github.io/installer.sig)
    [ -n "$EXPECTED_SIG" ] || r_fatal "Cannot fetch composer signature"
    r_retry php -r "copy('https://getcomposer.org/installer','/tmp/composer-setup.php');"
    [ -s /tmp/composer-setup.php ] || r_fatal "composer-setup.php empty"
    ACTUAL_SIG=$(php -r "echo hash_file('sha384','/tmp/composer-setup.php');")
    if [ "$EXPECTED_SIG" != "$ACTUAL_SIG" ]; then
        rm -f /tmp/composer-setup.php
        r_fatal "Composer installer checksum mismatch"
    fi
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
    rm -f /tmp/composer-setup.php
fi
command -v composer >/dev/null 2>&1 || r_fatal "composer not installed"
composer --version 2>&1 | head -n1 || r_fatal "composer not runnable"
r_ok "Composer ready"
REMOTE_S4
} )
    exec_cmd "$IP" "$PW" "$S4" || log_fatal "Step 4 failed!"
    log_ok "Redis & Composer OK."

    # ---------- STEP 5 ----------
    log_step "Step 5/9 — Download & extract Pterodactyl Panel"
    local S5
    S5=$( { remote_lib; cat <<REMOTE_S5
PANEL_DIR='${PANEL_DIR}'
PHP_VER='${PHP_VER}'

install -d -m 0755 "\$PANEL_DIR"
cd "\$PANEL_DIR" || r_fatal "cd \$PANEL_DIR failed"

r_retry curl -fsSL --retry 3 --retry-delay 5 \
    -o panel.tar.gz \
    https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
[ -s panel.tar.gz ] || r_fatal "panel.tar.gz empty/missing"

tar -xzf panel.tar.gz || r_fatal "tar extract failed"
rm -f panel.tar.gz

[ -d storage ] && [ -d bootstrap/cache ] || r_fatal "Panel structure invalid"
chmod -R 755 storage bootstrap/cache 2>/dev/null || true
chown -R www-data:www-data "\$PANEL_DIR" 2>/dev/null || true

if [ ! -f .env ]; then
    [ -f .env.example ] || r_fatal ".env.example missing"
    cp .env.example .env
fi

REQUIRED='curl pdo pdo_mysql mbstring xml bcmath zip openssl gd'
MISSING=''
for ext in \$REQUIRED; do
    php -m 2>/dev/null | grep -qi "^\${ext}\$" || MISSING="\$MISSING \$ext"
done
[ -z "\$MISSING" ] || r_fatal "PHP extensions missing:\$MISSING"

command -v composer >/dev/null 2>&1 || r_fatal "composer missing"

r_retry env COMPOSER_ALLOW_SUPERUSER=1 composer install \
    --no-dev --optimize-autoloader --no-interaction --no-progress

if ! grep -q '^APP_KEY=base64:' .env 2>/dev/null; then
    php artisan key:generate --force || r_fatal "APP_KEY generate failed"
fi

[ -f .env ] && [ -f artisan ] || r_fatal "Panel install incomplete"
r_ok "Panel files & dependencies ready"
REMOTE_S5
} )
    exec_cmd "$IP" "$PW" "$S5" || log_fatal "Step 5 failed!"
    log_ok "Panel downloaded."

    # ---------- STEP 6 ----------
    log_step "Step 6/9 — Configure environment & admin user"
    local S6
    S6=$( { remote_lib; cat <<REMOTE_S6
PANEL_DIR='${PANEL_DIR}'
ADMIN_EMAIL='${ADMIN_EMAIL}'
ADMIN_PASSWORD='${ADMIN_PASSWORD}'
DB_PASSWORD='${DB_PASSWORD}'
APP_URL='${APP_URL}'
TIMEZONE='${TIMEZONE}'

cd "\$PANEL_DIR" || r_fatal "cd \$PANEL_DIR failed"

php artisan p:environment:setup \
    --author="\$ADMIN_EMAIL" \
    --url="\$APP_URL" \
    --timezone="\$TIMEZONE" \
    --cache=redis --session=redis --queue=redis \
    --redis-host=127.0.0.1 --redis-pass= --redis-port=6379 \
    --settings-ui=true --no-interaction \
    || r_fatal "p:environment:setup failed"

php artisan p:environment:database \
    --host=127.0.0.1 --port=3306 --database=panel \
    --username=pterodactyl --password="\$DB_PASSWORD" \
    --no-interaction \
    || r_fatal "p:environment:database failed"

php artisan migrate --seed --force || r_fatal "migrate --seed failed"

php artisan p:user:make \
    --email="\$ADMIN_EMAIL" --username=admin \
    --name-first=Admin --name-last=User \
    --password="\$ADMIN_PASSWORD" --admin=1 --no-interaction \
    || r_warn "Admin user may already exist (idempotent)"

chown -R www-data:www-data "\$PANEL_DIR"
r_ok "Environment + admin user configured"
REMOTE_S6
} )
    exec_cmd "$IP" "$PW" "$S6" || log_fatal "Step 6 failed!"
    log_ok "Environment & admin user configured."

    # ---------- STEP 7 — NGINX (HARDENED) ----------
    log_step "Step 7/9 — Nginx"
    local S7
    S7=$( { remote_lib; cat <<REMOTE_S7
PANEL_DIR='${PANEL_DIR}'
PHP_VER='${PHP_VER}'
DOMAIN='${DOMAIN}'

r_apt_install nginx
command -v nginx >/dev/null 2>&1 || r_fatal "nginx binary missing after install"

SOCK=\$(r_php_fpm_socket "\$PHP_VER" || true)
[ -n "\$SOCK" ] && [ -S "\$SOCK" ] || r_fatal "PHP-FPM socket not found for php\${PHP_VER}"
r_info "Using PHP-FPM socket: \$SOCK"

install -d -m 0755 /etc/nginx/sites-available /etc/nginx/sites-enabled
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

NGX_CONF=/etc/nginx/sites-available/pterodactyl.conf
NGX_TMP=\$(mktemp)

cat >"\$NGX_TMP" <<NGINX_EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    root ${PANEL_DIR}/public;
    index index.php;

    access_log /var/log/nginx/pterodactyl.access.log;
    error_log  /var/log/nginx/pterodactyl.error.log;

    client_max_body_size 100m;
    client_body_timeout 120s;

    sendfile off;

    add_header X-Content-Type-Options "nosniff";
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Frame-Options "SAMEORIGIN";
    add_header Referrer-Policy "same-origin";

    location / {
        try_files \\\$uri \\\$uri/ /index.php?\\\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:\${SOCK};
        fastcgi_index index.php;
        include /etc/nginx/fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize=100M\\\\n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \\\$document_root\\\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\\.ht {
        deny all;
    }
}
NGINX_EOF

mv -f "\$NGX_TMP" "\$NGX_CONF"
chmod 644 "\$NGX_CONF"
ln -sfn "\$NGX_CONF" /etc/nginx/sites-enabled/pterodactyl.conf

if ! nginx -t 2>/tmp/nginx-test.err; then
    r_error "nginx config invalid:"
    cat /tmp/nginx-test.err >&2
    cat "\$NGX_CONF" >&2
    exit 1
fi
rm -f /tmp/nginx-test.err

r_svc_enable_start nginx                  || r_fatal "nginx failed"
r_svc_enable_start "php\${PHP_VER}-fpm"   || r_fatal "php-fpm failed"

r_wait_port 80 127.0.0.1 15 || r_warn "port 80 not yet listening"
r_ok "Nginx + PHP-FPM operational"
REMOTE_S7
} )
    exec_cmd "$IP" "$PW" "$S7" || log_fatal "Step 7 (Nginx) failed!"
    log_ok "Nginx & PHP-FPM OK."

    # ---------- STEP 8 — SSL ----------
    if [[ "$USE_SSL" == "yes" ]]; then
        log_step "Step 8/9 — SSL Let's Encrypt"
        local S8
        S8=$( { remote_lib; cat <<REMOTE_S8
DOMAIN='${DOMAIN}'
ADMIN_EMAIL='${ADMIN_EMAIL}'

r_apt_update
r_apt_install certbot python3-certbot-nginx

nginx -t 2>&1 | head -n 20 || true
nginx -t || r_fatal "nginx config invalid before SSL"

systemctl reload nginx 2>/dev/null || systemctl restart nginx || true

CERTBOT_LOG=\$(mktemp)
if ! r_retry certbot --nginx --non-interactive --agree-tos --redirect \
    -m "\$ADMIN_EMAIL" -d "\$DOMAIN" 2>&1 | tee "\$CERTBOT_LOG"; then
    r_error "CERTBOT FAILED"
    cat "\$CERTBOT_LOG" >&2
    r_warn "Possible causes: DNS not pointing, port 80/443 blocked, CF proxy"
    rm -f "\$CERTBOT_LOG"
    exit 1
fi
rm -f "\$CERTBOT_LOG"

CRON_TMP=\$(mktemp)
(crontab -l 2>/dev/null | grep -v 'certbot renew' || true) > "\$CRON_TMP"
echo '0 3 * * * certbot renew --quiet --post-hook "systemctl reload nginx"' >> "\$CRON_TMP"
crontab "\$CRON_TMP"
rm -f "\$CRON_TMP"

sleep 3
HTTP_CODE=\$(curl -k -o /dev/null -s -w '%{http_code}' --max-time 10 "https://\$DOMAIN" || echo 000)
r_info "HTTPS response code: \$HTTP_CODE"
REMOTE_S8
} )
        exec_cmd "$IP" "$PW" "$S8" || log_fatal "Step 8 (SSL) failed!"
        log_ok "SSL Let's Encrypt installed."
    else
        log_step "Step 8/9 — SSL skipped (HTTP only)"
        log_ok "Skipped."
    fi

    # ---------- STEP 9 — Cron, Queue Worker, Firewall ----------
    log_step "Step 9/9 — Cron, Queue Worker, Firewall"
    local PTEROQ_SVC PTEROQ_B64
    PTEROQ_SVC=$(cat <<EOF
[Unit]
Description=Pterodactyl Queue Worker
After=network.target redis-server.service mariadb.service
Wants=redis-server.service
StartLimitInterval=180
StartLimitBurst=30

[Service]
User=www-data
Group=www-data
WorkingDirectory=${PANEL_DIR}
ExecStart=/usr/bin/php ${PANEL_DIR}/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3 --max-time=3600
Restart=always
RestartSec=5
TimeoutStopSec=60
KillSignal=SIGTERM
StandardOutput=journal
StandardError=journal
SyslogIdentifier=pteroq

[Install]
WantedBy=multi-user.target
EOF
)
    PTEROQ_B64=$(printf '%s' "$PTEROQ_SVC" | base64 -w0 2>/dev/null || printf '%s' "$PTEROQ_SVC" | base64 | tr -d '\n')

    local S9
    S9=$( { remote_lib; cat <<REMOTE_S9
PANEL_DIR='${PANEL_DIR}'
PTEROQ_B64='${PTEROQ_B64}'

CRON_TMP=\$(mktemp)
(crontab -l 2>/dev/null | grep -v 'pterodactyl/artisan schedule:run' || true) > "\$CRON_TMP"
echo "* * * * * /usr/bin/php \${PANEL_DIR}/artisan schedule:run >> /dev/null 2>&1" >> "\$CRON_TMP"
crontab "\$CRON_TMP"
rm -f "\$CRON_TMP"

DECODED=\$(echo "\$PTEROQ_B64" | base64 -d 2>/dev/null) || r_fatal "pteroq b64 decode failed"
[ -n "\$DECODED" ] || r_fatal "pteroq service content empty"
SVC_TMP=\$(mktemp)
printf '%s\n' "\$DECODED" > "\$SVC_TMP"
grep -q '\[Service\]' "\$SVC_TMP" || r_fatal "pteroq.service invalid"
install -m 0644 "\$SVC_TMP" /etc/systemd/system/pteroq.service
rm -f "\$SVC_TMP"

systemctl daemon-reload
systemctl enable pteroq >/dev/null 2>&1 || true
r_svc_enable_start pteroq || {
    journalctl -u pteroq -n 60 --no-pager 2>&1 | tail -n 60 >&2 || true
    r_fatal "pteroq failed to start"
}

if command -v ufw >/dev/null 2>&1; then
    ufw allow 22/tcp  >/dev/null 2>&1 || true
    ufw allow 80/tcp  >/dev/null 2>&1 || true
    ufw allow 443/tcp >/dev/null 2>&1 || true
    yes | ufw enable  >/dev/null 2>&1 || ufw --force enable >/dev/null 2>&1 || true
    ufw status verbose 2>/dev/null | head -n 20 || true
else
    r_warn "UFW not available"
fi

r_svc_enable_start cron 2>/dev/null || systemctl restart cron 2>/dev/null || true
r_ok "Step 9 complete"
REMOTE_S9
} )
    exec_cmd "$IP" "$PW" "$S9" || log_fatal "Step 9 failed!"

    # ---------- HEALTH CHECK ----------
    log_step "Final Health Check"
    local HC
    HC=$( { remote_lib; cat <<REMOTE_HC
PHP_VER='${PHP_VER}'
DOMAIN='${DOMAIN}'

FAIL=0
echo '========================'
echo ' SYSTEM HEALTH CHECK'
echo '========================'

HTTP_CODE=\$(curl -o /dev/null -s -w '%{http_code}' --max-time 10 http://127.0.0.1 || echo 000)
echo "HTTP => \$HTTP_CODE"
case "\$HTTP_CODE" in
    200|301|302|400) ;;
    *) FAIL=1 ;;
esac

for svc in nginx "php\${PHP_VER}-fpm" redis-server mariadb pteroq cron; do
    if systemctl is-active --quiet "\$svc" 2>/dev/null; then
        echo "[OK]   \$svc"
    else
        echo "[FAIL] \$svc"
        [ "\$svc" = "cron" ] || FAIL=1
    fi
done

if [ -d "/etc/letsencrypt/live/\$DOMAIN" ]; then
    echo '[OK]   SSL certificate present'
else
    echo '[INFO] SSL not installed'
fi

[ "\$FAIL" -eq 0 ] && { echo '[SUCCESS] SYSTEM HEALTHY'; exit 0; } \
                  || { echo '[WARNING] SYSTEM HAS ISSUES'; exit 1; }
REMOTE_HC
} )
    exec_cmd "$IP" "$PW" "$HC" || log_warn "Health check reported issues."

    local CRED_FILE="${CRED_DIR}/panel-${IP}-$(date +%Y%m%d-%H%M%S).txt"
    cat >"$CRED_FILE" <<EOF
========================================
  PTERODACTYL PANEL CREDENTIALS
  Generated : $(date)
========================================
Panel URL    : ${APP_URL}
Admin Email  : ${ADMIN_EMAIL}
Admin User   : admin
Admin Pass   : ${ADMIN_PASSWORD}
DB User      : pterodactyl
DB Pass      : ${DB_PASSWORD}
DB Name      : panel
Node Domain  : ${NODE_DOMAIN}
RAM (alloc)  : ${RAM} MB
EOF
    chmod 600 "$CRED_FILE" 2>/dev/null || true
    log_ok "Credentials saved: ${CRED_FILE}"
}

# =============================================================================
#  UNINSTALL / UPDATE / STATUS / BACKUP / RESTORE / REPAIR
# =============================================================================
uninstall_panel() {
    local IP="${1:-}" PW="${2:--}"
    [[ -z "$IP" ]] && { log_error "Format: bash $0 uninstall-panel <ip> <pwvps>"; exit 1; }
    [[ -z "$PW" ]] && PW="-"

    show_banner
    printf '  %b%b🗑️  UNINSTALL PANEL%b\n\n' "$RED" "$BOLD" "$NC"
    if [[ "$ASSUME_YES" != "1" ]]; then
        printf '  Type %bDELETE PANEL%b to confirm: ' "$BOLD" "$NC"
        read -r CONFIRM </dev/tty 2>/dev/null || CONFIRM=""
        [[ "$CONFIRM" != "DELETE PANEL" ]] && { log_warn "Cancelled."; exit 0; }
    fi

    local U
    U=$( { remote_lib; cat <<REMOTE_U
PANEL_DIR='${PANEL_DIR}'
PHP_VER='${PHP_VER}'

systemctl stop pteroq    2>/dev/null || true
systemctl disable pteroq 2>/dev/null || true
rm -f /etc/systemd/system/pteroq.service
systemctl daemon-reload

rm -f /etc/nginx/sites-enabled/pterodactyl.conf
rm -f /etc/nginx/sites-available/pterodactyl.conf
systemctl reload nginx 2>/dev/null || true

systemctl stop "php\${PHP_VER}-fpm" 2>/dev/null || true
DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq "php\${PHP_VER}*" mariadb-server mariadb-client nginx redis-server 2>/dev/null || true
DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq 2>/dev/null || true

rm -rf "\$PANEL_DIR"

mysql -u root -e "DROP DATABASE IF EXISTS panel;"                  2>/dev/null || true
mysql -u root -e "DROP USER IF EXISTS 'pterodactyl'@'127.0.0.1';"  2>/dev/null || true

CRON_TMP=\$(mktemp)
(crontab -l 2>/dev/null | grep -v 'pterodactyl/artisan' || true) > "\$CRON_TMP"
crontab "\$CRON_TMP"; rm -f "\$CRON_TMP"

r_ok "Panel removed."
REMOTE_U
} )
    exec_cmd "$IP" "$PW" "$U" || log_warn "Partial uninstall."
    printf '\n  %b%b✅  Panel uninstalled!%b\n\n' "$GREEN" "$BOLD" "$NC"
}

uninstall_wings() {
    local IP="${1:-}" PW="${2:--}"
    [[ -z "$IP" ]] && { log_error "Format: bash $0 uninstall-wings <ip> <pwvps>"; exit 1; }
    [[ -z "$PW" ]] && PW="-"

    show_banner
    printf '  %b%b🗑️  UNINSTALL WINGS%b\n\n' "$RED" "$BOLD" "$NC"
    if [[ "$ASSUME_YES" != "1" ]]; then
        printf '  Type %bDELETE WINGS%b to confirm: ' "$BOLD" "$NC"
        read -r CONFIRM </dev/tty 2>/dev/null || CONFIRM=""
        [[ "$CONFIRM" != "DELETE WINGS" ]] && { log_warn "Cancelled."; exit 0; }
    fi

    local U
    U=$( { remote_lib; cat <<REMOTE_UW
WINGS_DIR='${WINGS_DIR}'

systemctl stop wings    2>/dev/null || true
systemctl disable wings 2>/dev/null || true
docker ps -a --filter 'name=pterodactyl' -q 2>/dev/null | xargs -r docker rm -f 2>/dev/null || true
rm -f /usr/local/bin/wings
rm -rf "\$WINGS_DIR"
rm -f /etc/systemd/system/wings.service
systemctl daemon-reload

REMAINING=\$(docker ps -a -q 2>/dev/null | wc -l)
if [ "\$REMAINING" -eq 0 ]; then
    r_info "No remaining Docker containers — purging Docker"
    DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq docker-ce docker-ce-cli containerd.io 2>/dev/null || true
    rm -rf /var/lib/docker
else
    r_warn "Other Docker containers detected — Docker not removed"
fi
r_ok "Wings removed."
REMOTE_UW
} )
    exec_cmd "$IP" "$PW" "$U" || log_warn "Partial uninstall."
    printf '\n  %b%b✅  Wings uninstalled!%b\n\n' "$GREEN" "$BOLD" "$NC"
}

update_panel() {
    local IP="${1:-}" PW="${2:--}"
    [[ -z "$IP" ]] && { log_error "Format: bash $0 update-panel <ip> <pwvps>"; exit 1; }
    [[ -z "$PW" ]] && PW="-"

    show_banner
    log_step "♻️  Update Pterodactyl Panel"
    confirm "Continue update?" "y" || exit 0

    local U
    U=$( { remote_lib; cat <<REMOTE_UP
PANEL_DIR='${PANEL_DIR}'
BACKUP_DIR='${BACKUP_DIR}'

cd "\$PANEL_DIR" || r_fatal "Panel not found at \$PANEL_DIR"
TS=\$(date +%Y%m%d-%H%M%S)
install -d -m 0700 "\$BACKUP_DIR"
cp -a .env "\$BACKUP_DIR/panel.env.\${TS}.bak" 2>/dev/null || true
command -v mysqldump >/dev/null 2>&1 && \
    mysqldump -u root panel > "\$BACKUP_DIR/panel-db.\${TS}.sql" 2>/dev/null || true

php artisan down || true
r_retry sh -c 'curl -fL --retry 3 https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz | tar -xz'
chmod -R 755 storage bootstrap/cache 2>/dev/null || true
r_retry env COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction
php artisan view:clear   || true
php artisan config:clear || true
php artisan migrate --seed --force || r_fatal "migrate failed"
chown -R www-data:www-data "\$PANEL_DIR"
php artisan queue:restart || true
php artisan up
r_ok "Update completed"
REMOTE_UP
} )
    exec_cmd "$IP" "$PW" "$U" || log_fatal "Update failed!"
    log_ok "Panel updated."
}

check_status() {
    local IP="${1:-127.0.0.1}" PW="${2:--}"
    [[ -z "$PW" ]] && PW="-"

    show_banner
    log_step "📊 Service status on $IP"
    local C
    C=$( { remote_lib; cat <<'REMOTE_C'
echo '── Service Status ──'
for svc in nginx php8.3-fpm php8.2-fpm php8.1-fpm php8.0-fpm mariadb mysql redis-server redis pteroq wings docker cron; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
        STATUS=$(systemctl is-active "$svc" 2>/dev/null || echo unknown)
        printf '  %-22s : %s\n' "$svc" "$STATUS"
    fi
done
echo ''
echo '── Disk & RAM ──'
df -h / | tail -1 | awk '{print "  Disk root : "$3"/"$2" ("$5" used)"}'
free -h | awk 'NR==2{printf "  RAM       : %s/%s\n", $3, $2}'
echo ''
echo '── Listener Ports ──'
ss -tlnp 2>/dev/null | awk 'NR==1 || /:(80|443|3306|6379|8080|2022)/' | head -n 15
REMOTE_C
} )
    exec_cmd "$IP" "$PW" "$C" || log_warn "Status partial."
}

backup_panel() {
    local IP="${1:-127.0.0.1}" PW="${2:--}"
    [[ -z "$PW" ]] && PW="-"

    show_banner
    log_step "💾 Backup Panel"
    local B
    B=$( { remote_lib; cat <<REMOTE_B
PANEL_DIR='${PANEL_DIR}'
BACKUP_DIR='${BACKUP_DIR}'
TS=\$(date +%Y%m%d-%H%M%S)
install -d -m 0700 "\$BACKUP_DIR"

cp -a "\$PANEL_DIR/.env" "\$BACKUP_DIR/panel.env.\${TS}.bak" 2>/dev/null || true
command -v mysqldump >/dev/null 2>&1 && \
    mysqldump -u root panel > "\$BACKUP_DIR/panel-db.\${TS}.sql" 2>/dev/null || true

PARENT=\$(dirname  "\$PANEL_DIR")
BASE=\$(basename "\$PANEL_DIR")
tar -czf "\$BACKUP_DIR/panel-files.\${TS}.tar.gz" -C "\$PARENT" "\$BASE" 2>/dev/null || true

ls -lh "\$BACKUP_DIR/"*\${TS}* 2>/dev/null || true
r_ok "Backup completed"
REMOTE_B
} )
    exec_cmd "$IP" "$PW" "$B" || log_error "Backup failed."
    log_ok "Backup stored in ${BACKUP_DIR}"
}

restore_panel() {
    local IP="${1:-127.0.0.1}" PW="${2:--}" SQL_FILE="${3:-}"
    [[ -z "$PW" ]] && PW="-"
    [[ -z "$SQL_FILE" ]] && { log_error "Format: bash $0 restore-panel <ip> <pw> <path-to-backup.sql>"; exit 1; }

    show_banner
    log_step "♻️  Restore panel database from $SQL_FILE"
    confirm "Sure? this will overwrite the current 'panel' database." "n" || exit 0

    local R
    R=$( { remote_lib; cat <<REMOTE_R
PANEL_DIR='${PANEL_DIR}'
SQL_FILE='${SQL_FILE}'
[ -f "\$SQL_FILE" ] || r_fatal "SQL file not found: \$SQL_FILE"
mysql -u root panel < "\$SQL_FILE" || r_fatal "Failed to restore database"
cd "\$PANEL_DIR" && php artisan migrate --force && php artisan optimize:clear
r_ok "Restore completed"
REMOTE_R
} )
    exec_cmd "$IP" "$PW" "$R" || log_error "Restore failed."
}

repair_panel() {
    local IP="${1:-127.0.0.1}" PW="${2:--}"
    [[ -z "$PW" ]] && PW="-"

    show_banner
    log_step "🛠️  Repair Panel"
    local R
    R=$( { remote_lib; cat <<REMOTE_RP
PANEL_DIR='${PANEL_DIR}'
PHP_VER='${PHP_VER}'

cd "\$PANEL_DIR" || r_fatal "Panel not found at \$PANEL_DIR"
chown -R www-data:www-data "\$PANEL_DIR"
find "\$PANEL_DIR" -type d -exec chmod 755 {} \;
find "\$PANEL_DIR" -type f -exec chmod 644 {} \;
chmod -R 775 "\$PANEL_DIR/storage" "\$PANEL_DIR/bootstrap/cache"
chown -R www-data:www-data "\$PANEL_DIR/storage" "\$PANEL_DIR/bootstrap/cache"
php artisan optimize:clear || true
php artisan queue:restart  || true
systemctl restart "php\${PHP_VER}-fpm" 2>/dev/null || true
systemctl reload nginx                 2>/dev/null || true
systemctl restart pteroq               2>/dev/null || true
r_ok "Repair completed"
REMOTE_RP
} )
    exec_cmd "$IP" "$PW" "$R" || log_warn "Partial repair."
    log_ok "Repair done."
}

# =============================================================================
#  INTERACTIVE MENU
# =============================================================================
prompt_target() {
    if [ ! -t 0 ]; then
        M_IP=$(get_local_ip); M_PW="-"; return 0
    fi
    read -rp "  Target IP (empty = local): " M_IP </dev/tty
    [[ -z "$M_IP" ]] && M_IP=$(get_local_ip)
    if is_local_target "$M_IP"; then
        M_PW="-"
    else
        read -rsp "  Root password: " M_PW </dev/tty; echo
    fi
}

interactive_menu() {
    if [ ! -t 0 ]; then
        log_warn "Non-interactive mode detected — use direct command (e.g. 'panel <ip> <pw> ...')"
        show_help
        exit 0
    fi
    while true; do
        show_banner
        printf '  %bMAIN MENU%b\n\n' "$BOLD" "$NC"
        printf '  %b[1]%b  Install Panel\n'                                   "$GREEN"  "$NC"
        printf '  %b[2]%b  Install Wings\n'                                   "$GREEN"  "$NC"
        printf '  %b[3]%b  Install via Official (pterodactyl-installer.se)\n' "$GREEN"  "$NC"
        printf '  %b[4]%b  Install SSL (standalone)\n'                        "$GREEN"  "$NC"
        printf '  %b[5]%b  Hackback Panel (Reset Admin)\n'                    "$RED"    "$NC"
        printf '  %b[6]%b  Hackback Wings\n'                                  "$RED"    "$NC"
        printf '  %b[7]%b  Update Panel\n'                                    "$YELLOW" "$NC"
        printf '  %b[8]%b  Repair Panel\n'                                    "$YELLOW" "$NC"
        printf '  %b[9]%b  Backup Panel\n'                                    "$MAGENTA" "$NC"
        printf '  %b[10]%b Restore Panel\n'                                   "$MAGENTA" "$NC"
        printf '  %b[11]%b Check Status\n'                                    "$CYAN"   "$NC"
        printf '  %b[12]%b Uninstall Panel\n'                                 "$RED"    "$NC"
        printf '  %b[13]%b Uninstall Wings\n'                                 "$RED"    "$NC"
        printf '  %b[14]%b View Installer Log\n'                              "$BLUE"   "$NC"
        printf '  %b[0]%b  Exit\n\n'                                          "$RED"    "$NC"
        printf '  %bSelect [0-14]:%b ' "$BOLD" "$NC"
        read -r CHOICE </dev/tty || CHOICE=""
        case "$CHOICE" in
            1)
                prompt_target
                read -rp "  Panel domain: " M_DOMAIN </dev/tty
                read -rp "  Node domain (empty = same): " M_NDOMAIN </dev/tty
                [[ -z "$M_NDOMAIN" ]] && M_NDOMAIN="$M_DOMAIN"
                read -rp "  RAM (MB, default 2048): " M_RAM </dev/tty
                [[ -z "$M_RAM" ]] && M_RAM="2048"
                read -rp "  SSL? (yes/no, default no): " M_SSL </dev/tty
                [[ -z "$M_SSL" ]] && M_SSL="no"
                install_panel "$M_IP" "$M_PW" "$M_DOMAIN" "$M_NDOMAIN" "$M_RAM" "$M_SSL"
                ;;
            2) prompt_target; read -rp "  Auto-deploy token (optional): " M_TOKEN </dev/tty; install_wings "$M_IP" "$M_PW" "$M_TOKEN" ;;
            3) install_official ;;
            4) prompt_target; read -rp "  Domain: " M_DOMAIN </dev/tty; read -rp "  Email: " M_EMAIL </dev/tty; install_ssl "$M_IP" "$M_PW" "$M_DOMAIN" "$M_EMAIL" ;;
            5)
                prompt_target
                read -rp "  New admin email [admin@localhost.local]: " M_EMAIL </dev/tty
                read -rp "  New password (empty=auto): " M_PASS </dev/tty
                hackback_panel "$M_IP" "$M_PW" "${M_EMAIL:-admin@localhost.local}" "${M_PASS:-}"
                ;;
            6) prompt_target; read -rp "  Auto-deploy token (empty=manual later): " M_TOKEN </dev/tty; hackback_wings "$M_IP" "$M_PW" "$M_TOKEN" ;;
            7)  prompt_target; update_panel    "$M_IP" "$M_PW" ;;
            8)  prompt_target; repair_panel    "$M_IP" "$M_PW" ;;
            9)  prompt_target; backup_panel    "$M_IP" "$M_PW" ;;
            10) prompt_target; read -rp "  Path to .sql backup: " M_SQL </dev/tty; restore_panel "$M_IP" "$M_PW" "$M_SQL" ;;
            11) prompt_target; check_status    "$M_IP" "$M_PW" ;;
            12) prompt_target; uninstall_panel "$M_IP" "$M_PW" ;;
            13) prompt_target; uninstall_wings "$M_IP" "$M_PW" ;;
            14) [[ -f "$LOG_FILE" ]] && (less +G "$LOG_FILE" 2>/dev/null || tail -n 200 "$LOG_FILE") || log_warn "Log not yet available" ;;
            0)  printf '\n  %bGoodbye! 👋%b\n\n' "$GREEN" "$NC"; exit 0 ;;
            *)  log_error "Invalid choice" ;;
        esac
        echo ""
        printf '  %bPress ENTER to return to menu...%b' "$YELLOW" "$NC"
        read -r _ </dev/tty || true
    done
}

show_help() {
    show_banner
    cat <<HLP
  ${BOLD}USAGE${NC}
    bash $0 menu
    bash $0 panel           <ip> <pw> <domain> <nodedomain> <ram> [yes|no]
    bash $0 wings           <ip> <pw> [auto-deploy-cmd]
    bash $0 official
    bash $0 ssl             <ip> <pw> <domain> <email>
    bash $0 hackback-panel  <ip> <pw> [email] [password]
    bash $0 hackback-wings  <ip> <pw> [auto-deploy-cmd]
    bash $0 update-panel    <ip> <pw>
    bash $0 repair-panel    <ip> <pw>
    bash $0 backup-panel    <ip> <pw>
    bash $0 restore-panel   <ip> <pw> <path.sql>
    bash $0 uninstall-panel <ip> <pw>
    bash $0 uninstall-wings <ip> <pw>
    bash $0 status          [ip] [pw]

  ${BOLD}ONE-LINER${NC}
    bash <(curl -fsSL <URL>) panel <ip> <pw> <domain> <nodedomain> <ram> [yes|no]
    curl -fsSL <URL> | bash -s -- panel <ip> <pw> <domain> <nodedomain> <ram> [yes|no]

  ${BOLD}ENV VAR${NC}
    PHP_VER=8.3
    TIMEZONE_OVERRIDE=Asia/Jakarta
    ASSUME_YES=1
    DEBUG=1
    ADMIN_EMAIL=, ADMIN_PASSWORD=, DB_PASSWORD=

  ${BOLD}LOG${NC}    : ${LOG_FILE}
  ${BOLD}BACKUP${NC} : ${BACKUP_DIR}
  ${BOLD}CRED${NC}   : ${CRED_DIR}
HLP
}

# =============================================================================
#  ENTRYPOINT
# =============================================================================
main() {
    init_log "$@"
    acquire_lock
    check_root
    detect_os
    check_internet
    check_disk_space 3000
    check_ram 1024

    local ACTION="${1:-menu}"
    case "$ACTION" in
        panel|install-panel)            install_panel    "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" "${7:-}" ;;
        wings|install-wings)            install_wings    "${2:-}" "${3:-}" "${4:-}" ;;
        official|installer-se)          install_official ;;
        ssl|letsencrypt)                install_ssl      "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
        hackback-panel|hackback)        hackback_panel   "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
        hackback-wings)                 hackback_wings   "${2:-}" "${3:-}" "${4:-}" ;;
        uninstall-panel|remove-panel)   uninstall_panel  "${2:-}" "${3:-}" ;;
        uninstall-wings|remove-wings)   uninstall_wings  "${2:-}" "${3:-}" ;;
        update-panel|update)            update_panel     "${2:-}" "${3:-}" ;;
        repair-panel|repair)            repair_panel     "${2:-}" "${3:-}" ;;
        backup-panel|backup)            backup_panel     "${2:-}" "${3:-}" ;;
        restore-panel|restore)          restore_panel    "${2:-}" "${3:-}" "${4:-}" ;;
        status|check)                   check_status     "${2:-}" "${3:-}" ;;
        menu|interactive|"")            interactive_menu ;;
        help|--help|-h)                 show_help ;;
        *)
            log_error "Unknown command: $ACTION"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
