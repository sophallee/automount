#!/bin/bash

# Automount Daemon Script
# Non-interactive background service for mounting remote shares.
# Usage: automount-daemon.sh <hostname>

set -u # Treat unset variables as an error

# --- Global Configuration Defaults ---
log_level="info"
log_dir="/var/log/automount"
mount_health_interval=30
default_retry_max=3
default_retry_sleep=2

# --- Internal Variables ---
_host_name="${1:-}"
_config_dir="/etc/automount"
_host_config_dir="${_config_dir}/config.d"
_global_config="${_config_dir}/automount.conf"
_host_config="${_host_config_dir}/${_host_name}.properties"
_mount_point=""
_protocol=""
_retry_count=0
_keep_running=true

# --- Logging Function ---
log() {
    local level="${1:-info}"
    local message="${2:-}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Convert level to uppercase for display
    local display_level
    display_level=$(echo "${level}" | tr '[:lower:]' '[:upper:]')

    # Filter based on log_level
    local log_priority=6 # info
    case "${log_level,,}" in
        debug) [[ "${level,,}" =~ (debug|info|warn|error) ]] || return 0; log_priority=7 ;;
        info)  [[ "${level,,}" =~ (info|warn|error) ]]       || return 0; log_priority=6 ;;
        warn)  [[ "${level,,}" =~ (warn|error) ]]            || return 0; log_priority=4 ;;
        error) [[ "${level,,}" == "error" ]]                 || return 0; log_priority=3 ;;
    esac

    local log_entry="${timestamp} [${display_level}] ${_host_name}: ${message}"

    # Log to file
    if [[ -d "${log_dir}" ]]; then
        echo "${log_entry}" >> "${log_dir}/${_host_name}.log" 2>/dev/null || true
    fi

    # Log to syslog/journald
    logger -p "user.${log_priority}" -t "automount-${_host_name}" "${message}"
}

# --- Signal Handling ---
cleanup() {
    log "info" "Received shutdown signal. Cleaning up..."
    _keep_running=false
    if [[ -n "${_mount_point}" ]]; then
        if mountpoint -q "${_mount_point}"; then
            log "info" "Unmounting ${_mount_point}"
            sudo umount "${_mount_point}" || log "error" "Failed to unmount ${_mount_point}"
        fi
    fi
    exit 0
}

trap cleanup SIGTERM SIGINT

reload_config() {
    log "info" "Reloading configuration..."
    if [[ -f "${_global_config}" ]]; then
        # shellcheck source=/dev/null
        source "${_global_config}"
    fi
}

trap reload_config SIGHUP

# --- Initialization ---
if [[ -z "${_host_name}" ]]; then
    echo "Usage: $0 <hostname>"
    exit 1
fi

# Check for host configuration
if [[ ! -f "${_host_config}" ]]; then
    # Log to syslog even if log_dir isn't available
    logger -t "automount-${_host_name}" "No host configured: ${_host_config} not found"
    exit 0
fi

# Load global config
if [[ -f "${_global_config}" ]]; then
    # shellcheck source=/dev/null
    source "${_global_config}"
fi

# Load host config
# shellcheck source=/dev/null
source "${_host_config}"

# Validate required variables from host config
if [[ -z "${protocol:-}" ]] || [[ -z "${remote_path:-}" ]] || [[ -z "${mount_point:-}" ]]; then
    log "error" "Missing required variables in ${_host_config}. Protocol, remote_path, and mount_point are required."
    exit 1
fi

_protocol="${protocol}"
_mount_point="${mount_point}"
_options="${options:-}"
_retry_max="${retry_max:-$default_retry_max}"
_retry_sleep="${retry_sleep:-$default_retry_sleep}"
_folder_chmod="${folder_chmod:-770}"
_host_user=$(id -un)
_host_group=$(id -gn)

# --- Dependency Check ---
check_dependencies() {
    local missing=()
    case "${_protocol}" in
        smb)  command -v mount.cifs >/dev/null || missing+=("cifs-utils") ;;
        nfs)  command -v mount.nfs >/dev/null  || missing+=("nfs-common") ;;
        ftp)  command -v curlftpfs >/dev/null  || missing+=("curlftpfs") ;;
        sftp) command -v sshfs >/dev/null      || missing+=("sshfs") ;;
        *)    log "error" "Unsupported protocol: ${_protocol}"; exit 1 ;;
    esac

    if [[ ${#missing[@]} -gt 0 ]]; then
        log "error" "Missing dependency: ${missing[*]}. Install manually or run installer."
        exit 1
    fi
}

check_dependencies

# --- Mounting Logic ---
do_mount() {
    log "info" "Starting automount for host ${_host_name} (protocol=${_protocol})"

    # Create directory and ensure ownership by automounter
    sudo /usr/bin/mkdir -p "${_mount_point}"
    sudo /usr/bin/chown "${_host_user}:${_host_group}" "${_mount_point}"
    sudo /usr/bin/chmod "${_folder_chmod}" "${_mount_point}"

    local mount_cmd=""
    local opts_flag=""
    [[ -n "${_options}" ]] && opts_flag="-o ${_options}"

    case "${_protocol}" in
        smb)
            mount_cmd="sudo /usr/bin/mount -t cifs ${_remote_path} ${_mount_point} ${opts_flag}"
            ;;
        nfs)
            mount_cmd="sudo /usr/bin/mount -t nfs ${_remote_path} ${_mount_point} ${opts_flag}"
            ;;
        ftp)
            # FUSE mounts don't need sudo if user_allow_other is set and folder is owned by user
            mount_cmd="/usr/bin/curlftpfs ${_remote_path} ${_mount_point} ${opts_flag}"
            ;;
        sftp)
            # FUSE mounts don't need sudo if user_allow_other is set and folder is owned by user
            mount_cmd="/usr/bin/sshfs ${_remote_path} ${_mount_point} ${opts_flag}"
            ;;
    esac

    _retry_count=0
    local sleep_time="${_retry_sleep}"

    while [[ ${_retry_count} -lt ${_retry_max} ]]; do
        log "debug" "Executing mount: ${mount_cmd}"
        
        # Capture stderr to help with diagnostics
        local mount_output
        mount_output=$(eval "${mount_cmd}" 2>&1)
        local exit_code=$?

        # Verification: FUSE commands often return 0 even if they fail shortly after.
        # We wait a brief moment and check if it's actually a mountpoint.
        sleep 2
        if [[ ${exit_code} -eq 0 ]] && findmnt "${_mount_point}" >/dev/null; then
            log "info" "Successfully mounted ${_mount_point}"
            return 0
        else
            _retry_count=$((_retry_count + 1))
            log "warn" "Mount verification failed for ${_mount_point} (attempt ${_retry_count}/${_retry_max})."
            [[ -n "${mount_output}" ]] && log "warn" "Error output: ${mount_output}"
            
            # Diagnostic: Show what is currently mounted at that path
            local actual_mount
            actual_mount=$(findmnt -n -o SOURCE,FSTYPE "${_mount_point}" 2>/dev/null || echo "nothing")
            log "debug" "Actual state at ${_mount_point}: ${actual_mount}"
            
            if [[ ${_retry_count} -lt ${_retry_max} ]]; then
                log "warn" "Retrying in ${sleep_time}s..."
                sleep "${sleep_time}"
                sleep_time=$((sleep_time * 2))
            fi
        fi
    done

    log "error" "Failed to mount ${_mount_point} after ${_retry_max} attempts."
    return 1
}

# Use internal copies of config variables to prevent collision if sourced files are messy
_remote_path="${remote_path}"

# Initial mount attempt
if ! mountpoint -q "${_mount_point}"; then
    do_mount || true # Don't exit on initial failure, loop will retry
fi

# --- Health Check Loop ---
while ${_keep_running}; do
    if ! findmnt "${_mount_point}" >/dev/null; then
        log "warn" "Mount point ${_mount_point} is not mounted. Attempting remount..."
        do_mount || true
    fi
    sleep "${mount_health_interval}"
done
