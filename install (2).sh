#!/usr/bin/env bash
set -euo pipefail

PATH="/usr/sbin:/usr/bin:/sbin:/bin"
LC_ALL="C"
LANG="C"
export PATH LC_ALL LANG

SERVICE_NAME="hcr-server"
SYSTEMD_DIR="/etc/systemd/system"
PORT="8080"
PORT_SET="false"
UNPRIVILEGED_PORT_MIN="1024"
TARGET="127.0.0.1:22"
TARGET_SET="false"
SESSION_STATS_INTERVAL="0"
SESSION_STATS_INTERVAL_SET="false"
MAX_DOWNLOAD_FRAME_LIMIT="16384"
MAX_DOWNLOAD_FRAME="${MAX_DOWNLOAD_FRAME_LIMIT}"
MAX_DOWNLOAD_FRAME_SET="false"
DOWNLOAD_POLL_TIMEOUT="8s"
DOWNLOAD_POLL_TIMEOUT_LIMIT_SECONDS="30"
DOWNLOAD_POLL_TIMEOUT_SET="false"
TRANSPORT="auto"
TRANSPORT_SET="false"
ACTION="install"

TEMP_UNIT=""

fail() {
	echo "Error: $*" >&2
	exit 1
}

command -v readlink >/dev/null 2>&1 || fail "readlink was not found."
SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname -- "${SCRIPT_PATH}")"
BINARY_PATH="${SCRIPT_DIR}/hcr-server"
TLS_CERT_PATH="${SCRIPT_DIR}/fullchain.pem"
TLS_KEY_PATH="${SCRIPT_DIR}/privkey.pem"
UNIT_SOURCE_PATH="${SCRIPT_DIR}/${SERVICE_NAME}.service"
UNIT_LINK_PATH="${SYSTEMD_DIR}/${SERVICE_NAME}.service"

usage() {
	cat <<'EOF'
Install HCR Server as a systemd service from one self-contained directory.

Usage:
  sudo ./install.sh [--port <1-65535>] [--transport <tls|plain|auto>] \
    [--target <host:port>] [--session-stats-interval <duration>] \
    [--max-download-frame <1-16384>] [--download-poll-timeout <1ms-30s>]
  sudo ./install.sh --uninstall
  ./install.sh --help

Options:
  --port <number>                    Listener port. Default: 8080
                                     Ports below 1024 receive only CAP_NET_BIND_SERVICE
  --transport <mode>                 Server transport. Default: auto
                                     tls   accepts TLS only
                                     plain accepts non-TLS HCR only
                                     auto  accepts TLS and non-TLS HCR on the same port
  --target <host:port>                Fixed SSH server. Default: 127.0.0.1:22
                                     Use brackets for IPv6, for example [::1]:22
  --session-stats-interval <duration> Log session counters to the journal. Default: 0 (off)
                                     Use 0 to disable, or whole ms, s, m, or h (for example 10s)
  --max-download-frame <bytes>       Download frame size, 1-16384. Default: 16384
  --download-poll-timeout <duration> Download poll timeout using integer ms or s,
                                     from 1ms through 30s. Default: 8s
  --uninstall                        Stop and unlink the service without deleting this directory
  -h, --help                         Show this help

Required next to install.sh:
  hcr-server          Binary for the current Linux architecture
  fullchain.pem       Required by tls and auto
  privkey.pem         Required by tls and auto

The generated hcr-server.service also stays next to this script. Only systemd
symlinks are created outside this directory. The installer does not create
binary backups or rollback files.
EOF
}

normalize_decimal_in_range() {
	local error_message="$1"
	local maximum="$2"
	local value="$3"
	case "${value}" in
		""|*[!0-9]*) fail "${error_message}" ;;
	esac
	# Nol di depan dibuang sebelum perbandingan agar selalu dibaca sebagai basis sepuluh.
	while [ "${#value}" -gt 1 ] && [ "${value:0:1}" = "0" ]; do
		value="${value:1}"
	done
	if [ "${#value}" -gt "${#maximum}" ] ||
		[ "${value}" -lt 1 ] || [ "${value}" -gt "${maximum}" ]; then
		fail "${error_message}"
	fi
	NORMALIZED_DECIMAL="${value}"
}

normalize_traffic_shape_options() {
	local amount
	local unit
	local maximum
	normalize_decimal_in_range \
		"--max-download-frame must be an integer between 1 and ${MAX_DOWNLOAD_FRAME_LIMIT}." \
		"${MAX_DOWNLOAD_FRAME_LIMIT}" \
		"${MAX_DOWNLOAD_FRAME}"
	MAX_DOWNLOAD_FRAME="${NORMALIZED_DECIMAL}"

	case "${DOWNLOAD_POLL_TIMEOUT}" in
		*ms)
			amount="${DOWNLOAD_POLL_TIMEOUT%ms}"
			unit="ms"
			maximum="$((DOWNLOAD_POLL_TIMEOUT_LIMIT_SECONDS * 1000))"
			;;
		*s)
			amount="${DOWNLOAD_POLL_TIMEOUT%s}"
			unit="s"
			maximum="${DOWNLOAD_POLL_TIMEOUT_LIMIT_SECONDS}"
			;;
		*) fail "--download-poll-timeout must be an integer duration from 1ms through 30s (ms or s)." ;;
	esac
	normalize_decimal_in_range \
		"--download-poll-timeout must be an integer duration from 1ms through 30s (ms or s)." \
		"${maximum}" \
		"${amount}"
	DOWNLOAD_POLL_TIMEOUT="${NORMALIZED_DECIMAL}${unit}"
}

normalize_target() {
	local host
	local port
	# Allowlist mencegah penyisipan argumen dan ekspansi specifier/environment systemd.
	if [[ "${TARGET}" =~ ^([A-Za-z0-9][A-Za-z0-9.-]*|\[[A-Fa-f0-9:.]*:[A-Fa-f0-9:.]+\]):([0-9]+)$ ]]; then
		host="${BASH_REMATCH[1]}"
		port="${BASH_REMATCH[2]}"
	else
		fail "--target must be host:port or [IPv6]:port, without credentials or spaces."
	fi
	normalize_decimal_in_range "--target port must be between 1 and 65535." "65535" "${port}"
	TARGET="${host}:${NORMALIZED_DECIMAL}"
}

normalize_session_stats_interval() {
	local amount
	local unit
	local nanoseconds_per_unit
	local error_message="--session-stats-interval must be 0 (off) or a positive whole ms, s, m, or h duration within Go's duration range."
	if [[ "${SESSION_STATS_INTERVAL}" =~ ^0+(ms|s|m|h)?$ ]]; then
		SESSION_STATS_INTERVAL="0"
		return
	fi
	[[ "${SESSION_STATS_INTERVAL}" =~ ^([0-9]+)(ms|s|m|h)$ ]] || fail "${error_message}"
	amount="${BASH_REMATCH[1]}"
	unit="${BASH_REMATCH[2]}"
	case "${unit}" in
		ms) nanoseconds_per_unit="1000000" ;;
		s) nanoseconds_per_unit="1000000000" ;;
		m) nanoseconds_per_unit="60000000000" ;;
		h) nanoseconds_per_unit="3600000000000" ;;
	esac
	# time.Duration memakai int64 nanodetik; tolak overflow sebelum service ditulis ulang.
	normalize_decimal_in_range "${error_message}" \
		"$((9223372036854775807 / nanoseconds_per_unit))" "${amount}"
	SESSION_STATS_INTERVAL="${NORMALIZED_DECIMAL}${unit}"
}

parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--port)
				[ "$#" -ge 2 ] || fail "--port requires a value."
				PORT="$2"
				PORT_SET="true"
				shift 2
				;;
			--transport)
				[ "$#" -ge 2 ] || fail "--transport requires a value."
				TRANSPORT="$2"
				TRANSPORT_SET="true"
				shift 2
				;;
			--target)
				[ "$#" -ge 2 ] || fail "--target requires a value."
				TARGET="$2"
				TARGET_SET="true"
				shift 2
				;;
			--session-stats-interval)
				[ "$#" -ge 2 ] || fail "--session-stats-interval requires a value."
				SESSION_STATS_INTERVAL="$2"
				SESSION_STATS_INTERVAL_SET="true"
				shift 2
				;;
			--max-download-frame)
				[ "$#" -ge 2 ] || fail "--max-download-frame requires a value."
				MAX_DOWNLOAD_FRAME="$2"
				MAX_DOWNLOAD_FRAME_SET="true"
				shift 2
				;;
			--download-poll-timeout)
				[ "$#" -ge 2 ] || fail "--download-poll-timeout requires a value."
				DOWNLOAD_POLL_TIMEOUT="$2"
				DOWNLOAD_POLL_TIMEOUT_SET="true"
				shift 2
				;;
			--uninstall)
				ACTION="uninstall"
				shift
				;;
			-h|--help)
				usage
				exit 0
				;;
			*) fail "Unknown option: $1" ;;
		esac
	done
	case "${TRANSPORT}" in
		tls|plain|auto) ;;
		*) fail "--transport must be tls, plain, or auto." ;;
	esac
	case "${PORT}" in
		""|*[!0-9]*) fail "--port must be a number between 1 and 65535." ;;
	esac
	# Basis sepuluh dipaksa: nilai berawalan nol seperti 0080 akan ditafsirkan sebagai oktal.
	if [ "$((10#${PORT}))" -lt 1 ] || [ "$((10#${PORT}))" -gt 65535 ]; then
		fail "--port must be a number between 1 and 65535."
	fi
	PORT="$((10#${PORT}))"
	normalize_target
	normalize_session_stats_interval
	normalize_traffic_shape_options
	if [ "${ACTION}" = "uninstall" ]; then
		[ "${TRANSPORT_SET}" = "false" ] || fail "--transport cannot be combined with --uninstall."
		[ "${PORT_SET}" = "false" ] || fail "--port cannot be combined with --uninstall."
		[ "${TARGET_SET}" = "false" ] || fail "--target cannot be combined with --uninstall."
		[ "${SESSION_STATS_INTERVAL_SET}" = "false" ] ||
			fail "--session-stats-interval cannot be combined with --uninstall."
		[ "${MAX_DOWNLOAD_FRAME_SET}" = "false" ] ||
			fail "--max-download-frame cannot be combined with --uninstall."
		[ "${DOWNLOAD_POLL_TIMEOUT_SET}" = "false" ] ||
			fail "--download-poll-timeout cannot be combined with --uninstall."
	fi
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 was not found."
}

require_environment() {
	[ "$(id -u)" -eq 0 ] || fail "Run this installer as root."
	[ "$(uname -s)" = "Linux" ] || fail "This installer supports Linux only."
	for command_name in stat systemctl systemd-analyze flock ln mv mktemp sleep; do
		require_command "${command_name}"
	done
	if [ "${ACTION}" = "install" ] && {
		[ "${TRANSPORT}" = "tls" ] || [ "${TRANSPORT}" = "auto" ];
	}; then
		require_command openssl
	fi
	systemctl show --property=Version --value >/dev/null 2>&1 ||
		fail "The systemd system manager is not available."
	if [[ ! "${SCRIPT_DIR}" =~ ^/[-A-Za-z0-9._/@+:]+$ ]]; then
		fail "The installer directory contains unsupported characters: ${SCRIPT_DIR}"
	fi
}

acquire_install_lock() {
	exec 9<"${SYSTEMD_DIR}" || fail "The systemd unit directory could not be opened for locking."
	flock -n 9 || fail "Another HCR Server installer is already running."
}

mode_is_writable_by_others() {
	(( (8#$1 & 8#022) != 0 ))
}

validate_secure_directory() {
	local current="${SCRIPT_DIR}"
	local mode
	while :; do
		[ -d "${current}" ] && [ ! -L "${current}" ] ||
			fail "Path component must be a real directory: ${current}"
		[ "$(stat -c '%u' -- "${current}")" = "0" ] ||
			fail "Path component must be owned by root: ${current}"
		mode="$(stat -c '%a' -- "${current}")"
		mode_is_writable_by_others "${mode}" &&
			fail "Path component must not be group- or world-writable: ${current}"
		[ "${current}" = "/" ] && break
		current="$(dirname -- "${current}")"
	done
}

validate_root_file() {
	local executable="$1"
	local label="$2"
	local path="$3"
	local mode
	[ -f "${path}" ] && [ ! -L "${path}" ] ||
		fail "${label} must be a regular file: ${path}"
	[ "$(stat -c '%u' -- "${path}")" = "0" ] ||
		fail "${label} must be owned by root: ${path}"
	mode="$(stat -c '%a' -- "${path}")"
	mode_is_writable_by_others "${mode}" &&
		fail "${label} must not be group- or world-writable: ${path}"
	if [ "${executable}" = "true" ] && [ ! -x "${path}" ]; then
		fail "${label} must be executable: ${path}"
	fi
}

validate_unit_link() {
	if [ -L "${UNIT_LINK_PATH}" ]; then
		[ "$(readlink -- "${UNIT_LINK_PATH}")" = "${UNIT_SOURCE_PATH}" ] ||
			fail "A different ${SERVICE_NAME}.service symlink already exists."
	elif [ -e "${UNIT_LINK_PATH}" ]; then
		fail "A non-symlink unit already exists: ${UNIT_LINK_PATH}"
	fi
}

loaded_fragment_path() {
	systemctl show --property=FragmentPath --value "${SERVICE_NAME}.service" 2>/dev/null || true
}

validate_loaded_fragment() {
	case "$1" in
		""|"${UNIT_SOURCE_PATH}"|"${UNIT_LINK_PATH}") ;;
		*) fail "systemd loaded ${SERVICE_NAME}.service from an unexpected unit: $1" ;;
	esac
}

validate_binary_identity() {
	local path="$1"
	local output
	output="$("${path}" -version 2>/dev/null)" ||
		fail "The binary does not support -version."
	[[ "${output}" =~ ^hcr-server\ version\ [0-9]+\.[0-9]+\.[0-9]+(\ -\ Patch\ [1-9][0-9]*)?$ ]] ||
		fail "The binary returned an unexpected version string."
}

validate_tls_pair() {
	local certificate_public_key
	local private_public_key
	openssl x509 -in "${TLS_CERT_PATH}" -noout >/dev/null 2>&1 ||
		fail "The TLS certificate could not be parsed."
	certificate_public_key="$(openssl x509 -in "${TLS_CERT_PATH}" -pubkey -noout 2>/dev/null)" ||
		fail "The TLS certificate public key could not be read."
	private_public_key="$(openssl pkey -in "${TLS_KEY_PATH}" -passin pass: -pubout 2>/dev/null)" ||
		fail "The TLS private key could not be parsed without a passphrase."
	[ "${certificate_public_key}" = "${private_public_key}" ] ||
		fail "The TLS certificate and private key do not match."
}

validate_binary() {
	validate_root_file true "HCR binary" "${BINARY_PATH}"
	validate_binary_identity "${BINARY_PATH}"
}

validate_bundle() {
	local key_mode
	validate_secure_directory
	validate_root_file true "Installer" "${SCRIPT_PATH}"
	validate_binary
	if [ -e "${UNIT_SOURCE_PATH}" ] || [ -L "${UNIT_SOURCE_PATH}" ]; then
		validate_root_file false "Generated systemd unit" "${UNIT_SOURCE_PATH}"
	fi
	if [ "${TRANSPORT}" = "tls" ] || [ "${TRANSPORT}" = "auto" ]; then
		validate_root_file false "TLS certificate" "${TLS_CERT_PATH}"
		validate_root_file false "TLS private key" "${TLS_KEY_PATH}"
		key_mode="$(stat -c '%a' -- "${TLS_KEY_PATH}")"
		(( (8#${key_mode} & 8#077) == 0 )) ||
			fail "TLS private key must not be accessible by group or other users."
		validate_tls_pair
	fi
}

render_unit() {
	local bind_capability=""
	local tls_arguments=""
	local stats_arguments=""
	if [ "${PORT}" -lt "${UNPRIVILEGED_PORT_MIN}" ]; then
		bind_capability="CAP_NET_BIND_SERVICE"
	fi
	if [ "${TRANSPORT}" = "tls" ] || [ "${TRANSPORT}" = "auto" ]; then
		tls_arguments=" --tls-cert ${TLS_CERT_PATH} --tls-key ${TLS_KEY_PATH}"
	fi
	if [ "${SESSION_STATS_INTERVAL}" != "0" ]; then
		stats_arguments=" --session-stats-interval ${SESSION_STATS_INTERVAL}"
	fi
	TEMP_UNIT="$(mktemp "${SCRIPT_DIR}/.${SERVICE_NAME}.XXXXXX.service")"
	chmod 0600 "${TEMP_UNIT}"
	cat >"${TEMP_UNIT}" <<EOF
[Unit]
Description=HCR relay
Documentation=file:${SCRIPT_DIR}/README.md
Wants=network-online.target
After=network-online.target ssh.service sshd.service
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=exec
User=root
Group=root
WorkingDirectory=${SCRIPT_DIR}
ExecStart=${BINARY_PATH} --listen :${PORT} --target ${TARGET} --transport ${TRANSPORT}${tls_arguments} --max-download-frame ${MAX_DOWNLOAD_FRAME} --download-poll-timeout ${DOWNLOAD_POLL_TIMEOUT}${stats_arguments}
Restart=on-failure
RestartSec=5s
TimeoutStopSec=15s
KillSignal=SIGTERM
UMask=0077
NoNewPrivileges=true
CapabilityBoundingSet=${bind_capability}
AmbientCapabilities=${bind_capability}
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=read-only
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=true
MemoryDenyWriteExecute=false
ReadOnlyPaths=${SCRIPT_DIR}
LimitNOFILE=4096
LimitCORE=0
TasksMax=512
MemoryMax=384M
StandardOutput=journal
StandardError=journal
SyslogIdentifier=hcr-server

[Install]
WantedBy=multi-user.target
EOF
	chmod 0644 "${TEMP_UNIT}"
	systemd-analyze verify "${TEMP_UNIT}"
}

cleanup() {
	local exit_code=$?
	trap - EXIT
	set +e
	[ -n "${TEMP_UNIT}" ] && rm -f -- "${TEMP_UNIT}"
	exit "${exit_code}"
}

verify_service_health() {
	local initial_pid
	initial_pid="$(systemctl show --property=MainPID --value "${SERVICE_NAME}.service")"
	[[ "${initial_pid}" =~ ^[1-9][0-9]*$ ]] || fail "The service did not report a running process."
	sleep 3
	systemctl is-active --quiet "${SERVICE_NAME}.service" ||
		fail "The service did not remain active during the startup check."
	[ "$(systemctl show --property=MainPID --value "${SERVICE_NAME}.service")" = "${initial_pid}" ] ||
		fail "The service restarted during the startup check."
}

install_service() {
	validate_unit_link
	validate_loaded_fragment "$(loaded_fragment_path)"
	render_unit
	mv -f -- "${TEMP_UNIT}" "${UNIT_SOURCE_PATH}"
	TEMP_UNIT=""
	[ -L "${UNIT_LINK_PATH}" ] || ln -s -- "${UNIT_SOURCE_PATH}" "${UNIT_LINK_PATH}"
	systemctl daemon-reload
	systemctl enable "${SERVICE_NAME}.service"
	systemctl reset-failed "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
	if ! systemctl restart "${SERVICE_NAME}.service"; then
		systemctl status --no-pager --full "${SERVICE_NAME}.service" || true
		fail "The service failed to start."
	fi
	systemctl is-active --quiet "${SERVICE_NAME}.service" ||
		fail "The service did not remain active after startup."
	[ "$(systemctl show --property=WorkingDirectory --value "${SERVICE_NAME}.service")" = "${SCRIPT_DIR}" ] ||
		fail "systemd reported an unexpected WorkingDirectory."
	verify_service_health
	echo "HCR Server was installed successfully."
	echo "Bundle directory: ${SCRIPT_DIR}"
	echo "Systemd unit: ${UNIT_SOURCE_PATH}"
	echo "Transport: ${TRANSPORT}"
	echo "Port: ${PORT}"
	echo "SSH target: ${TARGET}"
	echo "Session stats interval: ${SESSION_STATS_INTERVAL} (0 = off)"
}

uninstall_service() {
	local fragment
	local owned="false"
	validate_secure_directory
	validate_root_file true "Installer" "${SCRIPT_PATH}"
	if [ -e "${UNIT_SOURCE_PATH}" ]; then
		validate_root_file false "Generated systemd unit" "${UNIT_SOURCE_PATH}"
	fi
	validate_unit_link
	fragment="$(loaded_fragment_path)"
	validate_loaded_fragment "${fragment}"
	[ -L "${UNIT_LINK_PATH}" ] && owned="true"
	if [ "${fragment}" = "${UNIT_SOURCE_PATH}" ] || [ "${fragment}" = "${UNIT_LINK_PATH}" ]; then
		owned="true"
	fi
	if [ "${owned}" = "false" ]; then
		echo "HCR Server is not linked from this directory. Nothing was removed."
		return
	fi
	systemctl disable --now "${SERVICE_NAME}.service"
	if [ -L "${UNIT_LINK_PATH}" ]; then
		[ "$(readlink -- "${UNIT_LINK_PATH}")" = "${UNIT_SOURCE_PATH}" ] ||
			fail "The unit symlink changed during uninstall."
		rm -f -- "${UNIT_LINK_PATH}"
	fi
	systemctl daemon-reload
	systemctl reset-failed "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
	echo "HCR Server was uninstalled."
	echo "Runtime files were preserved in: ${SCRIPT_DIR}"
}

main() {
	trap cleanup EXIT
	parse_args "$@"
	require_environment
	acquire_install_lock
	if [ "${ACTION}" = "uninstall" ]; then
		uninstall_service
	else
		validate_bundle
		install_service
	fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
