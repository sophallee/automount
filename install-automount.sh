#!/bin/bash

# Automount Installer Script
# Deploys the automount daemon and configures the system.

set -e # Exit on error

# --- Configuration ---
daemon_script="automount-daemon.sh"
install_path="/usr/local/sbin/automount-daemon.sh"
config_dir="/etc/automount"
log_dir="/var/log/automount"
lib_dir="/var/lib/automount"
user_name="automounter"

# --- Functions ---
log() {
    echo "[INFO] $1"
}

warn() {
    echo "[WARN] $1" >&2
}

error() {
    echo "[ERROR] $1" >&2
    exit 1
}

# --- Root Check ---
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root (or with sudo)."
fi

# --- Dependency Detection ---
log "Checking dependencies..."
missing_deps=()
distro=""

if [[ -f /etc/debian_version ]]; then
    distro="debian"
elif [[ -f /etc/redhat-release ]]; then
    distro="rhel"
fi

deps=("cifs-utils" "nfs-common" "curlftpfs" "sshfs")
if [[ "${distro}" == "rhel" ]]; then
    deps=("cifs-utils" "nfs-utils" "curlftpfs" "fuse-sshfs")
fi

for dep in "${deps[@]}"; do
    case $dep in
        cifs-utils)  command -v mount.cifs >/dev/null || missing_deps+=("$dep") ;;
        nfs-common|nfs-utils)  command -v mount.nfs >/dev/null || missing_deps+=("$dep") ;;
        curlftpfs)   command -v curlftpfs >/dev/null || missing_deps+=("$dep") ;;
        sshfs|fuse-sshfs) command -v sshfs >/dev/null || missing_deps+=("$dep") ;;
    esac
done

if [[ ${#missing_deps[@]} -gt 0 ]]; then
    log "Missing dependencies detected: ${missing_deps[*]}"
    log "Attempting to install missing dependencies..."
    
    installation_failed=false

    if [[ "${distro}" == "debian" ]]; then
        apt-get update -qq || warn "Apt update failed, attempting installation anyway..."
        for dep in "${missing_deps[@]}"; do
            log "Installing ${dep}..."
            apt-get install -y "${dep}" || { warn "Failed to install ${dep}"; installation_failed=true; }
        done
    elif [[ "${distro}" == "rhel" ]]; then
        # Check if EPEL is needed for curlftpfs or fuse-sshfs
        if [[ " ${missing_deps[*]} " =~ " curlftpfs " ]] || [[ " ${missing_deps[*]} " =~ " fuse-sshfs " ]]; then
            log "Attempting to enable EPEL repository for extra dependencies..."
            yum install -y epel-release || warn "Could not install epel-release. Some packages might be missing."
        fi

        for dep in "${missing_deps[@]}"; do
            log "Installing ${dep}..."
            yum install -y "${dep}" || { warn "Failed to install ${dep}"; installation_failed=true; }
        done
    else
        warn "Unsupported distribution. Please install manually: ${missing_deps[*]}"
        installation_failed=true
    fi

    if ${installation_failed}; then
        warn "Some dependencies could not be installed automatically."
        warn "The daemon will still work for other protocols, but will log an error if a missing protocol is used."
    else
        log "Dependencies installed successfully."
    fi
else
    log "All dependencies are satisfied."
fi

# --- Install Daemon Script ---
log "Installing daemon script to ${install_path}..."
if [[ -f "${daemon_script}" ]]; then
    cp "${daemon_script}" "${install_path}"
    chmod 755 "${install_path}"
else
    error "Daemon script ${daemon_script} not found in current directory."
fi

# --- Create System User ---
log "Creating system user ${user_name}..."
if ! id -u "${user_name}" >/dev/null 2>&1; then
    useradd -r -s /usr/sbin/nologin -d "${lib_dir}" -m "${user_name}"
else
    log "User ${user_name} already exists."
fi

# --- Create Directories ---
log "Creating directories..."
mkdir -p "${config_dir}/config.d"
mkdir -p "${config_dir}/credentials"
mkdir -p "${log_dir}"
mkdir -p "${lib_dir}/.ssh"
mkdir -p "/mnt/automount"

chown -R "${user_name}:${user_name}" "${log_dir}"
chown -R "${user_name}:${user_name}" "${lib_dir}"
chown -R "${user_name}:${user_name}" "${config_dir}/credentials"
chown "${user_name}:${user_name}" "/mnt/automount"

chmod 750 "${log_dir}"
chmod 700 "${lib_dir}/.ssh"
chmod 700 "${config_dir}/credentials"
# 2770 = SetGID bit (2) + rwxrwx--- (770)
# SetGID ensures that new files/folders created inside inherit the group ownership
chmod 2770 "/mnt/automount"

# --- Global Config ---
log "Creating global config ${config_dir}/automount.conf..."
if [[ ! -f "${config_dir}/automount.conf" ]]; then
    cp "configs/automount.conf" "${config_dir}/automount.conf"
    chmod 644 "${config_dir}/automount.conf"
fi

# --- Example Template ---
log "Creating example template ${config_dir}/example.properties.template..."
# Replace placeholder UIDs with actual IDs of the created user
automounter_uid=$(id -u "${user_name}")
automounter_gid=$(id -g "${user_name}")
sed -e "s/uid=1001/uid=${automounter_uid}/g" \
    -e "s/gid=1001/gid=${automounter_gid}/g" \
    "configs/example.properties.template" > "${config_dir}/example.properties.template"
chmod 644 "${config_dir}/example.properties.template"

# --- Logrotate ---
log "Setting up logrotate..."
cp "configs/automount.logrotate" "/etc/logrotate.d/automount"
chmod 644 "/etc/logrotate.d/automount"

# --- Systemd Service Template ---
log "Creating systemd service template..."
cp "configs/automount@.service" "/etc/systemd/system/automount@.service"
chmod 644 "/etc/systemd/system/automount@.service"

# --- Sudoers ---
log "Setting up sudoers for mount/umount..."
mount_path=$(command -v mount || echo "/usr/bin/mount")
umount_path=$(command -v umount || echo "/usr/bin/umount")
mkdir_path=$(command -v mkdir || echo "/usr/bin/mkdir")
curlftpfs_path=$(command -v curlftpfs || echo "/usr/bin/curlftpfs")
sshfs_path=$(command -v sshfs || echo "/usr/bin/sshfs")
chown_path=$(command -v chown || echo "/usr/bin/chown")
chmod_path=$(command -v chmod || echo "/usr/bin/chmod")

# Use sed to update the sudoers file with actual paths and user name
sed -e "s|automounter|${user_name}|g" \
    -e "s|/usr/bin/mount|${mount_path}|g" \
    -e "s|/usr/bin/umount|${umount_path}|g" \
    -e "s|/usr/bin/mkdir|${mkdir_path}|g" \
    -e "s|/usr/bin/curlftpfs|${curlftpfs_path}|g" \
    -e "s|/usr/bin/sshfs|${sshfs_path}|g" \
    -e "s|/usr/bin/chown|${chown_path}|g" \
    -e "s|/usr/bin/chmod|${chmod_path}|g" \
    "configs/automount.sudoers" > "/etc/sudoers.d/automount"
chmod 440 "/etc/sudoers.d/automount"

# --- FUSE Config ---
FUSE_CONF="/etc/fuse.conf"
log "Configuring FUSE in ${FUSE_CONF}..."
if [[ -f "${FUSE_CONF}" ]]; then
    # Handle user_allow_other
    sed -i 's/^[[:space:]]*#[[:space:]]*user_allow_other/user_allow_other/' "${FUSE_CONF}"
    if ! grep -q "^user_allow_other" "${FUSE_CONF}"; then
        echo "user_allow_other" >> "${FUSE_CONF}"
    fi
    
    # Handle mount_max
    if grep -q "mount_max" "${FUSE_CONF}"; then
        sed -i 's/^[[:space:]]*#[[:space:]]*mount_max.*/mount_max = 1000/' "${FUSE_CONF}"
        # If it was already uncommented but had a different value, update it
        sed -i 's/^mount_max[[:space:]]*=[[:space:]]*.*/mount_max = 1000/' "${FUSE_CONF}"
    else
        echo "mount_max = 1000" >> "${FUSE_CONF}"
    fi
else
    # Create it if it doesn't exist
    {
        echo "user_allow_other"
        echo "mount_max = 1000"
    } > "${FUSE_CONF}"
    chmod 644 "${FUSE_CONF}"
fi

log "Installation complete!"
echo ""
echo "To configure a host:"
echo "  cp ${config_dir}/example.properties.template ${config_dir}/config.d/myserver.properties"
echo "  vi ${config_dir}/config.d/myserver.properties"
echo ""
echo "To enable and start:"
echo "  sudo systemctl daemon-reload"
echo "  sudo systemctl enable automount@myserver --now"
echo ""
echo "To check logs:"
echo "  journalctl -u automount@myserver -f"
echo "  tail -f ${log_dir}/myserver.log"
