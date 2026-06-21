#!/usr/bin/env bash
# =============================================================================
#  __  __  ____      _     __  __  _   _ _____ _____  _____
# \ \/ /|  _ \    / \    \ \/ / | | | |_   _|_   _||  __ \
#  \  / | |_) |  / _ \    \  /  | |_| |  | |   | |  | |__) |
#  /  \ |  _ <  / ___ \   /  \  |  _  |  | |   | |  |  ___/
# /_/\_\|_| \_\/_/   \_\ /_/\_\ |_| |_| _|_|_  |_|  |_|
#
# xray-xhttp-manager.sh  ·  Version 4.0.0
# =============================================================================
# Description : Automates the full lifecycle of Xray-core, fronted by nginx,
#               using XHTTP and HTTP Upgrade transports — both on the
#               standard ports 80 and 443 — on Ubuntu 24.04 LTS.
#               · Port 80   — nginx, HTTP Upgrade only (NTLS / CDN origin)
#               · Port 443  — nginx, XHTTP + HTTP Upgrade, both via TLS
#               · Xray itself never binds 80 or 443. It listens on two
#                 internal loopback-only ports; nginx is the only public
#                 listener and routes by path to the right Xray inbound.
#               · Protocol : VLESS (zero-overhead, CDN-friendly)
#               · CDN      : Cloudflare and compatible providers
#               · Why nginx in front: VLESS's own path-based fallback
#                 mechanism cannot parse HTTP/2 or XHTTP framing — only
#                 plaintext HTTP/1.1 request lines — so trying to share
#                 80/443 between two transports with Xray alone is
#                 fundamentally unreliable. nginx is a real HTTP server;
#                 its location path-matching works regardless of HTTP
#                 version or transport framing.
#               · Why XHTTP needs its own TLS-only port: XHTTP behind
#                 nginx must use grpc_pass (not proxy_pass) because its
#                 framing is HTTP/2 stream-based; proxy_pass is built for
#                 buffered HTTP/1.1 request/response and breaks it. nginx
#                 can only negotiate HTTP/2 safely per-connection via TLS
#                 ALPN — there is no cleartext (h2c) mode that can safely
#                 coexist with plain HTTP/1.1 in the same nginx server
#                 block, which port 80 also needs for the Upgrade
#                 handshake and static decoy content. So: XHTTP → 443
#                 only; HTTP Upgrade → both 80 and 443.
#
# Patch notes :
#   v2.1.0 — All read -rp replaced with echo + read -r (Android SSH fix)
#   v2.2.0 — exec 0</dev/tty + TERM export in main() (Android PTY fix)
#   v2.3.0 — geoip.dat/geosite.dat: create /usr/local/share/xray/ first,
#             download geo files there, add XRAY_LOCATION_ASSET env to
#             systemd service. Eliminates "no such file" crash on start.
#   v3.0.0 — HTTP Upgrade added on its OWN dedicated ports (8880/8443)
#             instead of sharing 80/443 with XHTTP via TCP fallback routing.
#             An earlier fallback-sharing design (v2.5.0–v2.7.0, never
#             released) tried to multiplex both transports onto 80/443 using
#             VLESS path-based fallbacks. That approach broke repeatedly:
#             fallbacks can't parse HTTP/2 frames (h2 ALPN caused silent
#             disconnects), require a catch-all entry or every unmatched
#             connection is dropped, and add an inner/outer split that
#             desyncs path values during any future edit.
#   v4.0.0 — Replaced dedicated ports (8880/8443) with nginx as a real
#             reverse proxy in front of Xray, restoring 80/443 as the only
#             public ports as originally requested. Xray's XHTTP and HTTP
#             Upgrade inbounds moved to internal loopback ports with no
#             "path" set (nginx now owns path validation — setting path on
#             both layers is a documented conflict that silently breaks
#             responses: github.com/XTLS/Xray-core/discussions/5822).
#             XHTTP uses grpc_pass per Xray's own official nginx reference
#             (github.com/XTLS/Xray-examples, VLESS-XHTTP3-Nginx) since
#             proxy_pass cannot relay XHTTP's HTTP/2 stream framing.
#             Client mode set to packet-up, the officially documented
#             "maximum compatibility behind a reverse proxy / CDN" mode.
#             IMPORTANT CONSTRAINT discovered during this build: XHTTP via
#             grpc_pass requires HTTP/2, and nginx can only negotiate HTTP/2
#             safely on a per-connection basis through TLS ALPN — there is
#             no cleartext equivalent that coexists with plain HTTP/1.1 in
#             the same server block. So XHTTP is TLS-only (port 443); HTTP
#             Upgrade, being genuine HTTP/1.1 Connection:Upgrade, works
#             cleartext and is available on both 80 and 443.
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
UPGRADE_PATH_FILE="${XRAY_CONFIG_DIR}/.upgrade_path"

CERT_DIR="/etc/ssl/xray"
CERT_FULLCHAIN="${CERT_DIR}/fullchain.pem"
CERT_KEY="${CERT_DIR}/privkey.pem"

ACME_HOME="/root/.acme.sh"
ACME_BIN="${ACME_HOME}/acme.sh"

PORT_TLS=443
PORT_NTLS=80
# Internal-only loopback ports — never exposed publicly. nginx terminates
# TLS and does path-based routing on 80/443, then hands off plaintext
# HTTP/2 (XHTTP) or HTTP/1.1 Upgrade (HTTP Upgrade) to these loopback ports.
PORT_XHTTP_INNER=20080
PORT_UPGRADE_INNER=20081

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
    echo "  ║   Transport : VLESS + XHTTP / HTTP Upgrade           v4.0.0     ║"
    echo "  ║   Front-end : nginx (TLS-terminating, path-based router)        ║"
    echo "  ║   Port 80   : nginx → HTTP Upgrade  (NTLS / CDN origin)         ║"
    echo "  ║   Port 443  : nginx → XHTTP + HTTP Upgrade  (TLS, LE cert)      ║"
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
    msg_step "Step 1/10 — Checking for port and service conflicts"
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
    msg_step "Step 2/10 — Domain configuration"
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
    msg_step "Step 3/10 — DNS resolution check"
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
    msg_step "Step 4/10 — Installing system dependencies"
    msg_info "Running apt-get update..."
    if ! apt-get update -y >>"${INSTALL_LOG}" 2>&1; then
        msg_err "apt-get update failed. Check your internet connection." "exit"
    fi
    msg_ok "Package lists updated."

    local -a DEPS=("curl" "wget" "unzip" "jq" "uuid-runtime" \
                   "socat" "dnsutils" "qrencode" "openssl" "nginx")
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

    # nginx is installed now but must NOT be running yet — acme.sh standalone
    # mode (Step 6) needs port 80 completely free to issue the certificate.
    # nginx is configured and started in the new final step, after Xray and
    # the certificate both exist.
    systemctl stop nginx 2>/dev/null || true
    systemctl disable nginx >>"${INSTALL_LOG}" 2>&1 || true

    # ── Step 5: acme.sh ────────────────────────────────────────────────────────
    msg_step "Step 5/10 — Setting up acme.sh (Let's Encrypt client)"
    if [[ -f "${ACME_BIN}" ]]; then
        msg_ok "acme.sh already installed."
        export PATH="${ACME_HOME}:${PATH}"
    else
        msg_info "Downloading acme.sh..."
        if ! curl -fsSL "https://get.acme.sh" | bash -s "email=admin@${DOMAIN}" \
             >>"${INSTALL_LOG}" 2>&1; then
            msg_err "acme.sh installation failed. See ${INSTALL_LOG}." "exit"
        fi
        msg_ok "acme.sh installed to ${ACME_HOME}."
    fi
    # Ensure acme.sh is in PATH for this session
    export PATH="${ACME_HOME}:${PATH}"
    msg_info "Setting CA to Let's Encrypt..."
    "${ACME_BIN}" --set-default-ca --server letsencrypt >>"${INSTALL_LOG}" 2>&1 || true
    msg_ok "CA set: Let's Encrypt."

    # ── Step 6: SSL certificate ────────────────────────────────────────────────
    msg_step "Step 6/10 — Issuing SSL certificate for ${DOMAIN}"
    echo -e "  ${WHITE}acme.sh standalone${NC} will start a temporary HTTP server on port 80."
    echo -e "  ${YELLOW}Requirements:${NC}"
    echo -e "   • Port 80 reachable from the internet."
    echo -e "   • Domain pointing directly to this server (no CDN proxy)."
    echo ""
    echo -e "  ${YELLOW}Ready to issue certificate? [Y/n]:${NC} "
    read -r CERT_CONFIRM < /dev/tty
    [[ "${CERT_CONFIRM,,}" == "n" ]] && { msg_info "Cancelled."; press_enter; return; }

    mkdir -p "${CERT_DIR}"
    msg_info "Stopping Xray and nginx temporarily to free port 80..."
    systemctl stop xray  2>/dev/null || true
    systemctl stop nginx 2>/dev/null || true
    sleep 1
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
         --pre-hook  "systemctl stop  nginx 2>/dev/null; true" \
         --post-hook "systemctl reload nginx 2>/dev/null || systemctl start nginx 2>/dev/null; true" \
         >>"${INSTALL_LOG}" 2>&1; then
        msg_err "Certificate copy failed. See ${INSTALL_LOG}." "exit"
    fi
    chmod 600 "${CERT_KEY}"
    chmod 644 "${CERT_FULLCHAIN}"
    msg_ok "Certificate installed. Auto-renewal hooks registered."

    # ── Step 7: Download Xray binary ───────────────────────────────────────────
    msg_step "Step 7/10 — Downloading and installing Xray-core"

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
    msg_step "Step 8/10 — Creating configuration files"

    local XHTTP_PATH UPGRADE_PATH
    XHTTP_PATH="/$(tr -dc 'a-z0-9' < /dev/urandom | head -c 12)"
    UPGRADE_PATH="/$(tr -dc 'a-z0-9' < /dev/urandom | head -c 12)"
    msg_ok "Generated XHTTP path   : ${WHITE}${XHTTP_PATH}${NC}"
    msg_ok "Generated Upgrade path : ${WHITE}${UPGRADE_PATH}${NC}"

    mkdir -p "${XRAY_CONFIG_DIR}" "${LOG_DIR}" "${CERT_DIR}"
    touch "${LOG_DIR}/access.log" "${LOG_DIR}/error.log"
    chmod 640 "${LOG_DIR}/access.log" "${LOG_DIR}/error.log"

    echo "${DOMAIN}"       > "${DOMAIN_FILE}"
    echo "${XHTTP_PATH}"   > "${PATH_FILE}"
    echo "${UPGRADE_PATH}" > "${UPGRADE_PATH_FILE}"

    local INIT_UUID INIT_USER
    INIT_UUID="$(uuidgen)"
    INIT_USER="user01"
    msg_ok "Initial user: ${WHITE}${INIT_USER}${NC}  UUID: ${WHITE}${INIT_UUID}${NC}"

    # Write config.json
    # Two INTERNAL, loopback-only inbounds. nginx owns ports 80 and 443
    # publicly, terminates TLS itself, and routes by path to whichever
    # inbound matches — XHTTP requests go to xhttp-inner via grpc_pass
    # (XHTTP's mode:auto/packet-up speaks HTTP/2 framing, which only
    # nginx's grpc_pass understands correctly — proxy_pass breaks it),
    # HTTP Upgrade requests go to upgrade-inner via proxy_pass with
    # Connection:Upgrade headers (it's a real HTTP/1.1 upgrade, like
    # WebSocket). Neither inner inbound sets "path" or "host" in its
    # settings — nginx already validated and stripped the path, and
    # setting it again on the Xray side causes a documented conflict
    # where Xray accepts the request but the client never gets a
    # response. See: github.com/XTLS/Xray-core/discussions/5822
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
      "tag": "xhttp-inner",
      "port": ${PORT_XHTTP_INNER},
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${INIT_UUID}",
            "email": "${INIT_USER}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "mode": "packet-up",
          "extra": {
            "scMaxEachPostBytes": 1000000,
            "scMinPostsIntervalMs": 30,
            "xPaddingBytes": "100-1000",
            "noGRPCHeader": false
          }
        }
      },
      "sniffing": { "enabled": false }
    },
    {
      "tag": "upgrade-inner",
      "port": ${PORT_UPGRADE_INNER},
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${INIT_UUID}",
            "email": "${INIT_USER}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "httpupgrade",
        "security": "none",
        "httpupgradeSettings": {}
      },
      "sniffing": { "enabled": false }
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
    msg_step "Step 9/10 — Creating systemd service and configuring firewall"

    # v2.3.0 KEY FIX: The Environment= line tells Xray exactly where to find
    # geoip.dat and geosite.dat. Without this, Xray defaults to searching
    # /usr/local/bin/ or the binary's directory — neither of which has the files.
    cat > "${SERVICE_FILE}" << SYSTEMD_EOF
[Unit]
Description=Xray-core (VLESS+XHTTP/HTTPUpgrade, internal — fronted by nginx)
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
        ufw allow OpenSSH                                  >>"${INSTALL_LOG}" 2>&1 || true
        ufw allow 80/tcp  comment 'nginx — HTTP Upgrade NTLS/CDN'  >>"${INSTALL_LOG}" 2>&1 || true
        ufw allow 443/tcp comment 'nginx — XHTTP/Upgrade TLS'      >>"${INSTALL_LOG}" 2>&1 || true
        msg_ok "UFW: ports 22, 80 and 443 opened. Inner Xray ports stay loopback-only."
    else
        msg_warn "UFW not found. Open ports 80/443 in your cloud security group manually."
    fi

    # ── Step 10: nginx reverse proxy (path-based router for both transports) ───
    msg_step "Step 10/10 — Configuring nginx as the public-facing router"
    #
    # nginx owns ports 80 and 443. It terminates TLS itself (Let's Encrypt
    # cert from Step 6) and splits incoming requests by path:
    #   /${XHTTP_PATH}    → grpc_pass  → 127.0.0.1:${PORT_XHTTP_INNER}
    #   /${UPGRADE_PATH}  → proxy_pass → 127.0.0.1:${PORT_UPGRADE_INNER}
    #
    # grpc_pass is required for XHTTP, not proxy_pass — XHTTP's mode:packet-up
    # speaks HTTP/2 stream framing, and nginx's proxy_pass (built for buffered
    # HTTP/1.1 request/response) cannot relay that correctly: it produces
    # "upstream prematurely closed connection" errors and silent client-side
    # hangs. grpc_pass natively understands HTTP/2 framing and passes it
    # through cleanly. This matches Xray's own official reference config:
    # github.com/XTLS/Xray-examples/blob/main/VLESS-XHTTP3-Nginx/nginx.conf
    #
    # HTTP Upgrade is the opposite: it really is an HTTP/1.1 `Connection:
    # Upgrade` handshake (the same mechanism WebSocket uses), so it needs
    # proxy_pass with explicit Upgrade/Connection headers, not grpc_pass.
    #
    # Any request to an unrecognized path returns 404, exactly mirroring
    # the "must return 400/404, never 502" sanity check the Xray community
    # uses to confirm nginx + Xray are wired correctly.

    mkdir -p /var/www/html
    if [[ ! -f /var/www/html/index.html ]]; then
        cat > /var/www/html/index.html << 'HTML_EOF'
<!DOCTYPE html>
<html><head><title>Welcome</title></head>
<body><h1>It works.</h1></body></html>
HTML_EOF
    fi

    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

    cat > /etc/nginx/sites-available/xray-router << NGINX_EOF
# ── Port 80 — HTTP Upgrade only (NTLS / CDN origin) ────────────────────────
# XHTTP is NOT served here. grpc_pass requires HTTP/2, and nginx negotiates
# HTTP/2 per-listener via TLS ALPN — there is no equivalent safe negotiation
# on a cleartext port that can coexist with plain HTTP/1.1 in the same
# server block. Forcing h2c cleartext on port 80 would break the plain
# HTTP/1.1 Upgrade handshake and static-file serving in this same block.
# This matches Xray's own official nginx reference, which only ever uses
# grpc_pass on the TLS-terminated, http2-negotiated server block.
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    root /var/www/html;
    index index.html;

    client_max_body_size 0;
    client_body_timeout   5m;
    client_header_timeout 5m;
    keepalive_timeout     5m;

    location = /${UPGRADE_PATH#/} {
        if (\$http_upgrade != "websocket") { return 404; }
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 86400;
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${PORT_UPGRADE_INNER};
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}

# ── Port 443 — TLS direct (Let's Encrypt cert, no CDN in front) ────────────
# Both transports live here. TLS lets nginx negotiate HTTP/2 via ALPN
# automatically per-connection — h2 clients (XHTTP/grpc_pass) and HTTP/1.1
# clients (the Upgrade handshake) are routed correctly without conflict,
# which is impossible to do safely on a cleartext listener.
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${DOMAIN};

    ssl_certificate     ${CERT_FULLCHAIN};
    ssl_certificate_key ${CERT_KEY};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    root /var/www/html;
    index index.html;

    client_max_body_size 0;
    client_body_timeout   5m;
    client_header_timeout 5m;
    keepalive_timeout     5m;

    location = /${XHTTP_PATH#/} {
        grpc_pass grpc://127.0.0.1:${PORT_XHTTP_INNER};
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_read_timeout 315;
        grpc_send_timeout 5m;
    }
    location /${XHTTP_PATH#/}/ {
        grpc_pass grpc://127.0.0.1:${PORT_XHTTP_INNER};
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_read_timeout 315;
        grpc_send_timeout 5m;
    }

    location = /${UPGRADE_PATH#/} {
        if (\$http_upgrade != "websocket") { return 404; }
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 86400;
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${PORT_UPGRADE_INNER};
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
NGINX_EOF

    ln -sf /etc/nginx/sites-available/xray-router /etc/nginx/sites-enabled/xray-router

    # Verify nginx actually has gRPC support compiled in. The stock Ubuntu
    # 'nginx' apt package (nginx-core) includes ngx_http_grpc_module by
    # default, but nginx-light does not — if grpc_pass is unrecognized,
    # nginx -t fails with "unknown directive" which is confusing without
    # this explicit check pointing at the real cause.
    if ! nginx -V 2>&1 | grep -q 'http_v2_module\|grpc'; then
        msg_warn "Could not confirm gRPC/HTTP2 module support in this nginx build."
        msg_warn "If 'nginx -t' below fails with 'unknown directive grpc_pass',"
        msg_warn "run: ${WHITE}apt-get install --reinstall nginx${NC} (not nginx-light)."
    fi

    if ! nginx -t >>"${INSTALL_LOG}" 2>&1; then
        msg_err "nginx config test FAILED. Check: ${WHITE}nginx -t${NC} and ${INSTALL_LOG}"
        press_enter; return
    fi
    msg_ok "nginx config syntax OK."

    systemctl enable nginx  >>"${INSTALL_LOG}" 2>&1 || true
    if ! systemctl restart nginx; then
        msg_err "nginx failed to start. Run: ${WHITE}journalctl -u nginx -n 30 --no-pager${NC}"
        press_enter; return
    fi
    sleep 1
    if systemctl is-active --quiet nginx; then
        msg_ok "nginx is ${GREEN}${BOLD}running${NC} and routing ports 80/443."
    else
        msg_warn "nginx may not be running — use Option 4 to investigate."
    fi

    separator
    echo ""
    echo -e "${GREEN}${BOLD}  ✔  Installation complete!${NC}"
    echo ""
    echo -e "  ${WHITE}Domain         :${NC} ${DOMAIN}"
    echo -e "  ${WHITE}XHTTP path     :${NC} ${XHTTP_PATH}"
    echo -e "  ${WHITE}Upgrade path   :${NC} ${UPGRADE_PATH}"
    echo -e "  ${WHITE}Port 80        :${NC} nginx — HTTP Upgrade only, NTLS (CDN-friendly)"
    echo -e "  ${WHITE}Port 443       :${NC} nginx — XHTTP + HTTP Upgrade, TLS (Let's Encrypt cert)"
    echo -e "  ${WHITE}Internal ports :${NC} ${PORT_XHTTP_INNER} (XHTTP) / ${PORT_UPGRADE_INNER} (Upgrade) — loopback only"
    echo -e "  ${WHITE}Initial user   :${NC} ${INIT_USER}  UUID: ${INIT_UUID}"
    echo -e "  ${WHITE}Geo-data       :${NC} ${GEO_DIR}/"
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
            msg_ok "User '${USERNAME}' added to all 4 inbounds (XHTTP x2 + Upgrade x2)."
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

    if [[ ! -f "${DOMAIN_FILE}" ]] || [[ ! -f "${PATH_FILE}" ]] || [[ ! -f "${UPGRADE_PATH_FILE}" ]]; then
        msg_err "Metadata files missing. Reinstall Xray (Option 1)."
        press_enter; return
    fi

    local DOMAIN XHTTP_PATH UPGRADE_PATH
    DOMAIN="$(cat "${DOMAIN_FILE}")"
    XHTTP_PATH="$(cat "${PATH_FILE}")"
    UPGRADE_PATH="$(cat "${UPGRADE_PATH_FILE}" 2>/dev/null || echo '/upgrade')"

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

    # [A] XHTTP CDN Mode — client:443 (or CDN edge) → nginx:443 → grpc_pass → xhttp-inner
    # mode=packet-up is the most CDN/reverse-proxy-compatible XHTTP mode
    # (official guidance: "if it can't get through other CDNs or proxy
    # software, set mode to packet-up — strongest compatibility").
    local CDN_URL
    CDN_URL="vless://${USER_UUID}@${DOMAIN}:443"
    CDN_URL+="?encryption=none&type=xhttp&mode=packet-up"
    CDN_URL+="&path=${PATH_ENC}&host=${DOMAIN}"
    CDN_URL+="&security=tls&sni=${DOMAIN}&fp=chrome&alpn=h2"
    CDN_URL+="#${SELECTED_USER}-XHTTP-CDN"

    # [B] XHTTP Direct TLS — client connects straight to nginx:443 (no CDN)
    local DIRECT_URL
    DIRECT_URL="vless://${USER_UUID}@${DOMAIN}:443"
    DIRECT_URL+="?encryption=none&type=xhttp&mode=packet-up"
    DIRECT_URL+="&path=${PATH_ENC}&host=${DOMAIN}"
    DIRECT_URL+="&security=tls&sni=${DOMAIN}&fp=chrome&alpn=h2"
    DIRECT_URL+="#${SELECTED_USER}-XHTTP-Direct-TLS"

    local UPGRADE_ENC
    UPGRADE_ENC="$(urlencode "${UPGRADE_PATH}")"

    # [D] HTTP Upgrade CDN Mode — client:443 (or CDN edge) → nginx:443 → proxy_pass (Upgrade)
    local UPGRADE_CDN_URL
    UPGRADE_CDN_URL="vless://${USER_UUID}@${DOMAIN}:443"
    UPGRADE_CDN_URL+="?encryption=none&type=httpupgrade"
    UPGRADE_CDN_URL+="&path=${UPGRADE_ENC}&host=${DOMAIN}"
    UPGRADE_CDN_URL+="&security=tls&sni=${DOMAIN}&fp=chrome"
    UPGRADE_CDN_URL+="#${SELECTED_USER}-Upgrade-CDN"

    # [E] HTTP Upgrade Direct TLS — client connects straight to nginx:443 (no CDN)
    local UPGRADE_DIRECT_URL
    UPGRADE_DIRECT_URL="vless://${USER_UUID}@${DOMAIN}:443"
    UPGRADE_DIRECT_URL+="?encryption=none&type=httpupgrade"
    UPGRADE_DIRECT_URL+="&path=${UPGRADE_ENC}&host=${DOMAIN}"
    UPGRADE_DIRECT_URL+="&security=tls&sni=${DOMAIN}&fp=chrome"
    UPGRADE_DIRECT_URL+="#${SELECTED_USER}-Upgrade-Direct-TLS"

    # [F] HTTP Upgrade NTLS — nginx:80, unencrypted — testing only
    local UPGRADE_NTLS_URL
    UPGRADE_NTLS_URL="vless://${USER_UUID}@${DOMAIN}:80"
    UPGRADE_NTLS_URL+="?encryption=none&type=httpupgrade"
    UPGRADE_NTLS_URL+="&path=${UPGRADE_ENC}&host=${DOMAIN}&security=none"
    UPGRADE_NTLS_URL+="#${SELECTED_USER}-Upgrade-NTLS-TestOnly"

    clear
    echo ""
    separator
    echo -e "  ${WHITE}${BOLD}Client config for: ${CYAN}${SELECTED_USER}${NC}"
    separator
    echo -e "  ${WHITE}Domain    :${NC} ${DOMAIN}"
    echo -e "  ${WHITE}UUID      :${NC} ${USER_UUID}"
    echo -e "  ${WHITE}XHTTP Path  :${NC} ${XHTTP_PATH}"
    echo -e "  ${WHITE}Upgrade Path:${NC} ${UPGRADE_PATH}"
    echo ""

    # ── [A] XHTTP CDN ─────────────────────────────────────────────────────────
    separator
    echo -e "  ${GREEN}${BOLD}[A]  XHTTP CDN MODE — Client:443 → CDN → nginx:443 → Xray${NC}"
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

    # ── [B] XHTTP Direct TLS ──────────────────────────────────────────────────
    separator
    echo -e "  ${GREEN}${BOLD}[B]  XHTTP DIRECT TLS — Client:443 → nginx:443 (no CDN) → Xray${NC}"
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

    # ── [C] HTTP Upgrade CDN ──────────────────────────────────────────────────
    separator
    echo -e "  ${GREEN}${BOLD}[C]  HTTP UPGRADE CDN MODE — Client:80 → CDN → nginx:80 → Xray${NC}"
    echo -e "  ${YELLOW}Use when:${NC} Cloudflare/CDN orange-cloud proxy is enabled."
    echo -e "  ${DIM}Port 80 is HTTP Upgrade's home — XHTTP requires TLS, see [A]/[B] above.${NC}"
    echo ""
    echo -e "  ${WHITE}VLESS URL:${NC}"
    echo -e "  ${CYAN}${UPGRADE_CDN_URL}${NC}"
    echo ""
    if cmd_exists qrencode; then
        echo -e "  ${WHITE}QR Code:${NC}"
        echo ""
        qrencode -t ANSIUTF8 -m 2 "${UPGRADE_CDN_URL}"
        echo ""
    fi

    # ── [D] HTTP Upgrade Direct TLS ───────────────────────────────────────────
    separator
    echo -e "  ${GREEN}${BOLD}[D]  HTTP UPGRADE DIRECT TLS — Client:443 → nginx:443 (no CDN) → Xray${NC}"
    echo -e "  ${YELLOW}Use when:${NC} DNS is grey-cloud / DNS-only (no CDN proxy)."
    echo ""
    echo -e "  ${WHITE}VLESS URL:${NC}"
    echo -e "  ${CYAN}${UPGRADE_DIRECT_URL}${NC}"
    echo ""
    if cmd_exists qrencode; then
        echo -e "  ${WHITE}QR Code:${NC}"
        echo ""
        qrencode -t ANSIUTF8 -m 2 "${UPGRADE_DIRECT_URL}"
        echo ""
    fi

    # ── [E] HTTP Upgrade NTLS ─────────────────────────────────────────────────
    separator
    echo -e "  ${MAGENTA}${BOLD}[E]  HTTP UPGRADE NTLS — nginx:80, unencrypted — TESTING ONLY${NC}"
    echo -e "  ${RED}  ⚠  Do NOT use in production. Traffic is plain-text.${NC}"
    echo ""
    echo -e "  ${WHITE}VLESS URL:${NC}"
    echo -e "  ${CYAN}${UPGRADE_NTLS_URL}${NC}"
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
    local P80_INFO P443_INFO PXHTTP_INFO PUPGRADE_INFO NGINX_ACTIVE
    P80_INFO="$(ss -tlnp 2>/dev/null | grep ':80 ' || echo '')"
    P443_INFO="$(ss -tlnp 2>/dev/null | grep ':443 ' || echo '')"
    PXHTTP_INFO="$(ss -tlnp 2>/dev/null | grep ":${PORT_XHTTP_INNER} " || echo '')"
    PUPGRADE_INFO="$(ss -tlnp 2>/dev/null | grep ":${PORT_UPGRADE_INNER} " || echo '')"
    NGINX_ACTIVE="$(systemctl is-active nginx 2>/dev/null || echo 'inactive')"

    echo -e "  ${WHITE}${BOLD}Public (nginx):${NC}"
    if [[ -n "${P80_INFO}" ]]; then
        echo -e "  Port 80   (nginx, HTTP Upgrade NTLS)  : ${GREEN}${BOLD}● LISTENING${NC}"
        echo -e "  ${DIM}  ${P80_INFO}${NC}"
    else
        echo -e "  Port 80   (nginx, HTTP Upgrade NTLS)  : ${RED}○ NOT LISTENING${NC}"
    fi

    if [[ -n "${P443_INFO}" ]]; then
        echo -e "  Port 443  (nginx, XHTTP+Upgrade TLS)  : ${GREEN}${BOLD}● LISTENING${NC}"
        echo -e "  ${DIM}  ${P443_INFO}${NC}"
    else
        echo -e "  Port 443  (nginx, XHTTP+Upgrade TLS)  : ${RED}○ NOT LISTENING${NC}"
    fi

    if [[ "${NGINX_ACTIVE}" == "active" ]]; then
        echo -e "  nginx service                         : ${GREEN}${BOLD}● ${NGINX_ACTIVE}${NC}"
    else
        echo -e "  nginx service                         : ${RED}○ ${NGINX_ACTIVE}${NC}"
    fi

    echo ""
    echo -e "  ${WHITE}${BOLD}Internal (Xray, loopback-only — not exposed):${NC}"
    if [[ -n "${PXHTTP_INFO}" ]]; then
        echo -e "  Port ${PORT_XHTTP_INNER} (XHTTP inner)   : ${GREEN}${BOLD}● LISTENING${NC}"
    else
        echo -e "  Port ${PORT_XHTTP_INNER} (XHTTP inner)   : ${RED}○ NOT LISTENING${NC}"
    fi

    if [[ -n "${PUPGRADE_INFO}" ]]; then
        echo -e "  Port ${PORT_UPGRADE_INNER} (Upgrade inner) : ${GREEN}${BOLD}● LISTENING${NC}"
    else
        echo -e "  Port ${PORT_UPGRADE_INNER} (Upgrade inner) : ${RED}○ NOT LISTENING${NC}"
    fi

    echo ""
    separator
    echo ""

    # [3] Config summary
    echo -e "  ${WHITE}${BOLD}[ 3 ]  Configuration Summary${NC}"
    echo ""
    if is_xray_installed; then
        [[ -f "${DOMAIN_FILE}" ]]       && echo -e "  Domain        : ${WHITE}$(cat "${DOMAIN_FILE}")${NC}"
        [[ -f "${PATH_FILE}" ]]         && echo -e "  XHTTP path    : ${WHITE}$(cat "${PATH_FILE}")${NC}"
        [[ -f "${UPGRADE_PATH_FILE}" ]] && echo -e "  Upgrade path  : ${WHITE}$(cat "${UPGRADE_PATH_FILE}")${NC}"

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

    systemctl stop    xray  2>/dev/null && msg_ok "Xray service stopped."   || \
        msg_warn "Xray service was not running."
    systemctl disable xray  2>/dev/null && msg_ok "Xray service disabled."  || \
        msg_warn "Xray service was not enabled."
    systemctl stop    nginx 2>/dev/null && msg_ok "nginx stopped."          || \
        msg_warn "nginx was not running."
    systemctl disable nginx 2>/dev/null && msg_ok "nginx disabled."         || \
        msg_warn "nginx was not enabled."

    rm -f /etc/nginx/sites-enabled/xray-router \
          /etc/nginx/sites-available/xray-router 2>/dev/null && \
        msg_ok "Removed nginx xray-router config."

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
