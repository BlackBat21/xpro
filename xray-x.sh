#!/usr/bin/env bash
#
# ============================================================================
#  XRAY-X  |  VLESS Multi-Transport Manager  (menu-driven)
#  Target OS  : Ubuntu 24.04 LTS (Noble Numbat)
#  Engine     : Xray-core (VLESS)
#  Transports : WebSocket + HTTP Upgrade + gRPC + XHTTP  (ALL AT ONCE)
#  Routing    : Path-based fallback, single vhost on 80 (NTLS) / 443 (TLS)
#  CDN Model  : Universal / provider-agnostic
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Globals & helpers
# ---------------------------------------------------------------------------
VERSION="1.0.0"
XRAY_CONF_DIR="/usr/local/etc/xray"
XRAY_CONF="${XRAY_CONF_DIR}/config.json"
CERT_DIR="${XRAY_CONF_DIR}/certs"
STATE_DIR="/etc/xray-x"
STATE_FILE="${STATE_DIR}/state.env"        # persisted domain / paths / overrides
ACCT_DB="${STATE_DIR}/accounts.db"         # username|uuid per line
NGINX_SITE="/etc/nginx/sites-available/xray-x.conf"
NGINX_LINK="/etc/nginx/sites-enabled/xray-x.conf"
ACME_HOME="${HOME}/.acme.sh"

# Loopback port map: transport -> (TLS port, NTLS port)
declare -A PORT_TLS=(  [ws]=10000 [httpupgrade]=10010 [grpc]=10020 [xhttp]=10030 )
declare -A PORT_NTLS=( [ws]=10001 [httpupgrade]=10011 [grpc]=10021 [xhttp]=10031 )
TRANSPORTS=(ws httpupgrade grpc xhttp)

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; CYN='\033[0;36m'
BLU='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${CYN}[*]${NC} $*"; }
ok()    { echo -e "${GRN}[+]${NC} $*"; }
warn()  { echo -e "${YLW}[!]${NC} $*"; }
die()   { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }
pause() { echo; read -rp "Press ENTER to return to the menu..." _; }

[[ $EUID -eq 0 ]] || die "This script must be run as root (use: sudo bash $0)."

# ===========================================================================
#  STATE PERSISTENCE
# ===========================================================================
load_state() { [[ -f "${STATE_FILE}" ]] && source "${STATE_FILE}"; return 0; }
save_state() {
    mkdir -p "${STATE_DIR}"
    cat > "${STATE_FILE}" <<EOF
DOMAIN="${DOMAIN}"
SNI_VALUE="${SNI_VALUE}"
HOST_VALUE="${HOST_VALUE}"
WS_PATH="${WS_PATH}"
HU_PATH="${HU_PATH}"
GRPC_SERVICE="${GRPC_SERVICE}"
XH_PATH="${XH_PATH}"
XH_MODE="${XH_MODE}"
EOF
    chmod 600 "${STATE_FILE}"
}
is_provisioned() { [[ -f "${STATE_FILE}" && -f "${CERT_DIR}/${DOMAIN:-__none__}.crt" ]]; }

# ===========================================================================
# 1. PREREQUISITE & PACKAGE SETUP  (runs once, idempotent)
# ===========================================================================
install_prereqs() {
    info "Updating system and installing base packages..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y \
        curl wget jq socat cron dnsutils ufw ca-certificates \
        nginx unzip xxd git
    systemctl enable --now cron

    if ! nginx -V 2>&1 | grep -q -- 'http_v2_module'; then
        die "Nginx lacks http_v2_module — gRPC proxying impossible. Install nginx-full."
    fi

    # Xray-core (xhttp/httpupgrade need a recent release; installer pulls latest).
    if ! command -v xray >/dev/null 2>&1; then
        info "Installing Xray-core..."
        bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    else
        info "Ensuring Xray-core is current..."
        bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install || true
    fi

    # acme.sh install: avoid `curl https://get.acme.sh | sh`. On some hosts/
    # states that installer leaves behind a broken/"fragmented" acme.sh copy
    # that re-triggers its own bootstrap on every call and mangles flags into
    # "Unknown parameter: ----issue" style errors (a known upstream quirk —
    # see acmesh-official/acme.sh#3683). Cloning the repo and running its
    # install.sh directly is more reliable and gives the same end result.
    if [[ ! -x "${ACME_HOME}/acme.sh" ]] || ! "${ACME_HOME}/acme.sh" --issue --help >/dev/null 2>&1; then
        if [[ -d "${ACME_HOME}" ]]; then
            warn "Existing acme.sh install at ${ACME_HOME} looks broken; reinstalling cleanly..."
            rm -rf "${ACME_HOME}"
        fi
        info "Installing acme.sh (clean clone)..."
        read -rp "Enter e-mail for ACME registration (Let's Encrypt): " ACME_EMAIL
        [[ -n "${ACME_EMAIL}" ]] || die "ACME e-mail cannot be empty."

        local tmp_clone; tmp_clone="$(mktemp -d)"
        git clone --depth 1 https://github.com/acmesh-official/acme.sh.git "${tmp_clone}" \
            || die "Failed to clone acme.sh repo. Check network access to github.com."
        (cd "${tmp_clone}" && ./acme.sh --install -m "${ACME_EMAIL}" --home "${ACME_HOME}") \
            || die "acme.sh install.sh failed."
        rm -rf "${tmp_clone}"
    fi

    # shellcheck disable=SC1090
    source "${ACME_HOME}/acme.sh.env" 2>/dev/null || true

    # Verify acme.sh is actually callable for real commands (not just --version,
    # which can succeed even on a broken/fragmented install).
    [[ -x "${ACME_HOME}/acme.sh" ]] || die "acme.sh install did not produce an executable at ${ACME_HOME}/acme.sh."
    "${ACME_HOME}/acme.sh" --issue --help >/dev/null 2>&1 \
        || die "acme.sh at ${ACME_HOME}/acme.sh is still not runnable after reinstall. Try manually: rm -rf ${ACME_HOME} && re-run this script."

    mkdir -p "${XRAY_CONF_DIR}" "${CERT_DIR}" "${STATE_DIR}"
}

# ===========================================================================
# 2. DOMAIN VERIFICATION & PRE-FLIGHT DNS CHECK
# ===========================================================================
domain_and_dns() {
    read -rp "Enter your Fully Qualified Domain Name (FQDN, e.g. cdn.example.com): " DOMAIN
    [[ -n "${DOMAIN}" ]] || die "Domain cannot be empty."
    if [[ "${DOMAIN}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        die "Raw IP addresses are not allowed. A valid FQDN is required for TLS."
    fi

    info "Determining server WAN IP..."
    WAN_IP="$(curl -fsS4 https://api.ipify.org || curl -fsS4 https://ifconfig.me || true)"
    [[ -n "${WAN_IP}" ]] || die "Unable to determine server WAN IP. Check connectivity."
    ok "Server WAN IP: ${WAN_IP}"

    info "Resolving A record for ${DOMAIN}..."
    DNS_IP="$(dig +short A "${DOMAIN}" @1.1.1.1 | tail -n1)"
    [[ -n "${DNS_IP}" ]] || die "No A record found for ${DOMAIN}. Configure DNS and wait for propagation."
    ok "Resolved A record: ${DNS_IP}"

    if [[ "${DNS_IP}" != "${WAN_IP}" ]]; then
        echo
        warn "DNS MISMATCH DETECTED:"
        warn "   Domain A record : ${DNS_IP}"
        warn "   Server WAN IP   : ${WAN_IP}"
        warn "If proxying through a CDN, the A record points to the CDN edge,"
        warn "so acme.sh HTTP-01 validation will FAIL from this origin."
        echo
        read -rp "Proceed anyway (DNS-01 / temporarily grey-cloud)? [y/N]: " FORCE
        [[ "${FORCE,,}" == "y" ]] || die "Aborting on DNS mismatch. Point A record at ${WAN_IP} for HTTP-01."
    else
        ok "Pre-flight DNS check passed: ${DOMAIN} -> ${WAN_IP}"
    fi
}

# ===========================================================================
# 3. SSL PROVISIONING & AUTO-RENEWAL (acme.sh)
# ===========================================================================
issue_cert() {
    info "Issuing TLS certificate for ${DOMAIN} via acme.sh (HTTP-01 standalone)..."

    # Guard against a stale/broken acme.sh binary (known upstream issue where
    # a corrupted install re-triggers its own installer and mangles flags
    # into "Unknown parameter: ----issue" style errors). Fail fast here
    # instead of burning through set-default-ca/issue/install-cert first.
    if ! "${ACME_HOME}/acme.sh" --issue --help >/dev/null 2>&1; then
        die "acme.sh at ${ACME_HOME}/acme.sh is broken (fails on --issue --help).
    This usually means a stale acme.sh install is being reused.
    Fix: rm -rf ${ACME_HOME} && re-run this script so install_prereqs()
    performs a clean reinstall before certificate issuance."
    fi

    systemctl stop nginx 2>/dev/null || true

    "${ACME_HOME}/acme.sh" --set-default-ca --server letsencrypt \
        || die "Failed to set default ACME CA (letsencrypt)."

    local issue_out issue_rc
    if issue_out="$("${ACME_HOME}/acme.sh" --issue -d "${DOMAIN}" --standalone --keylength ec-256 --httpport 80 2>&1)"; then
        issue_rc=0
    else
        issue_rc=$?
    fi
    echo "${issue_out}"

    if [[ ${issue_rc} -ne 0 ]]; then
        # acme.sh returns non-zero for a benign "already have a valid cert,
        # not due for renewal yet" skip, not just for real failures. Don't
        # treat that case as fatal — only die on genuine issuance errors.
        if echo "${issue_out}" | grep -qiE "Skipping[.,] Next renewal time is|Skip, Next"; then
            ok "Existing certificate for ${DOMAIN} is still valid; skipping re-issuance."
        else
            die "Certificate issuance failed. Verify port 80 reachability and DNS."
        fi
    fi

    "${ACME_HOME}/acme.sh" --install-cert -d "${DOMAIN}" --ecc \
        --fullchain-file "${CERT_DIR}/${DOMAIN}.crt" \
        --key-file       "${CERT_DIR}/${DOMAIN}.key" \
        --reloadcmd      "systemctl reload nginx 2>/dev/null || systemctl start nginx 2>/dev/null || true" \
        || die "Failed to install issued certificate to ${CERT_DIR}."

    # Sanity-check the files actually landed, not just that acme.sh returned 0.
    [[ -s "${CERT_DIR}/${DOMAIN}.crt" && -s "${CERT_DIR}/${DOMAIN}.key" ]] \
        || die "Certificate files missing after install-cert (${CERT_DIR}/${DOMAIN}.crt / .key)."

    "${ACME_HOME}/acme.sh" --install-cronjob >/dev/null 2>&1 || true
    ok "Certificate installed; auto-renewal cron configured (reloads nginx on renew)."
}

# ===========================================================================
# 4. XRAY CONFIGURATION  — 8 inbounds (4 transports x TLS/NTLS)
#     Rebuilt from the account DB every time accounts change.
# ===========================================================================
clients_json() {
    # Emit the shared "clients" array from the account DB.
    local first=1 out=""
    if [[ -s "${ACCT_DB}" ]]; then
        while IFS='|' read -r uname uuid; do
            [[ -z "${uuid}" ]] && continue
            [[ ${first} -eq 0 ]] && out+=","
            out+=$(printf '\n            { "id": "%s", "email": "%s@%s" }' "${uuid}" "${uname}" "${DOMAIN}")
            first=0
        done < "${ACCT_DB}"
    fi
    printf '%s' "${out}"
}

stream_block() {
    # $1 = transport
    case "$1" in
        ws)          printf '"network": "ws", "security": "none", "wsSettings": { "path": "%s", "headers": {} }' "${WS_PATH}" ;;
        httpupgrade) printf '"network": "httpupgrade", "security": "none", "httpupgradeSettings": { "path": "%s", "host": "%s" }' "${HU_PATH}" "${HOST_VALUE}" ;;
        grpc)        printf '"network": "grpc", "security": "none", "grpcSettings": { "serviceName": "%s", "multiMode": false }' "${GRPC_SERVICE}" ;;
        xhttp)       printf '"network": "xhttp", "security": "none", "xhttpSettings": { "path": "%s", "host": "%s", "mode": "%s" }' "${XH_PATH}" "${HOST_VALUE}" "${XH_MODE}" ;;
    esac
}

build_xray_config() {
    local clients; clients="$(clients_json)"
    local inbounds="" first=1 t sec port block

    for t in "${TRANSPORTS[@]}"; do
        for sec in tls ntls; do
            if [[ "${sec}" == "tls" ]]; then port="${PORT_TLS[$t]}"; else port="${PORT_NTLS[$t]}"; fi
            block="$(stream_block "$t")"
            [[ ${first} -eq 0 ]] && inbounds+=","
            inbounds+=$(cat <<EOF

    {
      "tag": "vless-${t}-${sec}",
      "listen": "127.0.0.1",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [${clients}
        ],
        "decryption": "none"
      },
      "streamSettings": { ${block} },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
    }
EOF
)
            first=0
        done
    done

    cat > "${XRAY_CONF}" <<EOF
{
  "log": { "loglevel": "warning", "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log" },
  "inbounds": [${inbounds}
  ],
  "outbounds": [
    { "tag": "direct",  "protocol": "freedom",   "settings": {} },
    { "tag": "blocked", "protocol": "blackhole", "settings": {} }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [ { "type": "field", "ip": ["geoip:private"], "outboundTag": "blocked" } ]
  }
}
EOF

    mkdir -p /var/log/xray
    chown -R nobody:nogroup /var/log/xray 2>/dev/null || true
    xray -test -config "${XRAY_CONF}" || die "Xray config test failed."
}

# ===========================================================================
# 5. NGINX REVERSE PROXY  — path-based fallback for all 4 transports
# ===========================================================================
build_nginx_config() {
    cat > /etc/nginx/conf.d/upgrade-map.conf <<'EOF'
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
EOF

    # location generators (upstream port passed in)
    loc_ws() { cat <<EOF
    location ${WS_PATH} {
        if (\$http_upgrade !~* "websocket") { return 404; }
        proxy_pass http://127.0.0.1:$1;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s; proxy_send_timeout 300s; proxy_buffering off;
    }
EOF
}
    loc_hu() { cat <<EOF
    location ${HU_PATH} {
        proxy_pass http://127.0.0.1:$1;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s; proxy_send_timeout 300s; proxy_buffering off;
    }
EOF
}
    loc_grpc() { cat <<EOF
    location /${GRPC_SERVICE} {
        grpc_pass grpc://127.0.0.1:$1;
        grpc_set_header Host \$host;
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_set_header X-Forwarded-Proto \$scheme;
        grpc_read_timeout 300s; grpc_send_timeout 300s; grpc_socket_keepalive on;
    }
EOF
}
    loc_xh() { cat <<EOF
    location ${XH_PATH} {
        proxy_pass http://127.0.0.1:$1;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off; proxy_request_buffering off;
        proxy_read_timeout 300s; proxy_send_timeout 300s; client_max_body_size 0;
    }
EOF
}

    cat > "${NGINX_SITE}" <<EOF
# ---- Port 80 : NTLS (plaintext; edge TLS terminated at CDN). h2 for gRPC. ----
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ { root /var/www/html; }

$(loc_ws   "${PORT_NTLS[ws]}")
$(loc_hu   "${PORT_NTLS[httpupgrade]}")
$(loc_grpc "${PORT_NTLS[grpc]}")
$(loc_xh   "${PORT_NTLS[xhttp]}")

    location / { return 200 "OK\n"; default_type text/plain; }
}

# ---- Port 443 : TLS (edge-to-origin TLS via acme.sh certificate) ----
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${DOMAIN};

    ssl_certificate     ${CERT_DIR}/${DOMAIN}.crt;
    ssl_certificate_key ${CERT_DIR}/${DOMAIN}.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1h;

$(loc_ws   "${PORT_TLS[ws]}")
$(loc_hu   "${PORT_TLS[httpupgrade]}")
$(loc_grpc "${PORT_TLS[grpc]}")
$(loc_xh   "${PORT_TLS[xhttp]}")

    location / { return 200 "OK\n"; default_type text/plain; }
}
EOF

    ln -sf "${NGINX_SITE}" "${NGINX_LINK}"
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    nginx -t || die "Nginx configuration test failed."
}

# ===========================================================================
# 6. SERVICE & FIREWALL ORCHESTRATION
# ===========================================================================
firewall_and_services() {
    ufw allow 22/tcp  >/dev/null 2>&1 || true
    ufw allow 80/tcp  >/dev/null 2>&1 || true
    ufw allow 443/tcp >/dev/null 2>&1 || true
    ufw --force enable >/dev/null 2>&1 || true

    systemctl enable --now xray  >/dev/null 2>&1 || true
    systemctl enable --now nginx >/dev/null 2>&1 || true
    systemctl enable --now cron  >/dev/null 2>&1 || true
    systemctl restart xray
    systemctl restart nginx
}

apply_config() {
    # Regenerate xray + nginx from current state/DB and reload.
    build_xray_config
    build_nginx_config
    systemctl restart xray

    # `reload` only works on an already-running service. issue_cert() stops
    # nginx for standalone HTTP-01 validation and doesn't always leave it
    # running afterward, so start it here if needed instead of assuming.
    if systemctl is-active --quiet nginx; then
        systemctl reload nginx || die "Nginx reload failed — check 'nginx -t' output above."
    else
        systemctl start nginx || die "Nginx failed to start. Run 'nginx -t' and 'journalctl -u nginx' to diagnose."
    fi
}

# ===========================================================================
#  FIRST-RUN PROVISIONING
# ===========================================================================
provision() {
    clear
    echo -e "${BOLD}${CYN}First-time setup — provisioning XRAY-X${NC}"
    echo "------------------------------------------------------------"
    install_prereqs
    domain_and_dns

    # Auto-generate per-transport paths / serviceName / mode
    WS_PATH="/ws$(head -c 4 /dev/urandom | xxd -p)"
    HU_PATH="/hu$(head -c 4 /dev/urandom | xxd -p)"
    GRPC_SERVICE="grpc$(head -c 4 /dev/urandom | xxd -p)"
    XH_PATH="/xh$(head -c 4 /dev/urandom | xxd -p)"
    XH_MODE="auto"

    echo
    info "Optional CDN overrides (Enter = default to origin domain):"
    read -rp "Custom SNI  [default: ${DOMAIN}]: " CUSTOM_SNI
    read -rp "Custom Host [default: ${DOMAIN}]: " CUSTOM_HOST
    SNI_VALUE="${CUSTOM_SNI:-${DOMAIN}}"
    HOST_VALUE="${CUSTOM_HOST:-${DOMAIN}}"

    issue_cert
    save_state
    : > "${ACCT_DB}"          # start with empty account DB
    apply_config
    firewall_and_services
    ok "Provisioning complete. Domain: ${DOMAIN}"
    pause
}

# ===========================================================================
#  MENU ACTIONS
# ===========================================================================
print_client_urls() {
    local uname="$1" uuid="$2"
    local enc_ws enc_hu enc_svc enc_xh
    enc_ws="$(printf '%s' "${WS_PATH}"  | jq -sRr @uri)"
    enc_hu="$(printf '%s' "${HU_PATH}"  | jq -sRr @uri)"
    enc_svc="$(printf '%s' "${GRPC_SERVICE}" | jq -sRr @uri)"
    enc_xh="$(printf '%s' "${XH_PATH}"  | jq -sRr @uri)"

    echo -e "${BOLD}Account: ${GRN}${uname}${NC}  |  UUID: ${uuid}"
    echo "----------------------------------------------------------------------"
    echo -e "${BOLD}${BLU}[ WebSocket ]${NC}"
    echo "TLS : vless://${uuid}@${DOMAIN}:443?encryption=none&security=tls&type=ws&host=${HOST_VALUE}&sni=${SNI_VALUE}&path=${enc_ws}#${uname}-WS-TLS"
    echo "NTLS: vless://${uuid}@${DOMAIN}:80?encryption=none&security=none&type=ws&host=${HOST_VALUE}&path=${enc_ws}#${uname}-WS-NTLS"
    echo -e "${BOLD}${BLU}[ HTTP Upgrade ]${NC}"
    echo "TLS : vless://${uuid}@${DOMAIN}:443?encryption=none&security=tls&type=httpupgrade&host=${HOST_VALUE}&sni=${SNI_VALUE}&path=${enc_hu}#${uname}-HU-TLS"
    echo "NTLS: vless://${uuid}@${DOMAIN}:80?encryption=none&security=none&type=httpupgrade&host=${HOST_VALUE}&path=${enc_hu}#${uname}-HU-NTLS"
    echo -e "${BOLD}${BLU}[ gRPC ]${NC}"
    echo "TLS : vless://${uuid}@${DOMAIN}:443?encryption=none&security=tls&type=grpc&serviceName=${enc_svc}&mode=gun&host=${HOST_VALUE}&sni=${SNI_VALUE}#${uname}-gRPC-TLS"
    echo "NTLS: vless://${uuid}@${DOMAIN}:80?encryption=none&security=none&type=grpc&serviceName=${enc_svc}&mode=gun&host=${HOST_VALUE}#${uname}-gRPC-NTLS"
    echo -e "${BOLD}${BLU}[ XHTTP ]${NC}"
    echo "TLS : vless://${uuid}@${DOMAIN}:443?encryption=none&security=tls&type=xhttp&mode=${XH_MODE}&host=${HOST_VALUE}&sni=${SNI_VALUE}&path=${enc_xh}#${uname}-XHTTP-TLS"
    echo "NTLS: vless://${uuid}@${DOMAIN}:80?encryption=none&security=none&type=xhttp&mode=${XH_MODE}&host=${HOST_VALUE}&path=${enc_xh}#${uname}-XHTTP-NTLS"
    echo "----------------------------------------------------------------------"
}

action_create() {
    clear
    echo -e "${BOLD}${CYN}Create Account — builds ALL 4 transports for one identity${NC}"
    echo "------------------------------------------------------------"
    read -rp "Username / remark: " UNAME
    UNAME="${UNAME// /_}"
    [[ -n "${UNAME}" ]] || { warn "Username cannot be empty."; pause; return; }
    if grep -q "^${UNAME}|" "${ACCT_DB}" 2>/dev/null; then
        warn "Account '${UNAME}' already exists."; pause; return
    fi
    local UUID; UUID="$(xray uuid)"
    echo "${UNAME}|${UUID}" >> "${ACCT_DB}"

    info "Rebuilding Xray config with new account and reloading..."
    apply_config
    ok "Account created across WebSocket, HTTP Upgrade, gRPC, and XHTTP."
    echo
    print_client_urls "${UNAME}" "${UUID}"
    pause
}

action_list_delete() {
    clear
    echo -e "${BOLD}${CYN}Accounts${NC}"
    echo "------------------------------------------------------------"
    if [[ ! -s "${ACCT_DB}" ]]; then
        warn "No accounts yet. Use 'Create Account' first."; pause; return
    fi
    local i=1; local -a names=()
    while IFS='|' read -r uname uuid; do
        [[ -z "${uname}" ]] && continue
        printf "  %2d) %-20s %s\n" "${i}" "${uname}" "${uuid}"
        names+=("${uname}"); ((i++))
    done < "${ACCT_DB}"
    echo "------------------------------------------------------------"
    echo "  Enter a number to DELETE, 's' + number to SHOW URLs, ENTER to go back."
    read -rp "  Select: " SEL
    [[ -z "${SEL}" ]] && return

    if [[ "${SEL}" =~ ^s([0-9]+)$ ]]; then
        local idx="${BASH_REMATCH[1]}"
        local target="${names[$((idx-1))]:-}"
        [[ -z "${target}" ]] && { warn "Invalid selection."; pause; return; }
        local uuid; uuid="$(grep "^${target}|" "${ACCT_DB}" | head -n1 | cut -d'|' -f2)"
        clear; print_client_urls "${target}" "${uuid}"; pause; return
    fi

    if [[ "${SEL}" =~ ^[0-9]+$ ]]; then
        local target="${names[$((SEL-1))]:-}"
        [[ -z "${target}" ]] && { warn "Invalid selection."; pause; return; }
        read -rp "  Delete account '${target}'? [y/N]: " C
        [[ "${C,,}" == "y" ]] || return
        grep -v "^${target}|" "${ACCT_DB}" > "${ACCT_DB}.tmp" || true
        mv "${ACCT_DB}.tmp" "${ACCT_DB}"
        apply_config
        ok "Account '${target}' deleted from all transports."
        pause
    else
        warn "Unrecognized input."; pause
    fi
}

action_uninstall() {
    clear
    echo -e "${BOLD}${RED}Uninstall XRAY-X${NC}"
    echo "------------------------------------------------------------"
    echo "  This will:"
    echo "    - stop & remove Xray-core (official uninstaller)"
    echo "    - remove the XRAY-X Nginx site + upgrade map"
    echo "    - delete ${XRAY_CONF_DIR} (config + certs)"
    echo "    - delete ${STATE_DIR} (state + accounts)"
    echo "    - remove the acme.sh cert/renewal for ${DOMAIN:-<domain>}"
    echo "  Nginx itself is kept (may be used by other sites)."
    echo "------------------------------------------------------------"
    read -rp "  Type 'UNINSTALL' to confirm: " C
    [[ "${C}" == "UNINSTALL" ]] || { warn "Aborted."; pause; return; }

    info "Stopping services..."
    systemctl stop xray 2>/dev/null || true

    info "Removing Xray-core..."
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge \
        >/dev/null 2>&1 || true

    info "Removing Nginx site..."
    rm -f "${NGINX_LINK}" "${NGINX_SITE}" /etc/nginx/conf.d/upgrade-map.conf
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx 2>/dev/null || true
    else
        warn "Nginx config test failed after removal — check remaining sites."
    fi

    info "Revoking / removing acme.sh certificate..."
    if [[ -n "${DOMAIN:-}" && -f "${ACME_HOME}/acme.sh" ]]; then
        "${ACME_HOME}/acme.sh" --remove -d "${DOMAIN}" --ecc >/dev/null 2>&1 || true
    fi

    info "Deleting config, certs, and state..."
    rm -rf "${XRAY_CONF_DIR}" "${STATE_DIR}" /var/log/xray

    ok "XRAY-X uninstalled."
    echo -e "  ${YLW}Note:${NC} UFW rules for 80/443 were left in place. Remove manually if unused:"
    echo "        ufw delete allow 80/tcp ; ufw delete allow 443/tcp"
    echo
    read -rp "Press ENTER to exit..." _
    exit 0
}

action_service() {
    clear
    echo -e "${BOLD}${CYN}Service Status${NC}"
    echo "------------------------------------------------------------"
    for svc in xray nginx cron; do
        if systemctl is-active --quiet "${svc}"; then
            echo -e "  ${svc}: ${GRN}active${NC}"
        else
            echo -e "  ${svc}: ${RED}inactive${NC}"
        fi
    done
    echo "------------------------------------------------------------"
    read -rp "  Restart xray+nginx now? [y/N]: " C
    if [[ "${C,,}" == "y" ]]; then
        systemctl restart xray && systemctl restart nginx
        ok "Services restarted."
    fi
    pause
}

# ===========================================================================
#  DASHBOARD / MAIN MENU
# ===========================================================================
header() {
    load_state
    local up acct_count xver
    up="$(uptime -p 2>/dev/null | sed 's/^up //')"
    acct_count="$( [[ -s "${ACCT_DB}" ]] && grep -c '|' "${ACCT_DB}" || echo 0 )"
    xver="$(xray version 2>/dev/null | head -n1 | awk '{print $2}')"
    clear
    echo -e "${GRN}============================================================${NC}"
    echo -e "${BOLD}          XRAY-X  v${VERSION}   |   Main Menu${NC}"
    echo -e "${GRN}============================================================${NC}"
    echo -e "  Domain   : ${CYN}${DOMAIN:-not set}${NC}"
    echo -e "  Xray     : ${xver:-unknown}"
    echo -e "  Accounts : ${acct_count}"
    echo -e "  Uptime   : up ${up:-unknown}"
    echo -e "${GRN}============================================================${NC}"
}

main_menu() {
    while true; do
        header
        echo
        echo -e "   ${GRN}1)${NC} Create Account   ${GRN}2)${NC} List / Delete Account"
        echo -e "   ${GRN}3)${NC} Service Status   ${RED}x)${NC} Uninstall"
        echo -e "   ${RED}0)${NC} Exit"
        echo
        read -rp "  Select option: " OPT
        case "${OPT}" in
            1) action_create ;;
            2) action_list_delete ;;
            3) action_service ;;
            x|X) action_uninstall ;;
            0) clear; ok "Bye."; exit 0 ;;
            *) warn "Invalid option."; sleep 1 ;;
        esac
    done
}

# ===========================================================================
#  ENTRYPOINT
# ===========================================================================
# This is an INTERACTIVE menu script — its prompts read from the terminal.
# Two ways people accidentally break that:
#   1) `curl ... | bash`     -> stdin is the pipe, no keyboard for `read`.
#   2) `sudo bash <(curl..)` -> sudo can't read the caller's /dev/fd/NN, so
#                               you get "bash: /dev/fd/63: No such file".
# If stdin is not a TTY we try to reattach it to the controlling terminal
# (/dev/tty). If that also fails, we explain both fixes and exit — instead of
# silently doing nothing.
if [[ ! -t 0 ]]; then
    if [[ -e /dev/tty ]] && exec < /dev/tty 2>/dev/null; then
        : # stdin successfully reattached to the terminal — carry on.
    else
        echo -e "${RED}[x]${NC} No interactive terminal available on stdin." >&2
        echo    "    Do NOT pipe this script or run it under sudo with <(...)." >&2
        echo    "    You are already root here, so run it like this:" >&2
        echo >&2
        echo    "      curl -fsSL <url>/xray-x.sh -o xray-x.sh" >&2
        echo    "      bash xray-x.sh" >&2
        exit 1
    fi
fi

load_state
if ! is_provisioned; then
    provision
fi
main_menu
