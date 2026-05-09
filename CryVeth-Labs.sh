#!/usr/bin/env sh

retry() {
  local n=1
  local max=5
  local delay=3

  until "$@"; do
    if [ $n -ge $max ]; then
      return 1
    fi
    sleep $delay
    n=$((n+1))
  done
}

exec_cmd_build() {
    local IP="$1"
    local PW="$2"
    shift 2

    local CMD=""
    for part in "$@"; do
        CMD+="$(printf "%q " "$part")"
    done

    exec_cmd "$IP" "$PW" "$CMD"
}

# Coba aktifkan pipefail kalau support
set -o pipefail 2>/dev/null || true

# Pastikan bash ada dan versi yang sesuai
if ! command -v bash >/dev/null 2>&1; then
    echo "bash belum ada, mencoba install..."

    # Cek apakah script dijalankan sebagai root
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        echo "Error: Untuk menginstall bash, script harus dijalankan sebagai root atau dengan sudo."
        echo "Jalankan dengan: sudo sh $0 $@"
        exit 1
    fi

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y bash
    elif command -v yum >/dev/null 2>&1; then
        yum install -y bash
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y bash
    else
        echo "Gagal install bash otomatis, install manual ya."
        exit 1
    fi
fi

# Re-eksekusi script dengan bash jika belum
if [ -z "$BASH_VERSION" ]; then
    exec bash "$0" "$@"
fi

if (( BASH_VERSINFO[0] < 4 )); then
    echo "Butuh bash >= 4.0, saat ini: $BASH_VERSION" >&2
    exit 1
fi

# ---------- Konstanta & warna ------------------------------------------------
readonly SCRIPT_VERSION="1.0.1" # Versi diperbarui setelah perbaikan
readonly SCRIPT_NAME="CryVeth Pterodactyl Installer"
LOG_FILE="/var/log/nortex-installer.log"
readonly PANEL_DIR="/var/www/pterodactyl"
readonly WINGS_DIR="/etc/pterodactyl"
readonly BACKUP_DIR="/root/nortex-backups"
readonly CRED_DIR="/root/nortex-credentials"

# Default versi PHP. Bisa di-override pakai env: PHP_VER=8.2 bash nortex.sh ...
PHP_VER="${PHP_VER:-8.3}"

# Warna (auto-disable kalau bukan TTY)
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; BLUE='\033[0;34m'; MAGENTA='\033[0;35m'
    BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BLUE=''; MAGENTA=''
    BOLD=''; DIM=''; NC=''
fi

# Variabel global yang akan diisi
OS_ID=""
OS_VER=""
OS_CODENAME=""
OS_FAMILY=""   # debian | rhel
ARCH=""

# ---------- Logging ----------------------------------------------------------
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

log_info()  { _log_raw "INFO  $*"; echo -e "  ${CYAN}[INFO]${NC}   $*"; }
log_ok()    { _log_raw "OK    $*"; echo -e "  ${GREEN}[OK]${NC}     $*"; }
log_warn()  { _log_raw "WARN  $*"; echo -e "  ${YELLOW}[WARN]${NC}   $*"; }
log_error() { _log_raw "ERROR $*"; echo -e "  ${RED}[ERROR]${NC}  $*" >&2; }
log_step()  { _log_raw "STEP  $*"; echo -e "\n  ${BOLD}${BLUE}▶ $*${NC}"; }
log_debug() { [[ "${DEBUG:-0}" == "1" ]] && echo -e "  ${DIM}[DEBUG] $*${NC}"; _log_raw "DEBUG $*"; }

# Trap error supaya stack trace masuk log
on_error() {
    local exit_code=$?
    local line_no=$1
    log_error "Terjadi error pada line ${line_no} (exit=${exit_code}). Cek log: ${LOG_FILE}"
}
trap 'on_error $LINENO' ERR

# ---------- Banner -----------------------------------------------------------
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

# ---------- Validasi awal ----------------------------------------------------
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
        ubuntu|debian|raspbian|linuxmint|pop)
            OS_FAMILY="debian"
            ;;
        almalinux|rocky|centos|rhel|fedora)
            OS_FAMILY="rhel"
            ;;
        *)
            # Coba deteksi via ID_LIKE
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
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
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
        # fallback http
        if command -v curl >/dev/null 2>&1; then
            if curl -fsS --max-time 5 https://1.1.1.1 >/dev/null 2>&1; then ok=1; fi
        fi
    fi
    if [[ $ok -eq 0 ]]; then
        log_error "Tidak ada koneksi internet!"
        exit 1
    fi
    log_ok "Koneksi internet OK"
}

check_disk_space() {
    local need_mb="${1:-3000}"
    local avail_mb
    avail_mb=$(df -Pm / | awk 'NR==2 {print $4}')
    if [[ -z "$avail_mb" || "$avail_mb" -lt "$need_mb" ]]; then
        log_warn "Disk root <  ${need_mb}MB free (avail=${avail_mb:-?}MB). Lanjutkan dengan risiko."
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

# ---------- Util umum --------------------------------------------------------
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
        echo -ne "  ${YELLOW}${PROMPT} [Y/n]: ${NC}"
    else
        echo -ne "  ${YELLOW}${PROMPT} [y/N]: ${NC}"
    fi
    read -r ANS || ANS=""
    ANS=${ANS:-$DEFAULT}
    [[ "$ANS" =~ ^[Yy]$ ]]
}

# Eksekusi command lokal/remote dengan handling error
ensure_sshpass() {
    if ! command -v sshpass &>/dev/null; then
        log_info "Install sshpass untuk koneksi remote..."
        if [[ "$OS_FAMILY" == "debian" ]]; then
            DEBIAN_FRONTEND=noninteractive apt-get update -qq >>"$LOG_FILE" 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sshpass >>"$LOG_FILE" 2>&1
        else
            yum install -y -q sshpass >>"$LOG_FILE" 2>&1 || dnf install -y -q sshpass >>"$LOG_FILE" 2>&1 || true
        fi
    fi
}

exec_cmd() {
    # Jalankan command pada local atau remote SSH.
    # Args: <ip> <password> <command>
    local IP="$1"
    local PW="$2"
    local CMD="$3"
    if is_local_target "$IP"; then
        bash -c "$CMD"
        return $?
    fi
    ensure_sshpass
    if ! command -v sshpass &>/dev/null; then
        log_error "sshpass tidak tersedia, tidak bisa konek remote."
        return 127
    fi
    sshpass -p "$PW" ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ConnectTimeout=20 \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=4 \
        root@"$IP" "bash -s" <<EOF
$CMD
EOF
    return $?
}

# ---------- Pre-flight package management ------------------------------------
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
        yum install -y -q "$@" >>"$LOG_FILE" 2>&1 || dnf install -y -q "$@" >>"$LOG_FILE" 2>&1 || true
    fi
}

# =============================================================================
#  INSTALL WINGS
# =============================================================================
install_wings() {
    local IP="${1:-}"
    local PW="${2:--}"
    local TOKEN_CMD="${3:-}"

    if [[ -z "$IP" ]]; then
        echo "Format: bash $0 wings <ip> <pwvps> [token]"
        exit 1
    fi

    show_banner
    log_step "🚀 Install Wings Pterodactyl"

    exec_cmd "$IP" "$PW" "
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ======================
# Docker Install (SAFE)
# ======================
if ! command -v docker >/dev/null 2>&1; then
    echo '[INFO] Installing Docker...'

    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    rm -f get-docker.sh

    systemctl enable --now docker
fi

# ======================
# Wings Binary (SAFE)
# ======================
mkdir -p /etc/pterodactyl

curl -fL --retry 3 \
    -o /usr/local/bin/wings \
    https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64

chmod +x /usr/local/bin/wings

# ======================
# Systemd Service (HARDENED)
# ======================
cat > /etc/systemd/system/wings.service <<EOF
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
EOF

systemctl daemon-reload
systemctl enable --now wings

# ======================
# Token deploy (SAFE MODE)
# ======================
if [[ -n \"$TOKEN_CMD\" ]]; then
    echo '[INFO] Running panel token command...'

    cd /etc/pterodactyl

    # JANGAN eval mentah — jalankan sebagai command biasa
    bash -c \"$TOKEN_CMD\" || echo '[WARN] Token command gagal'
else
    echo '[WARN] Token belum diberikan'
    echo 'Ambil dari: Panel → Node → Configuration → Auto Deploy'
fi

systemctl restart wings || true
sleep 2

systemctl status wings --no-pager | head -n 15
"
}
install_official() {
    show_banner
    log_step "🚀 Install Pterodactyl via Official Installer (pterodactyl-installer.se)"
    log_warn "Ini akan menjalankan script dari pihak ketiga. Pastikan Anda mempercayai sumbernya."
    if ! confirm "Lanjutkan instalasi official?" "n"; then
        log_warn "Instalasi dibatalkan."
        exit 0
    fi

    bash <(curl -s https://pterodactyl-installer.se) || { log_error "Instalasi official gagal!"; exit 1; }
    log_ok "Instalasi official selesai."
}

install_ssl() {
    local IP="${1:-}"
    local PW="${2:--}"
    local DOMAIN="${3:-}"
    local EMAIL="${4:-}"

    if [[ -z "$IP" || -z "$DOMAIN" || -z "$EMAIL" ]]; then
        log_error "Parameter kurang!"
        echo -e "  ${YELLOW}Format:${NC} bash $0 ssl <ip> <pwvps> <domain> <email>"
        exit 1
    fi
    if ! validate_ip "$IP"; then
        log_error "Format IP tidak valid: $IP"; exit 1
    fi
    if ! validate_domain "$DOMAIN"; then
        log_error "Format domain tidak valid: $DOMAIN"; exit 1
    fi
    if ! validate_email "$EMAIL"; then
        log_error "Format email tidak valid: $EMAIL"; exit 1
    fi
    [[ -z "$PW" ]] && PW="-"

    show_banner
    log_step "🔒 Install SSL Let's Encrypt (Standalone)"
    log_info "Target IP : $IP"
    log_info "Domain    : $DOMAIN"
    log_info "Email     : $EMAIL"

    if ! confirm "Lanjutkan instalasi SSL?" "y"; then
        log_warn "Instalasi dibatalkan."
        exit 0
    fi

    exec_cmd "$IP" "$PW" "
set -o pipefail
export DEBIAN_FRONTEND=noninteractive

# Install Certbot
if [[ \"$OS_FAMILY\" == \"debian\" ]]; then
    apt-get update -qq
    apt-get install -y -qq certbot
elif [[ \"$OS_FAMILY\" == \"rhel\" ]]; then
    yum install -y -q epel-release
    yum install -y -q certbot
fi

# Stop web server jika berjalan (misal: Nginx)
systemctl reload nginx || systemctl restart nginx 2>/dev/null || true
systemctl stop apache2 2>/dev/null || true

certbot certonly --standalone --non-interactive --agree-tos -m \"${EMAIL}\" -d \"${DOMAIN}\" || { log_error \"Certbot gagal mendapatkan sertifikat!\"; exit 1; }

# Restart web server jika sebelumnya berhenti
systemctl start nginx 2>/dev/null || true
systemctl start apache2 2>/dev/null || true

# Tambahkan cron job untuk renew otomatis
( crontab -l 2>/dev/null | grep -v \"certbot renew\" ; echo \"0 3 * * * certbot renew --quiet --post-hook \\\"systemctl reload nginx 2>/dev/null || systemctl reload apache2 2>/dev/null\\\"\" ) | crontab -

log_ok \"SSL berhasil diinstall dan dikonfigurasi untuk auto-renew.\"
" || { log_error "Instalasi SSL gagal!"; exit 1; }

    log_ok "SSL selesai."
}

hackback_panel() {
    local IP="${1:-}"
    local PW="${2:--}"
    local NEW_EMAIL="${3:-admin@localhost.local}"
    local NEW_PASS="${4:-$(gen_password 14)}"

    if [[ -z "$IP" ]]; then
        log_error "Format: bash $0 hackback-panel <ip> <pwvps> [email_baru] [password_baru]"
        exit 1
    fi
    [[ -z "$PW" ]] && PW="-"

    show_banner
    log_step "🔧 HACKBACK PANEL — Reset admin user"
    log_info "Target IP     : $IP"
    log_info "Email Admin Baru: $NEW_EMAIL"
    log_info "Password Baru : $NEW_PASS"

    if ! confirm "Lanjutkan hackback panel?" "n"; then
        log_warn "Dibatalkan."
        exit 0
    fi

    exec_cmd "$IP" "$PW" "
set -o pipefail
TS=\$(date +%Y%m%d-%H%M%S)
mkdir -p ${BACKUP_DIR}

# Backup database dan .env
if [ -d ${PANEL_DIR} ]; then
    if [ -f ${PANEL_DIR}/.env ]; then
        cp ${PANEL_DIR}/.env ${BACKUP_DIR}/panel.env.\${TS}.bak
        echo \"Backup .env disimpan\"
    fi
    if command -v mysqldump >/dev/null 2>&1; then
        mysqldump -u root panel > ${BACKUP_DIR}/panel-db.\${TS}.sql 2>/dev/null || true
        echo \"Backup database disimpan\"
    else
        log_warn \"mysqldump tidak ditemukan, backup database dilewati.\"
    fi
else
    log_warn \"Direktori panel tidak ditemukan, backup dilewati.\"
fi

cd ${PANEL_DIR} || { log_error \"Direktori panel tidak ditemukan!\"; exit 1; }

php artisan p:user:make \
    --email=\'${NEW_EMAIL}\' \
    --username=\'admin\' \
    --name-first=\'Admin\' \
    --name-last=\'NortexZ\' \
    --password=\'${NEW_PASS}\' \
    --admin=1 \
    --no-interaction || { log_error \"Gagal membuat/reset user admin!\"; exit 1; }

php artisan cache:clear
php artisan config:clear
php artisan view:clear

log_ok \"User admin berhasil direset.\"
" || { log_error "Hackback panel gagal!"; exit 1; }

    local CRED_FILE="${CRED_DIR}/hackback-panel-${IP}-$(date +%Y%m%d-%H%M%S).txt"
    cat >"$CRED_FILE" <<EOF
========================================
  PTERODACTYL PANEL HACKBACK CREDENTIALS
  Generated : $(date)
========================================
Email Admin Baru: ${NEW_EMAIL}
Username Admin  : admin
Password Baru   : ${NEW_PASS}
Backup tersimpan di server: ${BACKUP_DIR}
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
    echo -e "  ${BOLD}📦 Backup        :${NC} ${BACKUP_DIR}"
    echo ""
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
    log_step "🔧 HACKBACK WINGS — Reset konfigurasi Wings"
    log_info "Target IP : $IP"

    if ! confirm "Lanjutkan hackback wings?" "n"; then
        log_warn "Dibatalkan."
        exit 0
    fi

    exec_cmd "$IP" "$PW" "
set -o pipefail
TS=\$(date +%Y%m%d-%H%M%S)
mkdir -p ${BACKUP_DIR}
systemctl stop wings 2>/dev/null || true
if [ -d ${WINGS_DIR} ]; then
    if [ -f ${WINGS_DIR}/config.yml ]; then
        cp ${WINGS_DIR}/config.yml ${BACKUP_DIR}/wings-config.\${TS}.yml.bak
        echo \"Backup config.yml disimpan\"
    fi
fi
mkdir -p ${WINGS_DIR}
" || log_warn "Backup parsial"

    if [[ -n "$NEW_TOKEN" ]]; then
        log_info "Menjalankan token auto-deploy..."
        # NEW_TOKEN biasanya berbentuk: cd /etc/pterodactyl && wings configure --panel-url=... --token=... --node=... --force
        exec_cmd "$IP" "$PW" "
cd ${WINGS_DIR}
eval \"${NEW_TOKEN}\"
" || log_error "Token auto-deploy gagal"
    else
        log_warn "Token tidak diberikan — kamu perlu copy auto-deploy command dari panel"
        echo -e "  ${YELLOW}Caranya: Panel → Admin → Nodes → pilih node → tab Configuration → Generate Token${NC}"
    fi

    exec_cmd "$IP" "$PW" "
systemctl daemon-reload
systemctl enable wings 2>/dev/null || true
systemctl restart wings 2>/dev/null || systemctl start wings 2>/dev/null || true
sleep 2
systemctl status wings --no-pager 2>&1 | head -n 12 || true
" || log_warn "Restart wings gagal"

    echo ""
    echo -e "  ${GREEN}${BOLD}✅  HACKBACK WINGS SELESAI!${NC}"
    echo -e "  ${CYAN}ℹ️  Cek log: journalctl -u wings -f${NC}"
    echo ""
}

# =============================================================================
#  INSTALL PANEL
# =============================================================================
setup_php_repo_remote() {
cat <<'EOF'
set -euo pipefail

. /etc/os-release

install_deps() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg lsb-release
}

install_deps

case "$ID" in
  ubuntu)
    DEBIAN_FRONTEND=noninteractive apt-get install -y software-properties-common
    add-apt-repository -y ppa:ondrej/php
    ;;

  debian)
    mkdir -p /usr/share/keyrings
    curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/sury-php.gpg

    echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" \
      > /etc/apt/sources.list.d/sury-php.list
    ;;
esac

apt-get update -y
EOF
}

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

validate_ip "$IP" || {
    log_error "IP tidak valid: $IP"
    exit 1
}

validate_domain "$DOMAIN" || {
    log_error "Domain tidak valid: $DOMAIN"
    exit 1
}

# fallback aman
PW="${PW:-}"

NODE_DOMAIN="${NODE_DOMAIN:-$DOMAIN}"

# validasi NODE_DOMAIN juga
validate_domain "$NODE_DOMAIN" || {
    log_warn "NODE_DOMAIN invalid, fallback ke DOMAIN"
    NODE_DOMAIN="$DOMAIN"
}

# RAM harus numeric
if ! [[ "$RAM" =~ ^[0-9]+$ ]]; then
    log_warn "RAM tidak valid, fallback ke 2048"
    RAM=2048
fi

USE_SSL=$(echo "$USE_SSL" | tr '[:upper:]' '[:lower:]')

    # ---------- Step 1 ----------
log_step "Step 1/9 — System bootstrap (HARDENED)"

exec_cmd "$IP" "$PW" "
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# Fix broken dpkg state
dpkg --configure -a || true
apt-get -f install -y || true

# Clean system cache biar gak konflik
apt-get clean
rm -rf /var/lib/apt/lists/*

# Update aman
apt-get update -y

# Upgrade tanpa bikin dependency chaos
apt-get upgrade -y --allow-downgrades --allow-change-held-packages || true

# Core tools (dipisah biar gak silent failure)
apt-get install -y \
    curl wget git unzip tar sudo cron jq \
    software-properties-common ca-certificates gnupg lsb-release \
    dnsutils netcat-openbsd ufw

# DB install dipisah (biar gampang debug)
apt-get install -y mariadb-server mariadb-client

systemctl enable mariadb
systemctl start mariadb
"

log_ok "Step 1 stabilized"

    # ---------- Step 2 ----------
log_step "Step 2/9 — Install PHP ${PHP_VER} + ekstensi"

exec_cmd "$IP" "$PW" "
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

$(setup_php_repo_remote)

retry apt-get install -y -qq \
php${PHP_VER} php${PHP_VER}-cli php${PHP_VER}-gd php${PHP_VER}-mysql \
php${PHP_VER}-pdo php${PHP_VER}-mbstring php${PHP_VER}-tokenizer \
php${PHP_VER}-bcmath php${PHP_VER}-xml php${PHP_VER}-fpm \
php${PHP_VER}-curl php${PHP_VER}-zip php${PHP_VER}-intl php${PHP_VER}-readline \
php${PHP_VER}-sqlite3

systemctl enable --now php${PHP_VER}-fpm
"

    # ---------- Step 3 ----------
    log_step "Step 3/9 — Install MariaDB & buat database"
    exec_cmd "$IP" "$PW" "
set -o pipefail
export DEBIAN_FRONTEND=noninteractive
systemctl enable mariadb
systemctl start mariadb
sleep 3

mysql -u root <<SQL
CREATE USER IF NOT EXISTS 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${DB_PASSWORD}';
CREATE DATABASE IF NOT EXISTS panel CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
" || { log_error "Step 3 gagal!"; exit 1; }
    log_ok "MariaDB & database OK"

    # ---------- Step 4 ----------
    log_step "Step 4/9 — Install Redis & Composer"
    exec_cmd "$IP" "$PW" "
set -o pipefail
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq redis-server
systemctl enable --now redis-server
if ! command -v composer >/dev/null 2>&1; then
    EXPECTED_SIG=\$(curl -fsSL https://composer.github.io/installer.sig)
    php -r \"copy('https://getcomposer.org/installer','/tmp/composer-setup.php');\"
    ACTUAL_SIG=\$(php -r \"echo hash_file('sha384','/tmp/composer-setup.php');\")
    if [ \"\$EXPECTED_SIG\" != \"\$ACTUAL_SIG\" ]; then
        exit 1
    fi
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
    rm -f /tmp/composer-setup.php
fi
composer --version || true
" || { log_error "Step 4 gagal!"; exit 1; }
    log_ok "Redis & Composer OK"

    # ---------- Step 5 ----------
log_step "Step 5/9 — Download & extract Panel Pterodactyl"

exec_cmd "$IP" "$PW" '
set -euo pipefail

# ─── Define retry locally inside remote shell ─────────────────────────────────
retry() {
    local max_attempts=3
    local delay=5
    local attempt=1
    until "$@"; do
        if [ "$attempt" -ge "$max_attempts" ]; then
            echo "[RETRY] Command failed after $max_attempts attempts: $*" >&2
            return 1
        fi
        echo "[RETRY] Attempt $attempt failed. Retrying in ${delay}s..." >&2
        sleep "$delay"
        attempt=$(( attempt + 1 ))
        delay=$(( delay * 2 ))   # exponential backoff
    done
}

# ─── Variabel (diekspansi di remote, bukan lokal) ─────────────────────────────
PANEL_DIR="/var/www/pterodactyl"

# ─── Persiapan direktori ──────────────────────────────────────────────────────
mkdir -p "$PANEL_DIR"
cd "$PANEL_DIR"

# ─── Download panel ───────────────────────────────────────────────────────────
retry curl -fsSL --retry 3 --retry-delay 5 \
    -o panel.tar.gz \
    https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz

# ─── Verifikasi file sebelum extract ─────────────────────────────────────────
if [ ! -s panel.tar.gz ]; then
    echo "[ERROR] panel.tar.gz kosong atau tidak terdownload!" >&2
    exit 1
fi

tar -xzf panel.tar.gz
rm -f panel.tar.gz

# ─── Permission ───────────────────────────────────────────────────────────────
chmod -R 755 storage bootstrap/cache 2>/dev/null || true
chown -R www-data:www-data "$PANEL_DIR" 2>/dev/null || true

# ─── Setup .env ───────────────────────────────────────────────────────────────
if [ ! -f .env ]; then
    if [ -f .env.example ]; then
        cp .env.example .env
        echo "[INFO] .env dibuat dari .env.example"
    else
        echo "[ERROR] .env.example tidak ditemukan!" >&2
        exit 1
    fi
fi

# ─── Cek PHP extension yang wajib ada ────────────────────────────────────────
REQUIRED_EXTENSIONS="curl pdo pdo_mysql mbstring xml bcmath zip"
MISSING=""
for ext in $REQUIRED_EXTENSIONS; do
    if ! php -m 2>/dev/null | grep -qi "^${ext}$"; then
        MISSING="$MISSING $ext"
    fi
done
if [ -n "$MISSING" ]; then
    echo "[ERROR] PHP extension hilang:$MISSING" >&2
    echo "[INFO]  Jalankan: apt install -y php-{curl,pdo,pdo-mysql,mbstring,xml,bcmath,zip}" >&2
    exit 1
fi

# ─── Cek Composer tersedia ────────────────────────────────────────────────────
if ! command -v composer &>/dev/null; then
    echo "[INFO] Composer tidak ditemukan, menginstall..." >&2
    EXPECTED_CHECKSUM="$(curl -fsSL https://composer.github.io/installer.sig)"
    php -r "copy('\''https://getcomposer.org/installer'\'', '\''composer-setup.php'\'');"
    ACTUAL_CHECKSUM="$(php -r "echo hash_file('\''sha384'\'', '\''composer-setup.php'\'');")"
    if [ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]; then
        echo "[ERROR] Composer installer checksum tidak valid!" >&2
        rm -f composer-setup.php
        exit 1
    fi
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
    rm -f composer-setup.php
fi

# ─── Install dependensi PHP ───────────────────────────────────────────────────
COMPOSER_ALLOW_SUPERUSER=1 retry composer install \
    --no-dev \
    --optimize-autoloader \
    --no-interaction \
    --no-progress

# ─── Generate app key (hanya jika belum ada) ─────────────────────────────────
if ! grep -q "^APP_KEY=base64:" .env 2>/dev/null; then
    retry php artisan key:generate --force
    echo "[INFO] APP_KEY berhasil digenerate"
else
    echo "[INFO] APP_KEY sudah ada, skip generate"
fi

echo "[OK] Panel Pterodactyl berhasil didownload dan dikonfigurasi"
' || { log_error "Step 5 gagal!"; exit 1; }

log_ok "Panel terdownload"

DOMAIN="$(echo "${DOMAIN:-}" | tr -d '[:space:]')"
ADMIN_EMAIL="$(echo "${ADMIN_EMAIL:-}" | tr -d '[:space:]')"
ADMIN_PASSWORD="$(echo "${ADMIN_PASSWORD:-}" | tr -d '\n\r')"
DB_PASSWORD="$(echo "${DB_PASSWORD:-}" | tr -d '\n\r')"

[[ -z "$DOMAIN" ]] && { log_error "DOMAIN kosong"; exit 1; }

if [[ -z "$ADMIN_EMAIL" || "$ADMIN_EMAIL" == "admin@" || "$ADMIN_EMAIL" == "@" ]]; then
    ADMIN_EMAIL="admin@${DOMAIN}"
fi

if [[ ! "$ADMIN_EMAIL" =~ ^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$ ]]; then
    log_error "ADMIN_EMAIL tidak valid: '$ADMIN_EMAIL'"
    exit 1
fi

[[ -z "$ADMIN_PASSWORD" ]] && ADMIN_PASSWORD="$(openssl rand -base64 18 | tr -d '\n\r')"
[[ -z "$DB_PASSWORD" ]] && DB_PASSWORD="$(openssl rand -base64 24 | tr -d '\n\r')"

[[ -z "$ADMIN_PASSWORD" ]] && { log_error "ADMIN_PASSWORD gagal generate"; exit 1; }
[[ -z "$DB_PASSWORD" ]] && { log_error "DB_PASSWORD gagal generate"; exit 1; }

log_step "Step 6/9 — Konfigurasi environment & user admin"

exec_cmd "$IP" "$PW" "
set -euo pipefail
cd '${PANEL_DIR}'

EMAIL='${ADMIN_EMAIL}'
APASS='${ADMIN_PASSWORD}'
DBPASS='${DB_PASSWORD}'

[[ -z \"\$EMAIL\" ]] && exit 1
[[ -z \"\$APASS\" ]] && exit 1
[[ -z \"\$DBPASS\" ]] && exit 1

php artisan p:environment:setup \
    --author=\"\$EMAIL\" \
    --url='${APP_URL}' \
    --timezone='${TIMEZONE}' \
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
    --password=\"\$DBPASS\" \
    --no-interaction

php artisan migrate --seed --force

php artisan p:user:make \
    --email=\"\$EMAIL\" \
    --username=admin \
    --name-first=Admin \
    --name-last=User \
    --password=\"\$APASS\" \
    --admin=1 \
    --no-interaction || true
"


# ---------- Step 7: Nginx ----------
log_step "Step 7/9 — Nginx"

_NGINX_CONF=$(cat <<HEREDOC
server {
    listen 80;
    server_name ${DOMAIN};

    root ${PANEL_DIR}/public;
    index index.php;

    client_max_body_size 100m;
    add_header X-Content-Type-Options "nosniff";
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
HEREDOC
)
_NGINX_B64=$(printf '%s' "$_NGINX_CONF" | base64 -w0)

exec_cmd "$IP" "$PW" "
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

retry apt-get install -y -qq nginx

rm -f /etc/nginx/sites-enabled/default

# Decode & tulis config (aman dari escaping issues)
echo '${_NGINX_B64}' | base64 -d > /etc/nginx/sites-available/pterodactyl.conf

ln -sf /etc/nginx/sites-available/pterodactyl.conf \
        /etc/nginx/sites-enabled/pterodactyl.conf

# Validasi config dulu sebelum apply
nginx -t 2>&1 || {
    echo '[ERROR] nginx config invalid, isi file:'
    cat /etc/nginx/sites-available/pterodactyl.conf
    exit 1
}

systemctl enable nginx
systemctl restart nginx

# Pastikan nginx benar-benar running
sleep 1
systemctl is-active --quiet nginx || {
    echo '[ERROR] nginx gagal start:'
    systemctl status nginx --no-pager
    exit 1
}

# Restart PHP-FPM agar socket tersedia untuk nginx
systemctl restart php${PHP_VER}-fpm
systemctl is-active --quiet php${PHP_VER}-fpm || {
    echo '[ERROR] PHP-FPM gagal start:'
    systemctl status php${PHP_VER}-fpm --no-pager
    exit 1
}
" || { log_error "Step 7 (Nginx) gagal!"; exit 1; }
log_ok "Nginx & PHP-FPM OK"

    # ---------- Step 8 SSL ---------
if [[ "$USE_SSL" == "yes" ]]; then
    log_step "Step 8/9 — Install SSL Let's Encrypt"
    _NGINX_SSL_CONF=$(cat <<HEREDOC
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    root ${PANEL_DIR}/public;
    index index.php;

    client_max_body_size 100m;
    add_header X-Content-Type-Options "nosniff";
    add_header X-Frame-Options SAMEORIGIN;
    add_header Strict-Transport-Security "max-age=31536000" always;

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
HEREDOC
)
    _NGINX_SSL_B64=$(printf '%s' "$_NGINX_SSL_CONF" | base64 -w0)

    exec_cmd "$IP" "$PW" "
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

retry apt-get install -y -qq certbot python3-certbot-nginx

# Pastikan port 80 bisa diakses certbot (nginx tetap jalan, certbot pakai plugin nginx)
echo '[8/9] >>> Requesting certificate via certbot --nginx plugin'
certbot certonly \
    --nginx \
    --non-interactive \
    --agree-tos \
    -m '${ADMIN_EMAIL}' \
    -d '${DOMAIN}' 2>&1 || {
        echo '[ERROR] certbot gagal mendapatkan sertifikat.'
        echo '        Pastikan domain ${DOMAIN} sudah mengarah ke IP ini'
        echo '        dan port 80 tidak diblokir firewall upstream.'
        exit 1
}

echo '[8/9] >>> Deploy nginx config HTTPS'
echo '${_NGINX_SSL_B64}' | base64 -d > /etc/nginx/sites-available/pterodactyl.conf

nginx -t 2>&1 || {
    echo '[ERROR] nginx config SSL invalid, isi file:'
    cat /etc/nginx/sites-available/pterodactyl.conf
    exit 1
}

systemctl reload nginx

# Verifikasi HTTPS benar-benar jalan
sleep 2
curl -fsS --max-time 10 \
    --resolve '${DOMAIN}:443:127.0.0.1' \
    https://${DOMAIN} >/dev/null && echo '[OK] HTTPS verified' || {
    echo '[WARN] HTTPS belum merespons (mungkin DNS belum propagate), tapi cert sudah terpasang'
}

# Auto-renew cron (idempoten, no duplicate)
( crontab -l 2>/dev/null | grep -v 'certbot renew' ; \
  echo '0 3 * * * certbot renew --quiet --post-hook \"systemctl reload nginx\"' \
) | crontab -

echo '[8/9] >>> Cron renew terpasang'
" || { log_error "Step 8 (SSL) gagal!"; exit 1; }

    log_ok "SSL Let's Encrypt OK"

else
    log_step "Step 8/9 — SSL dilewati (HTTP only)"
    log_ok "Skipped"
fi


# ---------- Step 9: Cron + Queue + Firewall ----------
log_step "Step 9/9 — Cron, Queue Worker, Firewall"

_PTEROQ_SVC=$(cat <<HEREDOC
[Unit]
Description=Pterodactyl Queue Worker
After=network.target redis-server.service mysql.service
Wants=redis-server.service

[Service]
User=www-data
Group=www-data
WorkingDirectory=${PANEL_DIR}
ExecStart=/usr/bin/php ${PANEL_DIR}/artisan queue:work \
    --queue=high,standard,low \
    --sleep=3 \
    --tries=3 \
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
HEREDOC
)
_PTEROQ_B64=$(printf '%s' "$_PTEROQ_SVC" | base64 -w0)

exec_cmd "$IP" "$PW" "
set -euo pipefail

# --- Cron Pterodactyl (idempoten) ---
echo '[9/9] >>> Setup artisan schedule cron'
( crontab -l 2>/dev/null | grep -v 'artisan schedule:run' ; \
  echo '* * * * * /usr/bin/php ${PANEL_DIR}/artisan schedule:run >> /dev/null 2>&1' \
) | crontab -

# --- Queue Worker systemd ---
echo '[9/9] >>> Deploy pteroq.service'
echo '${_PTEROQ_B64}' | base64 -d > /etc/systemd/system/pteroq.service

systemctl daemon-reload
systemctl enable pteroq
systemctl restart pteroq
sleep 2

systemctl is-active --quiet pteroq || {
    echo '[ERROR] pteroq gagal start:'
    systemctl status pteroq --no-pager -l
    exit 1
}
echo '[OK] pteroq aktif'

# --- UFW Firewall ---
echo '[9/9] >>> Setup UFW'
if command -v ufw >/dev/null 2>&1; then
    ufw allow 22/tcp   comment 'SSH'    >/dev/null 2>&1 || true
    ufw allow 80/tcp   comment 'HTTP'   >/dev/null 2>&1 || true
    ufw allow 443/tcp  comment 'HTTPS'  >/dev/null 2>&1 || true

    # --force aman, tidak interactive, tidak lock out SSH (rule 22 sudah di-set atas)
    ufw --force enable >/dev/null 2>&1 || true
    ufw status verbose
else
    echo '[WARN] ufw tidak tersedia, skip firewall setup'
fi
" || { log_error "Step 9 gagal!"; exit 1; }


# --- Health Check Final ---
log_step "Health Check Final"

exec_cmd "$IP" "$PW" "
set -euo pipefail

_fail=0

echo '--- HTTP check ---'
HTTP_CODE=\$(curl -o /dev/null -s -w '%{http_code}' \
    --max-time 10 http://127.0.0.1 || echo '000')
if [[ \"\$HTTP_CODE\" =~ ^(200|301|302)$ ]]; then
    echo \"[OK] HTTP → \$HTTP_CODE\"
else
    echo \"[WARN] HTTP → \$HTTP_CODE (mungkin domain belum propagate)\"
fi

echo '--- HTTPS check ---'
if [[ -d '/etc/letsencrypt/live/${DOMAIN}' ]]; then
    HTTPS_CODE=\$(curl -o /dev/null -s -w '%{http_code}' \
        --max-time 10 \
        --resolve '${DOMAIN}:443:127.0.0.1' \
        https://${DOMAIN} || echo '000')
    if [[ \"\$HTTPS_CODE\" =~ ^(200|301|302)$ ]]; then
        echo \"[OK] HTTPS → \$HTTPS_CODE\"
    else
        echo \"[WARN] HTTPS → \$HTTPS_CODE\"
        _fail=1
    fi
else
    echo '[SKIP] No SSL cert found, skipping HTTPS check'
fi

echo '--- Service status ---'
for svc in nginx php${PHP_VER}-fpm redis-server mysql pteroq; do
    if systemctl is-active --quiet \"\$svc\" 2>/dev/null; then
        echo \"[OK] \$svc running\"
    else
        echo \"[WARN] \$svc tidak aktif\"
        _fail=1
    fi
done

exit \$_fail
" && log_ok "Health check OK" || log_error "Ada service yang tidak aktif, cek log di atas"
}

uninstall_panel() {
    local IP="${1:-}"
    local PW="${2:--}"
    if [[ -z "$IP" ]]; then
        log_error "Format: bash $0 uninstall-panel <ip> <pwvps>"; exit 1
    fi
    [[ -z "$PW" ]] && PW="-"

    show_banner
    echo -e "  ${RED}${BOLD}🗑️  UNINSTALL PANEL${NC}\n"
    echo -ne "  Ketik ${BOLD}HAPUS PANEL${NC} untuk konfirmasi: "
    read -r CONFIRM
    if [[ "$CONFIRM" != "HAPUS PANEL" ]]; then
        log_warn "Dibatalkan."; exit 0
    fi

    exec_cmd "$IP" "$PW" "
set -o pipefail
systemctl stop pteroq 2>/dev/null || true
systemctl disable pteroq 2>/dev/null || true
rm -f /etc/systemd/system/pteroq.service
systemctl daemon-reload

systemctl reload nginx || systemctl restart nginx 2>/dev/null || true
systemctl disable nginx 2>/dev/null || true
rm -f /etc/nginx/sites-enabled/pterodactyl.conf
rm -f /etc/nginx/sites-available/pterodactyl.conf
systemctl reload nginx 2>/dev/null || true

systemctl stop php${PHP_VER}-fpm 2>/dev/null || true
apt-get purge -y -qq php${PHP_VER}* mariadb-server mariadb-client nginx redis-server software-properties-common || true
apt-get autoremove -y -qq || true

rm -rf ${PANEL_DIR}

mysql -u root -e \"DROP DATABASE IF EXISTS panel;\" 2>/dev/null || true
mysql -u root -e \"DROP USER IF EXISTS 'pterodactyl'@'127.0.0.1';\" 2>/dev/null || true

crontab -l | grep -v 'pterodactyl/artisan' | crontab -

echo 'Panel removed.'
" || log_warn "Uninstall parsial"
    echo -e "\n  ${GREEN}${BOLD}✅  Panel berhasil diuninstall!${NC}\n"
}

uninstall_wings() {
    local IP="${1:-}"
    local PW="${2:--}"
    if [[ -z "$IP" ]]; then
        log_error "Format: bash $0 uninstall-wings <ip> <pwvps>"; exit 1
    fi
    [[ -z "$PW" ]] && PW="-"

    show_banner
    echo -e "  ${RED}${BOLD}🗑️  UNINSTALL WINGS${NC}\n"
    echo -ne "  Ketik ${BOLD}HAPUS WINGS${NC} untuk konfirmasi: "
    read -r CONFIRM
    if [[ "$CONFIRM" != "HAPUS WINGS" ]]; then
        log_warn "Dibatalkan."; exit 0
    fi

    exec_cmd "$IP" "$PW" "
systemctl stop wings 2>/dev/null || true
systemctl disable wings 2>/dev/null || true
docker ps -a --filter 'name=pterodactyl' -q | xargs -r docker rm -f 2>/dev/null || true
rm -f /usr/local/bin/wings
rm -rf ${WINGS_DIR}
rm -f /etc/systemd/system/wings.service
systemctl daemon-reload

# Hapus Docker jika tidak ada container lain yang berjalan
if [ -z \"$(docker ps -a -q)\" ]; then
    log_info \"Tidak ada container Docker lain, menghapus Docker.\"
    apt-get purge -y -qq docker-ce docker-ce-cli containerd.io || true
    rm -rf /var/lib/docker
else
    log_warn \"Container Docker lain terdeteksi, Docker tidak dihapus.\"
fi

echo 'Wings removed.'
" || log_warn "Uninstall parsial"
    echo -e "\n  ${GREEN}${BOLD}✅  Wings berhasil diuninstall!${NC}\n"
}

# =============================================================================
#  UPDATE PANEL
# =============================================================================
update_panel() {
    local IP="${1:-}"
    local PW="${2:--}"
    if [[ -z "$IP" ]]; then
        log_error "Format: bash $0 update-panel <ip> <pwvps>"; exit 1
    fi
    [[ -z "$PW" ]] && PW="-"

    show_banner
    log_step "♻️  Update Panel Pterodactyl"
    if ! confirm "Lanjutkan update?" "y"; then exit 0; fi

    exec_cmd "$IP" "$PW" "
set -o pipefail
cd ${PANEL_DIR} || { echo 'Panel tidak ditemukan!'; exit 1; }
TS=\$(date +%Y%m%d-%H%M%S)
mkdir -p ${BACKUP_DIR}
cp .env ${BACKUP_DIR}/panel.env.\${TS}.bak 2>/dev/null || true

if command -v mysqldump >/dev/null 2>&1; then
    mysqldump -u root panel > ${BACKUP_DIR}/panel-db.\${TS}.sql 2>/dev/null || true
else
    log_warn \"mysqldump tidak ditemukan, backup database dilewati.\"
fi

php artisan down || true
curl -fL --retry 3 https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz | tar -xz
chmod -R 755 storage bootstrap/cache || true
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction
php artisan view:clear
php artisan config:clear
php artisan migrate --seed --force
chown -R www-data:www-data ${PANEL_DIR}
php artisan queue:restart
php artisan up
" || { log_error "Update gagal!"; exit 1; }
    log_ok "Panel berhasil diupdate"
}

# =============================================================================
#  STATUS
# =============================================================================
check_status() {
    local IP="${1:-127.0.0.1}"
    local PW="${2:--}"

    show_banner
    log_step "📊 Status layanan di $IP"
    exec_cmd "$IP" "$PW" "
echo '── Service Status ──'
for svc in nginx php${PHP_VER}-fpm php8.2-fpm php8.1-fpm mariadb mysql redis-server redis pteroq wings docker; do
    if systemctl list-unit-files 2>/dev/null | grep -q \"^\${svc}\\.service\"; then
        STATUS=\$(systemctl is-active \${svc} 2>/dev/null)
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

# =============================================================================
#  BACKUP & RESTORE (fitur tambahan)
# =============================================================================
backup_panel() {
    local IP="${1:-127.0.0.1}"
    local PW="${2:--}"
    [[ -z "$PW" ]] && PW="-"

    show_banner
    log_step "💾 Backup Panel"
    exec_cmd "$IP" "$PW" "
set -o pipefail
TS=\$(date +%Y%m%d-%H%M%S)
mkdir -p ${BACKUP_DIR}
cp ${PANEL_DIR}/.env ${BACKUP_DIR}/panel.env.\${TS}.bak 2>/dev/null || true

if command -v mysqldump >/dev/null 2>&1; then
    mysqldump -u root panel > ${BACKUP_DIR}/panel-db.\${TS}.sql 2>/dev/null || true
else
    log_warn \"mysqldump tidak ditemukan, backup database dilewati.\"
fi

tar -czf ${BACKUP_DIR}/panel-files.\${TS}.tar.gz -C $(dirname ${PANEL_DIR}) $(basename ${PANEL_DIR}) 2>/dev/null || true
ls -lh ${BACKUP_DIR}/*\${TS}* 2>/dev/null || true
echo 'Backup selesai.'
" || log_error "Backup gagal"
    log_ok "Backup tersimpan di ${BACKUP_DIR}"
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
    log_step "♻️  Restore Database Panel dari $SQL_FILE"
    if ! confirm "Yakin? ini akan menimpa database 'panel' saat ini." "n"; then exit 0; fi
    exec_cmd "$IP" "$PW" "
set -o pipefail
mysql -u root panel < \'${SQL_FILE}\' || { log_error \"Gagal restore database!\"; exit 1; }
cd ${PANEL_DIR} && php artisan migrate --force && php artisan optimize:clear
echo 'Restore selesai.'
" || log_error "Restore gagal"
}

# =============================================================================
#  REPAIR (fitur tambahan) — fix permission, restart service, clear cache
# =============================================================================
repair_panel() {
    local IP="${1:-127.0.0.1}"
    local PW="${2:--}"
    [[ -z "$PW" ]] && PW="-"

    show_banner
    log_step "🛠️  Repair Panel — fix permission, cache, service"
    exec_cmd "$IP" "$PW" "
set -o pipefail
cd ${PANEL_DIR} || { echo 'Panel tidak ditemukan!'; exit 1; }
chown -R www-data:www-data ${PANEL_DIR}
find ${PANEL_DIR} -type d -exec chmod 755 {} \;
find ${PANEL_DIR} -type f -exec chmod 644 {} \;
chmod -R 775 ${PANEL_DIR}/storage ${PANEL_DIR}/bootstrap/cache
chown -R www-data:www-data ${PANEL_DIR}/storage ${PANEL_DIR}/bootstrap/cache
php artisan optimize:clear
php artisan queue:restart
systemctl restart php${PHP_VER}-fpm 2>/dev/null || true
systemctl reload nginx 2>/dev/null || true
systemctl restart pteroq 2>/dev/null || true
echo 'Repair selesai.'
" || log_warn "Repair parsial"
    log_ok "Repair selesai"
}

# =============================================================================
#  MENU INTERAKTIF
# =============================================================================
prompt_target() {
    # Menyimpan ke variabel global M_IP & M_PW
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
                hackback_panel "$M_IP" "$M_PW" "${M_EMAIL:-admin@localhost.local}" "${M_PASS:-$(gen_password 14)}"
                ;;
            6)
                prompt_target
                read -rp "  Token auto-deploy (kosong = manual nanti): " M_TOKEN
                hackback_wings "$M_IP" "$M_PW" "$M_TOKEN"
                ;;
            7) prompt_target; update_panel "$M_IP" "$M_PW" ;;
            8) prompt_target; repair_panel "$M_IP" "$M_PW" ;;
            9) prompt_target; backup_panel "$M_IP" "$M_PW" ;;
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
    bash $0 menu                                       # Menu interaktif
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

  ${BOLD}ENV VAR (opsional)${NC}
    PHP_VER=8.3            # default 8.3, bisa 8.1/8.2/8.3
    TIMEZONE_OVERRIDE=...  # default Asia/Jakarta
    ASSUME_YES=1           # auto-yes semua konfirmasi
    DEBUG=1                # verbose

  ${BOLD}CONTOH${NC}
    sudo bash $0 menu
    sudo bash $0 panel 1.2.3.4 P@ssw0rd panel.example.com node.example.com 4096 yes
    sudo bash $0 wings 1.2.3.4 P@ssw0rd "cd /etc/pterodactyl && wings configure --panel-url=... --token=... --node=1"
    sudo bash $0 hackback-panel 1.2.3.4 P@ssw0rd myadmin@example.com NewSecret123
    PHP_VER=8.2 ASSUME_YES=1 sudo -E bash $0 panel 1.2.3.4 - panel.example.com node.example.com 2048 no

  ${BOLD}NOTE${NC}
    • Wajib dijalankan sebagai root.
    • Wajib pakai bash (BUKAN sh). Kalau dapat error '=~' kemungkinan kamu pakai sh.
    • Log lengkap : ${LOG_FILE}
    • Backup     : ${BACKUP_DIR}
    • Kredensial : ${CRED_DIR}
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
            log_error "Perintah tidak dikenal: $ACTION"
            show_help
            exit 1
            ;;
    esac
}

main "$@"