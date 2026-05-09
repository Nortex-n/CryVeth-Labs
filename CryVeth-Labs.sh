#!/usr/bin/env bash
if [ -z "$BASH_VERSION" ]; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    fi
    echo "ERROR: Bash tidak ditemukan. Install bash dulu."
    exit 1
fi

if (( BASH_VERSINFO[0] < 4 )); then
    echo "Butuh bash >= 4.0, saat ini: $BASH_VERSION" >&2
    exit 1
fi

# Aktifkan pipefail setelah kita yakin ini bash
set -o pipefail

# =============================================================================
#  KONSTANTA & WARNA
# =============================================================================
readonly SCRIPT_VERSION="2.0.0"
readonly SCRIPT_NAME="CryVeth Pterodactyl Installer"
LOG_FILE="/var/log/nortex-installer.log"
readonly PANEL_DIR="/var/www/pterodactyl"
readonly WINGS_DIR="/etc/pterodactyl"
readonly BACKUP_DIR="/root/nortex-backups"
readonly CRED_DIR="/root/nortex-credentials"

# Default PHP version, bisa di-override via env
PHP_VER="${PHP_VER:-8.3}"
TIMEZONE="${TIMEZONE_OVERRIDE:-Asia/Jakarta}"

# Warna (auto-disable kalau bukan TTY)
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; BLUE='\033[0;34m'; MAGENTA='\033[0;35m'
    BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BLUE=''; MAGENTA=''
    BOLD=''; DIM=''; NC=''
fi

# Variabel global OS
OS_ID=""
OS_VER=""
OS_CODENAME=""
OS_FAMILY=""
ARCH=""

# =============================================================================
#  LOGGING
# =============================================================================
init_log() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    if ! touch "$LOG_FILE" 2>/dev/null; then
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

_ts()       { date '+%Y-%m-%d %H:%M:%S'; }
_log_raw()  { echo "[$(_ts)] $*" >>"$LOG_FILE" 2>/dev/null || true; }

log_info()  { _log_raw "INFO  $*"; echo -e "  ${CYAN}[INFO]${NC}   $*"; }
log_ok()    { _log_raw "OK    $*"; echo -e "  ${GREEN}[OK]${NC}     $*"; }
log_warn()  { _log_raw "WARN  $*"; echo -e "  ${YELLOW}[WARN]${NC}   $*"; }
log_error() { _log_raw "ERROR $*"; echo -e "  ${RED}[ERROR]${NC}  $*" >&2; }
log_step()  { _log_raw "STEP  $*"; echo -e "\n  ${BOLD}${BLUE}▶ $*${NC}"; }
log_debug() { [[ "${DEBUG:-0}" == "1" ]] && echo -e "  ${DIM}[DEBUG] $*${NC}"; _log_raw "DEBUG $*"; }

on_error() {
    local exit_code=$?
    local line_no=$1
    log_error "Error pada line ${line_no} (exit=${exit_code}). Log: ${LOG_FILE}"
}
trap 'on_error $LINENO' ERR

# =============================================================================
#  BANNER
# =============================================================================
show_banner() {
    clear 2>/dev/null || true
    echo -e "${CYAN}${BOLD}"
    cat <<'BANNER'
  ███╗   ██╗ ██████╗ ██████╗ ████████╗███████╗██╗  ██╗
  ████╗  ██║██╔═══██╗██╔══██╗╚══██╔══╝██╔════╝╚██╗██╔╝
  ██╔██╗ ██║██║   ██║██████╔╝   ██║   █████╗   ╚███╔╝
  ██║╚██╗██║██║   ██║██╔══██╗   ██║   ██╔══╝   ██╔██╗
  ██║ ╚████║╚██████╔╝██║  ██║   ██║   ███████╗██╔╝ ██╗
  ╚═╝  ╚═══╝ ╚═════╝ ╚═╝  ╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝
BANNER
    echo -e "${NC}"
    echo -e "  ${BOLD}Pterodactyl All-in-One Installer v${SCRIPT_VERSION}${NC} ${CYAN}— Credits: @NortexZ${NC}"
    echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# =============================================================================
#  VALIDASI AWAL
# =============================================================================
check_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        log_error "Script harus dijalankan sebagai root!"
        echo -e "  ${YELLOW}Jalankan dengan:${NC} ${BOLD}sudo bash $0${NC}"
        exit 1
    fi
}

detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "Tidak bisa membaca /etc/os-release. OS tidak didukung."
        exit 1
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VER="${VERSION_ID:-unknown}"
    OS_CODENAME="${VERSION_CODENAME:-}"
    case "$OS_ID" in
        ubuntu|debian|raspbian|linuxmint|pop) OS_FAMILY="debian" ;;
        almalinux|rocky|centos|rhel|fedora)  OS_FAMILY="rhel"   ;;
        *)
            if [[ "${ID_LIKE:-}" == *debian* ]]; then
                OS_FAMILY="debian"
            elif [[ "${ID_LIKE:-}" == *rhel* || "${ID_LIKE:-}" == *fedora* ]]; then
                OS_FAMILY="rhel"
            else
                log_error "OS tidak didukung: $OS_ID $OS_VER"
                exit 1
            fi
            ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64)   ARCH="amd64" ;;
        aarch64|arm64)  ARCH="arm64" ;;
        *)
            log_error "Arsitektur CPU tidak didukung: $(uname -m)"
            exit 1
            ;;
    esac
    log_ok "OS terdeteksi: ${OS_ID} ${OS_VER} (${OS_FAMILY}, ${ARCH})"
}

check_internet() {
    local ok=0
    for host in 1.1.1.1 8.8.8.8 9.9.9.9; do
        if ping -c 1 -W 3 "$host" &>/dev/null; then ok=1; break; fi
    done
    if [[ $ok -eq 0 ]]; then
        if command -v curl >/dev/null 2>&1; then
            curl -fsS --max-time 5 https://1.1.1.1 >/dev/null 2>&1 && ok=1
        fi
    fi
    [[ $ok -eq 0 ]] && { log_error "Tidak ada koneksi internet!"; exit 1; }
    log_ok "Koneksi internet OK"
}

check_disk_space() {
    local need_mb="${1:-3000}"
    local avail_mb
    avail_mb=$(df -Pm / | awk 'NR==2 {print $4}')
    if [[ -z "$avail_mb" || "$avail_mb" -lt "$need_mb" ]]; then
        log_warn "Disk root < ${need_mb}MB free (avail=${avail_mb:-?}MB). Lanjutkan dengan risiko."
    else
        log_ok "Disk root tersedia: ${avail_mb}MB (cukup)"
    fi
}

check_ram() {
    local need_mb="${1:-1024}"
    local total_mb
    total_mb=$(free -m | awk '/^Mem:/ {print $2}')
    if [[ -z "$total_mb" || "$total_mb" -lt "$need_mb" ]]; then
        log_warn "RAM total < ${need_mb}MB (total=${total_mb:-?}MB). Performa mungkin kurang optimal."
    else
        log_ok "RAM total: ${total_mb}MB"
    fi
}

# =============================================================================
#  UTILITY UMUM
# =============================================================================
retry() {
    local max=3
    local delay=5
    local n=1
    until "$@"; do
        if [[ $n -ge $max ]]; then
            log_error "Command gagal setelah $max percobaan: $*"
            return 1
        fi
        log_warn "Percobaan $n gagal, retry dalam ${delay}s..."
        sleep "$delay"
        n=$(( n + 1 ))
        delay=$(( delay * 2 ))
    done
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
    [[ -z "$TARGET" ]] && return 0
    [[ "$TARGET" == "127.0.0.1" || "$TARGET" == "localhost" ]] && return 0
    local LOCAL_IP
    LOCAL_IP=$(get_local_ip)
    [[ "$TARGET" == "$LOCAL_IP" ]] && return 0
    ip -4 addr show 2>/dev/null | grep -Eq "inet ${TARGET//./\\.}/" && return 0
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
    [[ "${ASSUME_YES:-0}" == "1" ]] && return 0
    if [[ "$DEFAULT" == "y" ]]; then
        echo -ne "  ${YELLOW}${PROMPT} [Y/n]: ${NC}"
    else
        echo -ne "  ${YELLOW}${PROMPT} [y/N]: ${NC}"
    fi
    read -r ANS || ANS=""
    ANS="${ANS:-$DEFAULT}"
    [[ "$ANS" =~ ^[Yy]$ ]]
}

# =============================================================================
#  SSH / EXEC
# =============================================================================
ensure_sshpass() {
    if ! command -v sshpass &>/dev/null; then
        log_info "Install sshpass untuk koneksi remote..."
        if [[ "$OS_FAMILY" == "debian" ]]; then
            DEBIAN_FRONTEND=noninteractive apt-get update -qq >>"$LOG_FILE" 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sshpass >>"$LOG_FILE" 2>&1
        else
            yum install -y -q sshpass >>"$LOG_FILE" 2>&1 \
                || dnf install -y -q sshpass >>"$LOG_FILE" 2>&1 || true
        fi
    fi
}

exec_cmd() {
    local IP="$1"
    local PW="$2"
    local CMD="$3"

    if is_local_target "$IP"; then
        bash -s <<< "$CMD"
        return $?
    fi

    ensure_sshpass
    if ! command -v sshpass &>/dev/null; then
        log_error "sshpass tidak tersedia, tidak bisa konek remote."
        return 127
    fi

    # Kirim script via stdin (bash -s) — lebih aman dan support heredoc
    echo "$CMD" | sshpass -p "$PW" ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ConnectTimeout=20 \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=4 \
        root@"$IP" "bash -s"
    return $?
}

# =============================================================================
#  PACKAGE MANAGEMENT
# =============================================================================
pkg_update() {
    if [[ "$OS_FAMILY" == "debian" ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >>"$LOG_FILE" 2>&1
    else
        yum makecache -q >>"$LOG_FILE" 2>&1 || dnf makecache -q >>"$LOG_FILE" 2>&1 || true
    fi
}

pkg_install() {
    if [[ "$OS_FAMILY" == "debian" ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" \
            "$@"
    else
        yum install -y -q "$@" >>"$LOG_FILE" 2>&1 \
            || dnf install -y -q "$@" >>"$LOG_FILE" 2>&1 || true
    fi
}

php_repo_script() {
    # Cetak script setup PHP repo untuk dijalankan di remote
    cat <<'PHPSCRIPT'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

. /etc/os-release

apt-get update -y -qq
apt-get install -y -qq ca-certificates curl gnupg lsb-release

case "$ID" in
  ubuntu)
    apt-get install -y -qq software-properties-common
    add-apt-repository -y ppa:ondrej/php
    ;;
  debian)
    mkdir -p /usr/share/keyrings
    curl -fsSL https://packages.sury.org/php/apt.gpg \
        | gpg --dearmor -o /usr/share/keyrings/sury-php.gpg
    echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] \
https://packages.sury.org/php/ $(lsb_release -sc) main" \
        > /etc/apt/sources.list.d/sury-php.list
    ;;
esac

apt-get update -y -qq
PHPSCRIPT
}

# =============================================================================
#  INSTALL WINGS
# =============================================================================
install_wings() {
    local IP="${1:-}"
    local PW="${2:-}"
    local TOKEN_CMD="${3:-}"

    if [[ -z "$IP" ]]; then
        echo "Format: bash $0 wings <ip> <pwvps> [token]"
        exit 1
    fi
    [[ -z "$PW" ]] && PW="-"

    show_banner
    log_step "🚀 Install Wings Pterodactyl → $IP"

    local REMOTE_SCRIPT
    REMOTE_SCRIPT=$(cat <<REMOTE
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
TOKEN_CMD='${TOKEN_CMD}'

echo '[INFO] Installing Docker...'
if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
    systemctl enable --now docker
fi

echo '[INFO] Installing Wings binary...'
mkdir -p /etc/pterodactyl
ARCH_STR=\$(uname -m)
case "\$ARCH_STR" in
    x86_64|amd64) WINGS_ARCH="amd64" ;;
    aarch64|arm64) WINGS_ARCH="arm64" ;;
    *) echo "[ERROR] Arsitektur tidak didukung: \$ARCH_STR"; exit 1 ;;
esac

curl -fL --retry 3 \
    -o /usr/local/bin/wings \
    "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_\${WINGS_ARCH}"
chmod +x /usr/local/bin/wings

echo '[INFO] Creating Wings systemd service...'
cat > /etc/systemd/system/wings.service <<'SVCEOF'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service network-online.target
Requires=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
ExecStart=/usr/local/bin/wings
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable --now wings

if [[ -n "\$TOKEN_CMD" ]]; then
    echo '[INFO] Running auto-deploy token...'
    cd /etc/pterodactyl
    bash -c "\$TOKEN_CMD" || echo '[WARN] Token command gagal'
else
    echo '[WARN] Token tidak diberikan.'
    echo 'Ambil dari: Panel → Nodes → Node → Auto Deploy'
fi

systemctl restart wings || true
sleep 2
systemctl status wings --no-pager | head -n 15
REMOTE
)

    exec_cmd "$IP" "$PW" "$REMOTE_SCRIPT" || { log_error "Install Wings gagal!"; exit 1; }
    log_ok "Wings terinstall di $IP"
}

# =============================================================================
#  INSTALL OFFICIAL
# =============================================================================
install_official() {
    show_banner
    log_step "🚀 Install via Official Installer (pterodactyl-installer.se)"
    log_warn "Ini menjalankan script pihak ketiga. Pastikan kamu mempercayai sumbernya."
    if ! confirm "Lanjutkan instalasi official?" "n"; then
        log_warn "Dibatalkan."; exit 0
    fi
    bash <(curl -s https://pterodactyl-installer.se) || { log_error "Instalasi official gagal!"; exit 1; }
    log_ok "Instalasi official selesai."
}

# =============================================================================
#  INSTALL SSL
# =============================================================================
install_ssl() {
    local IP="${1:-}"
    local PW="${2:-}"
    local DOMAIN="${3:-}"
    local EMAIL="${4:-}"

    if [[ -z "$IP" || -z "$DOMAIN" || -z "$EMAIL" ]]; then
        log_error "Parameter kurang!"
        echo -e "  ${YELLOW}Format:${NC} bash $0 ssl <ip> <pwvps> <domain> <email>"
        exit 1
    fi
    validate_ip "$IP"     || { log_error "IP tidak valid: $IP"; exit 1; }
    validate_domain "$DOMAIN" || { log_error "Domain tidak valid: $DOMAIN"; exit 1; }
    validate_email "$EMAIL"   || { log_error "Email tidak valid: $EMAIL"; exit 1; }
    [[ -z "$PW" ]] && PW="-"

    show_banner
    log_step "🔒 Install SSL Let's Encrypt"
    log_info "Target  : $IP"
    log_info "Domain  : $DOMAIN"
    log_info "Email   : $EMAIL"

    if ! confirm "Lanjutkan?" "y"; then log_warn "Dibatalkan."; exit 0; fi

    local REMOTE_SCRIPT
    REMOTE_SCRIPT=$(cat <<REMOTE
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
SSL_DOMAIN='${DOMAIN}'
SSL_EMAIL='${EMAIL}'

apt-get update -qq
apt-get install -y -qq certbot

# Stop nginx sementara kalau pakai standalone
systemctl stop nginx 2>/dev/null || true

certbot certonly \
    --standalone \
    --non-interactive \
    --agree-tos \
    -m "\$SSL_EMAIL" \
    -d "\$SSL_DOMAIN" \
    || { echo '[ERROR] Certbot gagal!'; exit 1; }

systemctl start nginx 2>/dev/null || true

( crontab -l 2>/dev/null | grep -v 'certbot renew' ; \
  echo '0 3 * * * certbot renew --quiet --post-hook "systemctl reload nginx 2>/dev/null || true"' \
) | crontab -

echo '[OK] SSL terpasang dan auto-renew aktif'
REMOTE
)

    exec_cmd "$IP" "$PW" "$REMOTE_SCRIPT" || { log_error "Instalasi SSL gagal!"; exit 1; }
    log_ok "SSL selesai untuk $DOMAIN"
}

# =============================================================================
#  HACKBACK PANEL
# =============================================================================
hackback_panel() {
    local IP="${1:-}"
    local PW="${2:-}"
    local NEW_EMAIL="${3:-admin@localhost.local}"
    local NEW_PASS="${4:-$(gen_password 14)}"

    if [[ -z "$IP" ]]; then
        log_error "Format: bash $0 hackback-panel <ip> <pwvps> [email] [password]"
        exit 1
    fi
    [[ -z "$PW" ]] && PW="-"

    show_banner
    log_step "🔧 HACKBACK PANEL — Reset admin user"
    log_info "Target IP : $IP"
    log_info "Email Baru: $NEW_EMAIL"
    log_info "Password  : $NEW_PASS"

    if ! confirm "Lanjutkan hackback panel?" "n"; then log_warn "Dibatalkan."; exit 0; fi

    local REMOTE_SCRIPT
    REMOTE_SCRIPT=$(cat <<REMOTE
set -euo pipefail
TS=\$(date +%Y%m%d-%H%M%S)
PANEL_DIR='${PANEL_DIR}'
BACKUP_DIR='${BACKUP_DIR}'
H_EMAIL='${NEW_EMAIL}'
H_PASS='${NEW_PASS}'

mkdir -p "\$BACKUP_DIR"

[[ -f "\$PANEL_DIR/.env" ]] \
    && cp "\$PANEL_DIR/.env" "\$BACKUP_DIR/panel.env.\${TS}.bak" \
    && echo 'Backup .env disimpan'

command -v mysqldump >/dev/null 2>&1 \
    && mysqldump -u root panel > "\$BACKUP_DIR/panel-db.\${TS}.sql" 2>/dev/null \
    && echo 'Backup database disimpan' \
    || echo '[WARN] mysqldump tidak ada, skip backup DB'

cd "\$PANEL_DIR" || { echo '[ERROR] Panel dir tidak ditemukan!'; exit 1; }

php artisan p:user:make \
    --email="\$H_EMAIL" \
    --username='admin' \
    --name-first='Admin' \
    --name-last='NortexZ' \
    --password="\$H_PASS" \
    --admin=1 \
    --no-interaction \
    || { echo '[ERROR] Gagal reset user admin!'; exit 1; }

php artisan cache:clear
php artisan config:clear
php artisan view:clear

echo '[OK] User admin berhasil direset'
REMOTE
)

    exec_cmd "$IP" "$PW" "$REMOTE_SCRIPT" || { log_error "Hackback panel gagal!"; exit 1; }

    local CRED_FILE="${CRED_DIR}/hackback-panel-${IP}-$(date +%Y%m%d-%H%M%S).txt"
    cat >"$CRED_FILE" <<EOF
========================================
  PTERODACTYL PANEL HACKBACK CREDENTIALS
  Generated : $(date)
========================================
Email Admin : ${NEW_EMAIL}
Username    : admin
Password    : ${NEW_PASS}
Backup dir  : ${BACKUP_DIR}
EOF
    chmod 600 "$CRED_FILE" 2>/dev/null || true

    echo ""
    echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${GREEN}${BOLD}✅  HACKBACK PANEL BERHASIL!${NC}"
    echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}📧 Email Admin   :${NC} ${NEW_EMAIL}"
    echo -e "  ${BOLD}👤 Username      :${NC} admin"
    echo -e "  ${BOLD}🔑 Password Baru :${NC} ${NEW_PASS}"
    echo -e "  ${BOLD}📁 Kredensial    :${NC} ${CRED_FILE}"
    echo ""
}

# =============================================================================
#  HACKBACK WINGS
# =============================================================================
hackback_wings() {
    local IP="${1:-}"
    local PW="${2:-}"
    local NEW_TOKEN="${3:-}"

    if [[ -z "$IP" ]]; then
        log_error "Format: bash $0 hackback-wings <ip> <pwvps> [token_cmd]"
        exit 1
    fi
    [[ -z "$PW" ]] && PW="-"

    show_banner
    log_step "🔧 HACKBACK WINGS — Reset konfigurasi Wings"
    log_info "Target IP : $IP"

    if ! confirm "Lanjutkan hackback wings?" "n"; then log_warn "Dibatalkan."; exit 0; fi

    local REMOTE_BACKUP
    REMOTE_BACKUP=$(cat <<REMOTE
set -euo pipefail
TS=\$(date +%Y%m%d-%H%M%S)
WINGS_DIR='${WINGS_DIR}'
BACKUP_DIR='${BACKUP_DIR}'
mkdir -p "\$BACKUP_DIR" "\$WINGS_DIR"
systemctl stop wings 2>/dev/null || true
[[ -f "\$WINGS_DIR/config.yml" ]] \
    && cp "\$WINGS_DIR/config.yml" "\$BACKUP_DIR/wings-config.\${TS}.yml.bak" \
    && echo 'Backup config.yml disimpan'
REMOTE
)
    exec_cmd "$IP" "$PW" "$REMOTE_BACKUP" || log_warn "Backup parsial"

    if [[ -n "$NEW_TOKEN" ]]; then
        log_info "Menjalankan token auto-deploy..."
        local REMOTE_TOKEN
        REMOTE_TOKEN=$(cat <<REMOTE
set -euo pipefail
cd '${WINGS_DIR}'
TOKEN_CMD='${NEW_TOKEN}'
bash -c "\$TOKEN_CMD" || echo '[WARN] Token gagal'
REMOTE
)
        exec_cmd "$IP" "$PW" "$REMOTE_TOKEN" || log_error "Token auto-deploy gagal"
    else
        log_warn "Token tidak diberikan — ambil dari: Panel → Admin → Nodes → Generate Token"
    fi

    local REMOTE_RESTART
    REMOTE_RESTART=$(cat <<'REMOTE'
set -euo pipefail
systemctl daemon-reload
systemctl enable wings 2>/dev/null || true
systemctl restart wings 2>/dev/null || systemctl start wings 2>/dev/null || true
sleep 2
systemctl status wings --no-pager 2>&1 | head -n 12 || true
REMOTE
)
    exec_cmd "$IP" "$PW" "$REMOTE_RESTART" || log_warn "Restart wings gagal"

    echo ""
    echo -e "  ${GREEN}${BOLD}✅  HACKBACK WINGS SELESAI!${NC}"
    echo -e "  ${CYAN}ℹ️  Cek log: journalctl -u wings -f${NC}"
    echo ""
}

# =============================================================================
#  INSTALL PANEL
# =============================================================================
install_panel() {
    local IP="${1:-}"
    local PW="${2:-}"
    local DOMAIN="${3:-}"
    local NODE_DOMAIN="${4:-}"
    local RAM="${5:-2048}"
    local USE_SSL="${6:-no}"

    if [[ -z "$IP" || -z "$DOMAIN" ]]; then
        log_error "Parameter kurang!"
        echo "Format: bash $0 panel <ip> <pwvps> <domain> <nodedomain> <ram> [ssl]"
        exit 1
    fi

    validate_ip "$IP"         || { log_error "IP tidak valid: $IP"; exit 1; }
    validate_domain "$DOMAIN" || { log_error "Domain tidak valid: $DOMAIN"; exit 1; }

    [[ -z "$PW" ]] && PW="-"
    NODE_DOMAIN="${NODE_DOMAIN:-$DOMAIN}"
    validate_domain "$NODE_DOMAIN" || { log_warn "NODE_DOMAIN invalid, fallback ke DOMAIN"; NODE_DOMAIN="$DOMAIN"; }
    [[ "$RAM" =~ ^[0-9]+$ ]] || { log_warn "RAM tidak valid, fallback ke 2048"; RAM=2048; }
    USE_SSL=$(echo "$USE_SSL" | tr '[:upper:]' '[:lower:]')

    # --- Generate credentials ---
    local ADMIN_EMAIL ADMIN_PASSWORD DB_PASSWORD APP_URL
    ADMIN_EMAIL="admin@${DOMAIN}"
    ADMIN_PASSWORD="$(gen_password 18)"
    DB_PASSWORD="$(gen_password 24)"
    APP_URL="http://${DOMAIN}"
    [[ "$USE_SSL" == "yes" ]] && APP_URL="https://${DOMAIN}"

    show_banner
    log_step "🚀 Install Panel Pterodactyl"
    log_info "IP          : $IP"
    log_info "Domain      : $DOMAIN"
    log_info "SSL         : $USE_SSL"
    log_info "PHP Version : $PHP_VER"

    # ─── STEP 1: System Bootstrap ───────────────────────────────────────────
    log_step "Step 1/9 — System bootstrap"

    exec_cmd "$IP" "$PW" "$(cat <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

dpkg --configure -a || true
apt-get -f install -y -qq || true
apt-get clean
rm -rf /var/lib/apt/lists/*
apt-get update -y -qq
apt-get upgrade -y -qq --allow-downgrades --allow-change-held-packages || true

apt-get install -y -qq \
    curl wget git unzip tar sudo cron jq \
    software-properties-common ca-certificates gnupg lsb-release \
    dnsutils netcat-openbsd ufw

apt-get install -y -qq mariadb-server mariadb-client
systemctl enable mariadb
systemctl start mariadb
REMOTE
)" || { log_error "Step 1 gagal!"; exit 1; }
    log_ok "Step 1 selesai"

    # ─── STEP 2: PHP ────────────────────────────────────────────────────────
    log_step "Step 2/9 — Install PHP ${PHP_VER} + ekstensi"
    local PHP_REMOTE
    PHP_REMOTE=$(cat <<REMOTE
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

$(php_repo_script)

PHP_VER='${PHP_VER}'

apt-get install -y -qq \
    php\${PHP_VER} php\${PHP_VER}-cli php\${PHP_VER}-gd php\${PHP_VER}-mysql \
    php\${PHP_VER}-pdo php\${PHP_VER}-mbstring php\${PHP_VER}-tokenizer \
    php\${PHP_VER}-bcmath php\${PHP_VER}-xml php\${PHP_VER}-fpm \
    php\${PHP_VER}-curl php\${PHP_VER}-zip php\${PHP_VER}-intl \
    php\${PHP_VER}-readline php\${PHP_VER}-sqlite3

systemctl enable --now php\${PHP_VER}-fpm
REMOTE
)
    exec_cmd "$IP" "$PW" "$PHP_REMOTE" || { log_error "Step 2 gagal!"; exit 1; }
    log_ok "PHP ${PHP_VER} terinstall"

    # ─── STEP 3: Database ───────────────────────────────────────────────────
    log_step "Step 3/9 — Setup database MariaDB"

    local DB_REMOTE
    DB_REMOTE=$(cat <<REMOTE
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
DBPASS='${DB_PASSWORD}'

systemctl enable mariadb
systemctl start mariadb
sleep 2

mysql -u root <<SQL
CREATE USER IF NOT EXISTS 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '\${DBPASS}';
ALTER USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '\${DBPASS}';
CREATE DATABASE IF NOT EXISTS panel CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
REMOTE
)
    exec_cmd "$IP" "$PW" "$DB_REMOTE" || { log_error "Step 3 gagal!"; exit 1; }
    log_ok "MariaDB & database OK"

    # ─── STEP 4: Redis & Composer ───────────────────────────────────────────
    log_step "Step 4/9 — Install Redis & Composer"

    exec_cmd "$IP" "$PW" "$(cat <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get install -y -qq redis-server
systemctl enable --now redis-server

if ! command -v composer >/dev/null 2>&1; then
    EXPECTED_SIG=$(curl -fsSL https://composer.github.io/installer.sig)
    php -r "copy('https://getcomposer.org/installer', '/tmp/composer-setup.php');"
    ACTUAL_SIG=$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');")
    if [ "$EXPECTED_SIG" != "$ACTUAL_SIG" ]; then
        echo '[ERROR] Composer checksum invalid!'; exit 1
    fi
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
    rm -f /tmp/composer-setup.php
fi
composer --version
REMOTE
)" || { log_error "Step 4 gagal!"; exit 1; }
    log_ok "Redis & Composer OK"

    # ─── STEP 5: Download Panel ─────────────────────────────────────────────
    log_step "Step 5/9 — Download & setup Panel"

    exec_cmd "$IP" "$PW" "$(cat <<'REMOTE'
set -euo pipefail
PANEL_DIR="/var/www/pterodactyl"

retry() {
    local max=3 delay=5 n=1
    until "$@"; do
        [ "$n" -ge "$max" ] && return 1
        echo "[RETRY] attempt $n gagal, retry dalam ${delay}s..."
        sleep "$delay"; n=$(( n+1 )); delay=$(( delay*2 ))
    done
}

mkdir -p "$PANEL_DIR"
cd "$PANEL_DIR"

retry curl -fsSL --retry 3 --retry-delay 5 \
    -o panel.tar.gz \
    https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz

[ -s panel.tar.gz ] || { echo '[ERROR] panel.tar.gz kosong!'; exit 1; }
tar -xzf panel.tar.gz
rm -f panel.tar.gz

chmod -R 755 storage bootstrap/cache 2>/dev/null || true
chown -R www-data:www-data "$PANEL_DIR" 2>/dev/null || true

[ -f .env ] || cp .env.example .env

REQUIRED="curl pdo pdo_mysql mbstring xml bcmath zip"
MISSING=""
for ext in $REQUIRED; do
    php -m 2>/dev/null | grep -qi "^${ext}$" || MISSING="$MISSING $ext"
done
[ -n "$MISSING" ] && { echo "[ERROR] PHP extension hilang:$MISSING"; exit 1; }

COMPOSER_ALLOW_SUPERUSER=1 retry composer install \
    --no-dev --optimize-autoloader --no-interaction --no-progress

grep -q "^APP_KEY=base64:" .env 2>/dev/null \
    || php artisan key:generate --force

echo '[OK] Panel berhasil didownload'
REMOTE
)" || { log_error "Step 5 gagal!"; exit 1; }
    log_ok "Panel terdownload"

    # ─── STEP 6: Environment & User Admin ───────────────────────────────────
    log_step "Step 6/9 — Konfigurasi environment & user admin"

    local ENV_REMOTE
    ENV_REMOTE=$(cat <<REMOTE
set -euo pipefail
cd '${PANEL_DIR}'

EMAIL='${ADMIN_EMAIL}'
APASS='${ADMIN_PASSWORD}'
DBPASS='${DB_PASSWORD}'
APP_URL='${APP_URL}'
TZ='${TIMEZONE}'

[[ -z "\$EMAIL" || -z "\$APASS" || -z "\$DBPASS" ]] && exit 1

php artisan p:environment:setup \
    --author="\$EMAIL" \
    --url="\$APP_URL" \
    --timezone="\$TZ" \
    --cache=redis \
    --session=redis \
    --queue=redis \
    --redis-host=127.0.0.1 \
    --redis-pass='' \
    --redis-port=6379 \
    --settings-ui=true \
    --no-interaction

php artisan p:environment:database \
    --host=127.0.0.1 \
    --port=3306 \
    --database=panel \
    --username=pterodactyl \
    --password="\$DBPASS" \
    --no-interaction

php artisan migrate --seed --force

php artisan p:user:make \
    --email="\$EMAIL" \
    --username=admin \
    --name-first=Admin \
    --name-last=User \
    --password="\$APASS" \
    --admin=1 \
    --no-interaction || true
REMOTE
)
    exec_cmd "$IP" "$PW" "$ENV_REMOTE" || { log_error "Step 6 gagal!"; exit 1; }
    log_ok "Environment & user admin OK"

    # ─── STEP 7: Nginx ──────────────────────────────────────────────────────
    log_step "Step 7/9 — Nginx"
    local NGINX_CONF
    NGINX_CONF=$(cat <<CONF
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

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht {
        deny all;
    }
}
CONF
)
    local NGINX_B64
    NGINX_B64=$(printf '%s' "$NGINX_CONF" | base64 -w0)

    local NGINX_REMOTE
    NGINX_REMOTE=$(cat <<REMOTE
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
PHP_VER='${PHP_VER}'

apt-get update -qq
apt-get install -y -qq nginx

rm -f /etc/nginx/sites-enabled/default

# Decode config dari base64 — bebas masalah escaping
echo '${NGINX_B64}' | base64 -d > /etc/nginx/sites-available/pterodactyl.conf

ln -sf /etc/nginx/sites-available/pterodactyl.conf \
       /etc/nginx/sites-enabled/pterodactyl.conf

nginx -t || {
    echo '[ERROR] nginx config invalid!'
    cat /etc/nginx/sites-available/pterodactyl.conf
    exit 1
}

systemctl enable nginx
systemctl restart nginx
systemctl is-active --quiet nginx || {
    echo '[ERROR] nginx gagal start!'
    systemctl status nginx --no-pager
    exit 1
}

systemctl enable php\${PHP_VER}-fpm
systemctl restart php\${PHP_VER}-fpm
systemctl is-active --quiet php\${PHP_VER}-fpm || {
    echo '[ERROR] php-fpm gagal start!'
    systemctl status php\${PHP_VER}-fpm --no-pager
    exit 1
}
REMOTE
)
    exec_cmd "$IP" "$PW" "$NGINX_REMOTE" || { log_error "Step 7 (Nginx) gagal!"; exit 1; }
    log_ok "Nginx & PHP-FPM OK"

    # ─── STEP 8: SSL ────────────────────────────────────────────────────────
    if [[ "$USE_SSL" == "yes" ]]; then
        log_step "Step 8/9 — SSL Let's Encrypt"

        local SSL_REMOTE
        SSL_REMOTE=$(cat <<REMOTE
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
SSL_DOMAIN='${DOMAIN}'
SSL_EMAIL='${ADMIN_EMAIL}'

apt-get update -qq
apt-get install -y -qq certbot python3-certbot-nginx

nginx -t || { echo '[FATAL] nginx config invalid sebelum SSL'; exit 1; }
systemctl reload nginx || systemctl restart nginx || true

CERTBOT_LOG=\$(mktemp)
certbot --nginx \
    --non-interactive --agree-tos --redirect \
    -m "\$SSL_EMAIL" -d "\$SSL_DOMAIN" \
    2>&1 | tee "\$CERTBOT_LOG" || {
        echo '[ERROR] Certbot gagal!'
        cat "\$CERTBOT_LOG"
        exit 1
    }

( crontab -l 2>/dev/null | grep -v 'certbot renew' ; \
  echo '0 3 * * * certbot renew --quiet --post-hook "systemctl reload nginx"' \
) | crontab -

HTTP_CODE=\$(curl -o /dev/null -s -w '%{http_code}' "https://\$SSL_DOMAIN" || true)
echo "[INFO] HTTPS response: \$HTTP_CODE"
[[ "\$HTTP_CODE" =~ ^(200|301|302)$ ]] && echo '[OK] HTTPS aktif' || echo '[WARN] HTTPS belum ready (DNS?)'
REMOTE
)
        exec_cmd "$IP" "$PW" "$SSL_REMOTE" || { log_error "Step 8 (SSL) gagal!"; exit 1; }
        log_ok "SSL OK"
    else
        log_step "Step 8/9 — SSL dilewati (HTTP only)"
        log_ok "Skipped"
    fi

    # ─── STEP 9: Cron + Queue + Firewall ────────────────────────────────────
    log_step "Step 9/9 — Cron, Queue Worker, Firewall"
    local PTEROQ_SVC
    PTEROQ_SVC=$(cat <<EOF
[Unit]
Description=Pterodactyl Queue Worker
After=network.target redis-server.service mysql.service
Wants=redis-server.service

[Service]
User=www-data
Group=www-data
WorkingDirectory=${PANEL_DIR}
ExecStart=/usr/bin/php ${PANEL_DIR}/artisan queue:work \\
    --queue=high,standard,low \\
    --sleep=3 \\
    --tries=3 \\
    --max-time=3600
Restart=always
RestartSec=5
StartLimitInterval=180
StartLimitBurst=30
TimeoutStopSec=60
KillSignal=SIGTERM
StandardOutput=journal
StandardError=journal
SyslogIdentifier=pteroq

[Install]
WantedBy=multi-user.target
EOF
)
    local PTEROQ_B64
    PTEROQ_B64=$(printf '%s' "$PTEROQ_SVC" | base64 -w0)

    local STEP9_REMOTE
    STEP9_REMOTE=$(cat <<REMOTE
set -euo pipefail
PANEL_DIR='${PANEL_DIR}'

echo '[9/9] Cron setup...'
( crontab -l 2>/dev/null | grep -v 'artisan schedule:run' ; \
  echo "* * * * * /usr/bin/php \${PANEL_DIR}/artisan schedule:run >> /dev/null 2>&1" \
) | crontab -

echo '[9/9] Deploy queue worker...'
echo '${PTEROQ_B64}' | base64 -d > /etc/systemd/system/pteroq.service

systemctl daemon-reload
systemctl enable pteroq
systemctl restart pteroq || systemctl start pteroq

sleep 2
systemctl is-active --quiet pteroq || {
    echo '[ERROR] pteroq gagal start!'
    journalctl -u pteroq -n 30 --no-pager || true
    exit 1
}
echo '[OK] pteroq aktif'

echo '[9/9] Firewall setup...'
if command -v ufw >/dev/null 2>&1; then
    ufw allow 22/tcp  >/dev/null 2>&1 || true
    ufw allow 80/tcp  >/dev/null 2>&1 || true
    ufw allow 443/tcp >/dev/null 2>&1 || true
    ufw --force enable >/dev/null 2>&1 || true
    ufw status verbose || true
else
    echo '[WARN] UFW tidak tersedia'
fi
echo '[9/9] DONE'
REMOTE
)
    exec_cmd "$IP" "$PW" "$STEP9_REMOTE" || { log_error "Step 9 gagal!"; exit 1; }
    log_ok "Cron, Queue, Firewall OK"

    # ─── Health Check ───────────────────────────────────────────────────────
    log_step "Health Check Final"

    local HC_REMOTE
    HC_REMOTE=$(cat <<REMOTE
set -euo pipefail
PHP_VER='${PHP_VER}'
DOMAIN='${DOMAIN}'
FAIL=0

echo '========================'
echo ' SYSTEM HEALTH CHECK'
echo '========================'

HTTP_CODE=\$(curl -o /dev/null -s -w '%{http_code}' --max-time 10 http://127.0.0.1 || echo 000)
echo "HTTP => \$HTTP_CODE"
[[ "\$HTTP_CODE" =~ ^(200|301|302)$ ]] || FAIL=1

for svc in nginx php\${PHP_VER}-fpm redis-server mariadb pteroq; do
    systemctl is-active --quiet "\$svc" 2>/dev/null \
        && echo "[OK] \$svc" \
        || { echo "[FAIL] \$svc"; FAIL=1; }
done

[[ -d /etc/letsencrypt/live/\$DOMAIN ]] \
    && echo '[OK] SSL exists' \
    || echo '[INFO] SSL tidak terpasang'

echo '========================'
[[ \$FAIL -eq 0 ]] && echo '[SUCCESS] SYSTEM HEALTHY' || echo '[WARNING] ADA ISSUES'
exit \$FAIL
REMOTE
)
    exec_cmd "$IP" "$PW" "$HC_REMOTE" || log_warn "Health check ada isu — cek log di server"

    # ─── Simpan Kredensial ───────────────────────────────────────────────────
    local CRED_FILE="${CRED_DIR}/panel-${IP}-$(date +%Y%m%d-%H%M%S).txt"
    cat >"$CRED_FILE" <<EOF
========================================
  PTERODACTYL PANEL CREDENTIALS
  Generated : $(date)
========================================
Panel URL       : ${APP_URL}
Admin Email     : ${ADMIN_EMAIL}
Admin Password  : ${ADMIN_PASSWORD}
DB Password     : ${DB_PASSWORD}
PHP Version     : ${PHP_VER}
Domain          : ${DOMAIN}
========================================
EOF
    chmod 600 "$CRED_FILE"

    echo ""
    echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${GREEN}${BOLD}✅  INSTALASI PANEL SELESAI!${NC}"
    echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}🌐 URL Panel     :${NC} ${APP_URL}"
    echo -e "  ${BOLD}📧 Email Admin   :${NC} ${ADMIN_EMAIL}"
    echo -e "  ${BOLD}🔑 Password      :${NC} ${ADMIN_PASSWORD}"
    echo -e "  ${BOLD}📁 Kredensial    :${NC} ${CRED_FILE}"
    echo ""
}

# =============================================================================
#  UNINSTALL PANEL
# =============================================================================
uninstall_panel() {
    local IP="${1:-}"
    local PW="${2:-}"
    [[ -z "$IP" ]] && { log_error "Format: bash $0 uninstall-panel <ip> <pwvps>"; exit 1; }
    [[ -z "$PW" ]] && PW="-"

    show_banner
    echo -e "  ${RED}${BOLD}🗑️  UNINSTALL PANEL${NC}\n"
    echo -ne "  Ketik ${BOLD}HAPUS PANEL${NC} untuk konfirmasi: "
    read -r CONFIRM
    [[ "$CONFIRM" != "HAPUS PANEL" ]] && { log_warn "Dibatalkan."; exit 0; }

    local REMOTE_SCRIPT
    REMOTE_SCRIPT=$(cat <<REMOTE
set -euo pipefail
PHP_VER='${PHP_VER}'
PANEL_DIR='${PANEL_DIR}'

systemctl stop pteroq 2>/dev/null || true
systemctl disable pteroq 2>/dev/null || true
rm -f /etc/systemd/system/pteroq.service
systemctl daemon-reload

rm -f /etc/nginx/sites-enabled/pterodactyl.conf
rm -f /etc/nginx/sites-available/pterodactyl.conf
systemctl reload nginx 2>/dev/null || true
systemctl disable nginx 2>/dev/null || true

systemctl stop php\${PHP_VER}-fpm 2>/dev/null || true

apt-get purge -y -qq php\${PHP_VER}* mariadb-server mariadb-client nginx redis-server || true
apt-get autoremove -y -qq || true

rm -rf "\$PANEL_DIR"

mysql -u root -e "DROP DATABASE IF EXISTS panel;" 2>/dev/null || true
mysql -u root -e "DROP USER IF EXISTS 'pterodactyl'@'127.0.0.1';" 2>/dev/null || true

( crontab -l 2>/dev/null | grep -v 'pterodactyl/artisan' ) | crontab - 2>/dev/null || true

echo 'Panel removed.'
REMOTE
)
    exec_cmd "$IP" "$PW" "$REMOTE_SCRIPT" || log_warn "Uninstall parsial"
    echo -e "\n  ${GREEN}${BOLD}✅  Panel berhasil diuninstall!${NC}\n"
}

# =============================================================================
#  UNINSTALL WINGS
# =============================================================================
uninstall_wings() {
    local IP="${1:-}"
    local PW="${2:-}"
    [[ -z "$IP" ]] && { log_error "Format: bash $0 uninstall-wings <ip> <pwvps>"; exit 1; }
    [[ -z "$PW" ]] && PW="-"

    show_banner
    echo -e "  ${RED}${BOLD}🗑️  UNINSTALL WINGS${NC}\n"
    echo -ne "  Ketik ${BOLD}HAPUS WINGS${NC} untuk konfirmasi: "
    read -r CONFIRM
    [[ "$CONFIRM" != "HAPUS WINGS" ]] && { log_warn "Dibatalkan."; exit 0; }

    local REMOTE_SCRIPT
    REMOTE_SCRIPT=$(cat <<'REMOTE'
set -euo pipefail
WINGS_DIR="/etc/pterodactyl"

systemctl stop wings 2>/dev/null || true
systemctl disable wings 2>/dev/null || true

docker ps -a --filter 'name=pterodactyl' -q | xargs -r docker rm -f 2>/dev/null || true

rm -f /usr/local/bin/wings
rm -rf "$WINGS_DIR"
rm -f /etc/systemd/system/wings.service
systemctl daemon-reload

if [ -z "$(docker ps -a -q 2>/dev/null)" ]; then
    echo '[INFO] Tidak ada container lain, menghapus Docker...'
    apt-get purge -y -qq docker-ce docker-ce-cli containerd.io 2>/dev/null || true
    rm -rf /var/lib/docker
else
    echo '[WARN] Container Docker lain ditemukan, Docker tidak dihapus.'
fi

echo 'Wings removed.'
REMOTE
)
    exec_cmd "$IP" "$PW" "$REMOTE_SCRIPT" || log_warn "Uninstall parsial"
    echo -e "\n  ${GREEN}${BOLD}✅  Wings berhasil diuninstall!${NC}\n"
}

# =============================================================================
#  UPDATE PANEL
# =============================================================================
update_panel() {
    local IP="${1:-}"
    local PW="${2:-}"
    [[ -z "$IP" ]] && { log_error "Format: bash $0 update-panel <ip> <pwvps>"; exit 1; }
    [[ -z "$PW" ]] && PW="-"

    show_banner
    log_step "♻️  Update Panel Pterodactyl"
    if ! confirm "Lanjutkan update?" "y"; then exit 0; fi

    local REMOTE_SCRIPT
    REMOTE_SCRIPT=$(cat <<REMOTE
set -euo pipefail
PANEL_DIR='${PANEL_DIR}'
BACKUP_DIR='${BACKUP_DIR}'
TS=\$(date +%Y%m%d-%H%M%S)

cd "\$PANEL_DIR" || { echo '[ERROR] Panel tidak ditemukan!'; exit 1; }
mkdir -p "\$BACKUP_DIR"
cp .env "\$BACKUP_DIR/panel.env.\${TS}.bak" 2>/dev/null || true
command -v mysqldump >/dev/null 2>&1 \
    && mysqldump -u root panel > "\$BACKUP_DIR/panel-db.\${TS}.sql" 2>/dev/null \
    || echo '[WARN] mysqldump tidak ada, skip DB backup'

php artisan down || true
curl -fL --retry 3 \
    https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz \
    | tar -xz
chmod -R 755 storage bootstrap/cache || true
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction
php artisan view:clear
php artisan config:clear
php artisan migrate --seed --force
chown -R www-data:www-data "\$PANEL_DIR"
php artisan queue:restart
php artisan up
REMOTE
)
    exec_cmd "$IP" "$PW" "$REMOTE_SCRIPT" || { log_error "Update gagal!"; exit 1; }
    log_ok "Panel berhasil diupdate"
}

# =============================================================================
#  STATUS
# =============================================================================
check_status() {
    local IP="${1:-127.0.0.1}"
    local PW="${2:-}"
    [[ -z "$PW" ]] && PW="-"

    show_banner
    log_step "📊 Status layanan di $IP"

    local REMOTE_SCRIPT
    REMOTE_SCRIPT=$(cat <<REMOTE
PHP_VER='${PHP_VER}'
echo '── Service Status ──'
for svc in nginx php\${PHP_VER}-fpm mariadb mysql redis-server redis pteroq wings docker; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^\${svc}\\.service"; then
        STATUS=\$(systemctl is-active "\$svc" 2>/dev/null || echo 'unknown')
        printf '  %-22s : %s\n' "\$svc" "\$STATUS"
    fi
done
echo ''
echo '── Disk & RAM ──'
df -h / | tail -1 | awk '{print "  Disk root : "\$3"/"\$2" ("\$5" used)"}'
free -h | awk 'NR==2{printf "  RAM       : %s/%s\n", \$3, \$2}'
echo ''
echo '── Listener Ports ──'
ss -tlnp 2>/dev/null | awk 'NR==1 || /:(80|443|3306|6379|8080|2022)/' | head -n 15
REMOTE
)
    exec_cmd "$IP" "$PW" "$REMOTE_SCRIPT"
}

# =============================================================================
#  BACKUP PANEL
# =============================================================================
backup_panel() {
    local IP="${1:-127.0.0.1}"
    local PW="${2:-}"
    [[ -z "$PW" ]] && PW="-"

    show_banner
    log_step "💾 Backup Panel"

    local REMOTE_SCRIPT
    REMOTE_SCRIPT=$(cat <<REMOTE
set -euo pipefail
PANEL_DIR='${PANEL_DIR}'
BACKUP_DIR='${BACKUP_DIR}'
TS=\$(date +%Y%m%d-%H%M%S)
mkdir -p "\$BACKUP_DIR"

cp "\$PANEL_DIR/.env" "\$BACKUP_DIR/panel.env.\${TS}.bak" 2>/dev/null || true
command -v mysqldump >/dev/null 2>&1 \
    && mysqldump -u root panel > "\$BACKUP_DIR/panel-db.\${TS}.sql" 2>/dev/null \
    || echo '[WARN] mysqldump tidak ada'

tar -czf "\$BACKUP_DIR/panel-files.\${TS}.tar.gz" \
    -C "\$(dirname "\$PANEL_DIR")" "\$(basename "\$PANEL_DIR")" 2>/dev/null || true

ls -lh "\$BACKUP_DIR/"*"\$TS"* 2>/dev/null || true
echo 'Backup selesai.'
REMOTE
)
    exec_cmd "$IP" "$PW" "$REMOTE_SCRIPT" || log_error "Backup gagal"
    log_ok "Backup tersimpan di ${BACKUP_DIR}"
}

# =============================================================================
#  RESTORE PANEL
# =============================================================================
restore_panel() {
    local IP="${1:-127.0.0.1}"
    local PW="${2:-}"
    local SQL_FILE="${3:-}"
    [[ -z "$PW" ]] && PW="-"

    if [[ -z "$SQL_FILE" ]]; then
        log_error "Format: bash $0 restore-panel <ip> <pw> <path-to-backup.sql>"
        exit 1
    fi

    show_banner
    log_step "♻️  Restore Database Panel dari $SQL_FILE"
    if ! confirm "Yakin? Ini akan menimpa database 'panel' saat ini." "n"; then exit 0; fi

    local REMOTE_SCRIPT
    REMOTE_SCRIPT=$(cat <<REMOTE
set -euo pipefail
PANEL_DIR='${PANEL_DIR}'
SQL_FILE='${SQL_FILE}'
mysql -u root panel < "\$SQL_FILE" || { echo '[ERROR] Gagal restore!'; exit 1; }
cd "\$PANEL_DIR" && php artisan migrate --force && php artisan optimize:clear
echo 'Restore selesai.'
REMOTE
)
    exec_cmd "$IP" "$PW" "$REMOTE_SCRIPT" || log_error "Restore gagal"
}

# =============================================================================
#  REPAIR PANEL
# =============================================================================
repair_panel() {
    local IP="${1:-127.0.0.1}"
    local PW="${2:-}"
    [[ -z "$PW" ]] && PW="-"

    show_banner
    log_step "🛠️  Repair Panel — fix permission, cache, service"

    local REMOTE_SCRIPT
    REMOTE_SCRIPT=$(cat <<REMOTE
set -euo pipefail
PANEL_DIR='${PANEL_DIR}'
PHP_VER='${PHP_VER}'

cd "\$PANEL_DIR" || { echo '[ERROR] Panel tidak ditemukan!'; exit 1; }

chown -R www-data:www-data "\$PANEL_DIR"
find "\$PANEL_DIR" -type d -exec chmod 755 {} \\;
find "\$PANEL_DIR" -type f -exec chmod 644 {} \\;
chmod -R 775 "\$PANEL_DIR/storage" "\$PANEL_DIR/bootstrap/cache"
chown -R www-data:www-data "\$PANEL_DIR/storage" "\$PANEL_DIR/bootstrap/cache"

php artisan optimize:clear
php artisan queue:restart

systemctl restart php\${PHP_VER}-fpm 2>/dev/null || true
systemctl reload nginx 2>/dev/null || true
systemctl restart pteroq 2>/dev/null || true

echo 'Repair selesai.'
REMOTE
)
    exec_cmd "$IP" "$PW" "$REMOTE_SCRIPT" || log_warn "Repair parsial"
    log_ok "Repair selesai"
}

# =============================================================================
#  MENU INTERAKTIF
# =============================================================================
prompt_target() {
    read -rp "  IP target (kosong = local): " M_IP
    [[ -z "$M_IP" ]] && M_IP=$(get_local_ip)
    if is_local_target "$M_IP"; then
        M_PW="-"
    else
        read -rsp "  Password root: " M_PW; echo
    fi
}

interactive_menu() {
    while true; do
        show_banner
        echo -e "  ${BOLD}MENU UTAMA${NC}"
        echo ""
        echo -e "  ${GREEN}[1]${NC}  Install Panel"
        echo -e "  ${GREEN}[2]${NC}  Install Wings"
        echo -e "  ${GREEN}[3]${NC}  Install via Official (pterodactyl-installer.se)"
        echo -e "  ${GREEN}[4]${NC}  Install SSL (standalone)"
        echo -e "  ${RED}[5]${NC}  Hackback Panel (Reset Admin)"
        echo -e "  ${RED}[6]${NC}  Hackback Wings"
        echo -e "  ${YELLOW}[7]${NC}  Update Panel"
        echo -e "  ${YELLOW}[8]${NC}  Repair Panel (fix permission/cache)"
        echo -e "  ${MAGENTA}[9]${NC}  Backup Panel"
        echo -e "  ${MAGENTA}[10]${NC} Restore Panel (dari .sql)"
        echo -e "  ${CYAN}[11]${NC} Cek Status"
        echo -e "  ${RED}[12]${NC} Uninstall Panel"
        echo -e "  ${RED}[13]${NC} Uninstall Wings"
        echo -e "  ${BLUE}[14]${NC} Lihat Log Installer"
        echo -e "  ${RED}[0]${NC}  Keluar"
        echo ""
        echo -ne "  ${BOLD}Pilih opsi [0-14]:${NC} "
        read -r CHOICE
        case "$CHOICE" in
            1)
                prompt_target
                read -rp "  Domain panel: " M_DOMAIN
                read -rp "  Domain node (kosong = sama): " M_NDOMAIN
                [[ -z "$M_NDOMAIN" ]] && M_NDOMAIN="$M_DOMAIN"
                read -rp "  RAM (MB, default 2048): " M_RAM
                [[ -z "$M_RAM" ]] && M_RAM="2048"
                read -rp "  SSL? (yes/no, default no): " M_SSL
                [[ -z "$M_SSL" ]] && M_SSL="no"
                install_panel "$M_IP" "$M_PW" "$M_DOMAIN" "$M_NDOMAIN" "$M_RAM" "$M_SSL"
                ;;
            2)
                prompt_target
                read -rp "  Token auto-deploy (boleh kosong): " M_TOKEN
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
                read -rp "  Email admin baru [admin@localhost.local]: " M_EMAIL
                read -rp "  Password baru (kosong=auto): " M_PASS
                hackback_panel "$M_IP" "$M_PW" \
                    "${M_EMAIL:-admin@localhost.local}" \
                    "${M_PASS:-$(gen_password 14)}"
                ;;
            6)
                prompt_target
                read -rp "  Token auto-deploy (kosong = manual nanti): " M_TOKEN
                hackback_wings "$M_IP" "$M_PW" "$M_TOKEN"
                ;;
            7)  prompt_target; update_panel  "$M_IP" "$M_PW" ;;
            8)  prompt_target; repair_panel  "$M_IP" "$M_PW" ;;
            9)  prompt_target; backup_panel  "$M_IP" "$M_PW" ;;
            10)
                prompt_target
                read -rp "  Path file .sql backup: " M_SQL
                restore_panel "$M_IP" "$M_PW" "$M_SQL"
                ;;
            11) prompt_target; check_status "$M_IP" "$M_PW" ;;
            12) prompt_target; uninstall_panel "$M_IP" "$M_PW" ;;
            13) prompt_target; uninstall_wings "$M_IP" "$M_PW" ;;
            14)
                if [[ -f "$LOG_FILE" ]]; then
                    less +G "$LOG_FILE" 2>/dev/null || tail -n 200 "$LOG_FILE"
                else
                    log_warn "Log belum ada"
                fi
                ;;
            0) echo -e "\n  ${GREEN}Sampai jumpa! 👋${NC}\n"; exit 0 ;;
            *) log_error "Pilihan tidak valid" ;;
        esac
        echo ""
        echo -ne "  ${YELLOW}Tekan ENTER untuk kembali ke menu...${NC}"
        read -r _
    done
}

# =============================================================================
#  HELP
# =============================================================================
show_help() {
    show_banner
    cat <<HLP
  ${BOLD}CARA PAKAI${NC}
    bash $0 menu
    bash $0 panel <ip> <pw> <domain> <nodedomain> <ram> [yes|no]
    bash $0 wings <ip> <pw> [auto-deploy-cmd]
    bash $0 official
    bash $0 ssl <ip> <pw> <domain> <email>
    bash $0 hackback-panel <ip> <pw> [email] [password]
    bash $0 hackback-wings <ip> <pw> [auto-deploy-cmd]
    bash $0 update-panel <ip> <pw>
    bash $0 repair-panel <ip> <pw>
    bash $0 backup-panel <ip> <pw>
    bash $0 restore-panel <ip> <pw> <path.sql>
    bash $0 uninstall-panel <ip> <pw>
    bash $0 uninstall-wings <ip> <pw>
    bash $0 status [ip] [pw]

  ${BOLD}ENV VAR (opsional)${NC}
    PHP_VER=8.3              # default 8.3 (bisa 8.1/8.2/8.3)
    TIMEZONE_OVERRIDE=...    # default Asia/Jakarta
    ASSUME_YES=1             # auto-yes semua konfirmasi
    DEBUG=1                  # verbose output

  ${BOLD}CONTOH${NC}
    sudo bash $0 menu
    sudo bash $0 panel 1.2.3.4 P@ssw0rd panel.example.com node.example.com 4096 yes
    sudo bash $0 wings 1.2.3.4 P@ssw0rd
    sudo bash $0 hackback-panel 1.2.3.4 P@ssw0rd admin@example.com Secret123
    PHP_VER=8.2 ASSUME_YES=1 sudo -E bash $0 panel 1.2.3.4 - panel.example.com node.example.com 2048 no

  ${BOLD}NOTE${NC}
    • Wajib dijalankan sebagai root.
    • Wajib bash >= 4.0 (BUKAN sh).
    • Log: ${LOG_FILE}
    • Backup: ${BACKUP_DIR}
    • Kredensial: ${CRED_DIR}
HLP
}

# =============================================================================
#  ENTRYPOINT
# =============================================================================
main() {
    init_log "$@"
    check_root
    detect_os
    check_internet
    check_disk_space 3000
    check_ram 1024

    local ACTION="${1:-menu}"
    case "$ACTION" in
        panel|install-panel)          install_panel    "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" "${7:-}" ;;
        wings|install-wings)          install_wings    "${2:-}" "${3:-}" "${4:-}" ;;
        official|installer-se)        install_official ;;
        ssl|letsencrypt)              install_ssl      "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
        hackback-panel|hackback)      hackback_panel   "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
        hackback-wings)               hackback_wings   "${2:-}" "${3:-}" "${4:-}" ;;
        uninstall-panel|remove-panel) uninstall_panel  "${2:-}" "${3:-}" ;;
        uninstall-wings|remove-wings) uninstall_wings  "${2:-}" "${3:-}" ;;
        update-panel|update)          update_panel     "${2:-}" "${3:-}" ;;
        repair-panel|repair)          repair_panel     "${2:-}" "${3:-}" ;;
        backup-panel|backup)          backup_panel     "${2:-}" "${3:-}" ;;
        restore-panel|restore)        restore_panel    "${2:-}" "${3:-}" "${4:-}" ;;
        status|check)                 check_status     "${2:-}" "${3:-}" ;;
        menu|interactive|"")          interactive_menu ;;
        help|--help|-h)               show_help ;;
        *)
            log_error "Perintah tidak dikenal: $ACTION"
            show_help
            exit 1
            ;;
    esac
}

main "$@"