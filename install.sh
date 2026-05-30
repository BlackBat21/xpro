#!/usr/bin/env bash
# =============================================================================
#  __  __  ____      _     __  __  _   _ _____ _____  _____
# \ \/ /|  _ \    / \    \ \/ / | | | |_   _|_   _||  __ \
#  \  / | |_) |  / _ \    \  /  | |_| |  | |   | |  | |__) |
#  /  \ |  _ <  / ___ \   /  \  |  _  |  | |   | |  |  ___/
# /_/\_\|_| \_\/_/   \_\ /_/\_\ |_| |_| _|_|_  |_|  |_|
#
# xray-xhttp-manager.sh  ·  Version 2.3.0
# =============================================================================
# Description : Automates the full lifecycle of Xray-core using the XHTTP
#               transport protocol on Ubuntu 24.04 LTS.
#               · Port 80  — NTLS inbound (CDN mode; CDN terminates TLS)
#               · Port 443 — TLS inbound  (direct; Let's Encrypt certificate)
#               · Protocol : VLESS (zero-overhead, CDN-friendly)
#               · CDN      : Cloudflare and compatible providers
#
# Patch notes :
#   v2.1.0 — All read -rp replaced with echo + read -r (Android SSH fix)
#   v2.2.0 — exec 0</dev/tty + TERM export in main() (Android PTY fix)
#   v2.3.0 — geoip.dat/geosite.dat: create /usr/local/share/xray/ first,
#             download geo files there, add XRAY_LOCATION_ASSET env to
#             systemd service. Eliminates "no such file" crash on start.
#
# Requirements: Ubuntu 24.04 LTS · Root access · Resolvable domain name
# Usage       : sudo bash xray-xhttp-manager.sh
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# § 1  ANSI COLOR CODES
# ─────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ─────────────────────────────────────────────────────────────────────────────
# § 2  GLOBAL CONSTANTS
# ─────────────────────────────────────────────────────────────────────────────
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
CONFIG_FILE="${XRAY_CONFIG_DIR}/config.json"
LOG_DIR="/var/log/xray"
SERVICE_FILE="/etc/systemd/system/xray.service"

# v2.3.0 — Dedicated geo-data directory. Xray is told about this via the
# XRAY_LOCATION_ASSET environment variable in the systemd unit file.
# This is the ONLY place Xray will look for geoip.dat and geosite.dat.
GEO_DIR="/usr/local/share/xray"

DOMAIN_FILE="${XRAY_CONFIG_DIR}/.domain"
PATH_FILE="${XRAY_CONFIG_DIR}/.xhttp_path"

CERT_DIR="/etc/ssl/xray"
CERT_FULLCHAIN="${CERT_DIR}/fullchain.pem"
CERT_KEY="${CERT_DIR}/privkey.pem"

ACME_HOME="/root/.acme.sh"
ACME_BIN="${ACME_HOME}/acme.sh"

PORT_TLS=443
PORT_NTLS=80

XRAY_RELEASE_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
XRAY_DL_BASE="https://github.com/XTLS/Xray-core/releases/download"

# Fallback geo-data download URLs (Loyalsoldier builds are more up-to-date)
GEOIP_URL_PRIMARY="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
GEOIP_URL_FALLBACK="https://github.com/v2fly/geoip/releases/latest/download/geoip.dat"
GEOSITE_URL_PRIMARY="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
GEOSITE_URL_FALLBACK="https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat"

INSTALL_LOG="/var/log/xray_install.log"

# ─────────────────────────────────────────────────────────────────────────────
# § 3  HELPER / UTILITY FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────

separator() {
    echo -e "${BLUE}  ──────────────────────────────────────────────────────────────  ${NC}"
}

msg_info() { echo -e "${YELLOW}  [INFO]  ${NC}${1}"; }
msg_ok()   { echo -e "${GREEN}  [OK]    ${NC}${1}"; }
msg_warn() { echo -e "${YELLOW}  [WARN]  ${NC}${1}"; }

msg_err() {
    echo -e "${RED}  [ERROR] ${NC}${1}" >&2
    if [[ "${2:-}" == "exit" ]]; then
        echo -e "${RED}  Script aborted. Details logged to: ${INSTALL_LOG}${NC}" >&2
        exit 1
    fi
}

msg_step() {
    echo ""
    echo -e "${CYAN}${BOLD}  ▶  ${1}${NC}"
    echo ""
}

cmd_exists() { command -v "$1" &>/dev/null; }

is_xray_installed() {
    [[ -f "${XRAY_BIN}" ]] && [[ -f "${CONFIG_FILE}" ]]
}

is_port_in_use() {
    ss -tln 2>/dev/null | grep -q ":${1} "
}

# press_enter — echo then plain read -r < /dev/tty (Android SSH compatible)
press_enter() {
    echo ""
    echo -e "  ${YELLOW}Press Enter to return to the main menu...${NC}"
    read -r _DUMMY < /dev/tty
}

urlencode() {
    python3 -c \
        "import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read().strip()))" \
        <<< "${1}"
}

# download_file PRIMARY_URL FALLBACK_URL DEST_PATH LABEL
# Tries the primary URL first; falls back to the secondary on failure.
# Exits the script if both fail — the file is non-negotiable.
download_file() {
    local primary="${1}" fallback="${2}" dest="${3}" label="${4}"
    msg_info "Downloading ${label} (primary source)..."
    if curl -fsSL --connect-timeout 20 -o "${dest}" "${primary}" 2>>"${INSTALL_LOG}"; then
        local sz
        sz=$(stat -c%s "${dest}" 2>/dev/null || echo 0)
        if [[ "${sz}" -gt 1024 ]]; then
            msg_ok "${label} downloaded ($(( sz / 1024 )) KB)."
            return 0
        fi
    fi
    msg_warn "Primary source failed. Trying fallback..."
    if curl -fsSL --connect-timeout 20 -o "${dest}" "${fallback}" 2>>"${INSTALL_LOG}"; then
        local sz
        sz=$(stat -c%s "${dest}" 2>/dev/null || echo 0)
        if [[ "${sz}" -gt 1024 ]]; then
            msg_ok "${label} downloaded via fallback ($(( sz / 1024 )) KB)."
            return 0
        fi
    fi
    msg_err "Both download sources failed for ${label}." "exit"
}

# ─────────────────────────────────────────────────────────────────────────────
# § 4  MAIN BANNER
# ─────────────────────────────────────────────────────────────────────────────

print_banner() {
    clear
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════════════════════════════╗"
    echo "  ║                                                                  ║"
    echo "  ║       X R A Y - C O R E   ·   X H T T P   M A N A G E R        ║"
    echo "  ║                                                                  ║"
    echo "  ║   Transport : VLESS + XHTTP                          v2.3.0     ║"
    echo "  ║   Port 80   : NTLS inbound  (CDN mode — CDN terminates TLS)     ║"
    echo "  ║   Port 443  : TLS  inbound  (Direct — Let's Encrypt cert)       ║"
    echo "  ║   CDN       : Cloudflare / CloudFront / Fastly compatible       ║"
    echo "  ║   OS        : Ubuntu 24.04 LTS                                  ║"
    echo "  ║                                                                  ║"
    echo "  ╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    if is_xray_installed; then
        local svc_status
        svc_status="$(systemctl is-active xray 2>/dev/null || echo 'unknown')"
        if [[ "${svc_status}" == "active" ]]; then
            echo -e "  Xray Status : ${GREEN}${BOLD}● Running${NC}"
        else
            echo -e "  Xray Status : ${RED}${BOLD}● ${svc_status}${NC}"
        fi
        [[ -f "${DOMAIN_FILE}" ]] && \
            echo -e "  Domain      : ${WHITE}$(cat "${DOMAIN_FILE}")${NC}"
    else
        echo -e "  Xray Status : ${DIM}Not installed${NC}"
    fi
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# § 5  PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo -e "${RED}[FATAL] This script must be run as root.${NC}"
        echo -e "        Re-run with: ${WHITE}sudo bash ${0}${NC}"
        exit 1
    fi
}

check_ubuntu_2404() {
    if [[ ! -f /etc/os-release ]]; then
        echo -e "${RED}[FATAL] /etc/os-release not found — cannot determine OS.${NC}"
        exit 1
    fi
    # shellcheck source=/dev/null
    source /etc/os-release
    if [[ "${ID:-}" != "ubuntu" ]] || [[ "${VERSION_ID:-}" != "24.04" ]]; then
        echo -e "${RED}[FATAL] This script requires Ubuntu 24.04 LTS.${NC}"
        echo -e "        Detected: ${WHITE}${PRETTY_NAME:-Unknown OS}${NC}"
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# § 6  WEB SERVER CONFLICT CHECK
# ─────────────────────────────────────────────────────────────────────────────

check_webserver_conflict() {
    local -a CONFLICT_SERVICES=("nginx" "apache2" "apache" "lighttpd" "caddy" "httpd")
    local -a found=()
    for svc in "${CONFLICT_SERVICES[@]}"; do
        if systemctl is-active --quiet "${svc}" 2>/dev/null; then
            found+=("${svc}")
        fi
    done
    if [[ ${#found[@]} -gt 0 ]]; then
        msg_err "The following web server(s) are ACTIVE and will block ports 80/443:"
        for s in "${found[@]}"; do
            echo -e "      ${RED}→ ${s}${NC}"
        done
        echo ""
        msg_warn "Disable them first, then re-run this script:"
        for s in "${found[@]}"; do
            echo -e "      ${WHITE}sudo systemctl stop ${s} && sudo systemctl disable ${s}${NC}"
        done
        echo ""
        msg_err "Installation aborted: web server conflict detected." "exit"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# § 7  INSTALL FUNCTION  (Menu option 1)
# ─────────────────────────────────────────────────────────────────────────────

install_xray() {
    print_banner
    msg_step "OPTION 1 — Install Xray-core (XHTTP + CDN Optimised)"

    if is_xray_installed; then
        msg_warn "Xray is already installed on this system."
        msg_info  "To reinstall, run Option 5 (Uninstall) first, then re-run Option 1."
        press_enter
        return
    fi

    # ── Step 1: Conflict checks ────────────────────────────────────────────────
    msg_step "Step 1/9 — Checking for port and service conflicts"
    check_webserver_conflict

    if is_port_in_use 80; then
        msg_err "Port 80 is already in use by an unknown process."
        msg_err "Identify it with: ${WHITE}sudo ss -tlnp | grep ':80 '${NC}"
        press_enter; return
    fi
    msg_ok "Port 80 is available."

    if is_port_in_use 443; then
        msg_err "Port 443 is already in use by an unknown process."
        msg_err "Identify it with: ${WHITE}sudo ss -tlnp | grep ':443 '${NC}"
        press_enter; return
    fi
    msg_ok "Port 443 is available."

    # ── Step 2: Domain input ───────────────────────────────────────────────────
    msg_step "Step 2/9 — Domain configuration"
    echo -e "  ${WHITE}Enter the fully-qualified domain name for this server.${NC}"
    echo -e "  ${DIM}Example: vpn.example.com${NC}"
    echo ""
    echo -e "  ${YELLOW}Important:${NC}"
    echo -e "   • The domain MUST have an A record pointing to this server's IP."
    echo -e "   • If using Cloudflare, set the record to ${WHITE}DNS-only (grey cloud)${NC}"
    echo -e "     during installation so the ACME challenge can reach this server."
    echo -e "   • You can re-enable the orange cloud AFTER the certificate is issued."
    echo ""
    echo -e "  ${YELLOW}Domain name:${NC} "
    read -r DOMAIN < /dev/tty

    DOMAIN="${DOMAIN#http://}"
    DOMAIN="${DOMAIN#https://}"
    DOMAIN="${DOMAIN%%/*}"
    DOMAIN="${DOMAIN%% *}"

    if [[ -z "${DOMAIN}" ]] || [[ "${DOMAIN}" != *.* ]] || \
       [[ "${DOMAIN}" =~ [[:space:]] ]]; then
        msg_err "Invalid domain '${DOMAIN}'. Must be a valid FQDN (e.g. vpn.example.com)." "exit"
    fi
    msg_ok "Domain accepted: ${WHITE}${DOMAIN}${NC}"

    # ── Step 3: DNS check ──────────────────────────────────────────────────────
    msg_step "Step 3/9 — DNS resolution check"
    SERVER_IP="$(curl -s -4 --connect-timeout 8 https://api.ipify.org 2>/dev/null || \
                 curl -s -4 --connect-timeout 8 https://ifconfig.me  2>/dev/null || \
                 echo 'unknown')"
    DOMAIN_IP="$(dig +short A "${DOMAIN}" 2>/dev/null | \
                 grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | tail -n1 || echo '')"

    echo -e "  ${WHITE}Server public IP :${NC} ${SERVER_IP}"
    echo -e "  ${WHITE}Domain resolves  :${NC} ${DOMAIN_IP:-NOT RESOLVED}"
    echo ""

    if [[ -z "${DOMAIN_IP}" ]]; then
        msg_warn "Domain '${DOMAIN}' did not resolve. SSL issuance will FAIL without DNS."
    elif [[ "${SERVER_IP}" != "${DOMAIN_IP}" ]]; then
        msg_warn "Domain IP (${DOMAIN_IP}) ≠ server IP (${SERVER_IP})."
        msg_warn "Disable Cloudflare proxy (grey cloud) before issuing the certificate."
    else
        msg_ok "Domain resolves correctly to this server."
    fi

    echo ""
    echo -e "  ${YELLOW}Continue with domain '${DOMAIN}'? [Y/n]:${NC} "
    read -r DNS_CONFIRM < /dev/tty
    [[ "${DNS_CONFIRM,,}" == "n" ]] && { msg_info "Cancelled."; press_enter; return; }

    mkdir -p "$(dirname "${INSTALL_LOG}")"
    { echo "=== Xray Install Log — $(date) ==="; echo "Domain: ${DOMAIN}"; } > "${INSTALL_LOG}"

    # ── Step 4: Dependencies ───────────────────────────────────────────────────
    msg_step "Step 4/9 — Installing system dependencies"
    msg_info "Running apt-get update..."
    if ! apt-get update -y >>"${INSTALL_LOG}" 2>&1; then
        msg_err "apt-get update failed. Check your internet connection." "exit"
    fi
    msg_ok "Package lists updated."

    local -a DEPS=("curl" "wget" "unzip" "jq" "uuid-runtime" \
                   "socat" "dnsutils" "qrencode" "openssl")
    for dep in "${DEPS[@]}"; do
        if cmd_exists "${dep}"; then
            msg_ok "${dep} — already installed."
        else
            msg_info "Installing ${dep}..."
            if ! apt-get install -y "${dep}" >>"${INSTALL_LOG}" 2>&1; then
                msg_err "Failed to install '${dep}'. See ${INSTALL_LOG}." "exit"
            fi
            msg_ok "${dep} installed."
        fi
    done

    # ── Step 5: acme.sh ────────────────────────────────────────────────────────
    msg_step "Step 5/9 — Setting up acme.sh (Let's Encrypt client)"
    if [[ -f "${ACME_BIN}" ]]; then
        msg_ok "acme.sh already installed."
    else
        msg_info "Downloading acme.sh..."
        if ! curl -fsSL "https://get.acme.sh" | bash -s -- \
             --install-online --accountemail "admin@${DOMAIN}" \
             >>"${INSTALL_LOG}" 2>&1; then
            msg_err "acme.sh installation failed. See ${INSTALL_LOG}." "exit"
        fi
        msg_ok "acme.sh installed to ${ACME_HOME}."
    fi
    msg_info "Setting CA to Let's Encrypt..."
    "${ACME_BIN}" --set-default-ca --server letsencrypt >>"${INSTALL_LOG}" 2>&1 || true
    msg_ok "CA set: Let's Encrypt."

    # ── Step 6: SSL certificate ────────────────────────────────────────────────
    msg_step "Step 6/9 — Issuing SSL certificate for ${DOMAIN}"
    echo -e "  ${WHITE}acme.sh standalone${NC} will start a temporary HTTP server on port 80."
    echo -e "  ${YELLOW}Requirements:${NC}"
    echo -e "   • Port 80 reachable from the internet."
    echo -e "   • Domain pointing directly to this server (no CDN proxy)."
    echo ""
    echo -e "  ${YELLOW}Ready to issue certificate? [Y/n]:${NC} "
    read -r CERT_CONFIRM < /dev/tty
    [[ "${CERT_CONFIRM,,}" == "n" ]] && { msg_info "Cancelled."; press_enter; return; }

    mkdir -p "${CERT_DIR}"
    msg_info "Issuing certificate (~30–60 seconds)..."
    if ! "${ACME_BIN}" --issue --standalone -d "${DOMAIN}" \
         --keylength ec-256 >>"${INSTALL_LOG}" 2>&1; then
        echo ""
        msg_err "SSL certificate issuance FAILED."
        echo -e "  ${YELLOW}Common causes:${NC}"
        echo -e "   1. Port 80 blocked — open it: ${WHITE}sudo ufw allow 80/tcp${NC}"
        echo -e "      Also check AWS/cloud Security Group inbound rules."
        echo -e "   2. Cloudflare orange cloud active — switch to grey (DNS only)."
        echo -e "   3. Domain not pointing to this server IP."
        echo -e "   4. Let's Encrypt rate limit — wait 1 hour."
        echo -e "  Full log: ${WHITE}tail -50 ${INSTALL_LOG}${NC}"
        press_enter; return
    fi
    msg_ok "Certificate issued."

    msg_info "Installing certificate to ${CERT_DIR}..."
    if ! "${ACME_BIN}" --install-cert -d "${DOMAIN}" --ecc \
         --key-file       "${CERT_KEY}"       \
         --fullchain-file "${CERT_FULLCHAIN}" \
         --pre-hook  "systemctl stop  xray 2>/dev/null; true" \
         --post-hook "systemctl start xray 2>/dev/null; true" \
         >>"${INSTALL_LOG}" 2>&1; then
        msg_err "Certificate copy failed. See ${INSTALL_LOG}." "exit"
    fi
    chmod 600 "${CERT_KEY}"
    chmod 644 "${CERT_FULLCHAIN}"
    msg_ok "Certificate installed. Auto-renewal hooks registered."

    # ── Step 7: Download Xray binary ───────────────────────────────────────────
    msg_step "Step 7/9 — Downloading and installing Xray-core"

    local ARCH XRAY_ARCH
    ARCH="$(uname -m)"
    case "${ARCH}" in
        x86_64)        XRAY_ARCH="64"        ;;
        aarch64|arm64) XRAY_ARCH="arm64-v8a" ;;
        armv7l)        XRAY_ARCH="arm32-v7a" ;;
        armv6l)        XRAY_ARCH="arm32-v6"  ;;
        *) msg_err "Unsupported CPU architecture: ${ARCH}." "exit" ;;
    esac
    msg_ok "Architecture: ${ARCH} → Xray-linux-${XRAY_ARCH}"

    msg_info "Querying GitHub API for latest Xray-core release..."
    local XRAY_VERSION
    XRAY_VERSION="$(curl -s --connect-timeout 10 "${XRAY_RELEASE_API}" 2>/dev/null \
                    | jq -r '.tag_name // empty' 2>/dev/null || echo '')"
    if [[ -z "${XRAY_VERSION}" ]]; then
        msg_warn "GitHub API unreachable. Falling back to v24.11.11."
        XRAY_VERSION="v24.11.11"
    fi
    msg_ok "Target version: ${WHITE}${XRAY_VERSION}${NC}"

    local XRAY_ZIP_URL="${XRAY_DL_BASE}/${XRAY_VERSION}/Xray-linux-${XRAY_ARCH}.zip"
    local XRAY_ZIP="/tmp/xray-linux-${XRAY_ARCH}.zip"

    msg_info "Downloading: ${XRAY_ZIP_URL}"
    if ! curl -fsSL --connect-timeout 30 -o "${XRAY_ZIP}" "${XRAY_ZIP_URL}"; then
        msg_err "Download failed." "exit"
    fi
    msg_ok "Download complete."

    local XRAY_EXTRACT="/tmp/xray-extract-$$"
    mkdir -p "${XRAY_EXTRACT}"
    if ! unzip -o "${XRAY_ZIP}" -d "${XRAY_EXTRACT}" >>"${INSTALL_LOG}" 2>&1; then
        msg_err "Failed to extract ${XRAY_ZIP}." "exit"
    fi
    install -m 755 "${XRAY_EXTRACT}/xray" "${XRAY_BIN}"
    msg_ok "Xray binary installed: ${XRAY_BIN}"
    rm -rf "${XRAY_EXTRACT}" "${XRAY_ZIP}"

    # ── Step 7b: Geo-data files (v2.3.0 definitive fix) ───────────────────────
    # The geo files MUST live in GEO_DIR (/usr/local/share/xray).
    # The systemd service exports XRAY_LOCATION_ASSET pointing here.
    # Creating the directory first is the fix for "curl: (23) Failure writing
    # output to destination" errors seen in earlier versions.
    msg_info "Creating geo-data directory: ${GEO_DIR}"
    mkdir -p "${GEO_DIR}"

    download_file \
        "${GEOIP_URL_PRIMARY}" \
        "${GEOIP_URL_FALLBACK}" \
        "${GEO_DIR}/geoip.dat" \
        "geoip.dat"

    download_file \
        "${GEOSITE_URL_PRIMARY}" \
        "${GEOSITE_URL_FALLBACK}" \
        "${GEO_DIR}/geosite.dat" \
        "geosite.dat"

    # Verify files exist and are non-empty
    if [[ ! -s "${GEO_DIR}/geoip.dat" ]] || [[ ! -s "${GEO_DIR}/geosite.dat" ]]; then
        msg_err "Geo-data files are empty or missing after download." "exit"
    fi
    msg_ok "Geo-data ready: $(ls -lh ${GEO_DIR}/*.dat | awk '{print $5, $9}' | tr '\n' '  ')"

    # ── Step 8: Config files ───────────────────────────────────────────────────
    msg_step "Step 8/9 — Creating configuration files"

    local XHTTP_PATH
    XHTTP_PATH="/$(tr -dc 'a-z0-9' < /dev/urandom | head -c 12)"
    msg_ok "Generated XHTTP path: ${WHITE}${XHTTP_PATH}${NC}"

    mkdir -p "${XRAY_CONFIG_DIR}" "${LOG_DIR}" "${CERT_DIR}"
    touch "${LOG_DIR}/access.log" "${LOG_DIR}/error.log"
    chmod 640 "${LOG_DIR}/access.log" "${LOG_DIR}/error.log"

    echo "${DOMAIN}"     > "${DOMAIN_FILE}"
    echo "${XHTTP_PATH}" > "${PATH_FILE}"

    local INIT_UUID INIT_USER
    INIT_UUID="$(uuidgen)"
    INIT_USER="user01"
    msg_ok "Initial user: ${WHITE}${INIT_USER}${NC}  UUID: ${WHITE}${INIT_UUID}${NC}"

    # Write config.json
    # Two inbounds:
    #   xhttp-ntls-p80  — port 80, no TLS (CDN terminates TLS upstream)
    #   xhttp-tls-p443  — port 443, TLS with Let's Encrypt cert (direct)
    # Routing: block private/LAN IPs to prevent SSRF (uses geoip:private
    # from the geo files we just downloaded)
    cat > "${CONFIG_FILE}" << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "${LOG_DIR}/access.log",
    "error":  "${LOG_DIR}/error.log"
  },
  "inbounds": [
    {
      "tag": "xhttp-ntls-p80",
      "port": ${PORT_NTLS},
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${INIT_UUID}",
            "email": "${INIT_USER}",
            "flow": ""
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "host": "${DOMAIN}",
          "path": "${XHTTP_PATH}",
          "mode": "auto",
          "extra": {
            "scMaxEachPostBytes": 1000000,
            "scMinPostsIntervalMs": 30,
            "xPaddingBytes": "100-1000",
            "noGRPCHeader": false
          }
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    },
    {
      "tag": "xhttp-tls-p443",
      "port": ${PORT_TLS},
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${INIT_UUID}",
            "email": "${INIT_USER}",
            "flow": ""
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "minVersion": "1.2",
          "alpn": ["h2", "http/1.1"],
          "certificates": [
            {
              "certificateFile": "${CERT_FULLCHAIN}",
              "keyFile": "${CERT_KEY}"
            }
          ]
        },
        "xhttpSettings": {
          "host": "${DOMAIN}",
          "path": "${XHTTP_PATH}",
          "mode": "auto",
          "extra": {
            "scMaxEachPostBytes": 1000000,
            "scMinPostsIntervalMs": 30,
            "xPaddingBytes": "100-1000",
            "noGRPCHeader": false
          }
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": { "domainStrategy": "UseIPv4v6" }
    },
    {
      "tag": "block",
      "protocol": "blackhole",
      "settings": { "response": { "type": "http" } }
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block",
        "remark": "Block RFC-1918 LAN destinations (SSRF prevention)"
      }
    ]
  },
  "policy": {
    "levels": {
      "0": {
        "handshake": 4,
        "connIdle": 300,
        "uplinkOnly": 1,
        "downlinkOnly": 1
      }
    },
    "system": {
      "statsInboundUplink": false,
      "statsInboundDownlink": false
    }
  }
}
EOF
    msg_ok "config.json written to ${CONFIG_FILE}."

    # ── Step 9: systemd service + firewall ─────────────────────────────────────
    msg_step "Step 9/9 — Creating systemd service and configuring firewall"

    # v2.3.0 KEY FIX: The Environment= line tells Xray exactly where to find
    # geoip.dat and geosite.dat. Without this, Xray defaults to searching
    # /usr/local/bin/ or the binary's directory — neither of which has the files.
    cat > "${SERVICE_FILE}" << SYSTEMD_EOF
[Unit]
Description=Xray-core (VLESS+XHTTP Transport)
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
Environment=XRAY_LOCATION_ASSET=${GEO_DIR}
ExecStart=${XRAY_BIN} run -config ${CONFIG_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF

    msg_ok "systemd unit written: ${SERVICE_FILE}"
    msg_ok "  XRAY_LOCATION_ASSET=${GEO_DIR} (geo-data path set correctly)"

    systemctl daemon-reload

    if ! systemctl enable xray >>"${INSTALL_LOG}" 2>&1; then
        msg_err "Failed to enable xray service." "exit"
    fi
    msg_ok "Xray enabled (starts on boot)."

    # Test the config before attempting to start
    msg_info "Validating config.json..."
    if ! "${XRAY_BIN}" -test -config "${CONFIG_FILE}" >>"${INSTALL_LOG}" 2>&1; then
        msg_err "Config validation FAILED. Check: ${WHITE}tail -20 ${INSTALL_LOG}${NC}"
        press_enter; return
    fi
    msg_ok "Config validation passed."

    if ! systemctl start xray; then
        msg_err "Xray failed to start."
        msg_err "Run: ${WHITE}journalctl -u xray -n 30 --no-pager -l${NC}"
        press_enter; return
    fi

    sleep 2

    if systemctl is-active --quiet xray; then
        msg_ok "Xray service is ${GREEN}${BOLD}running${NC}."
    else
        msg_warn "Xray may not be running — use Option 4 to investigate."
    fi

    if cmd_exists ufw; then
        ufw allow OpenSSH                                     >>"${INSTALL_LOG}" 2>&1 || true
        ufw allow 80/tcp  comment 'Xray XHTTP NTLS CDN'      >>"${INSTALL_LOG}" 2>&1 || true
        ufw allow 443/tcp comment 'Xray XHTTP TLS direct'    >>"${INSTALL_LOG}" 2>&1 || true
        msg_ok "UFW: ports 22, 80 and 443 opened."
    else
        msg_warn "UFW not found. Open ports 80/443 in your cloud security group manually."
    fi

    separator
    echo ""
    echo -e "${GREEN}${BOLD}  ✔  Installation complete!${NC}"
    echo ""
    echo -e "  ${WHITE}Domain       :${NC} ${DOMAIN}"
    echo -e "  ${WHITE}XHTTP path   :${NC} ${XHTTP_PATH}"
    echo -e "  ${WHITE}Port 80      :${NC} NTLS — CDN mode (Cloudflare orange cloud)"
    echo -e "  ${WHITE}Port 443     :${NC} TLS  — Direct mode (Let's Encrypt cert)"
    echo -e "  ${WHITE}Initial user :${NC} ${INIT_USER}  UUID: ${INIT_UUID}"
    echo -e "  ${WHITE}Geo-data     :${NC} ${GEO_DIR}/"
    echo ""
    echo -e "  ${YELLOW}Next steps:${NC}"
    echo -e "   • Option 3 — view client connection strings and QR codes."
    echo -e "   • Option 2 — add more users."
    echo -e "   • Re-enable Cloudflare orange cloud for ${DOMAIN} if desired."
    echo ""
    separator
    press_enter
}

# ─────────────────────────────────────────────────────────────────────────────
# § 8  ADD USER  (Menu option 2)
# ─────────────────────────────────────────────────────────────────────────────

add_user() {
    print_banner
    msg_step "OPTION 2 — Add New Xray User"

    if ! is_xray_installed; then
        msg_err "Xray is not installed. Please run Option 1 first."
        press_enter; return
    fi

    echo ""
    echo -e "  ${WHITE}Username rules:${NC} letters, numbers, hyphens, underscores only."
    echo ""
    echo -e "  ${YELLOW}New username:${NC} "
    read -r USERNAME < /dev/tty

    if [[ -z "${USERNAME}" ]] || [[ "${USERNAME}" =~ [^a-zA-Z0-9_-] ]]; then
        msg_err "Invalid username '${USERNAME}'. Allowed: a-z A-Z 0-9 _ -"
        press_enter; return
    fi

    if jq -e --arg em "${USERNAME}" \
          '.inbounds[0].settings.clients[] | select(.email == $em)' \
          "${CONFIG_FILE}" >/dev/null 2>&1; then
        msg_err "User '${USERNAME}' already exists."
        press_enter; return
    fi

    local NEW_UUID
    NEW_UUID="$(uuidgen)"
    msg_info "Generated UUID: ${WHITE}${NEW_UUID}${NC}"

    local TMP_CFG
    TMP_CFG="$(mktemp)"

    if jq --arg uuid "${NEW_UUID}" --arg em "${USERNAME}" \
       '(.inbounds[] | .settings.clients) += [{"id": $uuid, "email": $em, "flow": ""}]' \
       "${CONFIG_FILE}" > "${TMP_CFG}"; then
        if jq empty "${TMP_CFG}" 2>/dev/null; then
            mv "${TMP_CFG}" "${CONFIG_FILE}"
            msg_ok "User '${USERNAME}' added to both inbounds."
        else
            msg_err "jq produced invalid JSON. Config unchanged."
            rm -f "${TMP_CFG}"; press_enter; return
        fi
    else
        msg_err "jq failed. Config unchanged."
        rm -f "${TMP_CFG}"; press_enter; return
    fi

    msg_info "Restarting Xray..."
    if systemctl restart xray; then
        msg_ok "Xray restarted. User '${USERNAME}' is now active."
    else
        msg_err "Xray failed to restart! Run: journalctl -u xray -n 30 --no-pager"
    fi

    echo ""
    echo -e "  ${GREEN}${BOLD}User created!${NC}"
    echo -e "  ${WHITE}Username :${NC} ${USERNAME}"
    echo -e "  ${WHITE}UUID     :${NC} ${NEW_UUID}"
    echo ""
    echo -e "  ${YELLOW}Use Option 3 to generate the client connection strings.${NC}"
    press_enter
}

# ─────────────────────────────────────────────────────────────────────────────
# § 9  VIEW CLIENT CONFIG  (Menu option 3)
# ─────────────────────────────────────────────────────────────────────────────

view_client_config() {
    print_banner
    msg_step "OPTION 3 — View Client Configuration"

    if ! is_xray_installed; then
        msg_err "Xray is not installed. Please run Option 1 first."
        press_enter; return
    fi

    if [[ ! -f "${DOMAIN_FILE}" ]] || [[ ! -f "${PATH_FILE}" ]]; then
        msg_err "Metadata files missing. Reinstall Xray (Option 1)."
        press_enter; return
    fi

    local DOMAIN XHTTP_PATH
    DOMAIN="$(cat "${DOMAIN_FILE}")"
    XHTTP_PATH="$(cat "${PATH_FILE}")"

    local -a USERS
    mapfile -t USERS < <(jq -r '.inbounds[0].settings.clients[].email' \
                          "${CONFIG_FILE}" 2>/dev/null)

    if [[ ${#USERS[@]} -eq 0 ]]; then
        msg_err "No users found. Add users via Option 2 first."
        press_enter; return
    fi

    echo -e "  ${WHITE}${BOLD}Registered users:${NC}"
    echo ""
    local i
    for i in "${!USERS[@]}"; do
        echo -e "  ${CYAN}  $((i+1)).${NC}  ${USERS[$i]}"
    done
    echo ""
    echo -e "  ${YELLOW}Select user number [1-${#USERS[@]}]:${NC} "
    read -r USER_NUM < /dev/tty

    if ! [[ "${USER_NUM}" =~ ^[0-9]+$ ]] || \
       [[ "${USER_NUM}" -lt 1 ]] || \
       [[ "${USER_NUM}" -gt "${#USERS[@]}" ]]; then
        msg_err "Invalid selection '${USER_NUM}'."
        press_enter; return
    fi

    local SELECTED_USER USER_UUID
    SELECTED_USER="${USERS[$((USER_NUM-1))]}"
    USER_UUID="$(jq -r --arg em "${SELECTED_USER}" \
        '.inbounds[0].settings.clients[] | select(.email == $em) | .id' \
        "${CONFIG_FILE}")"

    if [[ -z "${USER_UUID}" ]] || [[ "${USER_UUID}" == "null" ]]; then
        msg_err "Could not retrieve UUID for '${SELECTED_USER}'."
        press_enter; return
    fi

    local PATH_ENC
    PATH_ENC="$(urlencode "${XHTTP_PATH}")"

    # [A] CDN Mode — client connects to CDN:443, CDN proxies to our port 80
    local CDN_URL
    CDN_URL="vless://${USER_UUID}@${DOMAIN}:443"
    CDN_URL+="?encryption=none&type=xhttp"
    CDN_URL+="&path=${PATH_ENC}&host=${DOMAIN}"
    CDN_URL+="&security=tls&sni=${DOMAIN}&fp=chrome"
    CDN_URL+="#${SELECTED_USER}-CDN"

    # [B] Direct TLS — client connects directly to our port 443
    local DIRECT_URL
    DIRECT_URL="vless://${USER_UUID}@${DOMAIN}:443"
    DIRECT_URL+="?encryption=none&type=xhttp"
    DIRECT_URL+="&path=${PATH_ENC}&host=${DOMAIN}"
    DIRECT_URL+="&security=tls&sni=${DOMAIN}&fp=chrome"
    DIRECT_URL+="#${SELECTED_USER}-Direct-TLS"

    # [C] NTLS — port 80, unencrypted — testing only
    local NTLS_URL
    NTLS_URL="vless://${USER_UUID}@${DOMAIN}:80"
    NTLS_URL+="?encryption=none&type=xhttp"
    NTLS_URL+="&path=${PATH_ENC}&host=${DOMAIN}&security=none"
    NTLS_URL+="#${SELECTED_USER}-NTLS-TestOnly"

    clear
    echo ""
    separator
    echo -e "  ${WHITE}${BOLD}Client config for: ${CYAN}${SELECTED_USER}${NC}"
    separator
    echo -e "  ${WHITE}Domain    :${NC} ${DOMAIN}"
    echo -e "  ${WHITE}UUID      :${NC} ${USER_UUID}"
    echo -e "  ${WHITE}XHTTP Path:${NC} ${XHTTP_PATH}"
    echo ""

    # ── [A] CDN ───────────────────────────────────────────────────────────────
    separator
    echo -e "  ${GREEN}${BOLD}[A]  CDN MODE — Client:443 → CDN → Origin:80${NC}"
    echo -e "  ${YELLOW}Use when:${NC} Cloudflare/CDN orange-cloud proxy is enabled."
    echo ""
    echo -e "  ${WHITE}VLESS URL:${NC}"
    echo -e "  ${CYAN}${CDN_URL}${NC}"
    echo ""
    if cmd_exists qrencode; then
        echo -e "  ${WHITE}QR Code:${NC}"
        echo ""
        qrencode -t ANSIUTF8 -m 2 "${CDN_URL}"
        echo ""
    fi

    # ── [B] Direct TLS ────────────────────────────────────────────────────────
    separator
    echo -e "  ${GREEN}${BOLD}[B]  DIRECT TLS — Client:443 → Origin:443 (no CDN)${NC}"
    echo -e "  ${YELLOW}Use when:${NC} DNS is grey-cloud / DNS-only (no CDN proxy)."
    echo ""
    echo -e "  ${WHITE}VLESS URL:${NC}"
    echo -e "  ${CYAN}${DIRECT_URL}${NC}"
    echo ""
    if cmd_exists qrencode; then
        echo -e "  ${WHITE}QR Code:${NC}"
        echo ""
        qrencode -t ANSIUTF8 -m 2 "${DIRECT_URL}"
        echo ""
    fi

    # ── [C] NTLS ──────────────────────────────────────────────────────────────
    separator
    echo -e "  ${MAGENTA}${BOLD}[C]  NTLS PORT 80 — Unencrypted — TESTING ONLY${NC}"
    echo -e "  ${RED}  ⚠  Do NOT use in production. Traffic is plain-text.${NC}"
    echo ""
    echo -e "  ${WHITE}VLESS URL:${NC}"
    echo -e "  ${CYAN}${NTLS_URL}${NC}"
    echo ""
    separator

    echo ""
    echo -e "  ${WHITE}Compatible clients:${NC}"
    echo -e "   v2rayNG (Android) · Shadowrocket (iOS) · Hiddify"
    echo -e "   Nekoray · Clash.Meta · Sing-box"
    echo ""
    press_enter
}

# ─────────────────────────────────────────────────────────────────────────────
# § 10  CHECK STATUS  (Menu option 4)
# ─────────────────────────────────────────────────────────────────────────────

check_status() {
    print_banner
    msg_step "OPTION 4 — System Status"

    separator
    echo ""

    # [1] Service
    echo -e "  ${WHITE}${BOLD}[ 1 ]  Xray Systemd Service${NC}"
    echo ""
    systemctl status xray --no-pager -l 2>/dev/null || \
        echo -e "  ${RED}xray.service not found in systemd.${NC}"

    echo ""
    separator
    echo ""

    # [2] Ports
    echo -e "  ${WHITE}${BOLD}[ 2 ]  Port Listening Status${NC}"
    echo ""
    local P80_INFO P443_INFO
    P80_INFO="$(ss -tlnp 2>/dev/null | grep ':80 ' || echo '')"
    P443_INFO="$(ss -tlnp 2>/dev/null | grep ':443 ' || echo '')"

    if [[ -n "${P80_INFO}" ]]; then
        echo -e "  Port 80  (NTLS) : ${GREEN}${BOLD}● LISTENING${NC}"
        echo -e "  ${DIM}  ${P80_INFO}${NC}"
    else
        echo -e "  Port 80  (NTLS) : ${RED}○ NOT LISTENING${NC}"
    fi

    if [[ -n "${P443_INFO}" ]]; then
        echo -e "  Port 443 (TLS)  : ${GREEN}${BOLD}● LISTENING${NC}"
        echo -e "  ${DIM}  ${P443_INFO}${NC}"
    else
        echo -e "  Port 443 (TLS)  : ${RED}○ NOT LISTENING${NC}"
    fi

    echo ""
    separator
    echo ""

    # [3] Config summary
    echo -e "  ${WHITE}${BOLD}[ 3 ]  Configuration Summary${NC}"
    echo ""
    if is_xray_installed; then
        [[ -f "${DOMAIN_FILE}" ]] && echo -e "  Domain      : ${WHITE}$(cat "${DOMAIN_FILE}")${NC}"
        [[ -f "${PATH_FILE}" ]]   && echo -e "  XHTTP path  : ${WHITE}$(cat "${PATH_FILE}")${NC}"

        local USER_COUNT
        USER_COUNT="$(jq '.inbounds[0].settings.clients | length' \
                     "${CONFIG_FILE}" 2>/dev/null || echo '0')"
        echo -e "  Total users : ${WHITE}${USER_COUNT}${NC}"

        if [[ "${USER_COUNT}" -gt 0 ]]; then
            echo -e "  User list   :"
            jq -r '.inbounds[0].settings.clients |
                   to_entries[] |
                   "    \(.key+1). \(.value.email)  [\(.value.id)]"' \
               "${CONFIG_FILE}" 2>/dev/null
        fi

        if [[ -x "${XRAY_BIN}" ]]; then
            local XRAY_VER
            XRAY_VER="$("${XRAY_BIN}" version 2>/dev/null | head -n1 || echo 'unknown')"
            echo -e "  Xray version: ${WHITE}${XRAY_VER}${NC}"
        fi

        # v2.3.0: show geo-data status
        echo -e "  Geo-data dir: ${WHITE}${GEO_DIR}${NC}"
        if [[ -s "${GEO_DIR}/geoip.dat" ]] && [[ -s "${GEO_DIR}/geosite.dat" ]]; then
            local gip_sz gst_sz
            gip_sz="$(du -sh "${GEO_DIR}/geoip.dat"   2>/dev/null | cut -f1)"
            gst_sz="$(du -sh "${GEO_DIR}/geosite.dat" 2>/dev/null | cut -f1)"
            echo -e "  geoip.dat   : ${GREEN}${gip_sz}${NC}"
            echo -e "  geosite.dat : ${GREEN}${gst_sz}${NC}"
        else
            echo -e "  ${RED}Geo-data files MISSING — Xray will fail to start!${NC}"
            echo -e "  Fix: ${WHITE}mkdir -p ${GEO_DIR} && bash $(realpath "$0")${NC}"
        fi
    else
        echo -e "  ${RED}Xray is not installed on this system.${NC}"
    fi

    echo ""
    separator
    echo ""

    # [4] SSL cert
    echo -e "  ${WHITE}${BOLD}[ 4 ]  SSL Certificate${NC}"
    echo ""
    if [[ -f "${CERT_FULLCHAIN}" ]]; then
        local CERT_EXPIRY CERT_CN
        CERT_EXPIRY="$(openssl x509 -noout -enddate -in "${CERT_FULLCHAIN}" 2>/dev/null \
                       | cut -d= -f2)"
        CERT_CN="$(openssl x509 -noout -subject -in "${CERT_FULLCHAIN}" 2>/dev/null \
                   | grep -oP 'CN\s*=\s*\K[^,/]+')"
        echo -e "  File    : ${GREEN}Found${NC}  (${CERT_FULLCHAIN})"
        echo -e "  CN / SAN: ${WHITE}${CERT_CN:-unknown}${NC}"
        echo -e "  Expires : ${WHITE}${CERT_EXPIRY:-unknown}${NC}"
        if openssl x509 -noout -checkend 2592000 -in "${CERT_FULLCHAIN}" &>/dev/null; then
            echo -e "  Status  : ${GREEN}Valid — more than 30 days remaining${NC}"
        else
            echo -e "  Status  : ${YELLOW}Expires < 30 days — acme.sh will auto-renew${NC}"
        fi
    else
        echo -e "  ${RED}Certificate not found at ${CERT_FULLCHAIN}.${NC}"
        echo -e "  ${YELLOW}Reinstall (Option 1) to re-issue.${NC}"
    fi

    echo ""
    separator
    echo ""

    # [5] Error log
    echo -e "  ${WHITE}${BOLD}[ 5 ]  Recent Xray Error Log (last 15 lines)${NC}"
    echo ""
    if [[ -f "${LOG_DIR}/error.log" ]]; then
        local LOG_LINES
        LOG_LINES="$(tail -n 15 "${LOG_DIR}/error.log" 2>/dev/null)"
        if [[ -z "${LOG_LINES}" ]]; then
            echo -e "  ${GREEN}No errors logged. ✓${NC}"
        else
            while IFS= read -r line; do
                echo -e "  ${DIM}${line}${NC}"
            done <<< "${LOG_LINES}"
        fi
    else
        echo -e "  ${DIM}Log not found: ${LOG_DIR}/error.log${NC}"
    fi

    echo ""
    separator
    press_enter
}

# ─────────────────────────────────────────────────────────────────────────────
# § 11  UNINSTALL  (Menu option 5)
# ─────────────────────────────────────────────────────────────────────────────

uninstall_xray() {
    print_banner
    msg_step "OPTION 5 — Uninstall Xray-core"

    echo -e "  ${RED}${BOLD}This will PERMANENTLY remove Xray and all associated data.${NC}"
    echo ""
    echo -e "  Items that will be deleted:"
    echo -e "   ${RED}→${NC}  Xray binary      : ${XRAY_BIN}"
    echo -e "   ${RED}→${NC}  Configuration    : ${XRAY_CONFIG_DIR}/"
    echo -e "   ${RED}→${NC}  Geo-data         : ${GEO_DIR}/"
    echo -e "   ${RED}→${NC}  Log files        : ${LOG_DIR}/"
    echo -e "   ${RED}→${NC}  SSL certificates : ${CERT_DIR}/"
    echo -e "   ${RED}→${NC}  systemd service  : ${SERVICE_FILE}"
    echo -e "   ${RED}→${NC}  UFW rules for ports 80 and 443"
    echo ""

    echo -e "  ${YELLOW}Also remove acme.sh and ALL its certificates? [y/N]:${NC} "
    read -r RM_ACME < /dev/tty
    echo ""
    echo -e "  ${YELLOW}Type ${WHITE}CONFIRM${YELLOW} and press Enter to proceed:${NC} "
    read -r UNINSTALL_WORD < /dev/tty
    echo ""

    if [[ "${UNINSTALL_WORD}" != "CONFIRM" ]]; then
        msg_info "Uninstallation cancelled. Nothing was modified."
        press_enter; return
    fi

    msg_step "Uninstalling..."

    systemctl stop    xray 2>/dev/null && msg_ok "Service stopped."   || \
        msg_warn "Service was not running."
    systemctl disable xray 2>/dev/null && msg_ok "Service disabled."  || \
        msg_warn "Service was not enabled."

    [[ -f "${SERVICE_FILE}" ]]    && rm -f  "${SERVICE_FILE}"    && msg_ok "Removed: ${SERVICE_FILE}"
    [[ -f "${XRAY_BIN}" ]]        && rm -f  "${XRAY_BIN}"        && msg_ok "Removed: ${XRAY_BIN}"
    [[ -d "${XRAY_CONFIG_DIR}" ]] && rm -rf "${XRAY_CONFIG_DIR}" && msg_ok "Removed: ${XRAY_CONFIG_DIR}"
    [[ -d "${GEO_DIR}" ]]         && rm -rf "${GEO_DIR}"         && msg_ok "Removed: ${GEO_DIR}"
    [[ -d "${LOG_DIR}" ]]         && rm -rf "${LOG_DIR}"         && msg_ok "Removed: ${LOG_DIR}"
    [[ -d "${CERT_DIR}" ]]        && rm -rf "${CERT_DIR}"        && msg_ok "Removed: ${CERT_DIR}"
    rm -f "${INSTALL_LOG}"

    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed  2>/dev/null || true
    msg_ok "systemd reloaded."

    if cmd_exists ufw; then
        ufw delete allow 80/tcp  2>/dev/null && msg_ok "Removed UFW rule: 80."  || true
        ufw delete allow 443/tcp 2>/dev/null && msg_ok "Removed UFW rule: 443." || true
    fi

    if [[ "${RM_ACME,,}" == "y" ]]; then
        if [[ -f "${ACME_BIN}" ]]; then
            msg_info "Uninstalling acme.sh..."
            "${ACME_BIN}" --uninstall >>"${INSTALL_LOG}" 2>&1 || true
            rm -rf "${ACME_HOME}"
            msg_ok "acme.sh removed."
        else
            msg_warn "acme.sh not found. Skipping."
        fi
        if crontab -l 2>/dev/null | grep -q 'acme.sh'; then
            crontab -l 2>/dev/null | grep -v 'acme.sh' | crontab -
            msg_ok "acme.sh cron entries removed."
        fi
    else
        msg_info "Keeping acme.sh."
    fi

    echo ""
    separator
    echo -e "  ${GREEN}${BOLD}Xray-core has been completely uninstalled.${NC}"
    echo ""
    echo -e "  System is back to its pre-installation state."
    echo -e "  To remove leftover apt packages: ${WHITE}sudo apt-get autoremove${NC}"
    echo ""
    separator
    press_enter
}

# ─────────────────────────────────────────────────────────────────────────────
# § 12  MAIN MENU
# ─────────────────────────────────────────────────────────────────────────────

show_menu() {
    print_banner
    echo -e "  ${WHITE}${BOLD}Select an option:${NC}"
    echo ""
    echo -e "  ${CYAN}  1.${NC}  ${GREEN}Install Xray-core${NC} (XHTTP + CDN Optimised)"
    echo -e "         ${DIM}Install Xray with VLESS+XHTTP on ports 80 and 443${NC}"
    echo ""
    echo -e "  ${CYAN}  2.${NC}  ${GREEN}Add User${NC}"
    echo -e "         ${DIM}Generate a UUID and add a new VLESS user${NC}"
    echo ""
    echo -e "  ${CYAN}  3.${NC}  ${GREEN}View Client Config${NC}"
    echo -e "         ${DIM}Show VLESS URLs and QR codes for all modes${NC}"
    echo ""
    echo -e "  ${CYAN}  4.${NC}  ${GREEN}Check Status${NC}"
    echo -e "         ${DIM}Service state, ports, users, cert expiry, logs${NC}"
    echo ""
    echo -e "  ${CYAN}  5.${NC}  ${RED}Uninstall${NC}"
    echo -e "         ${DIM}Completely remove Xray, configs, certs, service${NC}"
    echo ""
    echo -e "  ${CYAN}  6.${NC}  Exit"
    echo ""
    separator
    echo ""
    echo -e "  ${YELLOW}Enter choice [1-6]:${NC} "
    read -r MENU_CHOICE < /dev/tty
}

# ─────────────────────────────────────────────────────────────────────────────
# § 13  ENTRY POINT
# ─────────────────────────────────────────────────────────────────────────────

main() {
    # Force a sane TERM for Android SSH apps (JuiceSSH, ConnectBot, Termius).
    export TERM="${TERM:-xterm-256color}"

    # Rewire stdin to the real TTY device. This is the definitive fix for
    # Android SSH apps that break 'read' inside functions after 'clear'.
    # Every 'read' call also explicitly uses '< /dev/tty' as backup.
    exec 0</dev/tty

    check_root
    check_ubuntu_2404

    mkdir -p "$(dirname "${INSTALL_LOG}")" 2>/dev/null || true

    while true; do
        show_menu
        case "${MENU_CHOICE}" in
            1) install_xray       ;;
            2) add_user           ;;
            3) view_client_config ;;
            4) check_status       ;;
            5) uninstall_xray     ;;
            6)
                echo ""
                echo -e "  ${GREEN}Goodbye.${NC}"
                echo ""
                exit 0
                ;;
            *)
                msg_err "Invalid choice '${MENU_CHOICE}'. Enter a number from 1 to 6."
                sleep 1
                ;;
        esac
    done
}

main "$@"
