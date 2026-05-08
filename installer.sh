#!/usr/bin/env sh

# Coba aktifkan pipefail kalau support
set -o pipefail 2>/dev/null || true

# Pastikan bash ada
if ! command -v bash >/dev/null 2>&1; then
    echo "bash belum ada, mencoba install..."

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

exec bash "$0" "$@"

if (( BASH_VERSINFO[0] < 4 )); then
    echo "Butuh bash >= 4.0, saat ini: $BASH_VERSION" >&2
    exit 1
fi

# ---------- Konstanta & warna ------------------------------------------------
readonly SCRIPT_VERSION="1.0.0"
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
            -o Dpkg::Options::=--force-confdef \
            -o Dpkg::Options::=--force-confold \
            "$@" >>"$LOG_FILE" 2>&1
    else
        yum install -y -q "$@" >>"$LOG_FILE" 2>&1 || dnf install -y -q "$@" >>"$LOG_FILE" 2>&1
    fi
}

install_basic_tools_local() {
    log_info "Menginstall tool dasar (curl, wget, tar, jq, dll)..."
    pkg_update
    if [[ "$OS_FAMILY" == "debian" ]]; then
        pkg_install curl wget tar unzip git ca-certificates gnupg lsb-release \
            software-properties-common apt-transport-https jq cron sudo \
            iproute2 dnsutils netcat-openbsd
    else
        pkg_install curl wget tar unzip git ca-certificates gnupg jq cronie sudo \
            iproute dnsutils nmap-ncat
        systemctl enable --now crond >>"$LOG_FILE" 2>&1 || true
    fi
}

# =============================================================================
#  HACKBACK PANEL — reset admin & ambil kembali kontrol panel
# =============================================================================
hackback_panel() {
    local IP="${1:-}"
    local PW="${2:--}"
    local NEW_EMAIL="${3:-admin@localhost.local}"
    local NEW_PASS="${4:-$(gen_password 14)}"

    if [[ -z "$IP" ]]; then
        log_error "Format: bash $0 hackback-panel <ip> <pwvps> [email] [password]"
        echo -e "  ${YELLOW}Contoh:${NC} bash $0 hackback-panel 1.2.3.4 P@ssw0rd myadmin@panel.com NewPass123"
        exit 1
    fi
    [[ -z "$PW" ]] && PW="-"

    if ! validate_email "$NEW_EMAIL"; then
        log_error "Format email tidak valid: $NEW_EMAIL"
        exit 1
    fi

    show_banner
    log_step "🔐 HACKBACK PANEL — Reset Admin & Recovery"
    log_info "Target IP        : $IP"
    log_info "Email Admin Baru : $NEW_EMAIL"
    log_info "Password Baru    : $NEW_PASS"
    echo ""
    echo -e "  ${YELLOW}⚠️  Pastikan kamu adalah pemilik server. Operasi ini akan${NC}"
    echo -e "  ${YELLOW}    mereset user admin & menon-aktifkan 2FA semua user.${NC}"
    echo ""

    if ! confirm "Lanjutkan hackback panel?" "n"; then
        log_warn "Dibatalkan oleh user."
        exit 0
    fi

    # ---------- Step 1: Backup ----------
    log_step "Step 1/4 — Backup .env & database panel"
    exec_cmd "$IP" "$PW" "
set -o pipefail
TS=\$(date +%Y%m%d-%H%M%S)
mkdir -p ${BACKUP_DIR}
if [ ! -d ${PANEL_DIR} ]; then
    echo 'ERROR: Panel tidak ditemukan di ${PANEL_DIR}' >&2
    exit 1
fi
cd ${PANEL_DIR}
if [ -f .env ]; then
    cp .env ${BACKUP_DIR}/panel.env.\${TS}.bak
    echo \"Backup .env -> ${BACKUP_DIR}/panel.env.\${TS}.bak\"
fi
# Coba dump pakai kredensial dari .env
DB_DATABASE=\$(grep -E '^DB_DATABASE=' .env 2>/dev/null | cut -d= -f2 | tr -d '\"' || true)
DB_USERNAME=\$(grep -E '^DB_USERNAME=' .env 2>/dev/null | cut -d= -f2 | tr -d '\"' || true)
DB_PASSWORD=\$(grep -E '^DB_PASSWORD=' .env 2>/dev/null | cut -d= -f2 | tr -d '\"' || true)
DB_DATABASE=\${DB_DATABASE:-panel}
if [ -n \"\$DB_USERNAME\" ] && [ -n \"\$DB_PASSWORD\" ]; then
    mysqldump -u\"\$DB_USERNAME\" -p\"\$DB_PASSWORD\" \"\$DB_DATABASE\" > ${BACKUP_DIR}/panel-db.\${TS}.sql 2>/dev/null \
        || mysqldump -u root \"\$DB_DATABASE\" > ${BACKUP_DIR}/panel-db.\${TS}.sql 2>/dev/null \
        || echo 'WARN: dump database gagal'
else
    mysqldump -u root \"\$DB_DATABASE\" > ${BACKUP_DIR}/panel-db.\${TS}.sql 2>/dev/null || echo 'WARN: dump database gagal'
fi
echo \"Backup DB selesai\"
" || { log_error "Backup gagal!"; exit 1; }
    log_ok "Backup selesai (lihat ${BACKUP_DIR})"

    # ---------- Step 2: Reset password admin ----------
    log_step "Step 2/4 — Reset password admin via artisan"
    exec_cmd "$IP" "$PW" "
cd ${PANEL_DIR} || exit 1
NEW_EMAIL='${NEW_EMAIL}'
NEW_PASS='${NEW_PASS}'

# 1) Coba command resmi pterodactyl
if php artisan p:user:make --email=\"\$NEW_EMAIL\" --username=admin --name-first=Admin --name-last=Recovery --password=\"\$NEW_PASS\" --admin=1 --no-interaction 2>/dev/null; then
    echo 'User admin baru berhasil dibuat lewat p:user:make'
else
    echo 'p:user:make gagal/sudah ada, lanjut update via tinker...'
fi

# 2) Update via tinker (pakai heredoc agar aman dari escape)
php artisan tinker --execute=\"
try {
    \\\$user = \\App\\Models\\User::where('email', '\$NEW_EMAIL')->first();
    if (!\\\$user) { \\\$user = \\App\\Models\\User::where('username', 'admin')->first(); }
    if (!\\\$user) { \\\$user = \\App\\Models\\User::orderBy('id','asc')->first(); }
    if (\\\$user) {
        \\\$user->email = '\$NEW_EMAIL';
        \\\$user->username = 'admin';
        \\\$user->password = bcrypt('\$NEW_PASS');
        \\\$user->root_admin = 1;
        if (\\Schema::hasColumn('users','use_totp')) { \\\$user->use_totp = 0; }
        if (\\Schema::hasColumn('users','totp_secret')) { \\\$user->totp_secret = null; }
        if (\\Schema::hasColumn('users','google2fa_secret')) { \\\$user->google2fa_secret = null; }
        \\\$user->save();
        echo 'User di-reset: id=' . \\\$user->id . ' email=' . \\\$user->email . PHP_EOL;
    } else {
        echo 'Tidak ada user di tabel users.' . PHP_EOL;
    }
} catch (\\Throwable \\\$e) {
    echo 'TINKER ERROR: ' . \\\$e->getMessage() . PHP_EOL;
}
\" 2>&1 || true
" || log_warn "Reset via artisan mungkin parsial, lanjut..."
    log_ok "Reset password admin selesai"

    # ---------- Step 3: Disable 2FA ----------
    log_step "Step 3/4 — Nonaktifkan 2FA semua user & clear cache"
    exec_cmd "$IP" "$PW" "
cd ${PANEL_DIR} || exit 1
php artisan tinker --execute=\"
try {
    \\\$users = \\App\\Models\\User::all();
    foreach (\\\$users as \\\$u) {
        if (\\Schema::hasColumn('users','use_totp')) { \\\$u->use_totp = 0; }
        if (\\Schema::hasColumn('users','totp_secret')) { \\\$u->totp_secret = null; }
        if (\\Schema::hasColumn('users','google2fa_secret')) { \\\$u->google2fa_secret = null; }
        \\\$u->save();
    }
    echo '2FA dinonaktifkan untuk semua user (' . count(\\\$users) . ' user).' . PHP_EOL;
} catch(\\Throwable \\\$e) {
    echo 'ERR: ' . \\\$e->getMessage() . PHP_EOL;
}
\" 2>&1 || true

php artisan cache:clear  2>/dev/null || true
php artisan config:clear 2>/dev/null || true
php artisan view:clear   2>/dev/null || true
php artisan route:clear  2>/dev/null || true
php artisan optimize:clear 2>/dev/null || true
echo '2FA & cache: done'
" || log_warn "Disable 2FA mungkin parsial."
    log_ok "2FA dinonaktifkan & cache dibersihkan"

    # ---------- Step 4: Verifikasi ----------
    log_step "Step 4/4 — Verifikasi service & simpan kredensial"
    exec_cmd "$IP" "$PW" "
echo ''
echo '=== STATUS SERVICE ==='
for svc in nginx php${PHP_VER}-fpm php8.2-fpm php8.1-fpm mariadb mysql redis-server redis pteroq; do
    if systemctl list-unit-files 2>/dev/null | grep -q \"^\${svc}\"; then
        printf '  %-22s : %s\n' \"\$svc\" \"\$(systemctl is-active \$svc 2>/dev/null)\"
    fi
done
echo ''
echo 'HACKBACK COMPLETE!'
" || log_warn "Verifikasi sebagian gagal"

    # Simpan kredensial lokal & remote
    local CRED_FILE="${CRED_DIR}/hackback-${IP}-$(date +%Y%m%d-%H%M%S).txt"
    cat >"$CRED_FILE" <<EOF
========================================
  HACKBACK PANEL RECOVERY
  Generated : $(date)
  Target IP : ${IP}
========================================
Email Admin Baru : ${NEW_EMAIL}
Username        : admin
Password Baru    : ${NEW_PASS}
========================================
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
        echo 'Backup config.yml disimpan'
    fi
fi
mkdir -p ${WINGS_DIR}
" || log_warn "Backup parsial"

    if [[ -n "$NEW_TOKEN" ]]; then
        log_info "Menjalankan token auto-deploy..."
        # NEW_TOKEN biasanya berbentuk: cd /etc/pterodactyl && wings configure --panel-url=... --token=... --node=... --force
        exec_cmd "$IP" "$PW" "
cd ${WINGS_DIR}
${NEW_TOKEN}
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
    # Mengembalikan snippet shell yang menyiapkan repo PHP di remote.
    cat <<'PHPSETUP'
set -o pipefail
. /etc/os-release
if [ "$ID" = "ubuntu" ] || [ "${ID_LIKE:-}" = "*ubuntu*" ]; then
    if ! grep -rq "ondrej/php" /etc/apt/sources.list.d/ 2>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq software-properties-common
        LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
    fi
elif [ "$ID" = "debian" ] || [ "${ID_LIKE:-}" = "*debian*" ]; then
    if [ ! -f /usr/share/keyrings/deb.sury.org-php.gpg ]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates gnupg lsb-release
        curl -fsSLo /tmp/sury-keyring.deb https://packages.sury.org/debsuryorg-archive-keyring.deb
        dpkg -i /tmp/sury-keyring.deb
        echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list
    fi
fi
DEBIAN_FRONTEND=noninteractive apt-get update -qq
PHPSETUP
}

install_panel() {
    local IP="${1:-}"
    local PW="${2:--}"
    local DOMAIN="${3:-}"
    local NODE_DOMAIN="${4:-}"
    local RAM="${5:-2048}"
    local USE_SSL="${6:-no}"

    if [[ -z "$IP" || -z "$DOMAIN" ]]; then
        log_error "Parameter kurang!"
        echo -e "  ${YELLOW}Format:${NC} bash $0 panel <ip> <pwvps> <domain> <nodedomain> <ram> [ssl]"
        exit 1
    fi
    if ! validate_ip "$IP"; then
        log_error "Format IP tidak valid: $IP"; exit 1
    fi
    if ! validate_domain "$DOMAIN"; then
        log_error "Format domain tidak valid: $DOMAIN"; exit 1
    fi
    [[ -z "$PW" ]] && PW="-"
    [[ -z "$NODE_DOMAIN" ]] && NODE_DOMAIN="$DOMAIN"
    [[ -z "$RAM" ]] && RAM="2048"
    USE_SSL=$(echo "$USE_SSL" | tr '[:upper:]' '[:lower:]')

    show_banner
    log_step "🚀 Install Panel Pterodactyl"
    log_info "Target IP     : $IP"
    log_info "Domain Panel  : $DOMAIN"
    log_info "Domain Node   : $NODE_DOMAIN"
    log_info "RAM Alokasi   : ${RAM} MB"
    log_info "SSL (HTTPS)   : $USE_SSL"
    log_info "PHP Version   : $PHP_VER"

    if ! confirm "Lanjutkan instalasi panel?" "y"; then
        log_warn "Instalasi dibatalkan."
        exit 0
    fi

    local DB_PASSWORD ADMIN_PASSWORD ADMIN_EMAIL TIMEZONE APP_URL
    DB_PASSWORD=$(gen_password 28)
    ADMIN_PASSWORD=$(gen_password 16)
    ADMIN_EMAIL="admin@${DOMAIN}"
    TIMEZONE="${TIMEZONE_OVERRIDE:-Asia/Jakarta}"
    if [[ "$USE_SSL" == "yes" ]]; then
        APP_URL="https://${DOMAIN}"
    else
        APP_URL="http://${DOMAIN}"
    fi

    # ---------- Step 1 ----------
    log_step "Step 1/9 — Update sistem & install dependensi dasar"
    exec_cmd "$IP" "$PW" "
set -o pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq -o Dpkg::Options::=--force-confold || true
apt-get install -y -qq curl wget tar unzip git cron sudo \
    software-properties-common apt-transport-https ca-certificates gnupg lsb-release \
    ufw jq dnsutils netcat-openbsd
" || { log_error "Step 1 gagal!"; exit 1; }
    log_ok "Dependensi dasar terinstall"

    # ---------- Step 2 ----------
    log_step "Step 2/9 — Install PHP ${PHP_VER} + ekstensi"
    exec_cmd "$IP" "$PW" "$(setup_php_repo_remote)
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    php${PHP_VER} php${PHP_VER}-cli php${PHP_VER}-gd php${PHP_VER}-mysql \
    php${PHP_VER}-pdo php${PHP_VER}-mbstring php${PHP_VER}-tokenizer \
    php${PHP_VER}-bcmath php${PHP_VER}-xml php${PHP_VER}-fpm \
    php${PHP_VER}-curl php${PHP_VER}-zip php${PHP_VER}-intl php${PHP_VER}-readline \
    php${PHP_VER}-sqlite3
systemctl enable --now php${PHP_VER}-fpm
" || { log_error "Step 2 gagal!"; exit 1; }
    log_ok "PHP ${PHP_VER} terinstall"

    # ---------- Step 3 ----------
    log_step "Step 3/9 — Install MariaDB & buat database"
    exec_cmd "$IP" "$PW" "
set -o pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq mariadb-server mariadb-client
systemctl enable --now mariadb 2>/dev/null || systemctl enable --now mysql 2>/dev/null || true
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
        echo 'WARN: composer signature mismatch, lanjut tetap install...'
    fi
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
    rm -f /tmp/composer-setup.php
fi
composer --version || true
" || { log_error "Step 4 gagal!"; exit 1; }
    log_ok "Redis & Composer OK"

    # ---------- Step 5 ----------
    log_step "Step 5/9 — Download & extract Panel Pterodactyl"
    exec_cmd "$IP" "$PW" "
set -o pipefail
mkdir -p ${PANEL_DIR}
cd ${PANEL_DIR}
curl -fL --retry 3 -o panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzf panel.tar.gz
rm -f panel.tar.gz
chmod -R 755 storage bootstrap/cache || true
[ -f .env ] || cp .env.example .env
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction
php artisan key:generate --force
" || { log_error "Step 5 gagal!"; exit 1; }
    log_ok "Panel terdownload"

    # ---------- Step 6 ----------
    log_step "Step 6/9 — Konfigurasi environment & user admin"
    exec_cmd "$IP" "$PW" "
set -o pipefail
cd ${PANEL_DIR}
php artisan p:environment:setup \
    --author='${ADMIN_EMAIL}' \
    --url='${APP_URL}' \
    --timezone='${TIMEZONE}' \
    --cache='redis' \
    --session='redis' \
    --queue='redis' \
    --redis-host='127.0.0.1' \
    --redis-pass='null' \
    --redis-port='6379' \
    --settings-ui=true \
    --no-interaction

php artisan p:environment:database \
    --host='127.0.0.1' \
    --port='3306' \
    --database='panel' \
    --username='pterodactyl' \
    --password='${DB_PASSWORD}' \
    --no-interaction

php artisan migrate --seed --force

php artisan p:user:make \
    --email='${ADMIN_EMAIL}' \
    --username='admin' \
    --name-first='Admin' \
    --name-last='NortexZ' \
    --password='${ADMIN_PASSWORD}' \
    --admin=1 \
    --no-interaction || true

chown -R www-data:www-data ${PANEL_DIR}
find ${PANEL_DIR} -type d -exec chmod 755 {} \;
find ${PANEL_DIR} -type f -exec chmod 644 {} \;
chmod -R 775 ${PANEL_DIR}/storage ${PANEL_DIR}/bootstrap/cache
chown -R www-data:www-data ${PANEL_DIR}/storage ${PANEL_DIR}/bootstrap/cache
" || { log_error "Step 6 gagal!"; exit 1; }
    log_ok "Environment & admin user OK"

    # ---------- Step 7: Nginx ----------
    log_step "Step 7/9 — Install & konfigurasi Nginx"
    # Catatan tentang quoting:
    # - Heredoc remote: kita pakai 'NGINX_EOF' (single-quoted) supaya isi konfigurasi
    #   nginx tidak diekspansi di sisi LOCAL/REMOTE shell.
    # - Variabel ${DOMAIN} & ${PANEL_DIR} kita substitusi setelahnya pakai sed.
    exec_cmd "$IP" "$PW" "
set -o pipefail
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx
rm -f /etc/nginx/sites-enabled/default
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

USE_SSL='${USE_SSL}'
DOMAIN='${DOMAIN}'
PANEL_DIR='${PANEL_DIR}'
PHP_FPM_SOCK='/run/php/php${PHP_VER}-fpm.sock'

if [ \"\$USE_SSL\" = 'yes' ]; then
cat > /etc/nginx/sites-available/pterodactyl.conf <<'NGX_SSL'
server {
    listen 80;
    listen [::]:80;
    server_name __DOMAIN__;
    return 301 https://$server_name$request_uri;
}
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name __DOMAIN__;
    root __PANEL_DIR__/public;
    index index.php;

    ssl_certificate     /etc/letsencrypt/live/__DOMAIN__/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/__DOMAIN__/privkey.pem;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options DENY;
    add_header X-XSS-Protection \"1; mode=block\";
    add_header Strict-Transport-Security \"max-age=15768000; preload\";

    access_log /var/log/nginx/pterodactyl.access.log;
    error_log  /var/log/nginx/pterodactyl.error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~ \\.php\$ {
        fastcgi_split_path_info ^(.+\\.php)(/.+)\$;
        fastcgi_pass unix:__PHP_FPM_SOCK__;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE \"upload_max_filesize = 100M\\n post_max_size=100M\";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTPS on;
        fastcgi_read_timeout 300;
    }
    location ~ /\\.ht { deny all; }
}
NGX_SSL
else
cat > /etc/nginx/sites-available/pterodactyl.conf <<'NGX_HTTP'
server {
    listen 80;
    listen [::]:80;
    server_name __DOMAIN__;
    root __PANEL_DIR__/public;
    index index.php;

    access_log /var/log/nginx/pterodactyl.access.log;
    error_log  /var/log/nginx/pterodactyl.error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~ \\.php\$ {
        fastcgi_split_path_info ^(.+\\.php)(/.+)\$;
        fastcgi_pass unix:__PHP_FPM_SOCK__;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE \"upload_max_filesize = 100M\\n post_max_size=100M\";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_read_timeout 300;
    }
    location ~ /\\.ht { deny all; }
}
NGX_HTTP
fi

# Substitusi placeholder
sed -i \"s|__DOMAIN__|\$DOMAIN|g; s|__PANEL_DIR__|\$PANEL_DIR|g; s|__PHP_FPM_SOCK__|\$PHP_FPM_SOCK|g\" /etc/nginx/sites-available/pterodactyl.conf

ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
nginx -t
systemctl enable --now nginx
systemctl reload nginx || systemctl restart nginx
" || { log_error "Step 7 gagal!"; exit 1; }
    log_ok "Nginx terkonfigurasi"

    # ---------- Step 8 SSL ----------
    if [[ "$USE_SSL" == "yes" ]]; then
        log_step "Step 8/9 — Install SSL Let's Encrypt"
        exec_cmd "$IP" "$PW" "
set -o pipefail
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot python3-certbot-nginx
systemctl stop nginx 2>/dev/null || true
certbot certonly --standalone --non-interactive --agree-tos -m '${ADMIN_EMAIL}' -d '${DOMAIN}' || true
systemctl start nginx
( crontab -l 2>/dev/null | grep -v 'certbot renew' ; echo '0 3 * * * certbot renew --quiet --post-hook \"systemctl reload nginx\"' ) | crontab -
" || log_warn "SSL gagal — panel tetap jalan via HTTP"
        log_ok "SSL selesai"
    else
        log_step "Step 8/9 — SSL dilewati (HTTP only)"
    fi

    # ---------- Step 9: Cron + Queue + Firewall ----------
    log_step "Step 9/9 — Cron, Queue Worker, Firewall"
    exec_cmd "$IP" "$PW" "
set -o pipefail
( crontab -l 2>/dev/null | grep -v 'pterodactyl/artisan' ; echo \"* * * * * php ${PANEL_DIR}/artisan schedule:run >> /dev/null 2>&1\" ) | crontab -

cat > /etc/systemd/system/pteroq.service <<SVCEOF
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php ${PANEL_DIR}/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable --now pteroq

if command -v ufw >/dev/null 2>&1; then
    ufw allow 22/tcp   >/dev/null 2>&1 || true
    ufw allow 80/tcp   >/dev/null 2>&1 || true
    ufw allow 443/tcp  >/dev/null 2>&1 || true
    ufw allow 8080/tcp >/dev/null 2>&1 || true
    ufw allow 2022/tcp >/dev/null 2>&1 || true
    yes | ufw enable >/dev/null 2>&1 || true
fi
" || { log_error "Step 9 gagal!"; exit 1; }
    log_ok "Cron, Queue Worker & Firewall OK"

    # Simpan kredensial
    local CRED_FILE="${CRED_DIR}/panel-${DOMAIN}-$(date +%Y%m%d-%H%M%S).txt"
    cat >"$CRED_FILE" <<EOF
========================================
  PTERODACTYL PANEL CREDENTIALS
  Generated : $(date)
========================================
URL Panel       : ${APP_URL}
Email Admin     : ${ADMIN_EMAIL}
Username Admin  : admin
Password Admin  : ${ADMIN_PASSWORD}
Database User   : pterodactyl
Database Name   : panel
DB Password     : ${DB_PASSWORD}
PHP Version     : ${PHP_VER}
========================================
EOF
    chmod 600 "$CRED_FILE"

    # Health check sederhana
    log_step "Health check"
    if exec_cmd "$IP" "$PW" "curl -fsS --max-time 8 -o /dev/null -w '%{http_code}' http://127.0.0.1/ | grep -qE '^(200|301|302)$'"; then
        log_ok "Panel HTTP merespon dengan baik"
    else
        log_warn "Panel belum merespon di port 80, cek log nginx"
    fi

    echo ""
    echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${GREEN}${BOLD}✅  PANEL PTERODACTYL BERHASIL DIINSTALL!${NC}"
    echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}🌐 URL Panel      :${NC} ${APP_URL}"
    echo -e "  ${BOLD}📧 Email Admin    :${NC} ${ADMIN_EMAIL}"
    echo -e "  ${BOLD}👤 Username Admin :${NC} admin"
    echo -e "  ${BOLD}🔑 Password Admin :${NC} ${ADMIN_PASSWORD}"
    echo -e "  ${BOLD}🗃️  DB Password    :${NC} ${DB_PASSWORD}"
    echo -e "  ${BOLD}📁 Kredensial     :${NC} ${CRED_FILE}"
    echo ""
}

# =============================================================================
#  INSTALL WINGS
# =============================================================================
install_wings() {
    local IP="${1:-}"
    local PW="${2:--}"
    local TOKEN="${3:-}"

    if [[ -z "$IP" ]]; then
        log_error "Format: bash $0 wings <ip> <pwvps> [auto-deploy-command]"
        exit 1
    fi
    [[ -z "$PW" ]] && PW="-"

    show_banner
    log_step "🪶 Install Wings Pterodactyl"
    log_info "Target IP : $IP"

    if ! confirm "Lanjutkan instalasi Wings?" "y"; then
        log_warn "Dibatalkan."
        exit 0
    fi

    log_step "Step 1/6 — Update sistem"
    exec_cmd "$IP" "$PW" "
set -o pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl wget tar unzip ca-certificates gnupg lsb-release ufw jq
" || { log_error "Step 1 gagal!"; exit 1; }
    log_ok "Sistem terupdate"

    log_step "Step 2/6 — Install Docker"
    exec_cmd "$IP" "$PW" "
set -o pipefail
if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com/ | CHANNEL=stable bash
fi
systemctl enable --now docker
docker --version
" || { log_error "Step 2 gagal!"; exit 1; }
    log_ok "Docker OK"

    log_step "Step 3/6 — Aktifkan swap accounting (grub)"
    exec_cmd "$IP" "$PW" "
if [ -f /etc/default/grub ]; then
    if ! grep -q 'swapaccount=1' /etc/default/grub; then
        sed -i 's|GRUB_CMDLINE_LINUX_DEFAULT=\"|GRUB_CMDLINE_LINUX_DEFAULT=\"swapaccount=1 |' /etc/default/grub
        update-grub 2>/dev/null || true
        echo 'WARN: reboot disarankan agar swapaccount aktif.'
    fi
fi
" || true
    log_ok "Swap accounting checked"

    log_step "Step 4/6 — Download Wings binary"
    exec_cmd "$IP" "$PW" "
set -o pipefail
mkdir -p ${WINGS_DIR}
ARCH=\$(uname -m)
case \"\$ARCH\" in
    aarch64|arm64) WINGS_BIN=wings_linux_arm64 ;;
    x86_64|amd64)  WINGS_BIN=wings_linux_amd64 ;;
    *) echo \"Arsitektur tidak didukung: \$ARCH\" >&2; exit 1 ;;
esac
curl -fL --retry 3 -o /usr/local/bin/wings \"https://github.com/pterodactyl/wings/releases/latest/download/\${WINGS_BIN}\"
chmod +x /usr/local/bin/wings
/usr/local/bin/wings --version
" || { log_error "Step 4 gagal!"; exit 1; }
    log_ok "Wings binary OK"

    log_step "Step 5/6 — Konfigurasi Wings"
    if [[ -n "$TOKEN" ]]; then
        exec_cmd "$IP" "$PW" "
set -o pipefail
mkdir -p ${WINGS_DIR}
cd ${WINGS_DIR}
${TOKEN}
" && log_ok "Auto-deploy token sukses" || log_warn "Auto-deploy gagal (token salah / panel offline)"
    else
        log_warn "Token kosong, lewati konfigurasi (jalankan auto-deploy nanti)"
    fi

    log_step "Step 6/6 — Install Wings systemd service"
    exec_cmd "$IP" "$PW" "
set -o pipefail
cat > /etc/systemd/system/wings.service <<'WINGSEOF'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
WINGSEOF

systemctl daemon-reload
if [ -f ${WINGS_DIR}/config.yml ]; then
    systemctl enable --now wings
    sleep 2
    systemctl status wings --no-pager 2>&1 | head -n 12 || true
else
    systemctl enable wings
    echo 'INFO: config.yml belum ada — wings di-enable tapi belum start. Jalankan auto-deploy dari panel.'
fi

if command -v ufw >/dev/null 2>&1; then
    ufw allow 8080/tcp >/dev/null 2>&1 || true
    ufw allow 2022/tcp >/dev/null 2>&1 || true
    ufw allow 443/tcp  >/dev/null 2>&1 || true
fi
" || { log_error "Step 6 gagal!"; exit 1; }
    log_ok "Wings service terinstall"

    echo ""
    echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${GREEN}${BOLD}✅  WINGS PTERODACTYL BERHASIL DIINSTALL!${NC}"
    echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}🖥️  Node IP    :${NC} $IP"
    echo -e "  ${BOLD}⚙️  Status     :${NC} systemctl status wings"
    echo -e "  ${BOLD}📋 Log live   :${NC} journalctl -u wings -f"
    echo -e "  ${BOLD}🔧 Config     :${NC} ${WINGS_DIR}/config.yml"
    echo ""
}

# =============================================================================
#  INSTALL VIA OFFICIAL pterodactyl-installer.se
# =============================================================================
install_official() {
    show_banner
    log_step "Install via Official pterodactyl-installer.se"
    if ! confirm "Lanjutkan?" "y"; then
        log_warn "Dibatalkan."; exit 0
    fi
    bash <(curl -fsSL https://pterodactyl-installer.se)
}

# =============================================================================
#  SSL (standalone)
# =============================================================================
install_ssl() {
    local IP="${1:-}"
    local PW="${2:--}"
    local DOMAIN="${3:-}"
    local EMAIL="${4:-}"

    if [[ -z "$IP" || -z "$DOMAIN" ]]; then
        log_error "Format: bash $0 ssl <ip> <pwvps> <domain> [email]"; exit 1
    fi
    [[ -z "$PW" ]] && PW="-"
    [[ -z "$EMAIL" ]] && EMAIL="admin@${DOMAIN}"

    show_banner
    log_step "🔒 Install SSL Let's Encrypt untuk ${DOMAIN}"
    if ! confirm "Lanjut install SSL?" "y"; then exit 0; fi

    exec_cmd "$IP" "$PW" "
set -o pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq certbot python3-certbot-nginx
certbot --nginx -d '${DOMAIN}' --non-interactive --agree-tos -m '${EMAIL}' --redirect
systemctl reload nginx
( crontab -l 2>/dev/null | grep -v 'certbot renew' ; echo '0 3 * * * certbot renew --quiet --post-hook \"systemctl reload nginx\"' ) | crontab -
" || { log_error "SSL gagal!"; exit 1; }
    log_ok "SSL berhasil dipasang untuk ${DOMAIN}"
}

# =============================================================================
#  UNINSTALL
# =============================================================================
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
systemctl stop pteroq nginx redis-server 2>/dev/null || true
systemctl stop php${PHP_VER}-fpm 2>/dev/null || true
systemctl disable pteroq 2>/dev/null || true
rm -rf ${PANEL_DIR}
rm -f /etc/nginx/sites-enabled/pterodactyl.conf /etc/nginx/sites-available/pterodactyl.conf
systemctl restart nginx 2>/dev/null || true
rm -f /etc/systemd/system/pteroq.service
systemctl daemon-reload

mysql -u root <<SQL 2>/dev/null || true
DROP DATABASE IF EXISTS panel;
DROP USER IF EXISTS 'pterodactyl'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

( crontab -l 2>/dev/null | grep -v 'pterodactyl/artisan' ) | crontab - 2>/dev/null || true
echo 'Panel removed.'
"
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
echo 'Wings removed.'
"
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
mysqldump -u root panel > ${BACKUP_DIR}/panel-db.\${TS}.sql 2>/dev/null || true
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
ss -tlnp 2>/dev/null | awk 'NR==1 || /:(80|443|3306|6379|8080|2022)\\s/' | head -n 15
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
mysqldump -u root panel > ${BACKUP_DIR}/panel-db.\${TS}.sql 2>/dev/null || true
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
mysql -u root panel < '${SQL_FILE}'
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
