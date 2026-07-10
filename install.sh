#!/usr/bin/env bash
#
# xpro.sh — VLESS + XTLS-Vision + REALITY manager for Xray-core
#
#   Repo (placeholder — replace with your real fork before using "Update Script"):
#     https://github.com/BlackBat21/xpro
#
#   Upstream Xray-core:
#     https://github.com/xtls/xray-core
#
# WHAT THIS SCRIPT DOES
#   - Installs Xray-core from the official GitHub Releases API onto Ubuntu 24.04.
#   - Builds a single VLESS/XTLS-Vision/REALITY inbound on port 443.
#   - Manages "accounts" (Xray clients) with expiry dates tracked OUTSIDE the
#     Xray config, in a small local JSON database.
#   - Provides a dialog/whiptail TUI menu for create/delete/extend/list/update/
#     uninstall, plus a daily systemd timer that sweeps expired accounts.
#
# DESIGN NOTES
#   - Xray's config.json has no concept of "expiry" — it only knows about
#     clients that are either present or absent. Expiry is therefore modeled
#     as "does this user still exist in the config", and the source of truth
#     for *when* that should happen lives in our own DB file, never in the
#     Xray config itself. That satisfies requirement #2 in the spec and also
#     means a corrupt/rebuilt Xray config can never leak a stale expiry date.
#   - Every mutation of config.json goes through a read -> jq transform ->
#     validate -> atomically move into place pipeline, so a crash mid-write
#     can never leave Xray with a half-written (unparseable) config.
#   - jq is required, not optional, for anything that touches config.json.
#     No sed/awk/string-concat JSON generation, anywhere.
#
set -uo pipefail
# NOTE: we deliberately do NOT run this whole script under `set -e`.
# An interactive TUI needs to survive a failed sub-command (a bad jq filter,
# a user hitting Cancel, curl timing out) and return to the menu instead of
# dying. Instead, every function that performs a multi-step mutation checks
# each step's exit code explicitly and calls die()/warn() as appropriate.
# Where we DO want "abort this function on first error" semantics, we wrap
# the block in a subshell that itself uses `set -e` (see with_strict()).

# ---------------------------------------------------------------------------
# Global paths & constants
# ---------------------------------------------------------------------------
readonly XPRO_VERSION="1.0.0"
readonly XPRO_REPO="https://github.com/BlackBat21/xpro"                  # placeholder
readonly XPRO_RAW_URL="https://raw.githubusercontent.com/BlackBat21/xpro/main/xpro.sh"  # placeholder
_self_path="$(readlink -f "${BASH_SOURCE[0]}")"
readonly XPRO_SELF_PATH="${_self_path}"
unset _self_path

readonly XRAY_BIN_DIR="/usr/local/bin"
readonly XRAY_BIN="${XRAY_BIN_DIR}/xray"
readonly XRAY_ETC_DIR="/usr/local/etc/xray"
readonly XRAY_CONFIG="${XRAY_ETC_DIR}/config.json"
readonly XRAY_LOG_DIR="/var/log/xray"
readonly XRAY_SYSTEMD_UNIT="/etc/systemd/system/xray.service"
readonly XRAY_RELEASES_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"

readonly XPRO_HOME="/etc/xray-manager"
readonly XPRO_DB="${XPRO_HOME}/db.json"
readonly XPRO_KEYS="${XPRO_HOME}/reality_keys.json"
readonly XPRO_LOG="${XPRO_HOME}/xpro.log"
readonly XPRO_BACKUP_DIR="${XPRO_HOME}/backups"

readonly XPRO_SWEEP_SCRIPT="${XPRO_HOME}/expiry-sweep.sh"
readonly XPRO_SYSTEMD_SERVICE="/etc/systemd/system/xpro-sweep.service"
readonly XPRO_SYSTEMD_TIMER="/etc/systemd/system/xpro-sweep.timer"
readonly XPRO_CRON_FALLBACK="/etc/cron.d/xpro-sweep"   # used only if systemd timers are unavailable

readonly XPRO_INSTALLED_PATH="/usr/local/bin/xpro"     # where we install ourselves for `xpro` shorthand

# Default REALITY camouflage target. Overridable at install time via the TUI.
# (dest is always derived as "${sni}:443" at install time, so only the SNI
# and port need a default here — see run_installer.)
DEFAULT_SNI="www.microsoft.com"
DEFAULT_PORT="443"

# ---------------------------------------------------------------------------
# Colors (plain ANSI, degrade gracefully if not a tty)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    _c_red="$(tput setaf 1 2>/dev/null || true)"
    _c_green="$(tput setaf 2 2>/dev/null || true)"
    _c_yellow="$(tput setaf 3 2>/dev/null || true)"
    _c_blue="$(tput setaf 4 2>/dev/null || true)"
    _c_bold="$(tput bold 2>/dev/null || true)"
    _c_reset="$(tput sgr0 2>/dev/null || true)"
else
    _c_red="" _c_green="" _c_yellow="" _c_blue="" _c_bold="" _c_reset=""
fi
readonly C_RED="${_c_red}" C_GREEN="${_c_green}" C_YELLOW="${_c_yellow}"
readonly C_BLUE="${_c_blue}" C_BOLD="${_c_bold}" C_RESET="${_c_reset}"
unset _c_red _c_green _c_yellow _c_blue _c_bold _c_reset

# ---------------------------------------------------------------------------
# Logging helpers — everything goes to stderr AND the persistent log file,
# so the TUI's stdout stays clean for dialog/whiptail widgets.
# ---------------------------------------------------------------------------
_log_line() {
    # $1=level $2=message
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    printf '[%s] [%s] %s\n' "$ts" "$1" "$2" >>"${XPRO_LOG}" 2>/dev/null || true
}

info()  { echo -e "${C_BLUE}[INFO]${C_RESET} $*" >&2;  _log_line "INFO"  "$*"; }
ok()    { echo -e "${C_GREEN}[ OK ]${C_RESET} $*" >&2; _log_line "OK"    "$*"; }
warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET} $*" >&2; _log_line "WARN" "$*"; }
err()   { echo -e "${C_RED}[FAIL]${C_RESET} $*" >&2;   _log_line "ERROR" "$*"; }

die() {
    err "$*"
    exit 1
}

# Run a block with strict error handling and return its exit code instead of
# killing the whole interactive process. Usage: with_strict '<commands>'
with_strict() {
    (
        set -e
        eval "$1"
    )
}

pause() {
    # Give the operator a chance to read output before we redraw a dialog menu.
    read -rp "$(echo -e "${C_BOLD}Press Enter to continue...${C_RESET}")" _ </dev/tty || true
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "This script must be run as root (try: sudo bash $0)"
    fi
}

require_ubuntu() {
    if [[ ! -f /etc/os-release ]]; then
        warn "Cannot detect OS (missing /etc/os-release). Continuing anyway, but this script targets Ubuntu 24.04 LTS."
        return
    fi
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" != "ubuntu" ]]; then
        warn "Detected OS '${ID:-unknown}', not Ubuntu. This script is tested on Ubuntu 24.04 LTS only — proceed at your own risk."
    elif [[ "${VERSION_ID:-}" != "24.04" ]]; then
        warn "Detected Ubuntu ${VERSION_ID:-unknown}, not 24.04. Continuing, but some steps may differ."
    fi
}

# ---------------------------------------------------------------------------
# Dependency management
# ---------------------------------------------------------------------------
# Packages we need and the binary we check for to decide if they're present.
# uuid-runtime -> uuidgen, dialog -> dialog (whiptail is the fallback).
declare -A XPRO_DEPS=(
    [curl]=curl
    [jq]=jq
    [uuidgen]=uuid-runtime
    [unzip]=unzip
    [openssl]=openssl
    [qrencode]=qrencode
)

DIALOG_BIN=""   # set by ensure_tui_backend; either "dialog" or "whiptail"

apt_updated_once=0
apt_update_once() {
    if [[ "${apt_updated_once}" -eq 0 ]]; then
        info "Refreshing apt package lists..."
        if DEBIAN_FRONTEND=noninteractive apt-get update -qq; then
            apt_updated_once=1
        else
            warn "apt-get update failed — package installs below may fail or use a stale cache."
        fi
    fi
}

install_pkg() {
    local pkg="$1"
    apt_update_once
    info "Installing package: ${pkg}"
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkg}" >>"${XPRO_LOG}" 2>&1; then
        die "Failed to install required package '${pkg}'. Check ${XPRO_LOG} for details."
    fi
}

check_dependencies() {
    info "Checking base dependencies..."
    local bin pkg
    for bin in "${!XPRO_DEPS[@]}"; do
        pkg="${XPRO_DEPS[$bin]}"
        if ! command -v "${bin}" >/dev/null 2>&1; then
            install_pkg "${pkg}"
        fi
    done
    ok "Base dependencies satisfied (curl, jq, uuid-runtime, unzip, openssl, qrencode)."
}

# Prefer 'dialog' for its nicer widgets; fall back to 'whiptail' (near-identical
# CLI syntax) if dialog can't be installed for some reason (e.g. no universe
# repo). Both are driven the same way in this script via the dlg() wrapper.
ensure_tui_backend() {
    if command -v dialog >/dev/null 2>&1; then
        DIALOG_BIN="dialog"
        return
    fi
    if command -v whiptail >/dev/null 2>&1; then
        DIALOG_BIN="whiptail"
        return
    fi

    info "No TUI backend found — attempting to install 'dialog'..."
    apt_update_once
    if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq dialog >>"${XPRO_LOG}" 2>&1 \
        && command -v dialog >/dev/null 2>&1; then
        DIALOG_BIN="dialog"
        return
    fi

    warn "'dialog' install failed, trying 'whiptail'..."
    if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq whiptail >>"${XPRO_LOG}" 2>&1 \
        && command -v whiptail >/dev/null 2>&1; then
        DIALOG_BIN="whiptail"
        return
    fi

    die "Could not install either 'dialog' or 'whiptail'. A text UI backend is required."
}

# Thin wrapper so every call site doesn't need to branch on dialog vs
# whiptail. Both tools accept the same flags for the widgets we use
# (--menu, --inputbox, --yesno, --msgbox, --passwordbox, --checklist).
dlg() {
    "${DIALOG_BIN}" --backtitle "xpro — Xray VLESS/XTLS-Vision/REALITY manager v${XPRO_VERSION}" "$@"
}

# ---------------------------------------------------------------------------
# Local database (source of truth for expiry — NEVER stored in Xray config)
# ---------------------------------------------------------------------------
# Schema:
# {
#   "users": [
#     {
#       "username": "alice",
#       "uuid": "xxxxxxxx-xxxx-...",
#       "short_id": "a1b2c3d4",
#       "created_at": "2026-07-10T12:00:00Z",
#       "expires_at": "2026-08-09T12:00:00Z",
#       "enabled": true
#     }
#   ]
# }
#
# "enabled" tracks whether the user is currently present in config.json.
# The daily sweep sets it to false (and removes from config.json) once
# expires_at is in the past; it does NOT delete the DB row, so history and
# "extend after expiry" both remain possible.

db_init() {
    mkdir -p "${XPRO_HOME}" "${XPRO_BACKUP_DIR}"
    chmod 700 "${XPRO_HOME}"
    if [[ ! -f "${XPRO_DB}" ]]; then
        info "Initializing local database at ${XPRO_DB}"
        printf '{"users": []}' | jq '.' >"${XPRO_DB}"
        chmod 600 "${XPRO_DB}"
    fi
    # Validate on every startup — a hand-edited or half-written DB should be
    # caught immediately rather than corrupting the next write.
    if ! jq -e . "${XPRO_DB}" >/dev/null 2>&1; then
        die "Database file ${XPRO_DB} is not valid JSON. Restore from ${XPRO_BACKUP_DIR} or fix manually before continuing."
    fi
}

# Atomically write a jq filter's result back to the DB. Never edits the DB
# file in place — always writes to a temp file in the same directory (so the
# final `mv` is on the same filesystem and therefore atomic) and only
# replaces the real file if the jq run succeeded AND produced valid JSON.
# $1 = jq filter, remaining args = extra --arg/--argjson pairs.
db_write() {
    local filter="$1"
    shift
    local tmp
    tmp="$(mktemp "${XPRO_HOME}/.db.XXXXXX.json")"

    if ! jq "$@" "${filter}" "${XPRO_DB}" >"${tmp}" 2>>"${XPRO_LOG}"; then
        rm -f "${tmp}"
        die "Database update failed (jq error) — no changes were made. See ${XPRO_LOG}."
    fi
    if ! jq -e . "${tmp}" >/dev/null 2>&1; then
        rm -f "${tmp}"
        die "Database update produced invalid JSON — aborting before overwrite."
    fi

    cp -p "${XPRO_DB}" "${XPRO_BACKUP_DIR}/db.json.$(date +%s).bak" 2>/dev/null || true
    chmod 600 "${tmp}"
    mv -f "${tmp}" "${XPRO_DB}"
    # Keep only the last 20 backups so this doesn't grow forever.
    find "${XPRO_BACKUP_DIR}" -maxdepth 1 -name 'db.json.*.bak' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | tail -n +21 | cut -d' ' -f2- | xargs -r rm -f
}

db_user_exists() {
    local username="$1"
    jq -e --arg u "${username}" '.users[] | select(.username == $u)' "${XPRO_DB}" >/dev/null 2>&1
}

db_add_user() {
    local username="$1" uuid="$2" short_id="$3" created_at="$4" expires_at="$5"
    db_write '(.users) += [{
            username:   $username,
            uuid:       $uuid,
            short_id:   $short_id,
            created_at: $created_at,
            expires_at: $expires_at,
            enabled:    true
        }]' \
        --arg username "${username}" \
        --arg uuid "${uuid}" \
        --arg short_id "${short_id}" \
        --arg created_at "${created_at}" \
        --arg expires_at "${expires_at}"
}

db_remove_user() {
    local username="$1"
    db_write '.users |= map(select(.username != $u))' --arg u "${username}"
}

db_set_enabled() {
    local username="$1" enabled="$2"   # enabled: "true" | "false"
    db_write '.users |= map(if .username == $u then .enabled = ($e == "true") else . end)' \
        --arg u "${username}" --arg e "${enabled}"
}

db_extend_user() {
    local username="$1" new_expiry="$2"
    db_write '.users |= map(if .username == $u then .expires_at = $exp else . end)' \
        --arg u "${username}" --arg exp "${new_expiry}"
}

db_get_user_field() {
    local username="$1" field="$2"
    jq -r --arg u "${username}" --arg f "${field}" '.users[] | select(.username == $u) | .[$f]' "${XPRO_DB}"
}

# Returns tab-separated: username, expires_at, enabled — one line per user,
# for building menu lists.
db_list_users() {
    jq -r '.users[] | [.username, .expires_at, (.enabled|tostring)] | @tsv' "${XPRO_DB}"
}

db_list_expired_enabled_users() {
    local now="$1"   # ISO8601 UTC "now" to compare against
    jq -r --arg now "${now}" \
        '.users[] | select(.enabled == true and .expires_at < $now) | .username' \
        "${XPRO_DB}"
}

# ---------------------------------------------------------------------------
# Xray install / binary management
# ---------------------------------------------------------------------------
detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "64" ;;
        aarch64|arm64) echo "arm64-v8a" ;;
        armv7l)        echo "arm32-v7a" ;;
        s390x)         echo "s390x" ;;
        *) die "Unsupported CPU architecture: $(uname -m). Xray-core release assets don't cover this." ;;
    esac
}

xray_is_installed() {
    [[ -x "${XRAY_BIN}" ]] && "${XRAY_BIN}" version >/dev/null 2>&1
}

# Downloads and installs (or upgrades) the Xray-core binary from the official
# GitHub Releases API — always "latest", per XTLS/Xray-core.
install_xray_binary() {
    local arch tag download_url tmp_dir zip_path
    arch="$(detect_arch)"

    info "Querying GitHub Releases API for the latest Xray-core version..."
    tag="$(curl -fsSL "${XRAY_RELEASES_API}" | jq -r '.tag_name // empty')"
    if [[ -z "${tag}" ]]; then
        die "Could not determine the latest Xray-core release tag from ${XRAY_RELEASES_API}. Check network/DNS/GitHub API rate limits."
    fi
    ok "Latest Xray-core release: ${tag}"

    download_url="https://github.com/XTLS/Xray-core/releases/download/${tag}/Xray-linux-${arch}.zip"
    tmp_dir="$(mktemp -d)"
    zip_path="${tmp_dir}/xray.zip"

    info "Downloading ${download_url}"
    if ! curl -fL --retry 3 --retry-delay 2 -o "${zip_path}" "${download_url}"; then
        rm -rf "${tmp_dir}"
        die "Download failed for ${download_url}. If your arch/OS combo isn't published upstream, install manually."
    fi

    info "Extracting..."
    if ! unzip -oq "${zip_path}" -d "${tmp_dir}"; then
        rm -rf "${tmp_dir}"
        die "Failed to unzip the downloaded Xray-core release."
    fi
    if [[ ! -f "${tmp_dir}/xray" ]]; then
        rm -rf "${tmp_dir}"
        die "Downloaded archive did not contain an 'xray' binary as expected."
    fi

    # Stop the service before replacing the binary out from under it, if running.
    if systemctl is-active --quiet xray 2>/dev/null; then
        info "Stopping xray.service for binary upgrade..."
        systemctl stop xray
    fi

    install -d -m 755 "${XRAY_BIN_DIR}"
    install -m 755 "${tmp_dir}/xray" "${XRAY_BIN}"
    install -d -m 755 "${XRAY_ETC_DIR}"
    install -d -m 750 "${XRAY_LOG_DIR}"

    rm -rf "${tmp_dir}"

    if ! "${XRAY_BIN}" version >/dev/null 2>&1; then
        die "xray binary installed at ${XRAY_BIN} but fails to execute — check architecture compatibility."
    fi
    ok "Installed $("${XRAY_BIN}" version | head -n1)"
}

install_systemd_unit() {
    info "Writing systemd unit ${XRAY_SYSTEMD_UNIT}"
    cat >"${XRAY_SYSTEMD_UNIT}" <<EOF
[Unit]
Description=Xray Service (managed by xpro)
Documentation=https://github.com/xtls/xray-core
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
NoNewPrivileges=true
ExecStart=${XRAY_BIN} run -config ${XRAY_CONFIG}
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable xray >/dev/null 2>&1
}

restart_xray() {
    info "Validating config before restart..."
    if ! "${XRAY_BIN}" run -test -config "${XRAY_CONFIG}" >>"${XPRO_LOG}" 2>&1; then
        err "Xray config failed validation (xray run -test). NOT restarting the live service."
        err "See ${XPRO_LOG} for the validator's output, and ${XRAY_CONFIG} for the file itself."
        return 1
    fi
    systemctl restart xray
    sleep 1
    if ! systemctl is-active --quiet xray; then
        err "xray.service failed to start after restart. Recent logs:"
        journalctl -u xray -n 20 --no-pager >&2 || true
        return 1
    fi
    ok "xray.service restarted successfully."
    return 0
}

# ---------------------------------------------------------------------------
# REALITY keypair generation
# ---------------------------------------------------------------------------
# IMPORTANT VERSION NOTE:
#   Older Xray-core: `xray x25519` prints "Private key:" / "Public key:"
#   (note the space before "key").
#   Newer Xray-core (v25.3.6+): it prints "PrivateKey:" / "Password:" /
#   "Hash32:" (no space), where "Password" IS the value that used to be
#   called "Public key" (confirmed via XTLS/Xray-core discussion #5219 — the
#   devs renamed it specifically so people don't casually paste it around,
#   since it's usable to probe for REALITY servers).
#   Some current builds print all three lines together (Private key: /
#   Public key: / Password:), so we treat "Public key" and "Password" as
#   alternatives and prefer "Public key" when both are present, rather than
#   assuming the two label sets are mutually exclusive.
#   We must not hardcode one label set, since "the latest version" is a
#   moving target by design of this script (it always installs latest) — so
#   we parse robustly for old, new, and combined output.
generate_reality_keys() {
    local raw private_key public_key
    raw="$("${XRAY_BIN}" x25519 2>/dev/null)"
    if [[ -z "${raw}" ]]; then
        die "xray x25519 produced no output — cannot generate REALITY keys."
    fi

    # grep -i 'Private ?Key:' matches both "Private key:" (old, spaced) and
    # "PrivateKey:" (new, unspaced) case-insensitively; cut -d: -f2 takes
    # everything after the first colon (safe here since base64url key
    # material never contains a literal ':'), then we strip whitespace/CR.
    private_key="$(echo "${raw}" | grep -iE '^Private ?Key:' | head -n1 | cut -d: -f2 | tr -d ' \r')"
    public_key="$(echo "${raw}" | grep -iE '^Public ?Key:' | head -n1 | cut -d: -f2 | tr -d ' \r')"
    if [[ -z "${public_key}" ]]; then
        public_key="$(echo "${raw}" | grep -iE '^Password:' | head -n1 | cut -d: -f2 | tr -d ' \r')"
    fi

    if [[ -z "${private_key}" || -z "${public_key}" ]]; then
        err "Could not parse 'xray x25519' output. Raw output was:"
        echo "${raw}" >&2
        die "REALITY key generation failed — unrecognized xray x25519 output format."
    fi

    mkdir -p "${XPRO_HOME}"
    jq -n --arg priv "${private_key}" --arg pub "${public_key}" \
        '{private_key: $priv, public_key: $pub}' >"${XPRO_KEYS}"
    chmod 600 "${XPRO_KEYS}"
    ok "REALITY X25519 keypair generated and stored in ${XPRO_KEYS}."
}

reality_private_key() { jq -r '.private_key' "${XPRO_KEYS}"; }
reality_public_key()  { jq -r '.public_key'  "${XPRO_KEYS}"; }

gen_short_id() {
    # 8-byte hex shortId, distinct per user (helps distinguish clients at the
    # network level and lets you selectively invalidate one later if desired).
    openssl rand -hex 8
}

# ---------------------------------------------------------------------------
# Xray config.json generation & safe mutation
# ---------------------------------------------------------------------------
# All writes to config.json go through cfg_write(), which:
#   1. Applies a jq filter to the current config into a temp file.
#   2. Validates the result is well-formed JSON.
#   3. Validates it with `xray run -test` (catches semantic errors jq can't
#      see, e.g. a missing required field).
#   4. Only then atomically replaces the live config.
# If any step fails, the live config.json is left completely untouched.
cfg_write() {
    local filter="$1"
    shift
    local tmp
    tmp="$(mktemp "${XRAY_ETC_DIR}/.config.XXXXXX.json")"

    if ! jq "$@" "${filter}" "${XRAY_CONFIG}" >"${tmp}" 2>>"${XPRO_LOG}"; then
        rm -f "${tmp}"
        die "jq failed while updating ${XRAY_CONFIG} — no changes were made. See ${XPRO_LOG}."
    fi
    if ! jq -e . "${tmp}" >/dev/null 2>&1; then
        rm -f "${tmp}"
        die "Config update produced invalid JSON — aborting before overwrite."
    fi
    if ! "${XRAY_BIN}" run -test -config "${tmp}" >>"${XPRO_LOG}" 2>&1; then
        rm -f "${tmp}"
        die "Config update failed Xray's own validation (xray run -test) — aborting before overwrite. See ${XPRO_LOG}."
    fi

    cp -p "${XRAY_CONFIG}" "${XPRO_BACKUP_DIR}/config.json.$(date +%s).bak" 2>/dev/null || true
    chmod 644 "${tmp}"
    mv -f "${tmp}" "${XRAY_CONFIG}"
    find "${XPRO_BACKUP_DIR}" -maxdepth 1 -name 'config.json.*.bak' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | tail -n +21 | cut -d' ' -f2- | xargs -r rm -f
}

# Writes a brand-new base config with one VLESS/XTLS-Vision/REALITY inbound
# and no clients yet. Clients are added afterwards via cfg_add_client so the
# add-a-user code path is identical whether it's the 1st or 100th user.
generate_base_config() {
    local port="$1" dest="$2" sni="$3" private_key="$4"
    install -d -m 755 "${XRAY_ETC_DIR}"

    jq -n \
        --argjson port "${port}" \
        --arg dest "${dest}" \
        --arg sni "${sni}" \
        --arg priv "${private_key}" \
        '{
            log: {
                loglevel: "warning",
                access: "'"${XRAY_LOG_DIR}"'/access.log",
                error: "'"${XRAY_LOG_DIR}"'/error.log"
            },
            inbounds: [
                {
                    tag: "vless-reality-in",
                    listen: "0.0.0.0",
                    port: $port,
                    protocol: "vless",
                    settings: {
                        clients: [],
                        decryption: "none"
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
                            shortIds: []
                        }
                    },
                    sniffing: {
                        enabled: true,
                        destOverride: ["http", "tls", "quic"]
                    }
                }
            ],
            outbounds: [
                { protocol: "freedom", tag: "direct" },
                { protocol: "blackhole", tag: "block" }
            ]
        }' >"${XRAY_CONFIG}"

    chmod 644 "${XRAY_CONFIG}"
    ok "Base Xray config written to ${XRAY_CONFIG} (port ${port}, SNI ${sni})."
}

# Adds one client to the single inbound's clients[] AND its shortId to
# shortIds[]. email is set to the username purely for human-readable
# `xray api` / log correlation — it is NEVER used to store expiry.
cfg_add_client() {
    local username="$1" uuid="$2" short_id="$3"
    cfg_write '(.inbounds[0].settings.clients) += [{
            id: $uuid,
            flow: "xtls-rprx-vision",
            email: $username
        }]
        | (.inbounds[0].streamSettings.realitySettings.shortIds) += [$sid]' \
        --arg username "${username}" \
        --arg uuid "${uuid}" \
        --arg sid "${short_id}"
}

# Removes a client by username (email field) and its shortId. We look up the
# shortId from the DB (not the config) before calling this, then strip both
# in one jq pass so config.json never has an orphaned shortId hanging around
# unrelated to any live client.
cfg_remove_client() {
    local username="$1" short_id="$2"
    cfg_write '(.inbounds[0].settings.clients) |= map(select(.email != $username))
        | (.inbounds[0].streamSettings.realitySettings.shortIds) |= map(select(. != $sid))' \
        --arg username "${username}" \
        --arg sid "${short_id}"
}

cfg_client_exists() {
    local username="$1"
    jq -e --arg u "${username}" '.inbounds[0].settings.clients[] | select(.email == $u)' \
        "${XRAY_CONFIG}" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Public IP detection & VLESS share-link construction
# ---------------------------------------------------------------------------
detect_public_ip() {
    local ip
    ip="$(curl -fsSL4 --max-time 5 https://api.ipify.org 2>/dev/null)"
    if [[ -z "${ip}" ]]; then
        ip="$(curl -fsSL4 --max-time 5 https://ifconfig.me 2>/dev/null)"
    fi
    if [[ -z "${ip}" ]]; then
        warn "Could not auto-detect public IP. Falling back to first non-loopback address."
        ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi
    echo "${ip}"
}

# Builds a vless:// URI per the informal but widely-adopted VLESS URI scheme
# used by Xray/V2Ray clients. Query params are URL-encoded where it matters
# (username in the fragment is the one field likely to contain spaces).
urlencode() {
    # Pure-bash percent-encoding — deliberately avoids depending on python3
    # (not guaranteed present on a minimal Ubuntu server image) or a
    # jq @uri filter version quirk. Only used for the link's fragment
    # (the username label), so this only needs to be correct, not fast.
    local s="$1" out="" c i
    for (( i=0; i<${#s}; i++ )); do
        c="${s:i:1}"
        case "${c}" in
            [a-zA-Z0-9.~_-]) out+="${c}" ;;
            *) out+="$(printf '%%%02X' "'${c}")" ;;
        esac
    done
    echo "${out}"
}

build_vless_link() {
    local username="$1" uuid="$2" server_ip="$3" port="$4" sni="$5" pubkey="$6" short_id="$7"
    local frag
    frag="$(urlencode "${username}")"

    printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#%s\n' \
        "${uuid}" "${server_ip}" "${port}" "${sni}" "${pubkey}" "${short_id}" "${frag}"
}

# Displays a link both as text and (if qrencode is available, which we
# install as a dependency) as a terminal-rendered QR code for quick mobile
# scanning. Always shown outside dialog (plain stdout) since dialog's text
# boxes mangle wide QR output and scrollback is more useful here anyway.
show_link_and_qr() {
    local link="$1"
    echo
    echo -e "${C_BOLD}VLESS connection link:${C_RESET}"
    echo "${link}"
    echo
    if command -v qrencode >/dev/null 2>&1; then
        echo -e "${C_BOLD}QR code:${C_RESET}"
        qrencode -t ANSIUTF8 "${link}"
        echo
    else
        warn "qrencode not available — showing link text only."
    fi
}

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------
# Username rules: 3-32 chars, alnum + underscore/hyphen, must start with a
# letter. Kept restrictive on purpose — this value is used as a jq --arg
# match key, an Xray "email" field, and a URI fragment, so keeping it to a
# safe character set sidesteps a whole class of escaping bugs rather than
# trying to escape every consumer perfectly.
valid_username() {
    [[ "$1" =~ ^[a-zA-Z][a-zA-Z0-9_-]{2,31}$ ]]
}

valid_days() {
    # Positive integer, reasonable upper bound (10 years) to catch fat-finger
    # entry like an extra zero turning 30 days into 300 years.
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 3650 ))
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

# now / date-math helpers, all UTC, all ISO 8601 — one format used
# everywhere (DB, comparisons, display) so string comparison in jq
# (.expires_at < $now) is always correct without parsing.
now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

expiry_from_days() {
    local days="$1"
    date -u -d "+${days} days" +"%Y-%m-%dT%H:%M:%SZ"
}

extend_expiry() {
    local current_iso="$1" days="$2" base
    # If already expired, extend from *now* rather than compounding onto a
    # past date — otherwise "extend a 3-month-expired account by 7 days"
    # would still leave it expired, which is almost never the intent.
    if [[ "${current_iso}" < "$(now_iso)" ]]; then
        base="now"
    else
        base="${current_iso}"
    fi
    date -u -d "${base} +${days} days" +"%Y-%m-%dT%H:%M:%SZ"
}

human_date() {
    date -u -d "$1" +"%Y-%m-%d %H:%M UTC" 2>/dev/null || echo "$1"
}

# ---------------------------------------------------------------------------
# Menu action: Create Account
# ---------------------------------------------------------------------------
action_create_account() {
    local username days uuid short_id created_at expires_at server_ip port sni pubkey link
    local answer

    answer="$(dlg --title "Create Account" --inputbox "Enter a username (3-32 chars, letters/numbers/_/- , must start with a letter):" 10 70 3>&1 1>&2 2>&3)" \
        || { info "Create Account cancelled."; return; }
    username="${answer}"

    if [[ -z "${username}" ]]; then
        dlg --title "Error" --msgbox "Username cannot be empty." 8 50
        return
    fi
    if ! valid_username "${username}"; then
        dlg --title "Invalid username" --msgbox "Username must be 3-32 characters, start with a letter, and contain only letters, numbers, underscore, or hyphen." 9 70
        return
    fi
    # Block duplicates against BOTH the DB and the live config — belt and
    # braces in case they've ever drifted apart (e.g. manual config edits).
    if db_user_exists "${username}"; then
        dlg --title "Duplicate username" --msgbox "A user named '${username}' already exists in the database. Choose a different name, or use Extend/Delete instead." 9 70
        return
    fi
    if cfg_client_exists "${username}"; then
        dlg --title "Duplicate username" --msgbox "A client with email '${username}' already exists in the live Xray config even though it's not in the database. Refusing to create a duplicate — please investigate ${XRAY_CONFIG} manually." 10 70
        return
    fi

    answer="$(dlg --title "Create Account" --inputbox "Duration in days (1-3650):" 10 60 "30" 3>&1 1>&2 2>&3)" \
        || { info "Create Account cancelled."; return; }
    days="${answer}"

    if ! valid_days "${days}"; then
        dlg --title "Invalid duration" --msgbox "Duration must be a whole number of days between 1 and 3650." 8 60
        return
    fi

    uuid="$(uuidgen)"
    short_id="$(gen_short_id)"
    created_at="$(now_iso)"
    expires_at="$(expiry_from_days "${days}")"

    # --- Apply to Xray config first, DB second. If the config write fails
    # (e.g. validation error), we bail out BEFORE touching the DB, so we
    # never end up with a DB row for a user who was never actually granted
    # access. cfg_add_client calls die() on failure, which exits the whole
    # script — acceptable here since a config write failure means something
    # is structurally wrong and continuing the TUI would be misleading.
    info "Adding client '${username}' to Xray config..."
    cfg_add_client "${username}" "${uuid}" "${short_id}"

    info "Recording '${username}' in local database (expires ${expires_at})..."
    db_add_user "${username}" "${uuid}" "${short_id}" "${created_at}" "${expires_at}"

    if ! restart_xray; then
        dlg --title "Warning" --msgbox "Account was created, but xray.service failed to restart cleanly. It will likely pick up the change on the next successful restart. Check: journalctl -u xray -n 50" 10 70
    fi

    server_ip="$(detect_public_ip)"
    port="$(jq -r '.inbounds[0].port' "${XRAY_CONFIG}")"
    sni="$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "${XRAY_CONFIG}")"
    pubkey="$(reality_public_key)"
    link="$(build_vless_link "${username}" "${uuid}" "${server_ip}" "${port}" "${sni}" "${pubkey}" "${short_id}")"

    dlg --title "Account Created" --msgbox "User '${username}' created successfully.\n\nExpires: $(human_date "${expires_at}")\n\nThe VLESS link and QR code will be printed to the terminal after you close this dialog." 12 70

    # Drop out of the dialog UI to plain stdout for the link + QR, since QR
    # rendering needs real terminal width/scrollback that dialog boxes don't
    # give us cleanly.
    clear
    echo -e "${C_GREEN}${C_BOLD}Account '${username}' created.${C_RESET}"
    echo "  UUID:       ${uuid}"
    echo "  Short ID:   ${short_id}"
    echo "  Created:    $(human_date "${created_at}")"
    echo "  Expires:    $(human_date "${expires_at}")"
    show_link_and_qr "${link}"
    pause
}

# ---------------------------------------------------------------------------
# Shared helper: build a dialog --menu of existing users, return the chosen
# username on stdout (empty string / non-zero exit if cancelled or no users).
# ---------------------------------------------------------------------------
pick_user() {
    local title="$1"
    local -a menu_items=()
    local username expires_at enabled status line

    if [[ ! -s "${XPRO_DB}" ]] || [[ "$(jq '.users | length' "${XPRO_DB}")" -eq 0 ]]; then
        dlg --title "${title}" --msgbox "No accounts exist yet. Use 'Create Account' first." 8 60
        return 1
    fi

    while IFS=$'\t' read -r username expires_at enabled; do
        if [[ "${enabled}" == "true" ]]; then
            if [[ "${expires_at}" < "$(now_iso)" ]]; then
                status="expired, pending sweep"
            else
                status="active until $(human_date "${expires_at}")"
            fi
        else
            status="disabled/expired"
        fi
        menu_items+=("${username}" "${status}")
    done < <(db_list_users)

    if [[ "${#menu_items[@]}" -eq 0 ]]; then
        dlg --title "${title}" --msgbox "No accounts found." 8 50
        return 1
    fi

    line="$(dlg --title "${title}" --menu "Select an account:" 20 78 12 "${menu_items[@]}" 3>&1 1>&2 2>&3)" \
        || return 1
    echo "${line}"
    return 0
}

# ---------------------------------------------------------------------------
# Menu action: Delete Account
# ---------------------------------------------------------------------------
action_delete_account() {
    local username short_id

    username="$(pick_user "Delete Account")" || { info "Delete Account cancelled."; return; }

    if ! dlg --title "Confirm Delete" --yesno "Delete account '${username}'?\n\nThis removes them from the Xray config AND the local database. This cannot be undone (though a backup of both files is kept in ${XPRO_BACKUP_DIR})." 11 72; then
        info "Delete Account cancelled by operator."
        return
    fi

    short_id="$(db_get_user_field "${username}" "short_id")"

    # Remove from config first (same ordering rationale as create: never let
    # the DB and config disagree about who currently has access). If this
    # step fails, cfg_remove_client's cfg_write will die() before we touch
    # the DB, so the DB and config both still agree (both still list the
    # user) rather than disagreeing in a new way.
    if cfg_client_exists "${username}"; then
        info "Removing '${username}' from Xray config..."
        cfg_remove_client "${username}" "${short_id}"
    else
        warn "User '${username}' was not present in the live Xray config (already removed or never synced) — removing DB record only."
    fi

    db_remove_user "${username}"

    if ! restart_xray; then
        dlg --title "Warning" --msgbox "Account deleted from config and database, but xray.service failed to restart cleanly. Check: journalctl -u xray -n 50" 9 70
    else
        dlg --title "Deleted" --msgbox "Account '${username}' has been deleted and xray.service restarted." 8 60
    fi
}

# ---------------------------------------------------------------------------
# Menu action: Extend Account
# ---------------------------------------------------------------------------
action_extend_account() {
    local username current_expiry days new_expiry answer was_disabled uuid short_id

    username="$(pick_user "Extend Account")" || { info "Extend Account cancelled."; return; }

    current_expiry="$(db_get_user_field "${username}" "expires_at")"
    was_disabled="$(db_get_user_field "${username}" "enabled")"

    answer="$(dlg --title "Extend Account" --inputbox "Current expiry for '${username}': $(human_date "${current_expiry}")\n\nDays to ADD:" 11 70 "30" 3>&1 1>&2 2>&3)" \
        || { info "Extend Account cancelled."; return; }
    days="${answer}"

    if ! valid_days "${days}"; then
        dlg --title "Invalid duration" --msgbox "Duration must be a whole number of days between 1 and 3650." 8 60
        return
    fi

    new_expiry="$(extend_expiry "${current_expiry}" "${days}")"
    db_extend_user "${username}" "${new_expiry}"

    # If the account had already been swept (disabled + removed from config
    # by the expiry job), extending it should also RE-ENABLE it — otherwise
    # "extend" on an expired account would silently do nothing until the
    # next manual re-creation, which isn't what an operator asking to
    # extend an expired account wants.
    if [[ "${was_disabled}" == "false" ]]; then
        info "Account was previously expired/disabled — re-adding to Xray config..."
        uuid="$(db_get_user_field "${username}" "uuid")"
        short_id="$(db_get_user_field "${username}" "short_id")"
        if ! cfg_client_exists "${username}"; then
            cfg_add_client "${username}" "${uuid}" "${short_id}"
        fi
        db_set_enabled "${username}" "true"
        restart_xray || dlg --title "Warning" --msgbox "Expiry extended and account re-enabled, but xray.service failed to restart. Check: journalctl -u xray -n 50" 9 70
    fi

    dlg --title "Extended" --msgbox "Account '${username}' extended.\n\nNew expiry: $(human_date "${new_expiry}")" 9 60
}

# ---------------------------------------------------------------------------
# Menu action: List Accounts (read-only overview)
# ---------------------------------------------------------------------------
action_list_accounts() {
    local username expires_at enabled body status

    if [[ "$(jq '.users | length' "${XPRO_DB}")" -eq 0 ]]; then
        dlg --title "Accounts" --msgbox "No accounts exist yet." 8 50
        return
    fi

    body=""
    while IFS=$'\t' read -r username expires_at enabled; do
        if [[ "${enabled}" == "true" ]]; then
            if [[ "${expires_at}" < "$(now_iso)" ]]; then
                status="EXPIRED (pending sweep)"
            else
                status="active"
            fi
        else
            status="disabled"
        fi
        body+="$(printf '%-24s %-10s %s\n' "${username}" "${status}" "$(human_date "${expires_at}")")"$'\n'
    done < <(db_list_users)

    dlg --title "All Accounts" --msgbox "$(printf '%-24s %-10s %s\n\n' 'USERNAME' 'STATUS' 'EXPIRES')${body}" 22 78
}

# ---------------------------------------------------------------------------
# Menu action: Show Account Link (re-display an existing account's VLESS
# link/QR without needing to recreate it — useful if a client lost their
# config). Not explicitly called out as a separate top-level requirement,
# but directly implied by "print the resulting VLESS link/QR data" — the
# operator will want to reprint this later too.
# ---------------------------------------------------------------------------
action_show_link() {
    local username uuid short_id server_ip port sni pubkey link

    username="$(pick_user "Show Account Link")" || { info "Show Account Link cancelled."; return; }

    if ! cfg_client_exists "${username}"; then
        dlg --title "Not active" --msgbox "'${username}' is not currently present in the live Xray config (expired/disabled). Use Extend Account to re-enable them first." 9 70
        return
    fi

    uuid="$(db_get_user_field "${username}" "uuid")"
    short_id="$(db_get_user_field "${username}" "short_id")"
    server_ip="$(detect_public_ip)"
    port="$(jq -r '.inbounds[0].port' "${XRAY_CONFIG}")"
    sni="$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "${XRAY_CONFIG}")"
    pubkey="$(reality_public_key)"
    link="$(build_vless_link "${username}" "${uuid}" "${server_ip}" "${port}" "${sni}" "${pubkey}" "${short_id}")"

    clear
    echo -e "${C_GREEN}${C_BOLD}Connection details for '${username}':${C_RESET}"
    show_link_and_qr "${link}"
    pause
}

# ---------------------------------------------------------------------------
# Expiry sweep: standalone script + systemd timer (with cron fallback)
# ---------------------------------------------------------------------------
# The sweep runs as its OWN script file, not as "xpro.sh --sweep", so that:
#   - It has zero dependency on dialog/whiptail (it must run unattended,
#     non-interactively, at 3am with nobody watching).
#   - It can be inspected/audited independently of the interactive tool.
#   - An `Update Script` on xpro.sh can't accidentally change sweep behavior
#     mid-flight without a corresponding, deliberate regeneration step.
write_sweep_script() {
    install -d -m 700 "${XPRO_HOME}"
    cat >"${XPRO_SWEEP_SCRIPT}" <<'SWEEP_EOF'
#!/usr/bin/env bash
# Auto-generated by xpro.sh — daily expiry sweep.
# Do not edit directly; re-run xpro.sh's installer to regenerate this file.
set -uo pipefail

XRAY_BIN="__XRAY_BIN__"
XRAY_CONFIG="__XRAY_CONFIG__"
XPRO_HOME="__XPRO_HOME__"
XPRO_DB="__XPRO_DB__"
XPRO_LOG="__XPRO_LOG__"
XPRO_BACKUP_DIR="__XPRO_BACKUP_DIR__"

log() { printf '[%s] [SWEEP] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S')" "$1" >>"${XPRO_LOG}"; }

now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

if [[ ! -f "${XPRO_DB}" ]]; then
    log "No database at ${XPRO_DB} — nothing to sweep."
    exit 0
fi
if ! jq -e . "${XPRO_DB}" >/dev/null 2>&1; then
    log "ERROR: ${XPRO_DB} is not valid JSON — refusing to sweep against a corrupt database."
    exit 1
fi

mapfile -t expired_users < <(jq -r --arg now "${now}" \
    '.users[] | select(.enabled == true and .expires_at < $now) | .username' "${XPRO_DB}")

if [[ "${#expired_users[@]}" -eq 0 ]]; then
    log "No expired accounts found. Nothing to do."
    exit 0
fi

log "Found ${#expired_users[@]} expired account(s): ${expired_users[*]}"

# Build the jq filter to remove ALL expired users' clients + shortIds from
# the live config in a single pass (one restart instead of N restarts).
config_tmp="$(mktemp "$(dirname "${XRAY_CONFIG}")/.config.XXXXXX.json")"
usernames_json="$(printf '%s\n' "${expired_users[@]}" | jq -R . | jq -s .)"

if ! jq --argjson names "${usernames_json}" '
        (.inbounds[0].settings.clients) |= map(select((.email as $e | $names | index($e)) | not))
    ' "${XRAY_CONFIG}" >"${config_tmp}" 2>>"${XPRO_LOG}"; then
    log "ERROR: jq failed while stripping expired clients from config — aborting sweep, config untouched."
    rm -f "${config_tmp}"
    exit 1
fi

# Also strip shortIds belonging ONLY to expired users. We look each one up
# from the DB (source of truth) rather than trying to infer it from the
# config, since the DB is guaranteed to have it recorded at creation time.
short_ids_to_remove="$(jq -r --argjson names "${usernames_json}" \
    '.users[] | select(.username as $u | $names | index($u)) | .short_id' "${XPRO_DB}" | jq -R . | jq -s .)"

config_tmp2="$(mktemp "$(dirname "${XRAY_CONFIG}")/.config.XXXXXX.json")"
if ! jq --argjson sids "${short_ids_to_remove}" \
    '(.inbounds[0].streamSettings.realitySettings.shortIds) |= map(select((. as $s | $sids | index($s)) | not))' \
    "${config_tmp}" >"${config_tmp2}" 2>>"${XPRO_LOG}"; then
    log "ERROR: jq failed while stripping expired shortIds — aborting sweep, config untouched."
    rm -f "${config_tmp}" "${config_tmp2}"
    exit 1
fi
rm -f "${config_tmp}"

if ! jq -e . "${config_tmp2}" >/dev/null 2>&1; then
    log "ERROR: post-sweep config is not valid JSON — aborting, config untouched."
    rm -f "${config_tmp2}"
    exit 1
fi
if ! "${XRAY_BIN}" run -test -config "${config_tmp2}" >>"${XPRO_LOG}" 2>&1; then
    log "ERROR: post-sweep config failed 'xray run -test' — aborting, config untouched."
    rm -f "${config_tmp2}"
    exit 1
fi

cp -p "${XRAY_CONFIG}" "${XPRO_BACKUP_DIR}/config.json.$(date +%s).bak" 2>/dev/null || true
mv -f "${config_tmp2}" "${XRAY_CONFIG}"
chmod 644 "${XRAY_CONFIG}"

# Mark each swept user as disabled in the DB (row is kept for history / to
# allow Extend to resurrect them later — see action_extend_account).
db_tmp="$(mktemp "${XPRO_HOME}/.db.XXXXXX.json")"
if jq --argjson names "${usernames_json}" \
    '.users |= map(if (.username as $u | $names | index($u)) then .enabled = false else . end)' \
    "${XPRO_DB}" >"${db_tmp}" 2>>"${XPRO_LOG}" && jq -e . "${db_tmp}" >/dev/null 2>&1; then
    cp -p "${XPRO_DB}" "${XPRO_BACKUP_DIR}/db.json.$(date +%s).bak" 2>/dev/null || true
    mv -f "${db_tmp}" "${XPRO_DB}"
    chmod 600 "${XPRO_DB}"
else
    log "ERROR: failed to update database after config sweep — config was updated but DB was NOT. Manual reconciliation needed."
    rm -f "${db_tmp}"
    exit 1
fi

if systemctl restart xray >>"${XPRO_LOG}" 2>&1; then
    log "xray.service restarted successfully after sweeping ${#expired_users[@]} account(s)."
else
    log "ERROR: xray.service failed to restart after sweep. Check: journalctl -u xray -n 50"
    exit 1
fi

log "Sweep complete."
exit 0
SWEEP_EOF

    # Substitute real paths into the placeholders above (kept as literal
    # __TOKENS__ in the heredoc so the sweep script is self-contained and
    # doesn't need to source xpro.sh's variables at runtime).
    sed -i \
        -e "s#__XRAY_BIN__#${XRAY_BIN}#g" \
        -e "s#__XRAY_CONFIG__#${XRAY_CONFIG}#g" \
        -e "s#__XPRO_HOME__#${XPRO_HOME}#g" \
        -e "s#__XPRO_DB__#${XPRO_DB}#g" \
        -e "s#__XPRO_LOG__#${XPRO_LOG}#g" \
        -e "s#__XPRO_BACKUP_DIR__#${XPRO_BACKUP_DIR}#g" \
        "${XPRO_SWEEP_SCRIPT}"

    chmod 700 "${XPRO_SWEEP_SCRIPT}"
    ok "Expiry sweep script written to ${XPRO_SWEEP_SCRIPT}."
}

install_sweep_scheduler() {
    write_sweep_script

    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        info "Installing systemd timer for daily expiry sweep..."
        cat >"${XPRO_SYSTEMD_SERVICE}" <<EOF
[Unit]
Description=xpro daily Xray account expiry sweep
Documentation=${XPRO_REPO}
After=xray.service

[Service]
Type=oneshot
ExecStart=${XPRO_SWEEP_SCRIPT}
EOF
        cat >"${XPRO_SYSTEMD_TIMER}" <<EOF
[Unit]
Description=Run xpro expiry sweep daily

[Timer]
OnCalendar=*-*-* 03:30:00
RandomizedDelaySec=600
Persistent=true

[Install]
WantedBy=timers.target
EOF
        systemctl daemon-reload
        systemctl enable --now xpro-sweep.timer >/dev/null 2>&1
        ok "systemd timer xpro-sweep.timer enabled (runs daily ~03:30 UTC, persistent across reboots)."
    else
        warn "systemd not detected/active — falling back to a cron.d entry instead."
        cat >"${XPRO_CRON_FALLBACK}" <<EOF
# Managed by xpro.sh — daily Xray account expiry sweep.
30 3 * * * root ${XPRO_SWEEP_SCRIPT} >>${XPRO_LOG} 2>&1
EOF
        chmod 644 "${XPRO_CRON_FALLBACK}"
        ok "cron.d entry installed at ${XPRO_CRON_FALLBACK} (runs daily at 03:30 server time)."
    fi
}

remove_sweep_scheduler() {
    if systemctl list-unit-files 2>/dev/null | grep -q '^xpro-sweep.timer'; then
        systemctl disable --now xpro-sweep.timer >/dev/null 2>&1 || true
    fi
    rm -f "${XPRO_SYSTEMD_SERVICE}" "${XPRO_SYSTEMD_TIMER}" "${XPRO_CRON_FALLBACK}"
    systemctl daemon-reload 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Menu action: Update Script
# ---------------------------------------------------------------------------
# Fetches the raw script from XPRO_RAW_URL (placeholder — point this at your
# actual fork/repo's raw file URL before relying on this feature) and, after
# operator confirmation, atomically replaces the currently-running script
# file and re-execs it so the new version takes over immediately.
action_update_script() {
    local tmp_file remote_version current_hash remote_hash

    info "Checking for updates from ${XPRO_RAW_URL} ..."
    tmp_file="$(mktemp)"

    if ! curl -fsSL --max-time 15 -o "${tmp_file}" "${XPRO_RAW_URL}"; then
        rm -f "${tmp_file}"
        dlg --title "Update failed" --msgbox "Could not download the latest script from:\n${XPRO_RAW_URL}\n\nCheck your network connection and that the URL/repo is correct (this ships with a placeholder URL — update XPRO_RAW_URL at the top of the script to point at your real fork)." 13 76
        return
    fi

    # Sanity check: make sure we actually got a bash script, not e.g. a
    # GitHub 404 HTML page or an empty response, before going any further.
    if ! head -n1 "${tmp_file}" | grep -qE '^#!.*(bash|sh)'; then
        rm -f "${tmp_file}"
        dlg --title "Update failed" --msgbox "The downloaded file doesn't look like a shell script (missing #! shebang). Aborting update — nothing was changed. This usually means the URL returned an error page instead of the script." 10 74
        return
    fi
    if ! bash -n "${tmp_file}" 2>>"${XPRO_LOG}"; then
        rm -f "${tmp_file}"
        dlg --title "Update failed" --msgbox "The downloaded script failed a bash syntax check (bash -n). Aborting update — nothing was changed. See ${XPRO_LOG} for details." 10 70
        return
    fi

    current_hash="$(sha256sum "${XPRO_SELF_PATH}" 2>/dev/null | awk '{print $1}')"
    remote_hash="$(sha256sum "${tmp_file}" | awk '{print $1}')"

    if [[ "${current_hash}" == "${remote_hash}" ]]; then
        rm -f "${tmp_file}"
        dlg --title "Already up to date" --msgbox "The remote script is identical to the one currently running. Nothing to update." 8 66
        return
    fi

    remote_version="$(grep -m1 -oE 'XPRO_VERSION="[^"]+"' "${tmp_file}" | cut -d'"' -f2)"

    if ! dlg --title "Confirm Update" --yesno "A different version of xpro is available:\n\n  Current version:  ${XPRO_VERSION}\n  Remote version:   ${remote_version:-unknown}\n  Source:           ${XPRO_RAW_URL}\n\nThis will OVERWRITE the currently running script file:\n  ${XPRO_SELF_PATH}\n\nand immediately restart it. Continue?" 16 76; then
        rm -f "${tmp_file}"
        info "Update cancelled by operator."
        return
    fi

    # Backup the current script before overwriting, same pattern as our
    # config/DB writes — never destroy the only copy of something.
    cp -p "${XPRO_SELF_PATH}" "${XPRO_BACKUP_DIR}/xpro.sh.$(date +%s).bak" 2>/dev/null || true

    if ! install -m 755 "${tmp_file}" "${XPRO_SELF_PATH}"; then
        rm -f "${tmp_file}"
        dlg --title "Update failed" --msgbox "Failed to write the new script to ${XPRO_SELF_PATH} (permissions?). Nothing was changed beyond the backup." 9 70
        return
    fi
    rm -f "${tmp_file}"

    # Also refresh the /usr/local/bin/xpro shorthand copy if it exists and
    # differs from the self path (i.e. we were invoked via that symlink/copy).
    if [[ -f "${XPRO_INSTALLED_PATH}" && "${XPRO_INSTALLED_PATH}" != "${XPRO_SELF_PATH}" ]]; then
        cp -p "${XPRO_SELF_PATH}" "${XPRO_INSTALLED_PATH}" 2>/dev/null || true
        chmod 755 "${XPRO_INSTALLED_PATH}" 2>/dev/null || true
    fi

    clear
    ok "Script updated (backup saved in ${XPRO_BACKUP_DIR}). Restarting..."
    sleep 1
    # Re-exec: replaces the current process image with the new script,
    # preserving the same args, so the menu reopens seamlessly on the new
    # version rather than requiring the operator to run the command again.
    exec bash "${XPRO_SELF_PATH}" "${ORIGINAL_ARGS[@]}"
}

# ---------------------------------------------------------------------------
# Menu action: Uninstall
# ---------------------------------------------------------------------------
# Fully purges everything this script is responsible for. Deliberately does
# NOT touch: curl/jq/uuid-runtime/unzip/openssl/qrencode/dialog packages
# themselves (those are general-purpose system tools that may be used by
# other things on the box), or the operator's SSH/firewall config. Scope is
# strictly "everything xpro created", matching the spec.
action_uninstall() {
    if ! dlg --title "Uninstall xpro + Xray" --yesno "This will PERMANENTLY remove:\n\n  - Xray binary:        ${XRAY_BIN}\n  - Xray config dir:    ${XRAY_ETC_DIR}\n  - Xray logs:          ${XRAY_LOG_DIR}\n  - systemd unit:       ${XRAY_SYSTEMD_UNIT}\n  - xpro database/keys: ${XPRO_HOME}\n  - sweep timer/cron job\n  - xpro shorthand:     ${XPRO_INSTALLED_PATH}\n\nAll accounts and REALITY keys will be lost. This cannot be undone.\n\nProceed?" 20 76; then
        info "Uninstall cancelled by operator."
        return
    fi

    # Second confirmation via typed input — mirrors the "explicit
    # confirmation" requirement used elsewhere for destructive/irreversible
    # actions (see end_conversation-style confirm patterns): a single Yes/No
    # dialog is easy to fat-finger through, so for full uninstall we also
    # require typing the word DELETE.
    local typed
    typed="$(dlg --title "Final Confirmation" --inputbox "Type DELETE (all caps) to confirm total uninstall:" 9 60 3>&1 1>&2 2>&3)" \
        || { info "Uninstall cancelled by operator."; return; }
    if [[ "${typed}" != "DELETE" ]]; then
        dlg --title "Uninstall cancelled" --msgbox "Confirmation text did not match. Nothing was removed." 8 56
        return
    fi

    clear
    info "Beginning full uninstall..."

    # 1. Stop and disable the Xray service.
    if systemctl list-unit-files 2>/dev/null | grep -q '^xray.service'; then
        systemctl disable --now xray >/dev/null 2>&1 || true
    fi

    # 2. Remove the sweep timer/cron job.
    remove_sweep_scheduler

    # 3. Remove Xray binary, config, logs, systemd unit.
    rm -f "${XRAY_BIN}"
    rm -rf "${XRAY_ETC_DIR}"
    rm -rf "${XRAY_LOG_DIR}"
    rm -f "${XRAY_SYSTEMD_UNIT}"
    systemctl daemon-reload 2>/dev/null || true

    # 4. Remove xpro's own data directory (DB, keys, backups, logs, sweep
    #    script). Done LAST and only after everything above succeeded, so a
    #    failure partway through still leaves the DB available for a retry
    #    or for manual inspection of what was/wasn't cleaned up.
    rm -rf "${XPRO_HOME}"

    # 5. Remove the /usr/local/bin/xpro shorthand, if present.
    rm -f "${XPRO_INSTALLED_PATH}"

    ok "Uninstall complete. Xray, its config, the local database, and all scheduled jobs have been removed."
    echo
    echo "Note: this script file itself (${XPRO_SELF_PATH}) was left in place — delete it manually if you wish."
    pause
    exit 0
}

# ---------------------------------------------------------------------------
# First-run installer
# ---------------------------------------------------------------------------
# Walks the operator through the one-time setup: port, camouflage
# domain/SNI, binary install, REALITY keys, base config, systemd unit, and
# the expiry sweep scheduler. Safe to re-run — every step is idempotent
# (checks "is this already done" before doing it) except explicit
# overwrites, which are gated behind their own confirmation.
run_installer() {
    local port dest sni answer

    if xray_is_installed && [[ -f "${XRAY_CONFIG}" ]]; then
        if ! dlg --title "Already installed" --yesno "Xray appears to already be installed and configured:\n\n  Binary:  ${XRAY_BIN} ($("${XRAY_BIN}" version 2>/dev/null | head -n1))\n  Config:  ${XRAY_CONFIG}\n\nRe-running setup will REGENERATE the base config (new REALITY keypair, new port/SNI if you change them) and DISCONNECT all existing clients until they're re-issued links. Continue?" 15 76; then
            info "Setup cancelled — existing installation left untouched."
            return
        fi
    fi

    port="$(dlg --title "Listening Port" --inputbox "Port for the VLESS/REALITY inbound (443 strongly recommended — REALITY on a non-443 port is a known GFW fingerprinting signal):" 11 76 "${DEFAULT_PORT}" 3>&1 1>&2 2>&3)" \
        || { info "Setup cancelled."; return; }
    if ! valid_port "${port}"; then
        dlg --title "Invalid port" --msgbox "Port must be a number between 1 and 65535." 8 56
        return
    fi

    sni="$(dlg --title "Camouflage SNI" --inputbox "SNI / server name to impersonate (must be a real, reachable site serving modern TLS 1.3, e.g. www.microsoft.com):" 11 76 "${DEFAULT_SNI}" 3>&1 1>&2 2>&3)" \
        || { info "Setup cancelled."; return; }
    if [[ -z "${sni}" ]]; then
        dlg --title "Invalid SNI" --msgbox "SNI cannot be empty." 8 50
        return
    fi
    dest="${sni}:443"

    if ! dlg --title "Confirm" --yesno "About to install/configure Xray with:\n\n  Port:        ${port}\n  Camouflage:  ${sni} (dest ${dest})\n  Protocol:    VLESS + XTLS-Vision + REALITY\n\nProceed?" 13 70; then
        info "Setup cancelled by operator."
        return
    fi

    clear
    info "Starting installation..."

    install_xray_binary
    generate_reality_keys
    generate_base_config "${port}" "${dest}" "${sni}" "$(reality_private_key)"
    install_systemd_unit
    db_init

    if ! restart_xray; then
        die "Initial xray.service start failed — see ${XPRO_LOG} and 'journalctl -u xray -n 50' before retrying setup."
    fi

    install_sweep_scheduler

    # Install ourselves as /usr/local/bin/xpro for convenient future
    # invocation (`sudo xpro`) regardless of where the script was originally
    # downloaded to.
    if [[ "${XPRO_SELF_PATH}" != "${XPRO_INSTALLED_PATH}" ]]; then
        install -m 755 "${XPRO_SELF_PATH}" "${XPRO_INSTALLED_PATH}" 2>/dev/null \
            && ok "Installed shorthand command: run 'sudo xpro' any time to reopen this menu."
    fi

    ok "Installation complete."
    dlg --title "Setup Complete" --msgbox "Xray is installed and running on port ${port} with REALITY camouflage as ${sni}.\n\nUse 'Create Account' from the main menu to issue your first client.\n\nA daily expiry sweep has been scheduled automatically." 12 74
}

# ---------------------------------------------------------------------------
# Status / diagnostics view
# ---------------------------------------------------------------------------
action_status() {
    local svc_state timer_state user_count active_count port sni body pending_count

    svc_state="$(systemctl is-active xray 2>/dev/null || echo "unknown")"
    if systemctl list-unit-files 2>/dev/null | grep -q '^xpro-sweep.timer'; then
        timer_state="$(systemctl is-active xpro-sweep.timer 2>/dev/null || echo "unknown")"
    elif [[ -f "${XPRO_CRON_FALLBACK}" ]]; then
        timer_state="cron.d fallback active"
    else
        timer_state="not installed"
    fi

    user_count="$(jq '.users | length' "${XPRO_DB}" 2>/dev/null || echo 0)"
    active_count="$(jq '[.users[] | select(.enabled == true)] | length' "${XPRO_DB}" 2>/dev/null || echo 0)"
    port="$(jq -r '.inbounds[0].port // "?"' "${XRAY_CONFIG}" 2>/dev/null)"
    sni="$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0] // "?"' "${XRAY_CONFIG}" 2>/dev/null)"
    # Preview of who the NEXT sweep run would disable, so an operator can
    # sanity-check before the 03:30 UTC timer fires rather than being
    # surprised by it.
    pending_count="$(db_list_expired_enabled_users "$(now_iso)" | wc -l | tr -d ' ')"

    body="Xray service:      ${svc_state}
Sweep scheduler:   ${timer_state}
Xray version:      $("${XRAY_BIN}" version 2>/dev/null | head -n1 || echo 'not installed')
Listening port:    ${port}
Camouflage SNI:    ${sni}
Total accounts:    ${user_count}
Active accounts:   ${active_count}
Pending expiry:    ${pending_count} (will be swept at next daily run)
Public IP:         $(detect_public_ip)
Config path:       ${XRAY_CONFIG}
Database path:     ${XPRO_DB}
Log file:          ${XPRO_LOG}"

    dlg --title "Status" --msgbox "${body}" 19 76
}

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------
main_menu() {
    local choice
    while true; do
        choice="$(dlg --title "Main Menu" --cancel-label "Exit" --menu "Choose an action:" 20 72 11 \
            "1" "Create Account" \
            "2" "Delete Account" \
            "3" "Extend Account" \
            "4" "List Accounts" \
            "5" "Show Account Link / QR" \
            "6" "Status" \
            "7" "Re-run Install / Reconfigure" \
            "8" "Update Script" \
            "9" "Uninstall Everything" \
            "0" "Exit" \
            3>&1 1>&2 2>&3)"

        # Non-zero exit = Cancel/Esc pressed => treat as Exit.
        if [[ $? -ne 0 ]]; then
            break
        fi

        case "${choice}" in
            1) action_create_account ;;
            2) action_delete_account ;;
            3) action_extend_account ;;
            4) action_list_accounts ;;
            5) action_show_link ;;
            6) action_status ;;
            7) run_installer ;;
            8) action_update_script ;;
            9) action_uninstall ;;
            0) break ;;
            *) : ;;
        esac
    done
    clear
    echo "Goodbye."
}

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
xpro.sh v${XPRO_VERSION} — VLESS/XTLS-Vision/REALITY manager for Xray-core

Usage:
  sudo bash $0                Launch the interactive TUI (default).
  sudo bash $0 --install      Run first-time setup non-interactively-ish
                               (still uses dialog for the few required prompts).
  sudo bash $0 --sweep        Run the expiry sweep once, immediately, in the
                               foreground (same logic the daily timer runs).
  sudo bash $0 --status       Print status and exit (no TUI).
  sudo bash $0 --uninstall    Launch the uninstall flow directly.
  sudo bash $0 --version      Print version and exit.
  sudo bash $0 --help         Show this message.
EOF
}

main() {
    # Preserved so action_update_script can re-exec with the same invocation
    # the operator originally used (e.g. `--install` if that's how they
    # launched it), rather than always dropping back to the bare TUI.
    ORIGINAL_ARGS=("$@")

    require_root
    require_ubuntu

    # Logging directory must exist before the very first info()/warn() call
    # that might fire during dependency checks.
    mkdir -p "${XPRO_HOME}"
    touch "${XPRO_LOG}" 2>/dev/null || true

    check_dependencies
    ensure_tui_backend
    db_init

    case "${1:-}" in
        --help|-h)
            usage
            exit 0
            ;;
        --version|-v)
            echo "xpro.sh v${XPRO_VERSION}"
            exit 0
            ;;
        --install)
            run_installer
            exit 0
            ;;
        --sweep)
            if [[ ! -x "${XPRO_SWEEP_SCRIPT}" ]]; then
                die "Sweep script not found at ${XPRO_SWEEP_SCRIPT} — run --install first."
            fi
            "${XPRO_SWEEP_SCRIPT}"
            exit $?
            ;;
        --status)
            # Plain-text status for scripting/cron-mail use, bypassing dialog.
            echo "Xray service:    $(systemctl is-active xray 2>/dev/null || echo unknown)"
            echo "Xray version:    $("${XRAY_BIN}" version 2>/dev/null | head -n1 || echo 'not installed')"
            echo "Total accounts:  $(jq '.users | length' "${XPRO_DB}" 2>/dev/null || echo 0)"
            echo "Active accounts: $(jq '[.users[] | select(.enabled == true)] | length' "${XPRO_DB}" 2>/dev/null || echo 0)"
            exit 0
            ;;
        --uninstall)
            action_uninstall
            exit 0
            ;;
        "")
            : # fall through to interactive flow below
            ;;
        *)
            echo "Unknown argument: ${1}" >&2
            usage
            exit 1
            ;;
    esac

    # Interactive first run: if Xray isn't installed yet, walk through setup
    # before dropping into the main menu, since every menu action assumes a
    # working ${XRAY_CONFIG} and REALITY keys already exist.
    if ! xray_is_installed || [[ ! -f "${XRAY_CONFIG}" ]]; then
        if dlg --title "Welcome" --yesno "Xray does not appear to be installed yet.\n\nRun first-time setup now?" 9 60; then
            run_installer
        else
            clear
            echo "Nothing to do without an Xray installation. Run again and choose 'Yes' when ready, or use: sudo bash $0 --install"
            exit 0
        fi
    fi

    # If setup was declined/failed and config still doesn't exist, don't
    # open a menu full of actions that would all immediately fail.
    if [[ ! -f "${XRAY_CONFIG}" ]]; then
        die "No Xray configuration found at ${XRAY_CONFIG} — cannot continue without completing setup."
    fi

    main_menu
}

main "$@"
