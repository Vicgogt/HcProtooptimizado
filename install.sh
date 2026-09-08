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
LISTEN_ADDRESS=":${PORT}"
LISTEN_SET="false"
UNPRIVILEGED_PORT_MIN="1024"
TARGET="127.0.0.1:22"
TARGET_SET="false"
SESSION_STATS_INTERVAL="0"
SESSION_STATS_INTERVAL_SET="false"
# Nol menyerahkan default kapasitas kepada binary, termasuk saat opsi tidak diberikan.
MAX_CONNECTIONS="0"
MAX_CONNECTIONS_SET="false"
MAX_SESSIONS="0"
MAX_SESSIONS_SET="false"
MAX_SESSIONS_PER_IP="0"
MAX_SESSIONS_PER_IP_SET="false"
PORTABLE_INT_MAX="2147483647"
TLS_CERT_SET="false"
TLS_KEY_SET="false"
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
VALIDATED_BINARY_VERSION=""

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
  sudo ./install.sh [--port <1-65535> | --listen <host:port>] [--transport <tls|plain|auto>] \
    [--target <host:port>] [--session-stats-interval <duration>] \
    [--tls-cert <path>] [--tls-key <path>] \
    [--max-connections <number>] [--max-sessions <number>] [--max-sessions-per-ip <number>] \
    [--max-download-frame <1-16384>] [--download-poll-timeout <1ms-30s>]
  sudo ./install.sh --uninstall
  ./install.sh --version
  ./install.sh --help

Options:
  --port <number>                    Listener port. Default: 8080
                                     Ports below 1024 receive only CAP_NET_BIND_SERVICE
  --listen <host:port>               Listener address, for example 0.0.0.0:8080 or [::1]:80
                                     Use :8080 for all interfaces; cannot be combined with --port
  --transport <mode>                 Server transport. Default: auto
                                     tls   accepts TLS only
                                     plain accepts non-TLS HCR only
                                     auto  accepts TLS and non-TLS HCR on the same port
  --target <host:port>                Fixed SSH server. Default: 127.0.0.1:22
                                     Use brackets for IPv6, for example [::1]:22
  --tls-cert <path>                  TLS certificate inside this directory. Default: fullchain.pem
  --tls-key <path>                   TLS private key inside this directory. Default: privkey.pem
                                     Relative paths use the installer directory, not the shell directory
                                     TLS paths cannot be combined with --transport plain
  --max-connections <number>         Concurrent request limit. Binary default: 2048
  --max-sessions <number>            Global session limit. Binary default: 32
  --max-sessions-per-ip <number>     Per-source session limit. Default: min(16, global session limit)
                                     Limits accept 0 (binary default) through 2147483647
                                     A positive per-IP limit must not exceed the global limit
  --session-stats-interval <duration> Log session counters to the journal. Default: 0 (off)
                                     Use 0 to disable, or whole ms, s, m, or h (for example 10s)
  --max-download-frame <bytes>       Download frame size, 1-16384. Default: 16384
  --download-poll-timeout <duration> Download poll timeout using integer ms or s,
                                     from 1ms through 30s. Default: 8s
  --uninstall                        Stop and unlink the service without deleting this directory
  -version, --version                Print the adjacent binary version and exit without installing
  -h, --help                         Show this help

Required next to install.sh (TLS names may be overridden within this directory):
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

valid_ipv4_literal() {
	local address="$1"
	local octet
	local count=0
	[[ "${address}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
	while [ -n "${address}" ]; do
		octet="${address%%.*}"
		[ "${#octet}" -le 3 ] || return 1
		[[ "${octet}" != 0?* ]] || return 1
		[ "${octet}" -le 255 ] || return 1
		count=$((count + 1))
		[[ "${address}" = *.* ]] || break
		address="${address#*.}"
	done
	[ "${count}" -eq 4 ]
}

valid_ipv6_literal() {
	local address="$1"
	local group
	local count=0
	local compressed="false"
	[[ "${address}" != :* || "${address}" = ::* ]] || return 1
	[[ "${address}" != *: || "${address}" = *:: ]] || return 1
	if [[ "${address}" = *.* ]]; then
		valid_ipv4_literal "${address##*:}" || return 1
		address="${address%:*}:0:0"
	fi
	[[ "${address}" != *:::* ]] || return 1
	if [[ "${address}" = *::* ]]; then
		compressed="true"
		address="${address/::/:}"
		[[ "${address}" != *::* ]] || return 1
		address="${address#:}"
		address="${address%:}"
	else
		[[ "${address}" != :* && "${address}" != *: ]] || return 1
	fi
	while [ -n "${address}" ]; do
		group="${address%%:*}"
		[[ "${group}" =~ ^[A-Fa-f0-9]{1,4}$ ]] || return 1
		count=$((count + 1))
		[[ "${address}" = *:* ]] || break
		address="${address#*:}"
	done
	if [ "${compressed}" = "true" ]; then
		[ "${count}" -lt 8 ]
	else
		[ "${count}" -eq 8 ]
	fi
}

normalize_listener() {
	local host=""
	if [ "${LISTEN_SET}" = "true" ]; then
		[ "${PORT_SET}" = "false" ] || fail "--listen cannot be combined with --port."
		if [[ "${LISTEN_ADDRESS}" =~ ^([A-Za-z0-9][A-Za-z0-9.-]*|\[[A-Fa-f0-9:.]*:[A-Fa-f0-9:.]+\])?:([0-9]+)$ ]]; then
			host="${BASH_REMATCH[1]}"
			PORT="${BASH_REMATCH[2]}"
		else
			fail "--listen must be :port, host:port, or [IPv6]:port, without credentials or spaces."
		fi
		if [[ "${host}" = \[*\] ]]; then
			valid_ipv6_literal "${host:1:${#host}-2}" || fail "--listen contains an invalid IPv6 address."
		elif [[ "${host}" =~ ^[0-9.]+$ && "${host}" = *.* ]]; then
			valid_ipv4_literal "${host}" || fail "--listen contains an invalid IPv4 address."
		fi
	fi
	normalize_decimal_in_range "Listener port must be between 1 and 65535." "65535" "${PORT}"
	PORT="${NORMALIZED_DECIMAL}"
	LISTEN_ADDRESS="${host}:${PORT}"
}

normalize_capacity_options() {
	local variable
	for variable in MAX_CONNECTIONS MAX_SESSIONS MAX_SESSIONS_PER_IP; do
		if [[ "${!variable}" =~ ^0+$ ]]; then
			printf -v "${variable}" '%s' "0"
		else
			normalize_decimal_in_range \
				"Capacity limits must be integers from 0 through ${PORTABLE_INT_MAX} (0 = binary default)." \
				"${PORTABLE_INT_MAX}" "${!variable}"
			printf -v "${variable}" '%s' "${NORMALIZED_DECIMAL}"
		fi
	done
	if [ "${MAX_SESSIONS}" != "0" ]; then
		[ "${MAX_SESSIONS_PER_IP}" -le "${MAX_SESSIONS}" ] ||
			fail "--max-sessions-per-ip must not exceed --max-sessions."
	fi
}

validate_capacity_defaults() {
	local help_output
	local line
	local reading_default="false"
	[ "${MAX_SESSIONS}" = "0" ] && [ "${MAX_SESSIONS_PER_IP}" != "0" ] || return 0
	# Default efektif dibaca dari binary yang akan dijalankan, bukan disalin dari source Go.
	help_output="$("${BINARY_PATH}" --help 2>&1)" || fail "The binary could not report its default session limit."
	while IFS= read -r line; do
		if [[ "${line}" =~ ^[[:space:]]*-max-sessions[[:space:]]+int[[:space:]]*$ ]]; then
			reading_default="true"
			continue
		fi
		[ "${reading_default}" = "true" ] || continue
		[[ "${line}" =~ ^[[:space:]]*- ]] && break
		if [[ "${line}" =~ \(default[[:space:]]+([0-9]+)\) ]]; then
			normalize_decimal_in_range "The binary reported an invalid default session limit." \
				"${PORTABLE_INT_MAX}" "${BASH_REMATCH[1]}"
			[ "${MAX_SESSIONS_PER_IP}" -le "${NORMALIZED_DECIMAL}" ] ||
				fail "--max-sessions-per-ip exceeds the binary's global default (${NORMALIZED_DECIMAL}); set --max-sessions explicitly."
			return
		fi
	done <<<"${help_output}"
	fail "The binary did not report a usable --max-sessions default; set --max-sessions explicitly."
}

normalize_tls_path() {
	local option="$1"
	local path="$2"
	[ -n "${path}" ] || fail "${option} requires a file path."
	case "${path}" in
		/*) ;;
		*) path="${SCRIPT_DIR}/${path#./}" ;;
	esac
	# Sertifikat tetap di bundle; tolak traversal serta ekspansi argumen/specifier systemd.
	[[ "${path}" =~ ^/[-A-Za-z0-9._/@+:]+$ ]] || fail "${option} contains unsupported path characters."
	case "${path}/" in
		*/../*|*/./*|*//*) fail "${option} must not contain traversal or empty path components." ;;
	esac
	case "${path}" in
		"${SCRIPT_DIR}/"?*) ;;
		*) fail "${option} must stay inside the installer directory." ;;
	esac
	case "${path}" in
		"${UNIT_SOURCE_PATH}"|"${BINARY_PATH}"|"${SCRIPT_PATH}")
			fail "${option} must not use the installer, binary, or generated service path."
			;;
	esac
	NORMALIZED_TLS_PATH="${path}"
}

parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--uninstall)
				[ "${ACTION}" != "version" ] || fail "--uninstall cannot be combined with --version."
				ACTION="uninstall"
				shift
				;;
			-version|--version)
				[ "${ACTION}" != "uninstall" ] || fail "--version cannot be combined with --uninstall."
				ACTION="version"
				shift
				;;
			-h|--help)
				usage
				exit 0
				;;
			*)
				assign_option "$@"
				shift 2
				;;
		esac
	done
	validate_options
}

assign_option() {
	local variable
	local marker=""
	case "$1" in
		--port) variable="PORT" ;;
		--listen) variable="LISTEN_ADDRESS"; marker="LISTEN_SET" ;;
		--transport) variable="TRANSPORT" ;;
		--target) variable="TARGET" ;;
		--tls-cert) variable="TLS_CERT_PATH"; marker="TLS_CERT_SET" ;;
		--tls-key) variable="TLS_KEY_PATH"; marker="TLS_KEY_SET" ;;
		--max-connections) variable="MAX_CONNECTIONS" ;;
		--max-sessions) variable="MAX_SESSIONS" ;;
		--max-sessions-per-ip) variable="MAX_SESSIONS_PER_IP" ;;
		--session-stats-interval) variable="SESSION_STATS_INTERVAL" ;;
		--max-download-frame) variable="MAX_DOWNLOAD_FRAME" ;;
		--download-poll-timeout) variable="DOWNLOAD_POLL_TIMEOUT" ;;
		*) fail "Unknown option: $1" ;;
	esac
	[ "$#" -ge 2 ] || fail "$1 requires a value."
	# Nama variabel berasal dari allowlist, bukan input bebas atau eval.
	printf -v "${variable}" '%s' "$2"
	printf -v "${marker:-${variable}_SET}" '%s' "true"
}

validate_options() {
	if [ "${ACTION}" != "install" ]; then
		validate_standalone_action
		return
	fi
	case "${TRANSPORT}" in
		tls|plain|auto) ;;
		*) fail "--transport must be tls, plain, or auto." ;;
	esac
	normalize_listener
	normalize_target
	normalize_session_stats_interval
	normalize_traffic_shape_options
	normalize_capacity_options
	if [ "${TRANSPORT}" = "plain" ] && {
		[ "${TLS_CERT_SET}" = "true" ] || [ "${TLS_KEY_SET}" = "true" ];
	}; then
		fail "--tls-cert and --tls-key cannot be combined with --transport plain."
	fi
	normalize_tls_path "--tls-cert" "${TLS_CERT_PATH}"
	TLS_CERT_PATH="${NORMALIZED_TLS_PATH}"
	normalize_tls_path "--tls-key" "${TLS_KEY_PATH}"
	TLS_KEY_PATH="${NORMALIZED_TLS_PATH}"
}

validate_standalone_action() {
	local option
	local marker
	for option in port:PORT listen:LISTEN transport:TRANSPORT target:TARGET \
		tls-cert:TLS_CERT tls-key:TLS_KEY max-connections:MAX_CONNECTIONS \
		max-sessions:MAX_SESSIONS max-sessions-per-ip:MAX_SESSIONS_PER_IP \
		session-stats-interval:SESSION_STATS_INTERVAL max-download-frame:MAX_DOWNLOAD_FRAME \
		download-poll-timeout:DOWNLOAD_POLL_TIMEOUT; do
		marker="${option#*:}_SET"
		[ "${!marker}" = "false" ] || fail "--${option%%:*} cannot be combined with --${ACTION}."
	done
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
	local current="${1:-${SCRIPT_DIR}}"
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
	VALIDATED_BINARY_VERSION="${output}"
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
	validate_capacity_defaults
	if [ -e "${UNIT_SOURCE_PATH}" ] || [ -L "${UNIT_SOURCE_PATH}" ]; then
		validate_root_file false "Generated systemd unit" "${UNIT_SOURCE_PATH}"
	fi
	if [ "${TRANSPORT}" = "tls" ] || [ "${TRANSPORT}" = "auto" ]; then
		validate_secure_directory "$(dirname -- "${TLS_CERT_PATH}")"
		validate_secure_directory "$(dirname -- "${TLS_KEY_PATH}")"
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
	local capacity_arguments=""
	local option
	local variable
	local marker
	if [ "${PORT}" -lt "${UNPRIVILEGED_PORT_MIN}" ]; then
		bind_capability="CAP_NET_BIND_SERVICE"
	fi
	if [ "${TRANSPORT}" = "tls" ] || [ "${TRANSPORT}" = "auto" ]; then
		tls_arguments=" --tls-cert ${TLS_CERT_PATH} --tls-key ${TLS_KEY_PATH}"
	fi
	if [ "${SESSION_STATS_INTERVAL}" != "0" ]; then
		stats_arguments=" --session-stats-interval ${SESSION_STATS_INTERVAL}"
	fi
	for option in max-connections:MAX_CONNECTIONS max-sessions:MAX_SESSIONS max-sessions-per-ip:MAX_SESSIONS_PER_IP; do
		variable="${option#*:}"
		marker="${variable}_SET"
		if [ "${!marker}" = "true" ]; then
			capacity_arguments+=" --${option%%:*} ${!variable}"
		fi
	done
	TEMP_UNIT="$(mktemp "${SCRIPT_DIR}/.${SERVICE_NAME}.XXXXXX.service")"
	chmod 0600 "${TEMP_UNIT}"
	write_unit
	chmod 0644 "${TEMP_UNIT}"
	systemd-analyze verify "${TEMP_UNIT}"
}

write_unit() {
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
ExecStart=${BINARY_PATH} --listen ${LISTEN_ADDRESS} --target ${TARGET} --transport ${TRANSPORT}${tls_arguments} --max-download-frame ${MAX_DOWNLOAD_FRAME} --download-poll-timeout ${DOWNLOAD_POLL_TIMEOUT}${stats_arguments}${capacity_arguments}
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
	echo "Listener: ${LISTEN_ADDRESS}"
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
	if [ "${ACTION}" = "version" ]; then
		validate_secure_directory
		validate_binary
		printf '%s\n' "${VALIDATED_BINARY_VERSION}"
		return
	fi
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
