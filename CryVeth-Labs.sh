#!/usr/bin/env bash

set -o pipefail 2>/dev/null || true

if ! command -v bash >/dev/null 2>&1; then
    echo "bash not found, attempting install..."
    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: Must run as root to install bash. Use: sudo sh $0 $@"
        exit 1
    fi
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y bash
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y bash
    elif command -v yum >/dev/null 2>&1; then
        yum install -y bash
    else
        echo "ERROR: Unsupported package manager."
        exit 1
    fi
fi

if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

if (( BASH_VERSINFO[0] < 4 )); then
    echo "Need bash >= 4.0, current: $BASH_VERSION" >&2
    exit 1
fi

set -uo pipefail

readonly SCRIPT_VERSION="1.1.0"
readonly SCRIPT_NAME="CryVeth Pterodactyl Installer"
LOG_FILE="/var/log/nortex-installer.log"
readonly PANEL_DIR="/var/www/pterodactyl"
readonly WINGS_DIR="/etc/pterodactyl"
readonly BACKUP_DIR="/root/nortex-backups"
readonly CRED_DIR="/root/nortex-credentials"

PHP_VER="${PHP_VER:-8.3}"
TIMEZONE="${TIMEZONE_OVERRIDE:-${TIMEZONE:-Asia/Jakarta}}"

if [ -t 1 ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    CYAN=$'\033[0;36m'; BLUE=$'\033[0;34m'; MAGENTA=$'\033[0;35m'
    BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BLUE=''; MAGENTA=''
    BOLD=''; DIM=''; NC=''
fi

OS_ID=""
OS_VER=""
OS_CODENAME=""
OS_FAMILY=""
ARCH=""

init_log() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    if ! ( touch "$LOG_FILE" 2>/dev/null ); then
        LOG_FILE="/tmp/nortex-installer.log"
        touch "$LOG_FILE" 2>/dev/null || true
    fi
    {
        echo "==============================================================="
        echo "  $SCRIPT_NAME v$SCRIPT_VERSION"
        echo "  Started : $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "  Args    : $*"
        echo "  PID     : $$"
        echo "==============================================================="
    } >>"$LOG_FILE" 2>&1
    mkdir -p "$BACKUP_DIR" "$CRED_DIR" 2>/dev/null || true
    chmod 700 "$BACKUP_DIR" "$CRED_DIR" 2>/dev/null || true
}

_ts() { date '+%Y-%m-%d %H:%M:%S'; }
_log_raw() { echo "[$(_ts)] $*" >>"$LOG_FILE" 2>/dev/null || true; }

log_info()  { _log_raw "INFO  $*"; printf '  %b[INFO]%b   %s\n' "$CYAN" "$NC" "$*"; }
log_ok()    { _log_raw "OK    $*"; printf '  %b[OK]%b     %s\n' "$GREEN" "$NC" "$*"; }
log_warn()  { _log_raw "WARN  $*"; printf '  %b[WARN]%b   %s\n' "$YELLOW" "$NC" "$*"; }
log_error() { _log_raw "ERROR $*"; printf '  %b[ERROR]%b  %s\n' "$RED" "$NC" "$*" >&2; }
log_step()  { _log_raw "STEP  $*"; printf '\n  %b%b▶ %s%b\n' "$BOLD" "$BLUE" "$*" "$NC"; }
log_debug() { [[ "${DEBUG:-0}" == "1" ]] && printf '  %b[DEBUG] %s%b\n' "$DIM" "$*" "$NC"; _log_raw "DEBUG $*"; }

on_error() {
    local exit_code=$?
    local line_no=$1
    log_error "Error on line ${line_no} (exit=${exit_code}). Check log: ${LOG_FILE}"
}
trap 'on_error $LINENO' ERR

retry() {
    local n=1
    local max=5
    local delay=3
    until "$@"; do
        if [ "$n" -ge "$max" ]; then
            return 1
        fi
        sleep "$delay"
        n=$((n+1))
        delay=$((delay*2))
    done
}

show_banner() {
    clear 2>/dev/null || true
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
    printf '  %bPterodactyl All-in-One Installer v%s%b %b— Credits: @NortexZ%b\n' "$BOLD" "$SCRIPT_VERSION" "$NC" "$CYAN" "$NC"
    printf '  %b━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n\n' "$BLUE" "$NC"
}

check_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        log_error "Script must be run as root!"
        printf '  %bRun with:%b %bsudo bash %s%b\n' "$YELLOW" "$NC" "$BOLD" "$0" "$NC"
        exit 1
    fi
}

detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot read /etc/os-release. Unsupported OS."
        exit 1
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VER="${VERSION_ID:-unknown}"
    OS_CODENAME="${VERSION_CODENAME:-}"
    case "$OS_ID" in
        ubuntu|debian|raspbian|linuxmint|pop)
            OS_FAMILY="debian"
            ;;
        almalinux|rocky|centos|rhel|fedora)
            OS_FAMILY="rhel"
            ;;
        *)
            if [[ "${ID_LIKE:-}" == *debian* ]]; then
                OS_FAMILY="debian"
            elif [[ "${ID_LIKE:-}" == *rhel* || "${ID_LIKE:-}" == *fedora* ]]; then
                OS_FAMILY="rhel"
            else
                log_error "Unsupported OS: $OS_ID $OS_VER"
                exit 1
            fi
            ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *)
            log_error "Unsupported CPU architecture: $(uname -m)"
            exit 1
            ;;
    esac
    log_ok "OS detected: ${OS_ID} ${OS_VER} (${OS_FAMILY}, ${ARCH})"
}

check_internet() {
    local ok=0
    for host in 1.1.1.1 8.8.8.8 9.9.9.9; do
        if ping -c 1 -W 3 "$host" >/dev/null 2>&1; then ok=1; break; fi
    done
    if [[ $ok -eq 0 ]]; then
        if command -v curl >/dev/null 2>&1; then
            if curl -fsS --max-time 5 https://1.1.1.1 >/dev/null 2>&1; then ok=1; fi
        fi
    fi
    if [[ $ok -eq 0 ]]; then
        log_error "No internet connection!"
        exit 1
    fi
    log_ok "Internet connection OK"
}

check_disk_space() {
    local need_mb="${1:-3000}"
    local avail_mb
    avail_mb=$(df -Pm / | awk 'NR==2 {print $4}')
    if [[ -z "$avail_mb" || "$avail_mb" -lt "$need_mb" ]]; then
        log_warn "Disk root < ${need_mb}MB free (avail=${avail_mb:-?}MB)."
    else
        log_ok "Disk root available: ${avail_mb}MB"
    fi
}

check_ram() {
    local need_mb="${1:-1024}"
    local total_mb
    total_mb=$(free -m | awk '/^Mem:/ {print $2}')
    if [[ -z "$total_mb" || "$total_mb" -lt "$need_mb" ]]; then
        log_warn "RAM total < ${need_mb}MB (total=${total_mb:-?}MB)."
    else
        log_ok "RAM total: ${total_mb}MB"
    fi
}

get_local_ip() {
    local IP=""
    IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    [[ -z "$IP" ]] && IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$IP" ]] && IP="127.0.0.1"
    echo "$IP"
}

is_local_target() {
    local TARGET="$1"
    [[ -z "$TARGET" || "$TARGET" == "-" ]] && return 0
    [[ "$TARGET" == "127.0.0.1" || "$TARGET" == "localhost" ]] && return 0
    local LOCAL_IP
    LOCAL_IP=$(get_local_ip)
    [[ "$TARGET" == "$LOCAL_IP" ]] && return 0
    if ip -4 addr show 2>/dev/null | grep -Eq "inet ${TARGET//./\\.}/"; then
        return 0
    fi
    return 1
}

validate_ip() {
    local ip="$1"
    [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    local IFS_OLD=$IFS; IFS='.'
    local -a oct=($ip)
    IFS=$IFS_OLD
    for o in "${oct[@]}"; do
        (( o >= 0 && o <= 255 )) || return 1
    done
    return 0
}

validate_domain() {
    [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

validate_email() {
    [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

gen_password() {
    local len="${1:-24}"
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len"
}

confirm() {
    local PROMPT="$1"
    local DEFAULT="${2:-n}"
    local ANS
    if [[ "${ASSUME_YES:-0}" == "1" ]]; then
        return 0
    fi
    if [[ "$DEFAULT" == "y" ]]; then
        printf '  %b%s [Y/n]: %b' "$YELLOW" "$PROMPT" "$NC"
    else
        printf '  %b%s [y/N]: %b' "$YELLOW" "$PROMPT" "$NC"
    fi
    read -r ANS || ANS=""
    ANS=${ANS:-$DEFAULT}
    [[ "$ANS" =~ ^[Yy]$ ]]
}

ensure_sshpass() {
    if ! command -v sshpass >/dev/null 2>&1; then
        log_info "Installing sshpass for remote connection..."
        if [[ "$OS_FAMILY" == "debian" ]]; then
            DEBIAN_FRONTEND=noninteractive apt-get update -qq >>"$LOG_FILE" 2>&1 || true
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sshpass >>"$LOG_FILE" 2>&1 || true
        else
            (yum install -y -q sshpass >>"$LOG_FILE" 2>&1 || dnf install -y -q sshpass >>"$LOG_FILE" 2>&1) || true
        fi
    fi
}

exec_cmd() {
    local IP="$1"
    local PW="$2"
    local CMD="$3"
    if is_local_target "$IP"; then
        bash -c "$CMD"
        return $?
    fi
    ensure_sshpass
    if ! command -v sshpass >/dev/null 2>&1; then
        log_error "sshpass not available, cannot connect remotely."
        return 127
    fi
    sshpass -p "$PW" ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ConnectTimeout=20 \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=4 \
        "root@$IP" "bash -s" <<REMOTE_EOF
$CMD
REMOTE_EOF
    return $?
}

pkg_update() {
    if [[ "$OS_FAMILY" == "debian" ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >>"$LOG_FILE" 2>&1 || true
    else
        (yum makecache -q >>"$LOG_FILE" 2>&1 || dnf makecache -q >>"$LOG_FILE" 2>&1) || true
    fi
}

pkg_install() {
    if [[ "$OS_FAMILY" == "debian" ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" \
            "$@"
    else
        (yum install -y -q "$@" >>"$LOG_FILE" 2>&1 || dnf install -y -q "$@" >>"$LOG_FILE" 2>&1) || true
    fi
}

install_wings() {
    local IP="${1:-}"
    local PW="${2:--}"
    local TOKEN_CMD="${3:-}"

    if [[ -z "$IP" ]]; then
        echo "Format: bash $0 wings <ip> <pwvps> [token]"
        exit 1
    fi
    [[ -z "$PW" ]] && PW="-"

    show_banner
    log_step "🚀 Install Wings Pterodactyl"

    local WINGS_ARCH="amd64"
    [[ "$ARCH" == "arm64" ]] && WINGS_ARCH="arm64"

    local TOKEN_CMD_B64=""
    if [[ -n "$TOKEN_CMD" ]]; then
        TOKEN_CMD_B64=$(printf '%s' "$TOKEN_CMD" | base64 -w0)
    fi

    exec_cmd "$IP" "$PW" "
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if ! command -v curl >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates
fi

if ! command -v docker >/dev/null 2>&1; then
    echo '[INFO] Installing Docker...'
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
fi

systemctl enable --now docker

mkdir -p /etc/pterodactyl

curl -fL --retry 5 --retry-delay 5 \
    -o /usr/local/bin/wings \
    'https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${WINGS_ARCH}'

chmod +x /usr/local/bin/wings

cat > /etc/systemd/system/wings.service <<'SVC_EOF'
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
systemctl enable wings

TOKEN_B64='${TOKEN_CMD_B64}'
if [ -n \"\$TOKEN_B64\" ]; then
    echo '[INFO] Running panel token command...'
    cd /etc/pterodactyl
    DECODED=\$(echo \"\$TOKEN_B64\" | base64 -d)
    bash -c \"\$DECODED\" || echo '[WARN] Token command failed'
else
    echo '[WARN] Token not provided'
    echo 'Get from: Panel → Node → Configuration → Auto Deploy'
fi

if [ -f /etc/pterodactyl/config.yml ]; then
    systemctl restart wings || systemctl start wings || true
    sleep 2
    systemctl status wings --no-pager | head -n 15 || true
else
    echo '[INFO] Wings config not yet present, service will start after configure.'
fi
" || { log_error "Wings installation failed!"; exit 1; }

    log_ok "Wings installed."
}

install_official() {
    show_banner
    log_step "🚀 Install Pterodactyl via Official Installer"
    log_warn "This runs a third-party script. Make sure you trust the source."
    if ! confirm "Continue official installation?" "n"; then
        log_warn "Installation cancelled."
        exit 0
    fi
    bash <(curl -fsSL https://pterodactyl-installer.se) || { log_error "Official installation failed!"; exit 1; }
    log_ok "Official installation finished."
}

install_ssl() {
    local IP="${1:-}"
    local PW="${2:--}"
    local DOMAIN="${3:-}"
    local EMAIL="${4:-}"

    if [[ -z "$IP" || -z "$DOMAIN" || -z "$EMAIL" ]]; then
        log_error "Missing parameters!"
        printf '  %bFormat:%b bash %s ssl <ip> <pwvps> <domain> <email>\n' "$YELLOW" "$NC" "$0"
        exit 1
    fi
    validate_ip "$IP" || { log_error "Invalid IP: $IP"; exit 1; }
    validate_domain "$DOMAIN" || { log_error "Invalid domain: $DOMAIN"; exit 1; }
    validate_email "$EMAIL" || { log_error "Invalid email: $EMAIL"; exit 1; }
    [[ -z "$PW" ]] && PW="-"

    show_banner
    log_step "🔒 Install SSL Let's Encrypt (Standalone)"
    log_info "Target IP : $IP"
    log_info "Domain    : $DOMAIN"
    log_info "Email     : $EMAIL"

    if ! confirm "Continue SSL installation?" "y"; then
        log_warn "Cancelled."
        exit 0
    fi

    local OS_FAMILY_REMOTE="$OS_FAMILY"

    exec_cmd "$IP" "$PW" "
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

if [ '${OS_FAMILY_REMOTE}' = 'debian' ]; then
    apt-get update -qq
    apt-get install -y -qq certbot
elif [ '${OS_FAMILY_REMOTE}' = 'rhel' ]; then
    (yum install -y -q epel-release || dnf install -y -q epel-release) || true
    (yum install -y -q certbot || dnf install -y -q certbot) || true
fi

NGINX_WAS_RUNNING=0
APACHE_WAS_RUNNING=0
if systemctl is-active --quiet nginx 2>/dev/null; then
    NGINX_WAS_RUNNING=1
    systemctl stop nginx || true
fi
if systemctl is-active --quiet apache2 2>/dev/null; then
    APACHE_WAS_RUNNING=1
    systemctl stop apache2 || true
fi

certbot certonly --standalone --non-interactive --agree-tos \
    -m '${EMAIL}' -d '${DOMAIN}' || {
    echo '[ERROR] Certbot failed to obtain certificate.'
    [ \"\$NGINX_WAS_RUNNING\" = 1 ] && systemctl start nginx || true
    [ \"\$APACHE_WAS_RUNNING\" = 1 ] && systemctl start apache2 || true
    exit 1
}

[ \"\$NGINX_WAS_RUNNING\" = 1 ] && systemctl start nginx || true
[ \"\$APACHE_WAS_RUNNING\" = 1 ] && systemctl start apache2 || true

CRON_TMP=\$(mktemp)
(crontab -l 2>/dev/null | grep -v 'certbot renew' || true) > \"\$CRON_TMP\"
echo '0 3 * * * certbot renew --quiet --post-hook \"systemctl reload nginx 2>/dev/null || systemctl reload apache2 2>/dev/null || true\"' >> \"\$CRON_TMP\"
crontab \"\$CRON_TMP\"
rm -f \"\$CRON_TMP\"

echo '[OK] SSL installed and auto-renew configured.'
" || { log_error "SSL installation failed!"; exit 1; }

    log_ok "SSL finished."
}

hackback_panel() {
    local IP="${1:-}"
    local PW="${2:--}"
    local NEW_EMAIL="${3:-admin@localhost.local}"
    local NEW_PASS="${4:-}"
    [[ -z "$NEW_PASS" ]] && NEW_PASS="$(gen_password 14)"

    if [[ -z "$IP" ]]; then
        log_error "Format: bash $0 hackback-panel <ip> <pwvps> [new_email] [new_password]"
        exit 1
    fi
    [[ -z "$PW" ]] && PW="-"

    show_banner
    log_step "🔧 HACKBACK PANEL — Reset admin user"
    log_info "Target IP        : $IP"
    log_info "New admin email  : $NEW_EMAIL"
    log_info "New password     : $NEW_PASS"

    if ! confirm "Continue panel hackback?" "n"; then
        log_warn "Cancelled."
        exit 0
    fi

    exec_cmd "$IP" "$PW" "
set -uo pipefail
TS=\$(date +%Y%m%d-%H%M%S)
mkdir -p '${BACKUP_DIR}'

if [ -d '${PANEL_DIR}' ]; then
    if [ -f '${PANEL_DIR}/.env' ]; then
        cp '${PANEL_DIR}/.env' '${BACKUP_DIR}/panel.env.'\${TS}'.bak'
        echo '[INFO] .env backup saved.'
    fi
    if command -v mysqldump >/dev/null 2>&1; then
        mysqldump -u root panel > '${BACKUP_DIR}/panel-db.'\${TS}'.sql' 2>/dev/null || true
        echo '[INFO] Database backup saved.'
    else
        echo '[WARN] mysqldump not found, skipping DB backup.'
    fi
else
    echo '[WARN] Panel directory not found, skipping backup.'
    exit 1
fi

cd '${PANEL_DIR}' || exit 1

php artisan p:user:make \
    --email='${NEW_EMAIL}' \
    --username='admin' \
    --name-first='Admin' \
    --name-last='NortexZ' \
    --password='${NEW_PASS}' \
    --admin=1 \
    --no-interaction || { echo '[ERROR] Failed to create/reset admin user.'; exit 1; }

php artisan cache:clear || true
php artisan config:clear || true
php artisan view:clear || true

echo '[OK] Admin user reset.'
" || { log_error "Panel hackback failed!"; exit 1; }

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

hackback_wings() {
    local IP="${1:-}"
    local PW="${2:--}"
    local NEW_TOKEN="${3:-}"

    if [[ -z "$IP" ]]; then
        log_error "Format: bash $0 hackback-wings <ip> <pwvps> [token_curl_command]"
        exit 1
    fi
    [[ -z "$PW" ]] && PW="-"

    show_banner
    log_step "🔧 HACKBACK WINGS — Reset Wings configuration"
    log_info "Target IP : $IP"

    if ! confirm "Continue wings hackback?" "n"; then
        log_warn "Cancelled."
        exit 0
    fi

    exec_cmd "$IP" "$PW" "
set -uo pipefail
TS=\$(date +%Y%m%d-%H%M%S)
mkdir -p '${BACKUP_DIR}'
systemctl stop wings 2>/dev/null || true
if [ -d '${WINGS_DIR}' ] && [ -f '${WINGS_DIR}/config.yml' ]; then
    cp '${WINGS_DIR}/config.yml' '${BACKUP_DIR}/wings-config.'\${TS}'.yml.bak'
    echo '[INFO] config.yml backup saved.'
fi
mkdir -p '${WINGS_DIR}'
" || log_warn "Partial backup."

    if [[ -n "$NEW_TOKEN" ]]; then
        log_info "Running auto-deploy token..."
        local TOKEN_B64
        TOKEN_B64=$(printf '%s' "$NEW_TOKEN" | base64 -w0)
        exec_cmd "$IP" "$PW" "
set -uo pipefail
cd '${WINGS_DIR}'
DECODED=\$(echo '${TOKEN_B64}' | base64 -d)
bash -c \"\$DECODED\"
" || log_error "Auto-deploy token failed."
    else
        log_warn "Token not provided — copy auto-deploy command from panel."
        printf '  %bHow: Panel → Admin → Nodes → select node → Configuration tab → Generate Token%b\n' "$YELLOW" "$NC"
    fi

    exec_cmd "$IP" "$PW" "
systemctl daemon-reload
systemctl enable wings 2>/dev/null || true
systemctl restart wings 2>/dev/null || systemctl start wings 2>/dev/null || true
sleep 2
systemctl status wings --no-pager 2>&1 | head -n 12 || true
" || log_warn "Wings restart issue."

    printf '\n  %b%b✅  WINGS HACKBACK DONE!%b\n' "$GREEN" "$BOLD" "$NC"
    printf '  %bℹ️  Check log: journalctl -u wings -f%b\n\n' "$CYAN" "$NC"
}

setup_php_repo_remote() {
cat <<'PHPREPO_EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

. /etc/os-release

apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release apt-transport-https

case "$ID" in
  ubuntu)
    apt-get install -y software-properties-common
    LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
    ;;
  debian|raspbian)
    mkdir -p /usr/share/keyrings
    curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/sury-php.gpg
    chmod 644 /usr/share/keyrings/sury-php.gpg
    CODENAME=$(lsb_release -sc 2>/dev/null || echo bookworm)
    echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ ${CODENAME} main" \
      > /etc/apt/sources.list.d/sury-php.list
    ;;
esac

apt-get update -y
PHPREPO_EOF
}

install_panel() {
    local IP="${1:-}"
    local PW="${2:-}"
    local DOMAIN="${3:-}"
    local NODE_DOMAIN="${4:-}"
    local RAM="${5:-2048}"
    local USE_SSL="${6:-no}"

    if [[ -z "$IP" || -z "$DOMAIN" ]]; then
        log_error "Missing parameters!"
        echo "Format: bash $0 panel <ip> <pwvps> <domain> <nodedomain> <ram> [ssl]"
        exit 1
    fi

    validate_ip "$IP" || { log_error "Invalid IP: $IP"; exit 1; }
    validate_domain "$DOMAIN" || { log_error "Invalid domain: $DOMAIN"; exit 1; }

    PW="${PW:-}"
    [[ -z "$PW" ]] && PW="-"

    NODE_DOMAIN="${NODE_DOMAIN:-$DOMAIN}"
    if ! validate_domain "$NODE_DOMAIN"; then
        log_warn "NODE_DOMAIN invalid, falling back to DOMAIN."
        NODE_DOMAIN="$DOMAIN"
    fi

    if ! [[ "$RAM" =~ ^[0-9]+$ ]]; then
        log_warn "RAM not numeric, fallback to 2048."
        RAM=2048
    fi

    USE_SSL=$(echo "$USE_SSL" | tr '[:upper:]' '[:lower:]')

    DOMAIN="$(echo "$DOMAIN" | tr -d '[:space:]')"
    local ADMIN_EMAIL="${ADMIN_EMAIL:-admin@${DOMAIN}}"
    ADMIN_EMAIL="$(echo "$ADMIN_EMAIL" | tr -d '[:space:]')"
    if ! validate_email "$ADMIN_EMAIL"; then
        ADMIN_EMAIL="admin@${DOMAIN}"
    fi

    local ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
    local DB_PASSWORD="${DB_PASSWORD:-}"
    [[ -z "$ADMIN_PASSWORD" ]] && ADMIN_PASSWORD="$(gen_password 18)"
    [[ -z "$DB_PASSWORD" ]] && DB_PASSWORD="$(gen_password 24)"

    local APP_URL
    if [[ "$USE_SSL" == "yes" ]]; then
        APP_URL="https://${DOMAIN}"
    else
        APP_URL="http://${DOMAIN}"
    fi

    log_step "Step 1/9 — System bootstrap"

    exec_cmd "$IP" "$PW" "
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

dpkg --configure -a || true
apt-get -f install -y || true

apt-get clean || true
rm -rf /var/lib/apt/lists/* || true

apt-get update -y

apt-get upgrade -y --allow-downgrades --allow-change-held-packages || true

apt-get install -y \
    curl wget git unzip tar sudo cron jq openssl \
    software-properties-common ca-certificates gnupg lsb-release apt-transport-https \
    dnsutils netcat-openbsd ufw

apt-get install -y mariadb-server mariadb-client

systemctl enable mariadb
systemctl start mariadb
" || { log_error "Step 1 failed!"; exit 1; }

    log_ok "Step 1 done."

    log_step "Step 2/9 — Install PHP ${PHP_VER} + extensions"

    local PHP_REPO_SCRIPT
    PHP_REPO_SCRIPT="$(setup_php_repo_remote)"
    local PHP_REPO_B64
    PHP_REPO_B64=$(printf '%s' "$PHP_REPO_SCRIPT" | base64 -w0)

    exec_cmd "$IP" "$PW" "
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

echo '${PHP_REPO_B64}' | base64 -d | bash

retry_local() {
    local n=1; local max=5; local delay=5
    until \"\$@\"; do
        [ \"\$n\" -ge \"\$max\" ] && return 1
        sleep \"\$delay\"
        n=\$((n+1))
        delay=\$((delay*2))
    done
}

retry_local apt-get install -y -qq \
    php${PHP_VER} php${PHP_VER}-cli php${PHP_VER}-gd php${PHP_VER}-mysql \
    php${PHP_VER}-pdo php${PHP_VER}-mbstring php${PHP_VER}-tokenizer \
    php${PHP_VER}-bcmath php${PHP_VER}-xml php${PHP_VER}-fpm \
    php${PHP_VER}-curl php${PHP_VER}-zip php${PHP_VER}-intl php${PHP_VER}-readline \
    php${PHP_VER}-sqlite3

systemctl enable --now php${PHP_VER}-fpm
" || { log_error "Step 2 failed!"; exit 1; }

    log_ok "PHP ${PHP_VER} installed."

    log_step "Step 3/9 — Configure MariaDB & create database"
    exec_cmd "$IP" "$PW" "
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
systemctl enable mariadb
systemctl start mariadb

for i in 1 2 3 4 5 6 7 8 9 10; do
    if mysqladmin ping -u root --silent 2>/dev/null; then break; fi
    sleep 2
done

mysql -u root <<SQL
CREATE USER IF NOT EXISTS 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${DB_PASSWORD}';
CREATE DATABASE IF NOT EXISTS panel CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
" || { log_error "Step 3 failed!"; exit 1; }
    log_ok "MariaDB & database OK."

    log_step "Step 4/9 — Install Redis & Composer"
    exec_cmd "$IP" "$PW" "
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq redis-server
systemctl enable --now redis-server

if ! command -v composer >/dev/null 2>&1; then
    EXPECTED_SIG=\$(curl -fsSL https://composer.github.io/installer.sig)
    php -r \"copy('https://getcomposer.org/installer','/tmp/composer-setup.php');\"
    ACTUAL_SIG=\$(php -r \"echo hash_file('sha384','/tmp/composer-setup.php');\")
    if [ \"\$EXPECTED_SIG\" != \"\$ACTUAL_SIG\" ]; then
        echo '[ERROR] Composer installer checksum mismatch.'
        rm -f /tmp/composer-setup.php
        exit 1
    fi
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
    rm -f /tmp/composer-setup.php
fi
composer --version || true
" || { log_error "Step 4 failed!"; exit 1; }
    log_ok "Redis & Composer OK."

    log_step "Step 5/9 — Download & extract Pterodactyl Panel"

    exec_cmd "$IP" "$PW" "
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

retry_local() {
    local max_attempts=5
    local delay=5
    local attempt=1
    until \"\$@\"; do
        if [ \"\$attempt\" -ge \"\$max_attempts\" ]; then
            echo \"[RETRY] Command failed after \$max_attempts attempts: \$*\" >&2
            return 1
        fi
        echo \"[RETRY] Attempt \$attempt failed. Retrying in \${delay}s...\" >&2
        sleep \"\$delay\"
        attempt=\$((attempt + 1))
        delay=\$((delay * 2))
    done
}

mkdir -p '${PANEL_DIR}'
cd '${PANEL_DIR}'

retry_local curl -fsSL --retry 3 --retry-delay 5 \
    -o panel.tar.gz \
    https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz

if [ ! -s panel.tar.gz ]; then
    echo '[ERROR] panel.tar.gz empty or download failed!' >&2
    exit 1
fi

tar -xzf panel.tar.gz
rm -f panel.tar.gz

chmod -R 755 storage bootstrap/cache 2>/dev/null || true
chown -R www-data:www-data '${PANEL_DIR}' 2>/dev/null || true

if [ ! -f .env ]; then
    if [ -f .env.example ]; then
        cp .env.example .env
        echo '[INFO] .env created from .env.example'
    else
        echo '[ERROR] .env.example not found!' >&2
        exit 1
    fi
fi

REQUIRED_EXTENSIONS='curl pdo pdo_mysql mbstring xml bcmath zip'
MISSING=''
for ext in \$REQUIRED_EXTENSIONS; do
    if ! php -m 2>/dev/null | grep -qi \"^\${ext}\$\"; then
        MISSING=\"\$MISSING \$ext\"
    fi
done
if [ -n \"\$MISSING\" ]; then
    echo \"[ERROR] PHP extensions missing:\$MISSING\" >&2
    exit 1
fi

if ! command -v composer >/dev/null 2>&1; then
    echo '[ERROR] Composer not found!' >&2
    exit 1
fi

COMPOSER_ALLOW_SUPERUSER=1 retry_local composer install \
    --no-dev \
    --optimize-autoloader \
    --no-interaction \
    --no-progress

if ! grep -q '^APP_KEY=base64:' .env 2>/dev/null; then
    php artisan key:generate --force
    echo '[INFO] APP_KEY generated.'
else
    echo '[INFO] APP_KEY already set, skipping.'
fi

echo '[OK] Panel downloaded and configured.'
" || { log_error "Step 5 failed!"; exit 1; }

    log_ok "Panel downloaded."

    log_step "Step 6/9 — Configure environment & admin user"

    exec_cmd "$IP" "$PW" "
set -uo pipefail
cd '${PANEL_DIR}'

php artisan p:environment:setup \
    --author='${ADMIN_EMAIL}' \
    --url='${APP_URL}' \
    --timezone='${TIMEZONE}' \
    --cache=redis \
    --session=redis \
    --queue=redis \
    --redis-host=127.0.0.1 \
    --redis-pass= \
    --redis-port=6379 \
    --settings-ui=true \
    --no-interaction

php artisan p:environment:database \
    --host=127.0.0.1 \
    --port=3306 \
    --database=panel \
    --username=pterodactyl \
    --password='${DB_PASSWORD}' \
    --no-interaction

php artisan migrate --seed --force

php artisan p:user:make \
    --email='${ADMIN_EMAIL}' \
    --username=admin \
    --name-first=Admin \
    --name-last=User \
    --password='${ADMIN_PASSWORD}' \
    --admin=1 \
    --no-interaction || true

chown -R www-data:www-data '${PANEL_DIR}'
" || { log_error "Step 6 failed!"; exit 1; }

    log_ok "Environment & admin user configured."

    log_step "Step 7/9 — Nginx"

    exec_cmd "$IP" "$PW" "
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get install -y -qq nginx

rm -f /etc/nginx/sites-enabled/default

cat > /etc/nginx/sites-available/pterodactyl.conf <<'NGINX_EOF'
server {
    listen 80;
    server_name ${DOMAIN};

    root ${PANEL_DIR}/public;
    index index.php;

    client_max_body_size 100m;

    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options SAMEORIGIN;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht {
        deny all;
    }
}
NGINX_EOF

ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf

if ! nginx -t; then
    echo '[ERROR] nginx config invalid'
    cat /etc/nginx/sites-available/pterodactyl.conf
    exit 1
fi

systemctl enable nginx
systemctl restart nginx

if ! systemctl is-active --quiet nginx; then
    echo '[ERROR] nginx failed to start'
    systemctl status nginx --no-pager
    exit 1
fi

systemctl restart php${PHP_VER}-fpm
if ! systemctl is-active --quiet php${PHP_VER}-fpm; then
    echo '[ERROR] php-fpm failed to start'
    systemctl status php${PHP_VER}-fpm --no-pager
    exit 1
fi
" || { log_error "Step 7 (Nginx) failed!"; exit 1; }

    log_ok "Nginx & PHP-FPM OK."

    if [[ "$USE_SSL" == "yes" ]]; then
        log_step "Step 8/9 — SSL Let's Encrypt"

        exec_cmd "$IP" "$PW" "
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y -qq certbot python3-certbot-nginx

if ! nginx -t; then
    echo '[FATAL] nginx config invalid before SSL step'
    systemctl status nginx --no-pager || true
    exit 1
fi

systemctl reload nginx || systemctl restart nginx || true

CERTBOT_LOG=\$(mktemp)

if ! certbot --nginx \
    --non-interactive \
    --agree-tos \
    --redirect \
    -m '${ADMIN_EMAIL}' \
    -d '${DOMAIN}' 2>&1 | tee \"\$CERTBOT_LOG\"; then
    echo '[ERROR] CERTBOT FAILED'
    cat \"\$CERTBOT_LOG\"
    echo '[DIAG] Possible causes:'
    echo '  1. DNS not pointing to VPS'
    echo '  2. Port 80/443 blocked'
    echo '  3. Cloudflare proxy misconfig'
    rm -f \"\$CERTBOT_LOG\"
    exit 1
fi
rm -f \"\$CERTBOT_LOG\"

CRON_TMP=\$(mktemp)
(crontab -l 2>/dev/null | grep -v 'certbot renew' || true) > \"\$CRON_TMP\"
echo '0 3 * * * certbot renew --quiet --post-hook \"systemctl reload nginx\"' >> \"\$CRON_TMP\"
crontab \"\$CRON_TMP\"
rm -f \"\$CRON_TMP\"

sleep 3
HTTP_CODE=\$(curl -k -o /dev/null -s -w '%{http_code}' --max-time 10 https://${DOMAIN} || echo 000)
echo \"[INFO] HTTPS response code: \$HTTP_CODE\"
" || { log_error "Step 8 (SSL) failed!"; exit 1; }

        log_ok "SSL Let's Encrypt installed."
    else
        log_step "Step 8/9 — SSL skipped (HTTP only)"
        log_ok "Skipped."
    fi

log_step "Step 9/9 — Cron, Queue Worker, Firewall"

local PTEROQ_SVC
PTEROQ_SVC=$(cat <<EOF
[Unit]
Description=Pterodactyl Queue Worker
After=network.target redis-server.service mariadb.service
Wants=redis-server.service

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

local PTEROQ_FILE="/etc/systemd/system/pteroq.service"

exec_cmd "$IP" "$PW" "
set -euo pipefail

echo '[INFO] Installing cron schedule...'

# safer cron replace (no temp file race issues)
( crontab -l 2>/dev/null | grep -v 'artisan schedule:run' || true; \
  echo '* * * * * /usr/bin/php ${PANEL_DIR}/artisan schedule:run >> /dev/null 2>&1' \
) | crontab -

echo '[INFO] Writing systemd service...'

cat > $PTEROQ_FILE <<'EOT'
$PTEROQ_SVC
EOT

chmod 644 $PTEROQ_FILE

systemctl daemon-reload
systemctl enable pteroq

echo '[INFO] Restarting queue worker...'
systemctl restart pteroq || systemctl start pteroq

sleep 3

if ! systemctl is-active --quiet pteroq; then
    echo '[ERROR] pteroq failed to start'
    systemctl status pteroq --no-pager -l || true
    journalctl -u pteroq -n 50 --no-pager || true
    exit 1
fi

echo '[OK] pteroq active'

echo '[INFO] Configuring firewall...'

if command -v ufw >/dev/null 2>&1; then
    ufw allow 22/tcp >/dev/null 2>&1 || true
    ufw allow 80/tcp >/dev/null 2>&1 || true
    ufw allow 443/tcp >/dev/null 2>&1 || true

    # non-interactive enable (fix stuck prompt)
    ufw --force enable >/dev/null 2>&1 || true

    ufw status verbose || true
else
    echo '[WARN] UFW not installed'
fi
" || { log_error "Step 9 failed!"; exit 1; }

log_step "Final Health Check"

exec_cmd "$IP" "$PW" "
set -euo pipefail

FAIL=0

echo '========================'
echo ' SYSTEM HEALTH CHECK'
echo '========================'

HTTP_CODE=\$(curl -o /dev/null -s -w '%{http_code}' --max-time 10 http://127.0.0.1 || echo 000)
echo \"HTTP => \$HTTP_CODE\"

if [ \"\$HTTP_CODE\" != \"200\" ] && [ \"\$HTTP_CODE\" != \"301\" ] && [ \"\$HTTP_CODE\" != \"302\" ]; then
    FAIL=1
fi

for svc in nginx php${PHP_VER}-fpm redis-server mariadb pteroq; do
    if systemctl is-active --quiet \"\$svc\" 2>/dev/null; then
        echo \"[OK] \$svc\"
    else
        echo \"[FAIL] \$svc\"
        FAIL=1
    fi
done

if [ -d /etc/letsencrypt/live/${DOMAIN} ]; then
    echo '[OK] SSL exists'
else
    echo '[INFO] SSL not installed'
fi

if [ \"\$FAIL\" -eq 0 ]; then
    echo '[SUCCESS] SYSTEM HEALTHY'
    exit 0
else
    echo '[WARNING] SYSTEM HAS ISSUES'
    exit 1
fi
" || log_warn "Health check reported issues."
}

uninstall_panel() {
    local IP="${1:-}"
    local PW="${2:--}"
    if [[ -z "$IP" ]]; then
        log_error "Format: bash $0 uninstall-panel <ip> <pwvps>"; exit 1
    fi
    [[ -z "$PW" ]] && PW="-"

    show_banner
    printf '  %b%b🗑️  UNINSTALL PANEL%b\n\n' "$RED" "$BOLD" "$NC"
    printf '  Type %bDELETE PANEL%b to confirm: ' "$BOLD" "$NC"
    read -r CONFIRM
    if [[ "$CONFIRM" != "DELETE PANEL" ]]; then
        log_warn "Cancelled."; exit 0
    fi

    exec_cmd "$IP" "$PW" "
set -uo pipefail
systemctl stop pteroq 2>/dev/null || true
systemctl disable pteroq 2>/dev/null || true
rm -f /etc/systemd/system/pteroq.service
systemctl daemon-reload

rm -f /etc/nginx/sites-enabled/pterodactyl.conf
rm -f /etc/nginx/sites-available/pterodactyl.conf
systemctl reload nginx 2>/dev/null || true

systemctl stop php${PHP_VER}-fpm 2>/dev/null || true
DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq 'php${PHP_VER}*' mariadb-server mariadb-client nginx redis-server || true
DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq || true

rm -rf '${PANEL_DIR}'

mysql -u root -e \"DROP DATABASE IF EXISTS panel;\" 2>/dev/null || true
mysql -u root -e \"DROP USER IF EXISTS 'pterodactyl'@'127.0.0.1';\" 2>/dev/null || true

CRON_TMP=\$(mktemp)
(crontab -l 2>/dev/null | grep -v 'pterodactyl/artisan' || true) > \"\$CRON_TMP\"
crontab \"\$CRON_TMP\"
rm -f \"\$CRON_TMP\"

echo 'Panel removed.'
" || log_warn "Partial uninstall."
    printf '\n  %b%b✅  Panel uninstalled!%b\n\n' "$GREEN" "$BOLD" "$NC"
}

uninstall_wings() {
    local IP="${1:-}"
    local PW="${2:--}"
    if [[ -z "$IP" ]]; then
        log_error "Format: bash $0 uninstall-wings <ip> <pwvps>"; exit 1
    fi
    [[ -z "$PW" ]] && PW="-"

    show_banner
    printf '  %b%b🗑️  UNINSTALL WINGS%b\n\n' "$RED" "$BOLD" "$NC"
    printf '  Type %bDELETE WINGS%b to confirm: ' "$BOLD" "$NC"
    read -r CONFIRM
    if [[ "$CONFIRM" != "DELETE WINGS" ]]; then
        log_warn "Cancelled."; exit 0
    fi

    exec_cmd "$IP" "$PW" "
set -uo pipefail
systemctl stop wings 2>/dev/null || true
systemctl disable wings 2>/dev/null || true
docker ps -a --filter 'name=pterodactyl' -q 2>/dev/null | xargs -r docker rm -f 2>/dev/null || true
rm -f /usr/local/bin/wings
rm -rf '${WINGS_DIR}'
rm -f /etc/systemd/system/wings.service
systemctl daemon-reload

REMAINING=\$(docker ps -a -q 2>/dev/null | wc -l)
if [ \"\$REMAINING\" -eq 0 ]; then
    echo '[INFO] No remaining Docker containers, removing Docker.'
    DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq docker-ce docker-ce-cli containerd.io 2>/dev/null || true
    rm -rf /var/lib/docker
else
    echo '[WARN] Other Docker containers detected, Docker not removed.'
fi

echo 'Wings removed.'
" || log_warn "Partial uninstall."
    printf '\n  %b%b✅  Wings uninstalled!%b\n\n' "$GREEN" "$BOLD" "$NC"
}

update_panel() {
    local IP="${1:-}"
    local PW="${2:--}"
    if [[ -z "$IP" ]]; then
        log_error "Format: bash $0 update-panel <ip> <pwvps>"; exit 1
    fi
    [[ -z "$PW" ]] && PW="-"

    show_banner
    log_step "♻️  Update Pterodactyl Panel"
    if ! confirm "Continue update?" "y"; then exit 0; fi

    exec_cmd "$IP" "$PW" "
set -uo pipefail
cd '${PANEL_DIR}' || { echo 'Panel not found!'; exit 1; }
TS=\$(date +%Y%m%d-%H%M%S)
mkdir -p '${BACKUP_DIR}'
cp .env '${BACKUP_DIR}/panel.env.'\${TS}'.bak' 2>/dev/null || true

if command -v mysqldump >/dev/null 2>&1; then
    mysqldump -u root panel > '${BACKUP_DIR}/panel-db.'\${TS}'.sql' 2>/dev/null || true
fi

php artisan down || true
curl -fL --retry 3 https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz | tar -xz
chmod -R 755 storage bootstrap/cache || true
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction
php artisan view:clear || true
php artisan config:clear || true
php artisan migrate --seed --force
chown -R www-data:www-data '${PANEL_DIR}'
php artisan queue:restart || true
php artisan up
" || { log_error "Update failed!"; exit 1; }
    log_ok "Panel updated."
}

check_status() {
    local IP="${1:-127.0.0.1}"
    local PW="${2:--}"
    [[ -z "$PW" ]] && PW="-"

    show_banner
    log_step "📊 Service status on $IP"
    exec_cmd "$IP" "$PW" "
echo '── Service Status ──'
for svc in nginx php${PHP_VER}-fpm php8.3-fpm php8.2-fpm php8.1-fpm mariadb mysql redis-server redis pteroq wings docker; do
    if systemctl list-unit-files 2>/dev/null | grep -q \"^\${svc}\\.service\"; then
        STATUS=\$(systemctl is-active \"\${svc}\" 2>/dev/null || echo unknown)
        printf '  %-22s : %s\n' \"\$svc\" \"\$STATUS\"
    fi
done
echo ''
echo '── Disk & RAM ──'
df -h / | tail -1 | awk '{print \"  Disk root : \"\$3\"/\"\$2\" (\"\$5\" used)\"}'
free -h | awk 'NR==2{printf \"  RAM       : %s/%s\\n\", \$3, \$2}'
echo ''
echo '── Listener Ports ──'
ss -tlnp 2>/dev/null | awk 'NR==1 || /:(80|443|3306|6379|8080|2022)/' | head -n 15
"
}

backup_panel() {
    local IP="${1:-127.0.0.1}"
    local PW="${2:--}"
    [[ -z "$PW" ]] && PW="-"

    show_banner
    log_step "💾 Backup Panel"
    exec_cmd "$IP" "$PW" "
set -uo pipefail
TS=\$(date +%Y%m%d-%H%M%S)
mkdir -p '${BACKUP_DIR}'
cp '${PANEL_DIR}/.env' '${BACKUP_DIR}/panel.env.'\${TS}'.bak' 2>/dev/null || true

if command -v mysqldump >/dev/null 2>&1; then
    mysqldump -u root panel > '${BACKUP_DIR}/panel-db.'\${TS}'.sql' 2>/dev/null || true
fi

PARENT_DIR=\$(dirname '${PANEL_DIR}')
BASE_DIR=\$(basename '${PANEL_DIR}')
tar -czf '${BACKUP_DIR}/panel-files.'\${TS}'.tar.gz' -C \"\$PARENT_DIR\" \"\$BASE_DIR\" 2>/dev/null || true

ls -lh '${BACKUP_DIR}/'*\${TS}* 2>/dev/null || true
echo 'Backup completed.'
" || log_error "Backup failed."
    log_ok "Backup stored in ${BACKUP_DIR}"
}

restore_panel() {
    local IP="${1:-127.0.0.1}"
    local PW="${2:--}"
    local SQL_FILE="${3:-}"
    [[ -z "$PW" ]] && PW="-"

    if [[ -z "$SQL_FILE" ]]; then
        log_error "Format: bash $0 restore-panel <ip> <pw> <path-to-backup.sql>"; exit 1
    fi
    show_banner
    log_step "♻️  Restore panel database from $SQL_FILE"
    if ! confirm "Sure? this will overwrite the current 'panel' database." "n"; then exit 0; fi
    exec_cmd "$IP" "$PW" "
set -uo pipefail
if [ ! -f '${SQL_FILE}' ]; then
    echo '[ERROR] SQL file not found: ${SQL_FILE}'
    exit 1
fi
mysql -u root panel < '${SQL_FILE}' || { echo '[ERROR] Failed to restore database!'; exit 1; }
cd '${PANEL_DIR}' && php artisan migrate --force && php artisan optimize:clear
echo 'Restore completed.'
" || log_error "Restore failed."
}

repair_panel() {
    local IP="${1:-127.0.0.1}"
    local PW="${2:--}"
    [[ -z "$PW" ]] && PW="-"

    show_banner
    log_step "🛠️  Repair Panel"
    exec_cmd "$IP" "$PW" "
set -uo pipefail
cd '${PANEL_DIR}' || { echo 'Panel not found!'; exit 1; }
chown -R www-data:www-data '${PANEL_DIR}'
find '${PANEL_DIR}' -type d -exec chmod 755 {} \;
find '${PANEL_DIR}' -type f -exec chmod 644 {} \;
chmod -R 775 '${PANEL_DIR}/storage' '${PANEL_DIR}/bootstrap/cache'
chown -R www-data:www-data '${PANEL_DIR}/storage' '${PANEL_DIR}/bootstrap/cache'
php artisan optimize:clear || true
php artisan queue:restart || true
systemctl restart php${PHP_VER}-fpm 2>/dev/null || true
systemctl reload nginx 2>/dev/null || true
systemctl restart pteroq 2>/dev/null || true
echo 'Repair completed.'
" || log_warn "Partial repair."
    log_ok "Repair done."
}

prompt_target() {
    read -rp "  Target IP (empty = local): " M_IP
    [[ -z "$M_IP" ]] && M_IP=$(get_local_ip)
    if is_local_target "$M_IP"; then
        M_PW="-"
    else
        read -rsp "  Root password: " M_PW; echo
    fi
}

interactive_menu() {
    while true; do
        show_banner
        printf '  %bMAIN MENU%b\n\n' "$BOLD" "$NC"
        printf '  %b[1]%b  Install Panel\n' "$GREEN" "$NC"
        printf '  %b[2]%b  Install Wings\n' "$GREEN" "$NC"
        printf '  %b[3]%b  Install via Official (pterodactyl-installer.se)\n' "$GREEN" "$NC"
        printf '  %b[4]%b  Install SSL (standalone)\n' "$GREEN" "$NC"
        printf '  %b[5]%b  Hackback Panel (Reset Admin)\n' "$RED" "$NC"
        printf '  %b[6]%b  Hackback Wings\n' "$RED" "$NC"
        printf '  %b[7]%b  Update Panel\n' "$YELLOW" "$NC"
        printf '  %b[8]%b  Repair Panel\n' "$YELLOW" "$NC"
        printf '  %b[9]%b  Backup Panel\n' "$MAGENTA" "$NC"
        printf '  %b[10]%b Restore Panel\n' "$MAGENTA" "$NC"
        printf '  %b[11]%b Check Status\n' "$CYAN" "$NC"
        printf '  %b[12]%b Uninstall Panel\n' "$RED" "$NC"
        printf '  %b[13]%b Uninstall Wings\n' "$RED" "$NC"
        printf '  %b[14]%b View Installer Log\n' "$BLUE" "$NC"
        printf '  %b[0]%b  Exit\n\n' "$RED" "$NC"
        printf '  %bSelect [0-14]:%b ' "$BOLD" "$NC"
        read -r CHOICE
        case "$CHOICE" in
            1)
                prompt_target
                read -rp "  Panel domain: " M_DOMAIN
                read -rp "  Node domain (empty = same): " M_NDOMAIN
                [[ -z "$M_NDOMAIN" ]] && M_NDOMAIN="$M_DOMAIN"
                read -rp "  RAM (MB, default 2048): " M_RAM
                [[ -z "$M_RAM" ]] && M_RAM="2048"
                read -rp "  SSL? (yes/no, default no): " M_SSL
                [[ -z "$M_SSL" ]] && M_SSL="no"
                install_panel "$M_IP" "$M_PW" "$M_DOMAIN" "$M_NDOMAIN" "$M_RAM" "$M_SSL"
                ;;
            2)
                prompt_target
                read -rp "  Auto-deploy token (optional): " M_TOKEN
                install_wings "$M_IP" "$M_PW" "$M_TOKEN"
                ;;
            3) install_official ;;
            4)
                prompt_target
                read -rp "  Domain: " M_DOMAIN
                read -rp "  Email: " M_EMAIL
                install_ssl "$M_IP" "$M_PW" "$M_DOMAIN" "$M_EMAIL"
                ;;
            5)
                prompt_target
                read -rp "  New admin email [admin@localhost.local]: " M_EMAIL
                read -rp "  New password (empty=auto): " M_PASS
                hackback_panel "$M_IP" "$M_PW" "${M_EMAIL:-admin@localhost.local}" "${M_PASS:-}"
                ;;
            6)
                prompt_target
                read -rp "  Auto-deploy token (empty=manual later): " M_TOKEN
                hackback_wings "$M_IP" "$M_PW" "$M_TOKEN"
                ;;
            7) prompt_target; update_panel "$M_IP" "$M_PW" ;;
            8) prompt_target; repair_panel "$M_IP" "$M_PW" ;;
            9) prompt_target; backup_panel "$M_IP" "$M_PW" ;;
            10)
                prompt_target
                read -rp "  Path to .sql backup: " M_SQL
                restore_panel "$M_IP" "$M_PW" "$M_SQL"
                ;;
            11) prompt_target; check_status "$M_IP" "$M_PW" ;;
            12) prompt_target; uninstall_panel "$M_IP" "$M_PW" ;;
            13) prompt_target; uninstall_wings "$M_IP" "$M_PW" ;;
            14)
                if [[ -f "$LOG_FILE" ]]; then
                    less +G "$LOG_FILE" 2>/dev/null || tail -n 200 "$LOG_FILE"
                else
                    log_warn "Log not yet available"
                fi
                ;;
            0) printf '\n  %bGoodbye! 👋%b\n\n' "$GREEN" "$NC"; exit 0 ;;
            *) log_error "Invalid choice" ;;
        esac
        echo ""
        printf '  %bPress ENTER to return to menu...%b' "$YELLOW" "$NC"
        read -r _
    done
}

show_help() {
    show_banner
    cat <<HLP
  ${BOLD}USAGE${NC}
    bash $0 menu
    bash $0 panel <ip> <pw> <domain> <nodedomain> <ram> [yes|no]
    bash $0 wings <ip> <pw> [auto-deploy-cmd]
    bash $0 official
    bash $0 ssl <ip> <pw> <domain> [email]
    bash $0 hackback-panel <ip> <pw> [email] [password]
    bash $0 hackback-wings <ip> <pw> [auto-deploy-cmd]
    bash $0 update-panel <ip> <pw>
    bash $0 repair-panel <ip> <pw>
    bash $0 backup-panel <ip> <pw>
    bash $0 restore-panel <ip> <pw> <path.sql>
    bash $0 uninstall-panel <ip> <pw>
    bash $0 uninstall-wings <ip> <pw>
    bash $0 status [ip] [pw]

  ${BOLD}ENV VAR${NC}
    PHP_VER=8.3
    TIMEZONE_OVERRIDE=Asia/Jakarta
    ASSUME_YES=1
    DEBUG=1
    ADMIN_EMAIL=, ADMIN_PASSWORD=, DB_PASSWORD=

  ${BOLD}LOG${NC} : ${LOG_FILE}
  ${BOLD}BACKUP${NC} : ${BACKUP_DIR}
  ${BOLD}CRED${NC} : ${CRED_DIR}
HLP
}

main() {
    init_log "$@"
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