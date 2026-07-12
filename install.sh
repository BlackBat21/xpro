#!/usr/bin/env bash
#===============================================================================
# xray-manager.sh
#
# Interactive manager for an Xray-core proxy server supporting BOTH:
#   * VLESS + XTLS-Vision + REALITY   (raw TCP)
#   * VLESS + XHTTP + REALITY         (HTTP-multiplexed via fallback)
#
# Both protocols share ONE public port (default 443). Inbound 0 terminates
# REALITY and, when it sees an HTTP request matching a secret randomized path,
# falls back to a loopback Inbound 1 that speaks VLESS+XHTTP. This keeps a
# single TLS fingerprint on the wire while multiplexing two transports.
#
# Target OS   : Ubuntu 24.04 LTS
# Xray binary : /usr/local/bin/xray
# Xray config : /usr/local/etc/xray/config.json
# Manager data: /etc/xray-manager/db.json
# Service     : xray.service (systemd)
#
# Design notes:
#   * Expiration data is kept OUT of the Xray config. The config only knows
#     about currently-active clients. All lifecycle metadata (creation date,
#     expiry timestamp, protocol, etc.) lives in the manager database.
#   * ALL JSON edits go through `jq` so the Xray config can never be corrupted
#     by naive string manipulation.
#   * A systemd timer runs a daily reconciliation pass that strips expired
#     users out of the live config.
#===============================================================================

# --- Strict mode -------------------------------------------------------------
# -e : exit on unhandled error   -u : error on unset var   -o pipefail : catch
# failures anywhere in a pipeline. Interactive whiptail cancels are handled
# explicitly with `if ! ...` so they don't trip `set -e`.
set -euo pipefail

#===============================================================================
# GLOBAL CONSTANTS
#===============================================================================
readonly SCRIPT_VERSION="2.0.0"
readonly SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"

# Placeholder self-update source — replace with your own raw GitHub URL.
readonly UPDATE_URL="https://raw.githubusercontent.com/username/repo/main/script.sh"

readonly XRAY_BIN="/usr/local/bin/xray"
readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly XRAY_SERVICE="xray.service"

readonly MANAGER_DIR="/etc/xray-manager"
readonly DB_FILE="${MANAGER_DIR}/db.json"

readonly TIMER_UNIT="xray-manager-expiry.timer"
readonly TIMER_SERVICE="xray-manager-expiry.service"
readonly TIMER_SERVICE_PATH="/etc/systemd/system/${TIMER_SERVICE}"
readonly TIMER_UNIT_PATH="/etc/systemd/system/${TIMER_UNIT}"

# Default REALITY camouflage target. Must be a TLSv1.3 + HTTP/2 capable host.
readonly DEFAULT_SNI="www.microsoft.com"
readonly DEFAULT_DEST="www.microsoft.com:443"
readonly DEFAULT_PORT="443"

# Loopback port for the internal VLESS+XHTTP inbound (fallback destination).
readonly DEFAULT_INTERNAL_PORT="8080"

#===============================================================================
# LOW-LEVEL HELPERS
#===============================================================================

# Colored, timestamped logging to stderr (stdout stays clean for data output).
log()  { echo -e "\033[1;32m[+]\033[0m $*" >&2; }
warn() { echo -e "\033[1;33m[!]\033[0m $*" >&2; }
err()  { echo -e "\033[1;31m[x]\033[0m $*" >&2; }

# Abort with a message.
die() { err "$*"; exit 1; }

# Require root; almost everything here touches /usr/local and systemd.
require_root() {
    [[ "${EUID}" -eq 0 ]] || die "This script must be run as root (try: sudo $0)."
}

#===============================================================================
# DEPENDENCY MANAGEMENT
#===============================================================================
# Ensure the tools we rely on exist. We map "command -> apt package" because a
# couple of binaries live in differently-named packages (uuidgen -> uuid-runtime).
ensure_dependencies() {
    log "Checking dependencies..."
    declare -A pkg_for=(
        [curl]=curl
        [jq]=jq
        [uuidgen]=uuid-runtime
        [whiptail]=whiptail
        [qrencode]=qrencode
        [openssl]=openssl
    )

    local missing=()
    for cmd in "${!pkg_for[@]}"; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            missing+=("${pkg_for[$cmd]}")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log "Installing missing packages: ${missing[*]}"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y "${missing[@]}"
    else
        log "All dependencies satisfied."
    fi
}

#===============================================================================
# XRAY INSTALLATION
#===============================================================================
# Uses the official XTLS installer, which places the binary at
# /usr/local/bin/xray, the config at /usr/local/etc/xray/config.json, and
# installs a proper xray.service systemd unit — exactly matching our targets.
install_xray_core() {
    if [[ -x "${XRAY_BIN}" ]]; then
        log "Xray already installed at ${XRAY_BIN} ($("${XRAY_BIN}" version | head -n1))."
        return 0
    fi
    log "Installing Xray-core via official installer..."
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    [[ -x "${XRAY_BIN}" ]] || die "Xray installation failed."
    log "Xray installed: $("${XRAY_BIN}" version | head -n1)"
}

#===============================================================================
# REALITY KEY / IDENTITY HELPERS
#===============================================================================

# Generate a REALITY x25519 keypair. Prints "PRIVATE PUBLIC" on one line.
# Parses robustly across Xray versions (labels have shifted between releases).
generate_reality_keys() {
    local out priv pub
    out="$("${XRAY_BIN}" x25519)"
    # Match "Private key:" / "PrivateKey:" and "Public key:" / "Password:".
    priv="$(awk -F': *' 'tolower($0) ~ /private/ {print $2; exit}' <<<"${out}")"
    pub="$(awk  -F': *' 'tolower($0) ~ /public|password/ {print $2; exit}' <<<"${out}")"
    [[ -n "${priv}" && -n "${pub}" ]] || die "Failed to parse REALITY keys from: ${out}"
    echo "${priv} ${pub}"
}

# Random hex short-id (REALITY). 8 bytes -> 16 hex chars.
generate_short_id() { openssl rand -hex 8; }

# Random secret path for the XHTTP fallback. 8 bytes -> 16 hex chars, leading /.
generate_xhttp_path() { echo "/$(openssl rand -hex 8)"; }

# Best-effort public IPv4 discovery for building share links.
detect_public_ip() {
    local ip
    ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    [[ -z "${ip}" ]] && ip="$(curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
    [[ -z "${ip}" ]] && ip="$(hostname -I | awk '{print $1}')"
    echo "${ip}"
}

#===============================================================================
# INITIAL SERVER PROVISIONING
#===============================================================================
# Builds a TWO-inbound REALITY multiplexing config plus the manager DB. The
# DB's "meta" object stores the server-wide parameters we need to reconstruct
# share links later, including the internal XHTTP port and the randomized
# fallback path.
provision_server() {
    if [[ -f "${DB_FILE}" ]]; then
        log "Manager already provisioned (${DB_FILE} exists). Skipping."
        return 0
    fi

    log "Provisioning REALITY server parameters..."
    mkdir -p "${MANAGER_DIR}" "$(dirname "${XRAY_CONFIG}")"

    # Collect server-wide settings from the operator (with sane defaults).
    local port sni dest
    port="$(whiptail --inputbox "Listening port for VLESS/REALITY:" 8 60 "${DEFAULT_PORT}" \
             --title "Server Setup" 3>&1 1>&2 2>&3)" || port="${DEFAULT_PORT}"
    sni="$(whiptail --inputbox "REALITY SNI / serverName (a real TLS1.3 site):" 8 60 "${DEFAULT_SNI}" \
             --title "Server Setup" 3>&1 1>&2 2>&3)" || sni="${DEFAULT_SNI}"
    dest="${sni}:443"

    # Generate cryptographic identity + stealth parameters.
    local keys priv pub short_id server_ip internal_port xhttp_path
    keys="$(generate_reality_keys)"
    priv="${keys%% *}"
    pub="${keys##* }"
    short_id="$(generate_short_id)"
    server_ip="$(detect_public_ip)"
    internal_port="${DEFAULT_INTERNAL_PORT}"
    xhttp_path="$(generate_xhttp_path)"    # randomized secret fallback path

    log "Writing Xray REALITY multiplexing config -> ${XRAY_CONFIG}"
    # Inbound 0 (public):  VLESS + TCP + XTLS-Vision + REALITY, with a
    #                      path-based fallback to the loopback XHTTP inbound.
    # Inbound 1 (loopback): VLESS + XHTTP (no security; REALITY already
    #                      terminated upstream). Its transport path MUST equal
    #                      the fallback path above.
    # Both clients arrays start empty; accounts are appended via jq later.
    jq -n \
        --arg port   "${port}" \
        --arg dest   "${dest}" \
        --arg sni    "${sni}" \
        --arg priv   "${priv}" \
        --arg sid    "${short_id}" \
        --arg iport  "${internal_port}" \
        --arg xpath  "${xhttp_path}" \
        '{
          log: { loglevel: "warning" },
          inbounds: [
            {
              listen: "0.0.0.0",
              port: ($port | tonumber),
              protocol: "vless",
              settings: {
                clients: [],
                decryption: "none",
                fallbacks: [
                  { path: $xpath, dest: ("127.0.0.1:" + $iport), xver: 0 }
                ]
              },
              streamSettings: {
                network: "tcp",
                security: "reality",
                realitySettings: {
                  show: false,
                  dest: $dest,
                  xver: 0,
                  serverNames: [$sni],
                  privateKey: $priv,
                  shortIds: [$sid]
                }
              },
              sniffing: { enabled: true, destOverride: ["http","tls","quic"] }
            },
            {
              listen: "127.0.0.1",
              port: ($iport | tonumber),
              protocol: "vless",
              settings: {
                clients: [],
                decryption: "none"
              },
              streamSettings: {
                network: "xhttp",
                xhttpSettings: {
                  path: $xpath
                }
              },
              sniffing: { enabled: true, destOverride: ["http","tls","quic"] }
            }
          ],
          outbounds: [
            { protocol: "freedom", tag: "direct" },
            { protocol: "blackhole", tag: "block" }
          ]
        }' > "${XRAY_CONFIG}"

    log "Initializing manager database -> ${DB_FILE}"
    jq -n \
        --arg ip     "${server_ip}" \
        --arg port   "${port}" \
        --arg pub    "${pub}" \
        --arg sni    "${sni}" \
        --arg sid    "${short_id}" \
        --arg iport  "${internal_port}" \
        --arg xpath  "${xhttp_path}" \
        '{
          meta: {
            server_ip: $ip,
            port: ($port | tonumber),
            public_key: $pub,
            sni: $sni,
            short_id: $sid,
            internal_port: ($iport | tonumber),
            xhttp_path: $xpath
          },
          users: []
        }' > "${DB_FILE}"

    chmod 600 "${DB_FILE}"          # DB holds UUIDs -> keep it private.

    systemctl enable "${XRAY_SERVICE}" >/dev/null 2>&1 || true
    restart_xray
    log "Server provisioned successfully (Vision + XHTTP fallback path: ${xhttp_path})."
}

#===============================================================================
# SERVICE + CONFIG SAFETY
#===============================================================================

# Validate the config, then (re)start Xray. If validation fails we refuse to
# restart so a bad edit can never take the service down.
restart_xray() {
    if ! "${XRAY_BIN}" -test -config "${XRAY_CONFIG}" >/dev/null 2>&1; then
        err "Xray config test FAILED — not restarting. Run: ${XRAY_BIN} -test -config ${XRAY_CONFIG}"
        return 1
    fi
    systemctl restart "${XRAY_SERVICE}"
    log "Xray service restarted."
}

# Guard used by every menu action that needs an existing installation.
ensure_provisioned() {
    [[ -f "${DB_FILE}" && -f "${XRAY_CONFIG}" ]] || \
        die "Not provisioned yet. Run the installer first (menu option: Install / Provision)."
}

#===============================================================================
# PROTOCOL RESOLUTION HELPERS
#===============================================================================
# Map a protocol name to its inbound index. vision -> 0, xhttp -> 1.
# Unknown/empty protocols default to vision (index 0) for backwards compat.
protocol_inbound_index() {
    local protocol="${1:-vision}"
    if [[ "${protocol}" == "xhttp" ]]; then echo 1; else echo 0; fi
}

# Read a user's protocol from the DB, defaulting to "vision" if the key is
# absent (accounts created before XHTTP support existed).
get_user_protocol() {
    local username="$1" p
    p="$(jq -r --arg u "${username}" \
        '.users[] | select(.username==$u) | (.protocol // "vision")' "${DB_FILE}")"
    [[ "${p}" == "xhttp" ]] && { echo "xhttp"; return; }
    echo "vision"
}

#===============================================================================
# SHARE LINK / QR GENERATION
#===============================================================================
# Rebuilds a standards-compliant VLESS REALITY URI from DB meta + a user record.
# The transport section is conditional on the user's protocol:
#   * vision -> type=tcp   + flow=xtls-rprx-vision
#   * xhttp  -> type=xhttp + path=<randomized secret path> (no flow)
# Both share the same REALITY params (pbk/sni/sid) because XHTTP rides the same
# REALITY inbound via fallback.
build_vless_link() {
    local username="$1" uuid="$2" protocol="${3:-vision}"
    local ip port pub sni sid xpath xpath_enc
    ip="$(jq -r '.meta.server_ip' "${DB_FILE}")"
    port="$(jq -r '.meta.port' "${DB_FILE}")"
    pub="$(jq -r '.meta.public_key' "${DB_FILE}")"
    sni="$(jq -r '.meta.sni' "${DB_FILE}")"
    sid="$(jq -r '.meta.short_id' "${DB_FILE}")"

    if [[ "${protocol}" == "xhttp" ]]; then
        xpath="$(jq -r '.meta.xhttp_path // "/"' "${DB_FILE}")"
        # URL-encode the path so the "/" (and anything else) is link-safe.
        xpath_enc="$(jq -rn --arg x "${xpath}" '$x | @uri')"
        printf 'vless://%s@%s:%s?type=xhttp&security=reality&pbk=%s&fp=chrome&sni=%s&sid=%s&path=%s&mode=auto&encryption=none#%s' \
            "${uuid}" "${ip}" "${port}" "${pub}" "${sni}" "${sid}" "${xpath_enc}" "${username}"
    else
        # flow=xtls-rprx-vision + security=reality + fp=chrome is the canonical combo.
        printf 'vless://%s@%s:%s?type=tcp&security=reality&pbk=%s&fp=chrome&sni=%s&sid=%s&flow=xtls-rprx-vision&encryption=none#%s' \
            "${uuid}" "${ip}" "${port}" "${pub}" "${sni}" "${sid}" "${username}"
    fi
}

# Print the link plus an ASCII QR code to the terminal.
show_share_details() {
    local username="$1" uuid="$2" protocol="${3:-vision}" link
    link="$(build_vless_link "${username}" "${uuid}" "${protocol}")"
    echo
    log "Account: ${username}  [protocol: ${protocol}]"
    echo "VLESS Link:"
    echo "  ${link}"
    echo
    echo "QR Code:"
    qrencode -t ANSIUTF8 "${link}" || warn "qrencode failed to render QR."
    echo
}

#===============================================================================
# DATABASE + CONFIG MUTATIONS (all via jq, always paired atomically)
#===============================================================================

# Write JSON to a file atomically (temp + mv) so a crash mid-write can't corrupt.
# IMPORTANT: mktemp creates 0600 root:root files. If we mv that over the Xray
# config, the service user ('nobody') loses read access and Xray fails to start
# with "permission denied". So we create the temp file in the SAME directory
# (keeps mv atomic on one filesystem) and re-apply the target's original mode
# before moving. The Xray config must stay world-readable (0644); the manager
# DB stays private (0600) because it holds UUIDs.
atomic_write() {
    local target="$1" content="$2" tmp mode
    tmp="$(mktemp "${target}.XXXXXX")"
    printf '%s' "${content}" > "${tmp}"
    # Preserve the existing file's permissions; default to 0644 for new files.
    if [[ -f "${target}" ]]; then
        mode="$(stat -c '%a' "${target}")"
    else
        mode="644"
    fi
    chmod "${mode}" "${tmp}"
    mv "${tmp}" "${target}"
}

# Return 0 if a username already exists in the DB.
user_exists() {
    local username="$1"
    [[ "$(jq --arg u "${username}" '[.users[] | select(.username==$u)] | length' "${DB_FILE}")" -gt 0 ]]
}

# Add a client to the correct live Xray inbound (email == username for
# correlation). Vision clients go to inbound[0] WITH the Vision flow; XHTTP
# clients go to inbound[1] WITHOUT a flow (Vision only works over raw TCP).
config_add_client() {
    local username="$1" uuid="$2" protocol="${3:-vision}" new idx
    idx="$(protocol_inbound_index "${protocol}")"
    if [[ "${protocol}" == "xhttp" ]]; then
        new="$(jq --arg id "${uuid}" --arg email "${username}" --argjson i "${idx}" \
            '.inbounds[$i].settings.clients += [{"id":$id,"email":$email}]' \
            "${XRAY_CONFIG}")"
    else
        new="$(jq --arg id "${uuid}" --arg email "${username}" --argjson i "${idx}" \
            '.inbounds[$i].settings.clients += [{"id":$id,"flow":"xtls-rprx-vision","email":$email}]' \
            "${XRAY_CONFIG}")"
    fi
    atomic_write "${XRAY_CONFIG}" "${new}"
}

# Remove a client from the correct live Xray inbound by username/email.
config_remove_client() {
    local username="$1" protocol="${2:-vision}" new idx
    idx="$(protocol_inbound_index "${protocol}")"
    new="$(jq --arg email "${username}" --argjson i "${idx}" \
        '.inbounds[$i].settings.clients |= map(select(.email != $email))' \
        "${XRAY_CONFIG}")"
    atomic_write "${XRAY_CONFIG}" "${new}"
}

# Return 0 if a client with this email is present in its protocol's inbound.
config_has_client() {
    local username="$1" protocol="${2:-vision}" idx
    idx="$(protocol_inbound_index "${protocol}")"
    [[ "$(jq --arg email "${username}" --argjson i "${idx}" \
        '[.inbounds[$i].settings.clients[] | select(.email==$email)] | length' \
        "${XRAY_CONFIG}")" -gt 0 ]]
}

#===============================================================================
# MENU ACTION: CREATE ACCOUNT
#===============================================================================
action_create() {
    ensure_provisioned

    local username duration protocol proto_choice
    username="$(whiptail --inputbox "Enter a username (letters, digits, _ - . only):" 8 60 \
                --title "Create Account" 3>&1 1>&2 2>&3)" || return 0
    # Input validation: non-empty, safe charset.
    if [[ -z "${username}" || ! "${username}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
        whiptail --msgbox "Invalid username. Allowed: A-Z a-z 0-9 _ - ." 8 60
        return 0
    fi
    if user_exists "${username}"; then
        whiptail --msgbox "A user named '${username}' already exists." 8 60
        return 0
    fi

    # Protocol selection: Vision (raw TCP) vs XHTTP (HTTP-multiplexed fallback).
    proto_choice="$(whiptail --title "Create Account" \
        --menu "Choose transport protocol:" 12 62 2 \
        "1" "VLESS + XTLS-Vision (TCP)" \
        "2" "VLESS + XHTTP (fallback)" \
        3>&1 1>&2 2>&3)" || return 0
    case "${proto_choice}" in
        1) protocol="vision" ;;
        2) protocol="xhttp" ;;
        *) return 0 ;;
    esac

    duration="$(whiptail --inputbox "Validity duration in days:" 8 60 "30" \
                --title "Create Account" 3>&1 1>&2 2>&3)" || return 0
    if [[ ! "${duration}" =~ ^[0-9]+$ || "${duration}" -lt 1 ]]; then
        whiptail --msgbox "Duration must be a positive integer." 8 60
        return 0
    fi

    # Generate identity + compute timestamps.
    local uuid created_ts expires_ts
    uuid="$(uuidgen)"
    created_ts="$(date +%s)"
    expires_ts="$(( created_ts + duration * 86400 ))"

    # 1) Append client to the correct live inbound.
    config_add_client "${username}" "${uuid}" "${protocol}"

    # 2) Record lifecycle metadata (including protocol) in the DB.
    local new_db
    new_db="$(jq \
        --arg u "${username}" \
        --arg id "${uuid}" \
        --arg proto "${protocol}" \
        --argjson c "${created_ts}" \
        --argjson e "${expires_ts}" \
        '.users += [{"username":$u,"uuid":$id,"protocol":$proto,"created_ts":$c,"expires_ts":$e}]' \
        "${DB_FILE}")"
    atomic_write "${DB_FILE}" "${new_db}"

    # 3) Apply. If the restart fails, roll back both mutations.
    if ! restart_xray; then
        warn "Restart failed — rolling back creation of '${username}'."
        config_remove_client "${username}" "${protocol}"
        atomic_write "${DB_FILE}" "$(jq --arg u "${username}" '.users |= map(select(.username != $u))' "${DB_FILE}")"
        restart_xray || true
        whiptail --msgbox "Failed to activate account. Rolled back." 8 60
        return 0
    fi

    # 4) Present share details to the operator.
    clear
    show_share_details "${username}" "${uuid}" "${protocol}"
    echo "Expires: $(date -d "@${expires_ts}" '+%Y-%m-%d %H:%M:%S')"
    read -rp "Press Enter to return to the menu..."
}

#===============================================================================
# MENU ACTION: DELETE ACCOUNT
#===============================================================================

# Build a whiptail --menu argument list from the DB users. Echoes tag/label
# pairs: "username" "(<protocol>, expires <date>)".
_user_menu_items() {
    jq -r '.users[] | "\(.username)\t(\(.protocol // "vision"), expires \(.expires_ts | strftime("%Y-%m-%d")))"' "${DB_FILE}" \
        | while IFS=$'\t' read -r name label; do
              printf '%s\n%s\n' "${name}" "${label}"
          done
}

# Present a picker; echoes chosen username or empty on cancel/no-users.
pick_user() {
    local title="$1"
    local count
    count="$(jq '.users | length' "${DB_FILE}")"
    if [[ "${count}" -eq 0 ]]; then
        whiptail --msgbox "No accounts exist yet." 8 50
        return 1
    fi
    mapfile -t items < <(_user_menu_items)
    whiptail --title "${title}" --menu "Select an account:" 20 70 12 "${items[@]}" 3>&1 1>&2 2>&3
}

action_delete() {
    ensure_provisioned
    local username protocol
    username="$(pick_user "Delete Account")" || return 0
    [[ -n "${username}" ]] || return 0

    whiptail --yesno "Permanently delete account '${username}'?" 8 60 || return 0

    protocol="$(get_user_protocol "${username}")"

    # Remove from the correct inbound, then DB, then apply.
    config_remove_client "${username}" "${protocol}"
    atomic_write "${DB_FILE}" "$(jq --arg u "${username}" '.users |= map(select(.username != $u))' "${DB_FILE}")"
    restart_xray || warn "Service restart reported an issue."

    whiptail --msgbox "Account '${username}' deleted." 8 50
}

#===============================================================================
# MENU ACTION: EXTEND ACCOUNT
#===============================================================================
action_extend() {
    ensure_provisioned
    local username
    username="$(pick_user "Extend Account")" || return 0
    [[ -n "${username}" ]] || return 0

    local add_days
    add_days="$(whiptail --inputbox "Days to ADD to '${username}':" 8 60 "30" \
                --title "Extend Account" 3>&1 1>&2 2>&3)" || return 0
    if [[ ! "${add_days}" =~ ^[0-9]+$ || "${add_days}" -lt 1 ]]; then
        whiptail --msgbox "Days must be a positive integer." 8 60
        return 0
    fi

    # If already expired, extend from *now*; otherwise from the current expiry.
    # This prevents "adding days" to a date in the past from staying expired.
    local now new_db
    now="$(date +%s)"
    new_db="$(jq \
        --arg u "${username}" \
        --argjson add "$(( add_days * 86400 ))" \
        --argjson now "${now}" \
        '(.users[] | select(.username==$u) | .expires_ts) |=
            ((if . > $now then . else $now end) + $add)' \
        "${DB_FILE}")"
    atomic_write "${DB_FILE}" "${new_db}"

    # If the user had been stripped from the config due to prior expiry, put
    # them back (into their protocol's inbound) so the extension takes effect
    # immediately.
    local uuid protocol
    protocol="$(get_user_protocol "${username}")"
    uuid="$(jq -r --arg u "${username}" '.users[] | select(.username==$u) | .uuid' "${DB_FILE}")"
    if ! config_has_client "${username}" "${protocol}"; then
        log "Re-adding previously-expired user '${username}' (${protocol}) to config."
        config_add_client "${username}" "${uuid}" "${protocol}"
        restart_xray || true
    fi

    local new_exp
    new_exp="$(jq -r --arg u "${username}" '.users[] | select(.username==$u) | .expires_ts' "${DB_FILE}")"
    whiptail --msgbox "Extended '${username}'.\nNew expiry: $(date -d "@${new_exp}" '+%Y-%m-%d %H:%M')" 9 60
}

#===============================================================================
# MENU ACTION: LIST ACCOUNTS  (convenience view)
#===============================================================================
action_list() {
    ensure_provisioned
    local now table
    now="$(date +%s)"
    table="$(jq -r --argjson now "${now}" '
        (["USERNAME","PROTOCOL","CREATED","EXPIRES","STATUS"] | @tsv),
        (.users[] |
            [ .username,
              (.protocol // "vision"),
              (.created_ts | strftime("%Y-%m-%d")),
              (.expires_ts | strftime("%Y-%m-%d")),
              (if .expires_ts > $now then "active" else "EXPIRED" end)
            ] | @tsv)
    ' "${DB_FILE}" | column -t -s$'\t')"
    whiptail --title "Accounts" --msgbox "${table:-No accounts.}" 20 78
}

#===============================================================================
# EXPIRY RECONCILIATION  (invoked by the systemd timer AND interactively)
#===============================================================================
# Strips every user whose expires_ts is in the past out of the live config,
# targeting the correct inbound per the user's protocol. The DB record is
# retained (marked expired implicitly by its timestamp) so the account can be
# extended/reactivated later without losing its UUID history.
reconcile_expired() {
    ensure_provisioned
    local now changed=0
    now="$(date +%s)"

    # Emit "username<TAB>protocol" for every expired user; default vision.
    mapfile -t expired < <(jq -r --argjson now "${now}" \
        '.users[] | select(.expires_ts <= $now) | "\(.username)\t\(.protocol // "vision")"' \
        "${DB_FILE}")

    local line u proto
    for line in "${expired[@]:-}"; do
        [[ -z "${line}" ]] && continue
        IFS=$'\t' read -r u proto <<<"${line}"
        [[ -z "${u}" ]] && continue
        [[ -z "${proto}" ]] && proto="vision"
        if config_has_client "${u}" "${proto}"; then
            log "Expiring user: ${u} (${proto})"
            config_remove_client "${u}" "${proto}"
            changed=1
        fi
    done

    if [[ "${changed}" -eq 1 ]]; then
        restart_xray || err "Reconcile: restart failed."
        log "Expiry reconciliation applied."
    else
        log "Expiry reconciliation: nothing to do."
    fi
}

#===============================================================================
# SYSTEMD TIMER INSTALLATION  (daily expiry sweep)
#===============================================================================
# A systemd timer is preferred over cron: it's journald-logged, survives
# missed runs (Persistent=true), and is trivially removable on uninstall.
install_expiry_timer() {
    log "Installing daily expiry timer..."

    cat > "${TIMER_SERVICE_PATH}" <<EOF
[Unit]
Description=Xray Manager - expire stale accounts
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash ${SCRIPT_PATH} --cron-expiry
EOF

    cat > "${TIMER_UNIT_PATH}" <<EOF
[Unit]
Description=Run Xray Manager expiry sweep daily

[Timer]
OnCalendar=*-*-* 04:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now "${TIMER_UNIT}"
    log "Timer '${TIMER_UNIT}' installed (daily @ 04:00)."
}

#===============================================================================
# MENU ACTION: SELF-UPDATE
#===============================================================================
action_update_script() {
    whiptail --yesno "Fetch latest script from:\n${UPDATE_URL}\n\nOverwrite ${SCRIPT_PATH} and restart?" 12 70 || return 0

    local tmp
    tmp="$(mktemp)"
    if ! curl -fsSL "${UPDATE_URL}" -o "${tmp}"; then
        rm -f "${tmp}"
        whiptail --msgbox "Download failed. Update aborted." 8 50
        return 0
    fi

    # Sanity check: must look like a bash script before we trust it.
    if ! head -n1 "${tmp}" | grep -qE '^#!.*(bash|sh)'; then
        rm -f "${tmp}"
        whiptail --msgbox "Downloaded file doesn't look like a shell script. Aborted." 8 60
        return 0
    fi

    # Keep a backup, then replace and re-exec the new version.
    cp -f "${SCRIPT_PATH}" "${SCRIPT_PATH}.bak"
    install -m 0755 "${tmp}" "${SCRIPT_PATH}"
    rm -f "${tmp}"
    log "Script updated. Restarting..."
    exec /usr/bin/env bash "${SCRIPT_PATH}"
}

#===============================================================================
# MENU ACTION: UNINSTALL  (full purge)
#===============================================================================
action_uninstall() {
    whiptail --yesno "This PURGES Xray, all accounts, config, the manager DB and the timer.\n\nAre you absolutely sure?" 12 70 || return 0

    log "Stopping and removing systemd timer..."
    systemctl disable --now "${TIMER_UNIT}" >/dev/null 2>&1 || true
    rm -f "${TIMER_UNIT_PATH}" "${TIMER_SERVICE_PATH}"

    log "Removing any legacy cron entries created by this script..."
    # Defensive: strip our marker line from root's crontab if it ever existed.
    ( crontab -l 2>/dev/null | grep -v 'xray-manager' | crontab - ) 2>/dev/null || true

    log "Uninstalling Xray-core..."
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge \
        || warn "Xray uninstaller returned non-zero (may already be gone)."

    log "Removing config and manager data..."
    rm -rf "$(dirname "${XRAY_CONFIG}")" "${MANAGER_DIR}"

    systemctl daemon-reload || true
    whiptail --msgbox "Uninstall complete. The script file itself remains at:\n${SCRIPT_PATH}" 9 70
    log "Done. Goodbye."
    exit 0
}

#===============================================================================
# INSTALL / PROVISION FLOW  (menu-triggered full setup)
#===============================================================================
action_install() {
    ensure_dependencies
    install_xray_core
    provision_server
    install_expiry_timer
    whiptail --msgbox "Installation complete.\n\nUse 'Create Account' to add your first user (Vision or XHTTP)." 10 62
}

#===============================================================================
# MAIN MENU (TUI)
#===============================================================================
main_menu() {
    while true; do
        local choice
        choice="$(whiptail --title "Xray VLESS+REALITY Manager v${SCRIPT_VERSION}" \
            --menu "Select an action:" 20 66 10 \
            "1" "Install / Provision server" \
            "2" "Create account" \
            "3" "Delete account" \
            "4" "Extend account" \
            "5" "List accounts" \
            "6" "Run expiry sweep now" \
            "7" "Update this script" \
            "8" "Uninstall everything" \
            "9" "Exit" \
            3>&1 1>&2 2>&3)" || break

        case "${choice}" in
            1) action_install ;;
            2) action_create ;;
            3) action_delete ;;
            4) action_extend ;;
            5) action_list ;;
            6) reconcile_expired; whiptail --msgbox "Expiry sweep finished." 8 40 ;;
            7) action_update_script ;;
            8) action_uninstall ;;
            9) break ;;
        esac
    done
    clear
    log "Exited manager."
}

#===============================================================================
# ENTRYPOINT
#===============================================================================
main() {
    require_root

    # Non-interactive hook used by the systemd timer.
    if [[ "${1:-}" == "--cron-expiry" ]]; then
        reconcile_expired
        exit 0
    fi

    # Interactive path.
    ensure_dependencies   # guarantee whiptail/jq exist before we draw any TUI.
    main_menu
}

main "$@"
