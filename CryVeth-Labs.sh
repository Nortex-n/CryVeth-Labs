#!/usr/bin/env bash

set -o pipefail 2>/dev/null || true

# ---------------------------------------------------------------------------
# BOOTSTRAP: ensure bash >= 4 is running this script
# ---------------------------------------------------------------------------
if [ -z "${BASH_VERSION:-}" ]; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    else
        echo "ERROR: bash not found. Install bash first." >&2
        exit 1
    fi
fi

if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: bash >= 4.0 required. Current: $BASH_VERSION" >&2
    exit 1
fi

set -uo pipefail

# ---------------------------------------------------------------------------
# CONSTANTS
# ---------------------------------------------------------------------------
readonly SCRIPT_VERSION="2.0.0"
readonly SCRIPT_NAME="CryVeth Pterodactyl Installer"
readonly PANEL_DIR="/var/www/pterodactyl"
readonly WINGS_DIR="/etc/pterodactyl"
readonly BACKUP_DIR="/root/nortex-backups"
readonly CRED_DIR="/root/nortex-credentials"
LOG_FILE="/var/log/nortex-installer.log"

PHP_VER="${PHP_VER:-8.3}"
TIMEZONE="${TIMEZONE_OVERRIDE:-Asia/Jakarta}"

# ---------------------------------------------------------------------------
# COLORS (only when stdout is a terminal)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    CYAN=$'\033[0;36m'; BLUE=$'\033[0;34m'; MAGENTA=$'\033[0;35m'
    BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BLUE=''; MAGENTA=''
    BOLD=''; DIM=''; NC=''
fi

# ---------------------------------------------------------------------------
# GLOBAL STATE
# ---------------------------------------------------------------------------
OS_ID=""
OS_VER=""
OS_CODENAME=""
OS_FAMILY=""
ARCH=""

# ---------------------------------------------------------------------------
# LOGGING
# ---------------------------------------------------------------------------
init_log() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    if ! touch "$LOG_FILE" 2>/dev/null; then
        LOG_FILE="/tmp/nortex-installer.log"
        touch "$LOG_FILE" 2>/dev/null || true
    fi
    {
        echo "================================================================"
        echo "  ${SCRIPT_NAME} v${SCRIPT_VERSION}"
        echo "  Started : $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "  PID     : $$"
        echo "  Args    : $*"
        echo "================================================================"
    } >>"$LOG_FILE" 2>&1
    mkdir -p "$BACKUP_DIR" "$CRED_DIR" 2>/dev/null || true
    chmod 700 "$BACKUP_DIR" "$CRED_DIR" 2>/dev/null || true
}

_ts()      { date '+%Y-%m-%d %H:%M:%S'; }
_log_raw() { printf '[%s] %s\n' "$(_ts)" "$*" >>"$LOG_FILE" 2>/dev/null || true; }

log_info()  { _log_raw "INFO  $*"; printf '  %b[INFO]%b   %s\n'    "$CYAN"    "$NC" "$*"; }
log_ok()    { _log_raw "OK    $*"; printf '  %b[OK]%b     %s\n'    "$GREEN"   "$NC" "$*"; }
log_warn()  { _log_raw "WARN  $*"; printf '  %b[WARN]%b   %s\n'    "$YELLOW"  "$NC" "$*"; }
log_error() { _log_raw "ERROR $*"; printf '  %b[ERROR]%b  %s\n'    "$RED"     "$NC" "$*" >&2; }
log_step()  { _log_raw "STEP  $*"; printf '\n  %b%b▶ %s%b\n'       "$BOLD"   "$BLUE" "$*" "$NC"; }
log_debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        printf '  %b[DEBUG] %s%b\n' "$DIM" "$*" "$NC"
    fi
    _log_raw "DEBUG $*"
}

# ---------------------------------------------------------------------------
# ERROR TRAP
# ---------------------------------------------------------------------------
on_error() {
    local code=$? line=${1:-?}
    log_error "Fatal error on line ${line} (exit=${code}). Log: ${LOG_FILE}"
}
trap 'on_error $LINENO' ERR

# ---------------------------------------------------------------------------
# RETRY WRAPPER  retry [max] [delay] cmd [args...]
#   default: max=5, initial_delay=3s, exponential backoff
# ---------------------------------------------------------------------------
retry() {
    local max="${1:-5}"; shift
    local delay="${1:-3}"; shift
    local n=1
    until "$@"; do
        if (( n >= max )); then
            log_error "Command failed after ${max} attempts: $*"
            return 1
        fi
        log_warn "Attempt ${n}/${max} failed. Retrying in ${delay}s…"
        sleep "$delay"
        (( n++ )) || true
        delay=$(( delay * 2 ))
    done
}

# ---------------------------------------------------------------------------
# BANNER
# ---------------------------------------------------------------------------
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
    printf '  %b%s v%s%b %b— CryVeth Labs%b\n' \
        "$BOLD" "$SCRIPT_NAME" "$SCRIPT_VERSION" "$NC" "$CYAN" "$NC"
    printf '  %b━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n\n' \
        "$BLUE" "$NC"
}

# ---------------------------------------------------------------------------
# PREFLIGHT VALIDATORS
# ---------------------------------------------------------------------------
check_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        log_error "Script must be run as root!"
        printf '  %bRun with:%b %bsudo bash %s%b\n' "$YELLOW" "$NC" "$BOLD" "$0" "$NC"
        exit 1
    fi
}

detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot read /etc/os-release — unsupported OS."
        exit 1
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VER="${VERSION_ID:-unknown}"
    OS_CODENAME="${VERSION_CODENAME:-}"

    case "$OS_ID" in
        ubuntu|debian|raspbian|linuxmint|pop) OS_FAMILY="debian" ;;
        almalinux|rocky|centos|rhel|fedora)   OS_FAMILY="rhel"   ;;
        *)
            if [[ "${ID_LIKE:-}" == *debian* ]]; then
                OS_FAMILY="debian"
            elif [[ "${ID_LIKE:-}" == *rhel* || "${ID_LIKE:-}" == *fedora* ]]; then
                OS_FAMILY="rhel"
            else
                log_error "Unsupported OS: ${OS_ID} ${OS_VER}"
                exit 1
            fi
            ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64)   ARCH="amd64" ;;
        aarch64|arm64)  ARCH="arm64" ;;
        *)
            log_error "Unsupported CPU architecture: $(uname -m)"
            exit 1
            ;;
    esac

    log_ok "OS: ${OS_ID} ${OS_VER} (${OS_FAMILY}, ${ARCH})"
}

check_internet() {
    local ok=0
    for host in 1.1.1.1 8.8.8.8 9.9.9.9; do
        if ping -c 1 -W 3 "$host" >/dev/null 2>&1; then ok=1; break; fi
    done
    if [[ $ok -eq 0 ]] && command -v curl >/dev/null 2>&1; then
        curl -fsS --max-time 5 https://1.1.1.1 >/dev/null 2>&1 && ok=1 || true
    fi
    if [[ $ok -eq 0 ]]; then
        log_error "No internet connection!"
        exit 1
    fi
    log_ok "Internet OK"
}

check_disk_space() {
    local need_mb="${1:-3000}"
    local avail_mb
    avail_mb=$(df -Pm / | awk 'NR==2 {print $4}')
    if [[ -z "${avail_mb:-}" || "$avail_mb" -lt "$need_mb" ]]; then
        log_warn "Disk < ${need_mb}MB free (avail=${avail_mb:-?}MB). Proceeding anyway."
    else
        log_ok "Disk: ${avail_mb}MB available"
    fi
}

check_ram() {
    local need_mb="${1:-1024}"
    local total_mb
    total_mb=$(free -m | awk '/^Mem:/ {print $2}')
    if [[ -z "${total_mb:-}" || "$total_mb" -lt "$need_mb" ]]; then
        log_warn "RAM < ${need_mb}MB (total=${total_mb:-?}MB). Proceeding anyway."
    else
        log_ok "RAM: ${total_mb}MB"
    fi
}

# ---------------------------------------------------------------------------
# UTILITIES
# ---------------------------------------------------------------------------
get_local_ip() {
    local ip=""
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    [[ -z "$ip" ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$ip" ]] && ip="127.0.0.1"
    printf '%s' "$ip"
}

is_local_target() {
    local t="${1:-}"
    [[ -z "$t" || "$t" == "-" || "$t" == "127.0.0.1" || "$t" == "localhost" ]] && return 0
    local lip; lip=$(get_local_ip)
    [[ "$t" == "$lip" ]] && return 0
    ip -4 addr show 2>/dev/null | grep -qE "inet ${t//./\\.}/" && return 0
    return 1
}

validate_ip() {
    local ip="$1"
    [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    local IFS_OLD=$IFS; IFS='.'
    local -a oct=($ip)
    IFS=$IFS_OLD
    local o
    for o in "${oct[@]}"; do
        (( o >= 0 && o <= 255 )) || return 1
    done
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
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len"
    echo
}

confirm() {
    local prompt="$1" default="${2:-n}" ans
    [[ "${ASSUME_YES:-0}" == "1" ]] && return 0
    if [[ "$default" == "y" ]]; then
        printf '  %b%s [Y/n]: %b' "$YELLOW" "$prompt" "$NC"
    else
        printf '  %b%s [y/N]: %b' "$YELLOW" "$prompt" "$NC"
    fi
    read -r ans || ans=""
    ans="${ans:-$default}"
    [[ "$ans" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
# SSHPASS BOOTSTRAP
# ---------------------------------------------------------------------------
ensure_sshpass() {
    command -v sshpass >/dev/null 2>&1 && return 0
    log_info "Installing sshpass…"
    if [[ "$OS_FAMILY" == "debian" ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >>"$LOG_FILE" 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sshpass >>"$LOG_FILE" 2>&1 || true
    else
        ( yum install -y -q sshpass >>"$LOG_FILE" 2>&1 \
          || dnf install -y -q sshpass >>"$LOG_FILE" 2>&1 ) || true
    fi
    if ! command -v sshpass >/dev/null 2>&1; then
        log_error "sshpass install failed."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# REMOTE EXECUTION ENGINE
#
#   exec_cmd <ip> <password> <bash_script_string>
#
#   • Local target → runs with bash -c
#   • Remote target → streams the script over SSH stdin using sshpass
#     (avoids all quoting / heredoc / escaping pitfalls)
# ---------------------------------------------------------------------------
exec_cmd() {
    local ip="$1"
    local pw="$2"
    local script="$3"

    if is_local_target "$ip"; then
        bash -c "$script"
        return $?
    fi

    ensure_sshpass || return 1

    # Write the script to a temp file and pipe it, preventing any
    # double-quoting or special-character corruption.
    local tmpf
    tmpf=$(mktemp /tmp/.nortex-remote-XXXXXX.sh)
    printf '%s\n' "$script" >"$tmpf"

    sshpass -p "$pw" ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ConnectTimeout=30 \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=6 \
        "root@${ip}" "bash -s" <"$tmpf"
    local rc=$?
    rm -f "$tmpf"
    return $rc
}

# ---------------------------------------------------------------------------
# SAFE BASE64 ENCODE  (portable: GNU + macOS + BusyBox)
# ---------------------------------------------------------------------------
b64enc() {
    if base64 --version 2>&1 | grep -q GNU; then
        printf '%s' "$1" | base64 -w0
    else
        printf '%s' "$1" | base64 | tr -d '\n'
    fi
}

# ---------------------------------------------------------------------------
# REMOTE PHP REPO SETUP SCRIPT  (returned as a string, NOT executed locally)
# ---------------------------------------------------------------------------
_php_repo_script() {
    # Returns a self-contained bash script that sets up sury/ondrej PHP repo.
    cat <<'PHPREPO'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

. /etc/os-release
apt-get update -y -qq
apt-get install -y -qq ca-certificates curl gnupg lsb-release apt-transport-https

case "${ID:-}" in
  ubuntu)
    apt-get install -y -qq software-properties-common
    LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
    ;;
  debian|raspbian)
    mkdir -p /usr/share/keyrings
    curl -fsSL https://packages.sury.org/php/apt.gpg \
        | gpg --dearmor -o /usr/share/keyrings/sury-php.gpg
    chmod 644 /usr/share/keyrings/sury-php.gpg
    CODENAME=$(lsb_release -sc 2>/dev/null || echo bookworm)
    echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ ${CODENAME} main" \
        > /etc/apt/sources.list.d/sury-php.list
    ;;
  *)
    echo "[WARN] Unknown distro '${ID:-}', skipping PHP repo setup."
    ;;
esac

apt-get update -y -qq
PHPREPO
}

# ---------------------------------------------------------------------------
# REMOTE RETRY HELPER SNIPPET  (injected into remote scripts)
# ---------------------------------------------------------------------------
_remote_retry_fn() {
    cat <<'RETRYFN'
retry_pkg() {
    local max=5 delay=5 n=1
    until "$@"; do
        [ "$n" -ge "$max" ] && { echo "[RETRY] Failed after ${max} attempts: $*" >&2; return 1; }
        echo "[RETRY] Attempt ${n}/${max} failed. Retrying in ${delay}s…" >&2
        sleep "$delay"; n=$((n+1)); delay=$((delay*2))
    done
}
RETRYFN
}

# ===========================================================================
# STEP IMPLEMENTATIONS
# ===========================================================================

# ---------------------------------------------------------------------------
# INSTALL WINGS
# ---------------------------------------------------------------------------
install_wings() {
    local ip="${1:-}"
    local pw="${2:--}"
    local token_cmd="${3:-}"

    if [[ -z "$ip" ]]; then
        log_error "Format: bash $0 wings <ip> <pw_vps> [auto_deploy_cmd]"
        exit 1
    fi
    [[ -z "$pw" ]] && pw="-"

    show_banner
    log_step "Install Wings — Pterodactyl"
    log_info "Target: $ip"

    local wings_arch="amd64"
    [[ "$ARCH" == "arm64" ]] && wings_arch="arm64"

    # Encode token command safely
    local token_b64=""
    [[ -n "$token_cmd" ]] && token_b64=$(b64enc "$token_cmd")

    exec_cmd "$ip" "$pw" "$(cat <<REMOTE
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ---- Docker ----
if ! command -v curl >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates
fi

if ! command -v docker >/dev/null 2>&1; then
    echo '[INFO] Installing Docker…'
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
fi

systemctl enable docker
systemctl start docker

for i in \$(seq 1 10); do
    docker info >/dev/null 2>&1 && break || sleep 2
done
docker info >/dev/null 2>&1 || { echo '[ERROR] Docker not healthy'; exit 1; }

# ---- Wings binary ----
mkdir -p /etc/pterodactyl

echo '[INFO] Downloading Wings binary…'
curl -fL --retry 5 --retry-delay 5 --retry-max-time 120 \
    -o /usr/local/bin/wings \
    "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${wings_arch}"

chmod +x /usr/local/bin/wings
/usr/local/bin/wings --version || { echo '[ERROR] Wings binary not executable'; exit 1; }

# ---- Systemd unit ----
cat > /etc/systemd/system/wings.service <<'SVC'
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
SVC

systemctl daemon-reload
systemctl enable wings

# ---- Auto-deploy token ----
TOKEN_B64="${token_b64}"
if [ -n "\${TOKEN_B64}" ]; then
    echo '[INFO] Running auto-deploy token…'
    cd /etc/pterodactyl
    DECODED=\$(printf '%s' "\${TOKEN_B64}" | base64 -d)
    bash -c "\${DECODED}" || echo '[WARN] Token command failed — configure manually.'
else
    echo '[WARN] No token provided — configure via: Panel → Node → Configuration → Generate Token'
fi

# ---- Start wings if config present ----
if [ -f /etc/pterodactyl/config.yml ]; then
    systemctl restart wings || systemctl start wings || true
    sleep 3
    if ! systemctl is-active --quiet wings; then
        echo '[ERROR] Wings failed to start'
        journalctl -u wings -n 30 --no-pager || true
        exit 1
    fi
    echo '[OK] Wings running'
else
    echo '[INFO] Wings config not yet present — will start after token registration.'
fi
REMOTE
)" || { log_error "Wings installation failed!"; exit 1; }

    log_ok "Wings installed successfully."
}

# ---------------------------------------------------------------------------
# INSTALL PANEL  (Steps 1–9)
# ---------------------------------------------------------------------------
install_panel() {
    local ip="${1:-}"
    local pw="${2:-}"
    local domain="${3:-}"
    local node_domain="${4:-}"
    local ram="${5:-2048}"
    local use_ssl="${6:-no}"

    # ---- Validate inputs ----
    if [[ -z "$ip" || -z "$domain" ]]; then
        log_error "Missing parameters!"
        echo "Format: bash $0 panel <ip> <pw> <domain> [nodedomain] [ram] [ssl]"
        exit 1
    fi
    validate_ip "$ip"      || { log_error "Invalid IP: ${ip}"; exit 1; }
    validate_domain "$domain" || { log_error "Invalid domain: ${domain}"; exit 1; }

    [[ -z "$pw" ]]         && pw="-"
    [[ -z "$node_domain" ]] && node_domain="$domain"
    validate_domain "$node_domain" || node_domain="$domain"
    [[ "$ram" =~ ^[0-9]+$ ]] || { log_warn "RAM not numeric, fallback 2048."; ram=2048; }

    use_ssl=$(printf '%s' "$use_ssl" | tr '[:upper:]' '[:lower:]')
    domain=$(printf '%s' "$domain" | tr -d '[:space:]')

    local admin_email="${ADMIN_EMAIL:-admin@${domain}}"
    admin_email=$(printf '%s' "$admin_email" | tr -d '[:space:]')
    validate_email "$admin_email" || admin_email="admin@${domain}"

    local admin_password="${ADMIN_PASSWORD:-}"
    local db_password="${DB_PASSWORD:-}"
    [[ -z "$admin_password" ]] && admin_password=$(gen_password 18)
    [[ -z "$db_password" ]]    && db_password=$(gen_password 24)

    local app_url
    [[ "$use_ssl" == "yes" ]] && app_url="https://${domain}" || app_url="http://${domain}"

    # ---- Pre-flight summary ----
    show_banner
    log_info "Target IP    : ${ip}"
    log_info "Domain       : ${domain}"
    log_info "App URL      : ${app_url}"
    log_info "Admin Email  : ${admin_email}"
    log_info "PHP Version  : ${PHP_VER}"
    log_info "SSL          : ${use_ssl}"

    # =========================================================================
    # STEP 1 — System bootstrap
    # =========================================================================
    log_step "Step 1/9 — System bootstrap"

    exec_cmd "$ip" "$pw" "$(cat <<REMOTE
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo '[INFO] Repairing any broken dpkg state…'
dpkg --configure -a 2>/dev/null || true
apt-get -f install -y -qq 2>/dev/null || true

echo '[INFO] Cleaning apt cache…'
apt-get clean -qq || true
rm -rf /var/lib/apt/lists/*

echo '[INFO] Updating package index…'
apt-get update -y -qq

echo '[INFO] Upgrading system packages…'
apt-get upgrade -y -qq --allow-downgrades --allow-change-held-packages || true

echo '[INFO] Installing base dependencies…'
apt-get install -y -qq \
    curl wget git unzip tar sudo cron jq openssl \
    software-properties-common ca-certificates gnupg \
    lsb-release apt-transport-https \
    dnsutils netcat-openbsd ufw

echo '[INFO] Installing MariaDB…'
apt-get install -y -qq mariadb-server mariadb-client

systemctl enable mariadb
systemctl start mariadb

echo '[INFO] Waiting for MariaDB to be ready…'
for i in \$(seq 1 15); do
    mysqladmin ping -u root --silent 2>/dev/null && break || sleep 2
done
mysqladmin ping -u root --silent 2>/dev/null \
    || { echo '[ERROR] MariaDB did not start in time'; exit 1; }

echo '[OK] Step 1 complete'
REMOTE
)" || { log_error "Step 1 failed!"; exit 1; }
    log_ok "Step 1 done."

    # =========================================================================
    # STEP 2 — PHP installation
    # =========================================================================
    log_step "Step 2/9 — Install PHP ${PHP_VER} + extensions"

    local php_repo_b64
    php_repo_b64=$(b64enc "$(_php_repo_script)")
    local remote_retry
    remote_retry=$(_remote_retry_fn)

    exec_cmd "$ip" "$pw" "$(cat <<REMOTE
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

${remote_retry}

echo '[INFO] Setting up PHP ${PHP_VER} repository…'
printf '%s' '${php_repo_b64}' | base64 -d | bash

echo '[INFO] Installing PHP ${PHP_VER} and extensions…'
retry_pkg apt-get install -y -qq \
    php${PHP_VER} php${PHP_VER}-cli php${PHP_VER}-gd php${PHP_VER}-mysql \
    php${PHP_VER}-pdo php${PHP_VER}-mbstring php${PHP_VER}-tokenizer \
    php${PHP_VER}-bcmath php${PHP_VER}-xml php${PHP_VER}-fpm \
    php${PHP_VER}-curl php${PHP_VER}-zip php${PHP_VER}-intl \
    php${PHP_VER}-readline php${PHP_VER}-sqlite3

echo '[INFO] Verifying PHP binary…'
php${PHP_VER} --version || php --version || { echo '[ERROR] PHP not found'; exit 1; }

echo '[INFO] Enabling php${PHP_VER}-fpm…'
systemctl enable php${PHP_VER}-fpm
systemctl start php${PHP_VER}-fpm

sleep 2
if ! systemctl is-active --quiet php${PHP_VER}-fpm; then
    echo '[ERROR] php${PHP_VER}-fpm failed to start'
    systemctl status php${PHP_VER}-fpm --no-pager -l || true
    exit 1
fi

# Validate FPM socket exists
FPM_SOCK="/run/php/php${PHP_VER}-fpm.sock"
for i in \$(seq 1 10); do
    [ -S "\${FPM_SOCK}" ] && break || sleep 1
done
[ -S "\${FPM_SOCK}" ] \
    || { echo "[ERROR] php-fpm socket not found: \${FPM_SOCK}"; exit 1; }

echo "[OK] PHP ${PHP_VER} installed, FPM socket: \${FPM_SOCK}"
REMOTE
)" || { log_error "Step 2 failed!"; exit 1; }
    log_ok "PHP ${PHP_VER} installed."

    # =========================================================================
    # STEP 3 — MariaDB database setup
    # =========================================================================
    log_step "Step 3/9 — Configure MariaDB & create database"

    exec_cmd "$ip" "$pw" "$(cat <<REMOTE
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

systemctl enable mariadb
systemctl start mariadb

echo '[INFO] Waiting for MariaDB…'
for i in \$(seq 1 20); do
    mysqladmin ping -u root --silent 2>/dev/null && break || sleep 2
done
mysqladmin ping -u root --silent 2>/dev/null \
    || { echo '[ERROR] MariaDB not ready'; exit 1; }

echo '[INFO] Creating database and user…'
mysql -u root <<SQL
CREATE USER IF NOT EXISTS 'pterodactyl'@'127.0.0.1'
    IDENTIFIED BY '${db_password}';
ALTER USER 'pterodactyl'@'127.0.0.1'
    IDENTIFIED BY '${db_password}';
CREATE DATABASE IF NOT EXISTS panel
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON panel.*
    TO 'pterodactyl'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL

echo '[INFO] Verifying DB connectivity…'
mysql -u pterodactyl -p'${db_password}' -h 127.0.0.1 panel -e 'SELECT 1;' >/dev/null 2>&1 \
    || { echo '[ERROR] DB connection test failed'; exit 1; }

echo '[OK] Database ready'
REMOTE
)" || { log_error "Step 3 failed!"; exit 1; }
    log_ok "MariaDB ready."

    # =========================================================================
    # STEP 4 — Redis & Composer
    # =========================================================================
    log_step "Step 4/9 — Install Redis & Composer"

    exec_cmd "$ip" "$pw" "$(cat <<REMOTE
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo '[INFO] Installing Redis…'
apt-get install -y -qq redis-server
systemctl enable redis-server
systemctl start redis-server

sleep 2
if ! systemctl is-active --quiet redis-server; then
    echo '[ERROR] Redis failed to start'
    systemctl status redis-server --no-pager || true
    exit 1
fi

echo '[INFO] Verifying Redis…'
redis-cli ping | grep -q PONG || { echo '[ERROR] Redis not responding'; exit 1; }

if ! command -v composer >/dev/null 2>&1; then
    echo '[INFO] Installing Composer…'
    EXPECTED_SIG=\$(curl -fsSL https://composer.github.io/installer.sig)
    php -r "copy('https://getcomposer.org/installer','/tmp/composer-setup.php');"
    ACTUAL_SIG=\$(php -r "echo hash_file('sha384','/tmp/composer-setup.php');")
    if [ "\${EXPECTED_SIG}" != "\${ACTUAL_SIG}" ]; then
        echo '[ERROR] Composer installer checksum mismatch!'
        rm -f /tmp/composer-setup.php
        exit 1
    fi
    php /tmp/composer-setup.php \
        --install-dir=/usr/local/bin \
        --filename=composer \
        --quiet
    rm -f /tmp/composer-setup.php
fi

composer --version || { echo '[ERROR] Composer not functional'; exit 1; }
echo '[OK] Redis + Composer ready'
REMOTE
)" || { log_error "Step 4 failed!"; exit 1; }
    log_ok "Redis & Composer ready."

    # =========================================================================
    # STEP 5 — Download & install Panel
    # =========================================================================
    log_step "Step 5/9 — Download & extract Pterodactyl Panel"

    exec_cmd "$ip" "$pw" "$(cat <<REMOTE
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

$(_remote_retry_fn)

mkdir -p '${PANEL_DIR}'
cd '${PANEL_DIR}'

echo '[INFO] Downloading panel release…'
retry_pkg curl -fsSL --retry 3 --retry-delay 5 --retry-max-time 120 \
    -o panel.tar.gz \
    https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz

[ -s panel.tar.gz ] || { echo '[ERROR] panel.tar.gz empty or download failed'; exit 1; }

echo '[INFO] Extracting…'
tar -xzf panel.tar.gz
rm -f panel.tar.gz

chmod -R 755 storage bootstrap/cache 2>/dev/null || true
chown -R www-data:www-data '${PANEL_DIR}' 2>/dev/null || true

if [ ! -f .env ]; then
    [ -f .env.example ] \
        && cp .env.example .env \
        || { echo '[ERROR] .env.example not found!'; exit 1; }
fi

echo '[INFO] Checking required PHP extensions…'
REQUIRED='curl pdo pdo_mysql mbstring xml bcmath zip'
MISSING=''
for ext in \${REQUIRED}; do
    php -m 2>/dev/null | grep -qi "^\${ext}\$" || MISSING="\${MISSING} \${ext}"
done
[ -z "\${MISSING}" ] || { echo "[ERROR] Missing PHP extensions:\${MISSING}"; exit 1; }

echo '[INFO] Running composer install…'
COMPOSER_ALLOW_SUPERUSER=1 retry_pkg composer install \
    --no-dev \
    --optimize-autoloader \
    --no-interaction \
    --no-progress

echo '[INFO] Generating APP_KEY if not set…'
if ! grep -q '^APP_KEY=base64:' .env 2>/dev/null; then
    php artisan key:generate --force
else
    echo '[INFO] APP_KEY already present, skipping.'
fi

echo '[OK] Panel downloaded and prepared'
REMOTE
)" || { log_error "Step 5 failed!"; exit 1; }
    log_ok "Panel downloaded."

    # =========================================================================
    # STEP 6 — Environment configuration & admin user
    # =========================================================================
    log_step "Step 6/9 — Configure environment & admin user"

    exec_cmd "$ip" "$pw" "$(cat <<REMOTE
set -euo pipefail
cd '${PANEL_DIR}'

echo '[INFO] Configuring environment…'
php artisan p:environment:setup \
    --author='${admin_email}' \
    --url='${app_url}' \
    --timezone='${TIMEZONE}' \
    --cache=redis \
    --session=redis \
    --queue=redis \
    --redis-host=127.0.0.1 \
    --redis-pass='' \
    --redis-port=6379 \
    --settings-ui=true \
    --no-interaction

echo '[INFO] Configuring database connection…'
php artisan p:environment:database \
    --host=127.0.0.1 \
    --port=3306 \
    --database=panel \
    --username=pterodactyl \
    --password='${db_password}' \
    --no-interaction

echo '[INFO] Running migrations…'
php artisan migrate --seed --force

echo '[INFO] Creating admin user…'
php artisan p:user:make \
    --email='${admin_email}' \
    --username=admin \
    --name-first=Admin \
    --name-last=User \
    --password='${admin_password}' \
    --admin=1 \
    --no-interaction || echo '[WARN] User may already exist — continuing'

echo '[INFO] Setting final file permissions…'
chown -R www-data:www-data '${PANEL_DIR}'
chmod -R 755 '${PANEL_DIR}/storage' '${PANEL_DIR}/bootstrap/cache'

echo '[OK] Environment configured'
REMOTE
)" || { log_error "Step 6 failed!"; exit 1; }
    log_ok "Environment & admin configured."

    # =========================================================================
    # STEP 7 — Nginx configuration  [CRITICAL — most bug-prone step]
    # =========================================================================
    log_step "Step 7/9 — Nginx"

    # Build nginx config locally so we have full shell control
    local nginx_conf
    nginx_conf=$(cat <<NGINXCONF
server {
    listen 80;
    server_name ${domain};

    root ${PANEL_DIR}/public;
    index index.php;

    client_max_body_size 100m;
    client_body_timeout 300s;

    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-XSS-Protection "1; mode=block";

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_read_timeout 300;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
NGINXCONF
)
    local nginx_conf_b64
    nginx_conf_b64=$(b64enc "$nginx_conf")

    exec_cmd "$ip" "$pw" "$(cat <<REMOTE
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo '[INFO] Installing Nginx…'
apt-get install -y -qq nginx

systemctl enable nginx

# Remove default site
rm -f /etc/nginx/sites-enabled/default

# Ensure snippets/fastcgi-php.conf is present (it ships with nginx-common)
[ -f /etc/nginx/snippets/fastcgi-php.conf ] \
    || { echo '[ERROR] fastcgi-php.conf snippet not found!'; exit 1; }

# Validate php-fpm socket is present before writing config
FPM_SOCK="/run/php/php${PHP_VER}-fpm.sock"
if [ ! -S "\${FPM_SOCK}" ]; then
    echo "[WARN] FPM socket not found, starting php${PHP_VER}-fpm…"
    systemctl start php${PHP_VER}-fpm
    for i in \$(seq 1 10); do
        [ -S "\${FPM_SOCK}" ] && break || sleep 1
    done
    [ -S "\${FPM_SOCK}" ] || { echo "[ERROR] FPM socket still missing: \${FPM_SOCK}"; exit 1; }
fi

echo '[INFO] Writing Nginx config…'
printf '%s' '${nginx_conf_b64}' | base64 -d \
    > /etc/nginx/sites-available/pterodactyl.conf

ln -sf /etc/nginx/sites-available/pterodactyl.conf \
       /etc/nginx/sites-enabled/pterodactyl.conf

echo '[INFO] Validating Nginx config…'
nginx -t 2>&1 || {
    echo '[ERROR] Nginx config test FAILED!'
    cat /etc/nginx/sites-available/pterodactyl.conf
    exit 1
}

echo '[INFO] Restarting Nginx…'
systemctl restart nginx

sleep 2
if ! systemctl is-active --quiet nginx; then
    echo '[ERROR] Nginx failed to start!'
    systemctl status nginx --no-pager -l
    journalctl -u nginx -n 50 --no-pager
    exit 1
fi

echo '[INFO] Restarting php${PHP_VER}-fpm…'
systemctl restart php${PHP_VER}-fpm
if ! systemctl is-active --quiet php${PHP_VER}-fpm; then
    echo '[ERROR] php${PHP_VER}-fpm failed!'
    systemctl status php${PHP_VER}-fpm --no-pager -l
    exit 1
fi

echo '[OK] Nginx and PHP-FPM running'
REMOTE
)" || { log_error "Step 7 (Nginx) failed!"; exit 1; }
    log_ok "Nginx & PHP-FPM running."

    # =========================================================================
    # STEP 8 — SSL (optional)
    # =========================================================================
    if [[ "$use_ssl" == "yes" ]]; then
        log_step "Step 8/9 — SSL Let's Encrypt"

        exec_cmd "$ip" "$pw" "$(cat <<REMOTE
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -y -qq
apt-get install -y -qq certbot python3-certbot-nginx

echo '[INFO] Validating Nginx before Certbot…'
nginx -t 2>&1 || { echo '[FATAL] Nginx config invalid before SSL!'; exit 1; }
systemctl reload nginx || systemctl restart nginx

CERTBOT_LOG=\$(mktemp)
if ! certbot --nginx \
        --non-interactive \
        --agree-tos \
        --redirect \
        -m '${admin_email}' \
        -d '${domain}' 2>&1 | tee "\${CERTBOT_LOG}"; then
    echo '[ERROR] Certbot FAILED!'
    cat "\${CERTBOT_LOG}"
    echo '[DIAG] Possible causes:'
    echo '  1. DNS A record not pointing to this server'
    echo '  2. Port 80 or 443 blocked by firewall/provider'
    echo '  3. Cloudflare orange-cloud proxy is enabled'
    rm -f "\${CERTBOT_LOG}"
    exit 1
fi
rm -f "\${CERTBOT_LOG}"

# Setup auto-renew cron
CRON_TMP=\$(mktemp)
( crontab -l 2>/dev/null | grep -v 'certbot renew' || true ) > "\${CRON_TMP}"
echo '0 3 * * * certbot renew --quiet --post-hook "systemctl reload nginx"' >> "\${CRON_TMP}"
crontab "\${CRON_TMP}"
rm -f "\${CRON_TMP}"

sleep 3
HTTP_CODE=\$(curl -k -o /dev/null -s -w '%{http_code}' --max-time 15 "https://${domain}" || echo 000)
echo "[INFO] HTTPS check: \${HTTP_CODE}"

echo '[OK] SSL installed'
REMOTE
)" || { log_error "Step 8 (SSL) failed!"; exit 1; }
        log_ok "SSL installed."
    else
        log_step "Step 8/9 — SSL skipped (HTTP only)"
        log_ok "Skipped."
    fi

    # =========================================================================
    # STEP 9 — Cron, Queue Worker (pteroq), Firewall
    # =========================================================================
    log_step "Step 9/9 — Cron, Queue Worker & Firewall"

    # Build systemd service locally to avoid any heredoc-inside-SSH issues
    local pteroq_svc
    pteroq_svc=$(cat <<PTEROQSVC
[Unit]
Description=Pterodactyl Queue Worker
After=network.target redis-server.service mariadb.service
Wants=redis-server.service mariadb.service

[Service]
User=www-data
Group=www-data
WorkingDirectory=${PANEL_DIR}
ExecStart=/usr/bin/php ${PANEL_DIR}/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3 --max-time=3600
Restart=always
RestartSec=5s
StartLimitInterval=180s
StartLimitBurst=30
TimeoutStopSec=60
KillSignal=SIGTERM
StandardOutput=journal
StandardError=journal
SyslogIdentifier=pteroq

[Install]
WantedBy=multi-user.target
PTEROQSVC
)
    local pteroq_b64
    pteroq_b64=$(b64enc "$pteroq_svc")

    exec_cmd "$ip" "$pw" "$(cat <<REMOTE
set -euo pipefail

echo '[INFO] Setting up cron schedule…'
CRON_TMP=\$(mktemp)
( crontab -l 2>/dev/null | grep -v 'artisan schedule:run' || true ) > "\${CRON_TMP}"
echo "* * * * * /usr/bin/php ${PANEL_DIR}/artisan schedule:run >> /dev/null 2>&1" >> "\${CRON_TMP}"
crontab "\${CRON_TMP}"
rm -f "\${CRON_TMP}"

echo '[INFO] Installing pteroq systemd service…'
printf '%s' '${pteroq_b64}' | base64 -d > /etc/systemd/system/pteroq.service

systemctl daemon-reload
systemctl enable pteroq

# Verify www-data can access panel dir
if ! runuser -u www-data -- test -r '${PANEL_DIR}/artisan'; then
    chown -R www-data:www-data '${PANEL_DIR}'
fi

echo '[INFO] Starting pteroq…'
systemctl restart pteroq 2>/dev/null || systemctl start pteroq

sleep 4

if ! systemctl is-active --quiet pteroq; then
    echo '[ERROR] pteroq failed to start!'
    systemctl status pteroq --no-pager -l
    journalctl -u pteroq -n 50 --no-pager
    exit 1
fi
echo '[OK] pteroq active'

echo '[INFO] Configuring UFW firewall…'
if command -v ufw >/dev/null 2>&1; then
    ufw allow 22/tcp  >/dev/null 2>&1 || true
    ufw allow 80/tcp  >/dev/null 2>&1 || true
    ufw allow 443/tcp >/dev/null 2>&1 || true
    ufw --force enable >/dev/null 2>&1 || true
    ufw status verbose
else
    echo '[WARN] UFW not installed — skipping firewall config'
fi

echo '[INFO] Starting cron daemon…'
systemctl enable cron 2>/dev/null || systemctl enable crond 2>/dev/null || true
systemctl start  cron 2>/dev/null || systemctl start  crond 2>/dev/null || true

echo '[OK] Step 9 complete'
REMOTE
)" || { log_error "Step 9 failed!"; exit 1; }
    log_ok "Cron, pteroq, firewall configured."

    # =========================================================================
    # FINAL HEALTH CHECK
    # =========================================================================
    log_step "Final Health Check"

    exec_cmd "$ip" "$pw" "$(cat <<REMOTE
set -uo pipefail
FAIL=0

echo '============================='
echo '  SYSTEM HEALTH CHECK'
echo '============================='

HTTP_CODE=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 http://127.0.0.1 || echo 000)
echo "HTTP response: \${HTTP_CODE}"
case "\${HTTP_CODE}" in
    200|301|302|307|308) echo '[OK] HTTP endpoint reachable' ;;
    *) echo "[WARN] HTTP returned \${HTTP_CODE}" ;;
esac

for svc in nginx php${PHP_VER}-fpm redis-server mariadb pteroq; do
    if systemctl is-active --quiet "\${svc}" 2>/dev/null; then
        echo "[OK] \${svc}"
    else
        echo "[FAIL] \${svc} is NOT running"
        systemctl status "\${svc}" --no-pager -l 2>/dev/null | tail -20 || true
        FAIL=1
    fi
done

if [ -d /etc/letsencrypt/live/${domain} ]; then
    echo '[OK] SSL certificate present'
else
    echo '[INFO] SSL certificate not installed (expected if ssl=no)'
fi

echo ''
df -h / | awk 'NR==2 {print "Disk: "$3"/"$2" used"}'
free -m | awk '/^Mem:/ {printf "RAM: %dMB used / %dMB total\n", $3, $2}'
echo ''

if [ "\${FAIL}" -eq 0 ]; then
    echo '[SUCCESS] ALL SERVICES HEALTHY'
else
    echo '[WARNING] ONE OR MORE SERVICES HAVE ISSUES — check logs above'
    exit 1
fi
REMOTE
)" || log_warn "Health check reported issues — review the log above."

    # =========================================================================
    # SAVE CREDENTIALS
    # =========================================================================
    local cred_file="${CRED_DIR}/panel-${ip}-$(date +%Y%m%d-%H%M%S).txt"
    cat >"$cred_file" <<EOF
================================================
  PTERODACTYL PANEL CREDENTIALS
  Generated : $(date)
================================================
Panel URL       : ${app_url}
Admin Email     : ${admin_email}
Admin Username  : admin
Admin Password  : ${admin_password}
DB User         : pterodactyl
DB Password     : ${db_password}
DB Name         : panel
Node Domain     : ${node_domain}
RAM Allocation  : ${ram} MB
================================================
EOF
    chmod 600 "$cred_file" 2>/dev/null || true

    printf '\n  %b━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n' "$BLUE" "$NC"
    printf '  %b%b✅  PANEL INSTALLATION COMPLETE!%b\n' "$GREEN" "$BOLD" "$NC"
    printf '  %b━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n\n' "$BLUE" "$NC"
    printf '  %b🌐 URL         :%b %s\n'  "$BOLD" "$NC" "$app_url"
    printf '  %b📧 Email       :%b %s\n'  "$BOLD" "$NC" "$admin_email"
    printf '  %b👤 Username    :%b admin\n' "$BOLD" "$NC"
    printf '  %b🔑 Password    :%b %s\n'  "$BOLD" "$NC" "$admin_password"
    printf '  %b📁 Credentials :%b %s\n\n' "$BOLD" "$NC" "$cred_file"
}

# ---------------------------------------------------------------------------
# INSTALL SSL (standalone — no panel needed)
# ---------------------------------------------------------------------------
install_ssl() {
    local ip="${1:-}"
    local pw="${2:--}"
    local domain="${3:-}"
    local email="${4:-}"

    if [[ -z "$ip" || -z "$domain" || -z "$email" ]]; then
        log_error "Missing parameters!"
        printf '  %bFormat:%b bash %s ssl <ip> <pw> <domain> <email>\n' "$YELLOW" "$NC" "$0"
        exit 1
    fi
    validate_ip     "$ip"     || { log_error "Invalid IP: ${ip}";         exit 1; }
    validate_domain "$domain" || { log_error "Invalid domain: ${domain}"; exit 1; }
    validate_email  "$email"  || { log_error "Invalid email: ${email}";   exit 1; }
    [[ -z "$pw" ]] && pw="-"

    show_banner
    log_step "Install SSL — Let's Encrypt (standalone)"
    log_info "Target: ${ip} | Domain: ${domain}"
    confirm "Continue?" "y" || { log_warn "Cancelled."; exit 0; }

    exec_cmd "$ip" "$pw" "$(cat <<REMOTE
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -y -qq
apt-get install -y -qq certbot

NGINX_WAS_UP=0; APACHE_WAS_UP=0

systemctl is-active --quiet nginx  2>/dev/null && { NGINX_WAS_UP=1;  systemctl stop nginx;  } || true
systemctl is-active --quiet apache2 2>/dev/null && { APACHE_WAS_UP=1; systemctl stop apache2; } || true

certbot certonly --standalone \
    --non-interactive --agree-tos \
    -m '${email}' \
    -d '${domain}' \
    || {
        echo '[ERROR] Certbot standalone failed!'
        [ "\${NGINX_WAS_UP}" = 1 ]  && systemctl start nginx  || true
        [ "\${APACHE_WAS_UP}" = 1 ] && systemctl start apache2 || true
        exit 1
    }

[ "\${NGINX_WAS_UP}" = 1 ]  && systemctl start nginx  || true
[ "\${APACHE_WAS_UP}" = 1 ] && systemctl start apache2 || true

CRON_TMP=\$(mktemp)
( crontab -l 2>/dev/null | grep -v 'certbot renew' || true ) > "\${CRON_TMP}"
echo '0 3 * * * certbot renew --quiet --post-hook "systemctl reload nginx 2>/dev/null || systemctl reload apache2 2>/dev/null || true"' >> "\${CRON_TMP}"
crontab "\${CRON_TMP}"
rm -f "\${CRON_TMP}"

echo '[OK] SSL installed + auto-renew configured'
REMOTE
)" || { log_error "SSL installation failed!"; exit 1; }
    log_ok "SSL done."
}

# ---------------------------------------------------------------------------
# HACKBACK PANEL
# ---------------------------------------------------------------------------
hackback_panel() {
    local ip="${1:-}"
    local pw="${2:--}"
    local new_email="${3:-admin@localhost.local}"
    local new_pass="${4:-}"
    [[ -z "$new_pass" ]] && new_pass=$(gen_password 14)
    [[ -z "$ip" ]] && { log_error "Format: bash $0 hackback-panel <ip> <pw> [email] [pass]"; exit 1; }
    [[ -z "$pw" ]] && pw="-"

    show_banner
    log_step "HACKBACK PANEL — Reset admin user"
    log_info "Target: ${ip} | Email: ${new_email}"
    confirm "Continue?" "n" || { log_warn "Cancelled."; exit 0; }

    exec_cmd "$ip" "$pw" "$(cat <<REMOTE
set -euo pipefail
TS=\$(date +%Y%m%d-%H%M%S)
mkdir -p '${BACKUP_DIR}'

[ -d '${PANEL_DIR}' ] || { echo '[ERROR] Panel directory not found!'; exit 1; }
[ -f '${PANEL_DIR}/.env' ] \
    && cp '${PANEL_DIR}/.env' '${BACKUP_DIR}/panel.env.'\${TS}'.bak' \
    && echo '[INFO] .env backed up'

if command -v mysqldump >/dev/null 2>&1; then
    mysqldump -u root panel > '${BACKUP_DIR}/panel-db.'\${TS}'.sql' 2>/dev/null || true
    echo '[INFO] DB backed up'
fi

cd '${PANEL_DIR}'

php artisan p:user:make \
    --email='${new_email}' \
    --username=admin \
    --name-first=Admin \
    --name-last=NortexZ \
    --password='${new_pass}' \
    --admin=1 \
    --no-interaction \
    || { echo '[ERROR] Failed to create/reset admin user'; exit 1; }

php artisan cache:clear   || true
php artisan config:clear  || true
php artisan view:clear    || true

echo '[OK] Admin user reset'
REMOTE
)" || { log_error "Panel hackback failed!"; exit 1; }

    local cred_file="${CRED_DIR}/hackback-panel-${ip}-$(date +%Y%m%d-%H%M%S).txt"
    cat >"$cred_file" <<EOF
================================================
  PANEL HACKBACK CREDENTIALS
  Generated : $(date)
================================================
Email     : ${new_email}
Username  : admin
Password  : ${new_pass}
Backups   : ${BACKUP_DIR}
================================================
EOF
    chmod 600 "$cred_file" 2>/dev/null || true

    printf '\n  %b%b✅  PANEL HACKBACK SUCCESS!%b\n' "$GREEN" "$BOLD" "$NC"
    printf '  %b📧 Email    :%b %s\n'  "$BOLD" "$NC" "$new_email"
    printf '  %b🔑 Password :%b %s\n'  "$BOLD" "$NC" "$new_pass"
    printf '  %b📁 Saved    :%b %s\n\n' "$BOLD" "$NC" "$cred_file"
}

# ---------------------------------------------------------------------------
# HACKBACK WINGS
# ---------------------------------------------------------------------------
hackback_wings() {
    local ip="${1:-}"
    local pw="${2:--}"
    local new_token="${3:-}"
    [[ -z "$ip" ]] && { log_error "Format: bash $0 hackback-wings <ip> <pw> [token_cmd]"; exit 1; }
    [[ -z "$pw" ]] && pw="-"

    show_banner
    log_step "HACKBACK WINGS — Reset Wings config"
    confirm "Continue?" "n" || { log_warn "Cancelled."; exit 0; }

    exec_cmd "$ip" "$pw" "$(cat <<REMOTE
set -uo pipefail
TS=\$(date +%Y%m%d-%H%M%S)
mkdir -p '${BACKUP_DIR}'
systemctl stop wings 2>/dev/null || true
[ -f '${WINGS_DIR}/config.yml' ] \
    && cp '${WINGS_DIR}/config.yml' '${BACKUP_DIR}/wings-config.'\${TS}'.yml.bak' \
    && echo '[INFO] Wings config backed up'
mkdir -p '${WINGS_DIR}'
REMOTE
)" || log_warn "Backup step had issues — continuing."

    if [[ -n "$new_token" ]]; then
        log_info "Applying auto-deploy token…"
        local token_b64; token_b64=$(b64enc "$new_token")
        exec_cmd "$ip" "$pw" "$(cat <<REMOTE
set -uo pipefail
cd '${WINGS_DIR}'
DECODED=\$(printf '%s' '${token_b64}' | base64 -d)
bash -c "\${DECODED}" || echo '[WARN] Token command failed — configure manually.'
REMOTE
)" || log_error "Auto-deploy token failed."
    else
        log_warn "No token provided. Get it from: Panel → Admin → Nodes → Configuration → Generate Token"
    fi

    exec_cmd "$ip" "$pw" "$(cat <<REMOTE
set -uo pipefail
systemctl daemon-reload
systemctl enable wings 2>/dev/null || true
systemctl restart wings 2>/dev/null || systemctl start wings 2>/dev/null || true
sleep 3
if systemctl is-active --quiet wings; then
    echo '[OK] Wings running'
else
    echo '[WARN] Wings not running — may need config'
    systemctl status wings --no-pager | tail -15 || true
fi
REMOTE
)" || log_warn "Wings restart had issues."

    printf '\n  %b%b✅  WINGS HACKBACK DONE!%b\n' "$GREEN" "$BOLD" "$NC"
    printf '  %bCheck: journalctl -u wings -f%b\n\n' "$CYAN" "$NC"
}

# ---------------------------------------------------------------------------
# INSTALL OFFICIAL (pterodactyl-installer.se)
# ---------------------------------------------------------------------------
install_official() {
    show_banner
    log_step "Install via Official (pterodactyl-installer.se)"
    log_warn "This runs a third-party script."
    confirm "Continue?" "n" || { log_warn "Cancelled."; exit 0; }
    bash <(curl -fsSL https://pterodactyl-installer.se) \
        || { log_error "Official installer failed!"; exit 1; }
    log_ok "Official installation finished."
}

# ---------------------------------------------------------------------------
# UPDATE PANEL
# ---------------------------------------------------------------------------
update_panel() {
    local ip="${1:-}"
    local pw="${2:--}"
    [[ -z "$ip" ]] && { log_error "Format: bash $0 update-panel <ip> <pw>"; exit 1; }
    [[ -z "$pw" ]] && pw="-"

    show_banner
    log_step "Update Pterodactyl Panel"
    confirm "Continue update?" "y" || exit 0

    exec_cmd "$ip" "$pw" "$(cat <<REMOTE
set -euo pipefail
cd '${PANEL_DIR}' || { echo 'Panel not found!'; exit 1; }
TS=\$(date +%Y%m%d-%H%M%S)
mkdir -p '${BACKUP_DIR}'
cp .env '${BACKUP_DIR}/panel.env.'\${TS}'.bak' 2>/dev/null || true
command -v mysqldump >/dev/null 2>&1 \
    && mysqldump -u root panel > '${BACKUP_DIR}/panel-db.'\${TS}'.sql' 2>/dev/null || true

php artisan down || true

curl -fL --retry 3 --retry-delay 5 \
    https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz \
    | tar -xz

chmod -R 755 storage bootstrap/cache || true
COMPOSER_ALLOW_SUPERUSER=1 composer install \
    --no-dev --optimize-autoloader --no-interaction
php artisan view:clear   || true
php artisan config:clear || true
php artisan migrate --seed --force
chown -R www-data:www-data '${PANEL_DIR}'
php artisan queue:restart || true
php artisan up
echo '[OK] Panel updated'
REMOTE
)" || { log_error "Update failed!"; exit 1; }
    log_ok "Panel updated."
}

# ---------------------------------------------------------------------------
# REPAIR PANEL
# ---------------------------------------------------------------------------
repair_panel() {
    local ip="${1:-127.0.0.1}"
    local pw="${2:--}"
    [[ -z "$pw" ]] && pw="-"

    show_banner
    log_step "Repair Panel"

    exec_cmd "$ip" "$pw" "$(cat <<REMOTE
set -euo pipefail
cd '${PANEL_DIR}' || { echo 'Panel not found!'; exit 1; }
chown -R www-data:www-data '${PANEL_DIR}'
find '${PANEL_DIR}' -type d -exec chmod 755 {} \;
find '${PANEL_DIR}' -type f -exec chmod 644 {} \;
chmod -R 775 '${PANEL_DIR}/storage' '${PANEL_DIR}/bootstrap/cache'
chown -R www-data:www-data '${PANEL_DIR}/storage' '${PANEL_DIR}/bootstrap/cache'
php artisan optimize:clear  || true
php artisan queue:restart    || true
systemctl restart php${PHP_VER}-fpm 2>/dev/null || true
systemctl reload  nginx           2>/dev/null || true
systemctl restart pteroq          2>/dev/null || true
echo '[OK] Repair complete'
REMOTE
)" || log_warn "Repair had partial issues."
    log_ok "Repair done."
}

# ---------------------------------------------------------------------------
# BACKUP PANEL
# ---------------------------------------------------------------------------
backup_panel() {
    local ip="${1:-127.0.0.1}"
    local pw="${2:--}"
    [[ -z "$pw" ]] && pw="-"

    show_banner
    log_step "Backup Panel"

    exec_cmd "$ip" "$pw" "$(cat <<REMOTE
set -uo pipefail
TS=\$(date +%Y%m%d-%H%M%S)
mkdir -p '${BACKUP_DIR}'
cp '${PANEL_DIR}/.env' '${BACKUP_DIR}/panel.env.'\${TS}'.bak' 2>/dev/null || true
command -v mysqldump >/dev/null 2>&1 \
    && mysqldump -u root panel > '${BACKUP_DIR}/panel-db.'\${TS}'.sql' 2>/dev/null || true
PARENT=\$(dirname '${PANEL_DIR}')
BASE=\$(basename '${PANEL_DIR}')
tar -czf '${BACKUP_DIR}/panel-files.'\${TS}'.tar.gz' -C "\${PARENT}" "\${BASE}" 2>/dev/null || true
ls -lh '${BACKUP_DIR}/'*\${TS}* 2>/dev/null || true
echo '[OK] Backup complete'
REMOTE
)" || log_error "Backup failed."
    log_ok "Backup stored in ${BACKUP_DIR}"
}

# ---------------------------------------------------------------------------
# RESTORE PANEL
# ---------------------------------------------------------------------------
restore_panel() {
    local ip="${1:-127.0.0.1}"
    local pw="${2:--}"
    local sql_file="${3:-}"
    [[ -z "$pw" ]] && pw="-"
    [[ -z "$sql_file" ]] && { log_error "Format: bash $0 restore-panel <ip> <pw> <backup.sql>"; exit 1; }

    show_banner
    log_step "Restore Panel from ${sql_file}"
    confirm "This will OVERWRITE the current 'panel' database. Sure?" "n" || exit 0

    exec_cmd "$ip" "$pw" "$(cat <<REMOTE
set -euo pipefail
[ -f '${sql_file}' ] || { echo '[ERROR] SQL file not found: ${sql_file}'; exit 1; }
mysql -u root panel < '${sql_file}' || { echo '[ERROR] Restore failed!'; exit 1; }
cd '${PANEL_DIR}'
php artisan migrate --force
php artisan optimize:clear
echo '[OK] Restore complete'
REMOTE
)" || log_error "Restore failed."
}

# ---------------------------------------------------------------------------
# UNINSTALL PANEL
# ---------------------------------------------------------------------------
uninstall_panel() {
    local ip="${1:-}"
    local pw="${2:--}"
    [[ -z "$ip" ]] && { log_error "Format: bash $0 uninstall-panel <ip> <pw>"; exit 1; }
    [[ -z "$pw" ]] && pw="-"

    show_banner
    printf '  %b%b🗑️  UNINSTALL PANEL%b\n\n' "$RED" "$BOLD" "$NC"
    printf '  Type %bDELETE PANEL%b to confirm: ' "$BOLD" "$NC"
    read -r CONFIRM
    [[ "$CONFIRM" != "DELETE PANEL" ]] && { log_warn "Cancelled."; exit 0; }

    exec_cmd "$ip" "$pw" "$(cat <<REMOTE
set -uo pipefail
systemctl stop    pteroq  2>/dev/null || true
systemctl disable pteroq  2>/dev/null || true
rm -f /etc/systemd/system/pteroq.service
systemctl daemon-reload

rm -f /etc/nginx/sites-enabled/pterodactyl.conf
rm -f /etc/nginx/sites-available/pterodactyl.conf
systemctl reload nginx 2>/dev/null || true

systemctl stop php${PHP_VER}-fpm 2>/dev/null || true
DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq \
    'php${PHP_VER}*' mariadb-server mariadb-client nginx redis-server 2>/dev/null || true
DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq 2>/dev/null || true

rm -rf '${PANEL_DIR}'

mysql -u root -e "DROP DATABASE IF EXISTS panel;" 2>/dev/null || true
mysql -u root -e "DROP USER IF EXISTS 'pterodactyl'@'127.0.0.1';" 2>/dev/null || true

CRON_TMP=\$(mktemp)
( crontab -l 2>/dev/null | grep -v 'pterodactyl/artisan' || true ) > "\${CRON_TMP}"
crontab "\${CRON_TMP}"
rm -f "\${CRON_TMP}"

echo '[OK] Panel removed'
REMOTE
)" || log_warn "Partial uninstall."
    printf '\n  %b%b✅  Panel uninstalled!%b\n\n' "$GREEN" "$BOLD" "$NC"
}

# ---------------------------------------------------------------------------
# UNINSTALL WINGS
# ---------------------------------------------------------------------------
uninstall_wings() {
    local ip="${1:-}"
    local pw="${2:--}"
    [[ -z "$ip" ]] && { log_error "Format: bash $0 uninstall-wings <ip> <pw>"; exit 1; }
    [[ -z "$pw" ]] && pw="-"

    show_banner
    printf '  %b%b🗑️  UNINSTALL WINGS%b\n\n' "$RED" "$BOLD" "$NC"
    printf '  Type %bDELETE WINGS%b to confirm: ' "$BOLD" "$NC"
    read -r CONFIRM
    [[ "$CONFIRM" != "DELETE WINGS" ]] && { log_warn "Cancelled."; exit 0; }

    exec_cmd "$ip" "$pw" "$(cat <<REMOTE
set -uo pipefail
systemctl stop    wings 2>/dev/null || true
systemctl disable wings 2>/dev/null || true
docker ps -a --filter 'name=pterodactyl' -q 2>/dev/null | xargs -r docker rm -f 2>/dev/null || true
rm -f /usr/local/bin/wings
rm -rf '${WINGS_DIR}'
rm -f /etc/systemd/system/wings.service
systemctl daemon-reload

REMAINING=\$(docker ps -a -q 2>/dev/null | wc -l)
if [ "\${REMAINING}" -eq 0 ]; then
    DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq \
        docker-ce docker-ce-cli containerd.io 2>/dev/null || true
    rm -rf /var/lib/docker
    echo '[INFO] Docker removed (no remaining containers)'
else
    echo '[WARN] Other Docker containers detected — Docker NOT removed'
fi

echo '[OK] Wings removed'
REMOTE
)" || log_warn "Partial uninstall."
    printf '\n  %b%b✅  Wings uninstalled!%b\n\n' "$GREEN" "$BOLD" "$NC"
}

# ---------------------------------------------------------------------------
# CHECK STATUS
# ---------------------------------------------------------------------------
check_status() {
    local ip="${1:-127.0.0.1}"
    local pw="${2:--}"
    [[ -z "$pw" ]] && pw="-"

    show_banner
    log_step "Service status on ${ip}"

    exec_cmd "$ip" "$pw" "$(cat <<REMOTE
echo '── Services ──'
for svc in nginx php${PHP_VER}-fpm php8.3-fpm php8.2-fpm php8.1-fpm \
           mariadb mysql redis-server redis pteroq wings docker; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^\${svc}\.service"; then
        STATUS=\$(systemctl is-active "\${svc}" 2>/dev/null || echo unknown)
        printf '  %-22s : %s\n' "\${svc}" "\${STATUS}"
    fi
done
echo ''
echo '── Disk & RAM ──'
df -h / | awk 'NR==2 {print "  Root: "$3"/"$2" ("$5" used)"}'
free -h | awk '/^Mem:/ {printf "  RAM:  %s used / %s total\n", $3, $2}'
echo ''
echo '── Listening ports ──'
ss -tlnp 2>/dev/null | awk 'NR==1 || /:(80|443|3306|6379|8080|2022)/' | head -20
REMOTE
)"
}

# ---------------------------------------------------------------------------
# INTERACTIVE MENU
# ---------------------------------------------------------------------------
prompt_target() {
    read -rp "  Target IP (empty = local): " M_IP
    [[ -z "${M_IP:-}" ]] && M_IP=$(get_local_ip)
    if is_local_target "${M_IP:-}"; then
        M_PW="-"
    else
        read -rsp "  Root password: " M_PW; echo
    fi
}

interactive_menu() {
    while true; do
        show_banner
        printf '  %bMAIN MENU%b\n\n' "$BOLD" "$NC"
        printf '  %b[1]%b  Install Panel\n'                           "$GREEN"   "$NC"
        printf '  %b[2]%b  Install Wings\n'                           "$GREEN"   "$NC"
        printf '  %b[3]%b  Install via Official Installer\n'          "$GREEN"   "$NC"
        printf '  %b[4]%b  Install SSL (standalone)\n'                "$GREEN"   "$NC"
        printf '  %b[5]%b  Hackback Panel (Reset Admin)\n'            "$RED"     "$NC"
        printf '  %b[6]%b  Hackback Wings\n'                          "$RED"     "$NC"
        printf '  %b[7]%b  Update Panel\n'                            "$YELLOW"  "$NC"
        printf '  %b[8]%b  Repair Panel\n'                            "$YELLOW"  "$NC"
        printf '  %b[9]%b  Backup Panel\n'                            "$MAGENTA" "$NC"
        printf '  %b[10]%b Restore Panel\n'                           "$MAGENTA" "$NC"
        printf '  %b[11]%b Check Status\n'                            "$CYAN"    "$NC"
        printf '  %b[12]%b Uninstall Panel\n'                         "$RED"     "$NC"
        printf '  %b[13]%b Uninstall Wings\n'                         "$RED"     "$NC"
        printf '  %b[14]%b View Installer Log\n'                      "$BLUE"    "$NC"
        printf '  %b[0]%b  Exit\n\n'                                  "$RED"     "$NC"
        printf '  %bSelect [0-14]:%b ' "$BOLD" "$NC"
        read -r CHOICE

        case "${CHOICE:-}" in
            1)
                prompt_target
                read -rp "  Panel domain: " M_DOMAIN
                read -rp "  Node domain (empty = same): " M_NDOMAIN
                [[ -z "${M_NDOMAIN:-}" ]] && M_NDOMAIN="${M_DOMAIN:-}"
                read -rp "  RAM MB (default 2048): " M_RAM
                [[ -z "${M_RAM:-}" ]] && M_RAM="2048"
                read -rp "  SSL? (yes/no, default no): " M_SSL
                [[ -z "${M_SSL:-}" ]] && M_SSL="no"
                install_panel "${M_IP:-}" "${M_PW:-}" "${M_DOMAIN:-}" "${M_NDOMAIN:-}" "${M_RAM:-}" "${M_SSL:-}"
                ;;
            2)
                prompt_target
                read -rp "  Auto-deploy token (optional): " M_TOKEN
                install_wings "${M_IP:-}" "${M_PW:-}" "${M_TOKEN:-}"
                ;;
            3) install_official ;;
            4)
                prompt_target
                read -rp "  Domain: " M_DOMAIN
                read -rp "  Email: "  M_EMAIL
                install_ssl "${M_IP:-}" "${M_PW:-}" "${M_DOMAIN:-}" "${M_EMAIL:-}"
                ;;
            5)
                prompt_target
                read -rp "  New admin email [admin@localhost.local]: " M_EMAIL
                read -rp "  New password (empty=auto): " M_PASS
                hackback_panel "${M_IP:-}" "${M_PW:-}" "${M_EMAIL:-admin@localhost.local}" "${M_PASS:-}"
                ;;
            6)
                prompt_target
                read -rp "  Auto-deploy token (empty=manual): " M_TOKEN
                hackback_wings "${M_IP:-}" "${M_PW:-}" "${M_TOKEN:-}"
                ;;
            7)  prompt_target; update_panel  "${M_IP:-}" "${M_PW:-}" ;;
            8)  prompt_target; repair_panel  "${M_IP:-}" "${M_PW:-}" ;;
            9)  prompt_target; backup_panel  "${M_IP:-}" "${M_PW:-}" ;;
            10)
                prompt_target
                read -rp "  Path to .sql backup: " M_SQL
                restore_panel "${M_IP:-}" "${M_PW:-}" "${M_SQL:-}"
                ;;
            11) prompt_target; check_status   "${M_IP:-}" "${M_PW:-}" ;;
            12) prompt_target; uninstall_panel "${M_IP:-}" "${M_PW:-}" ;;
            13) prompt_target; uninstall_wings "${M_IP:-}" "${M_PW:-}" ;;
            14)
                if [[ -f "$LOG_FILE" ]]; then
                    less +G "$LOG_FILE" 2>/dev/null || tail -n 200 "$LOG_FILE"
                else
                    log_warn "Log not yet available"
                fi
                ;;
            0)
                printf '\n  %bGoodbye! 👋%b\n\n' "$GREEN" "$NC"
                exit 0
                ;;
            *) log_error "Invalid choice: ${CHOICE:-}" ;;
        esac

        echo ""
        printf '  %bPress ENTER to return to menu…%b' "$YELLOW" "$NC"
        read -r _
    done
}

# ---------------------------------------------------------------------------
# HELP
# ---------------------------------------------------------------------------
show_help() {
    show_banner
    cat <<HLP
  ${BOLD}USAGE${NC}
    bash $0 menu
    bash $0 panel       <ip> <pw> <domain> [nodedomain] [ram] [yes|no]
    bash $0 wings       <ip> <pw> [auto-deploy-cmd]
    bash $0 official
    bash $0 ssl         <ip> <pw> <domain> <email>
    bash $0 hackback-panel  <ip> <pw> [email] [password]
    bash $0 hackback-wings  <ip> <pw> [auto-deploy-cmd]
    bash $0 update-panel    <ip> <pw>
    bash $0 repair-panel    <ip> <pw>
    bash $0 backup-panel    <ip> <pw>
    bash $0 restore-panel   <ip> <pw> <path.sql>
    bash $0 uninstall-panel <ip> <pw>
    bash $0 uninstall-wings <ip> <pw>
    bash $0 status      [ip] [pw]

  ${BOLD}ENV VARS${NC}
    PHP_VER=8.3
    TIMEZONE_OVERRIDE=Asia/Jakarta
    ASSUME_YES=1
    DEBUG=1
    ADMIN_EMAIL=   ADMIN_PASSWORD=   DB_PASSWORD=

  ${BOLD}LOG${NC}    : ${LOG_FILE}
  ${BOLD}BACKUP${NC} : ${BACKUP_DIR}
  ${BOLD}CRED${NC}   : ${CRED_DIR}
HLP
}

# ===========================================================================
# MAIN
# ===========================================================================
main() {
    init_log "$@"
    check_root
    detect_os
    check_internet
    check_disk_space 3000
    check_ram 1024

    local action="${1:-menu}"
    case "$action" in
        panel|install-panel)           install_panel    "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" "${7:-}" ;;
        wings|install-wings)           install_wings    "${2:-}" "${3:-}" "${4:-}" ;;
        official|installer-se)         install_official ;;
        ssl|letsencrypt)               install_ssl      "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
        hackback-panel|hackback)       hackback_panel   "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
        hackback-wings)                hackback_wings   "${2:-}" "${3:-}" "${4:-}" ;;
        uninstall-panel|remove-panel)  uninstall_panel  "${2:-}" "${3:-}" ;;
        uninstall-wings|remove-wings)  uninstall_wings  "${2:-}" "${3:-}" ;;
        update-panel|update)           update_panel     "${2:-}" "${3:-}" ;;
        repair-panel|repair)           repair_panel     "${2:-}" "${3:-}" ;;
        backup-panel|backup)           backup_panel     "${2:-}" "${3:-}" ;;
        restore-panel|restore)         restore_panel    "${2:-}" "${3:-}" "${4:-}" ;;
        status|check)                  check_status     "${2:-}" "${3:-}" ;;
        menu|interactive|"")           interactive_menu ;;
        help|--help|-h)                show_help ;;
        *)
            log_error "Unknown command: ${action}"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
