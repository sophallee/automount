# Automount Daemon

A lightweight, non-interactive Bash-based daemon for managing remote share mounts (SMB, NFS, FTP, SFTP) on Linux systems. It is designed to run as a systemd background service, providing automated mounting, health monitoring, and exponential backoff on failures.

## Features

- **Protocol Support:** SMB, NFS, FTP (via `curlftpfs`), and SFTP (via `sshfs`).
- **Health Monitoring:** Periodically checks mount points and automatically remounts if a share becomes disconnected.
- **Robustness:** Implements exponential backoff for retries during mount failures.
- **Non-Interactive:** Designed for headless servers; all configuration is file-based.
- **Secure:** Runs as a dedicated `automounter` system user with restricted `sudo` privileges.
- **Logging:** Structured logging to both `syslog/journald` and dedicated per-host log files.
- **Automated Installation:** Installer script handles user creation, directory setup, dependency resolution, and systemd integration.

## Installation

Run the installer script as root or with `sudo`:

```bash
sudo ./install-automount.sh
```

The installer will:
1. Detect and install missing dependencies (`cifs-utils`, `nfs-common`, etc.).
2. Install the daemon script to `/usr/local/sbin/automount-daemon.sh`.
3. Create a dedicated `automounter` system user.
4. Set up `/etc/automount/` for configuration and `/var/log/automount/` for logs.
5. Configure `logrotate` for log management.
6. Install a systemd service template: `automount@.service`.
7. Configure `sudoers` for the `automounter` user.

## Configuration

### Global Configuration
Global settings are located in `/etc/automount/automount.conf`.

- `log_level`: debug, info, warn, error.
- `mount_health_interval`: Seconds between health checks (default: 30).
- `default_retry_max`: Number of mount attempts (default: 3).

### Per-Host Configuration
Create a `.properties` file for each host in `/etc/automount/config.d/`.
#### Example: `nas1.properties`
```bash
protocol=smb
remote_path=//192.168.1.100/data
mount_point=/mnt/automount/nas1
options=credentials=/etc/automount/credentials/nas1.creds,uid=1001,gid=1001,vers=3.0
port=4445          # Optional: Specify a custom port
folder_chmod=770   # Optional: defaults to 770 (rwxrwx---)
```

#### Protocol Syntax Examples:
- **SMB:** `protocol=smb`, `remote_path=//server/share`
- **NFS:** `protocol=nfs`, `remote_path=server:/export`
- **FTP:** `protocol=ftp`, `remote_path=ftp://user:pass@host/path`
- **SFTP:** `protocol=sftp`, `remote_path=user@host:/remote`

## Security and Permissions

### Directory Permissions
The installer sets `/mnt/automount` to `2770` (`drwxrws---`).
- **770:** Both the `automounter` user and the `automounter` group have full read/write/execute permissions.
- **SetGID (2):** Ensures that any new subfolders created by the daemon inherit the `automounter` group ownership automatically.

### Restricting Access
If you want to restrict a specific mount point so only the `automounter` user can access it, you can override the permissions in the host's `.properties` file:

```bash
# In /etc/automount/config.d/secret_nas.properties
folder_chmod=700  # Only the user (automounter) has access
```

Common values:
- `770`: User & Group read/write (Default)
- `750`: User read/write, Group read-only
- `700`: Only User read/write

## Usage

### Custom Ports
You can specify a custom port using the `port` variable in your properties file.
- **SMB/NFS/SFTP:** The daemon automatically appends `port=<port>` to the mount options.
- **FTP:** The `port` variable is not directly supported by `curlftpfs`. Please include it in the `remote_path` (e.g., `ftp://host:2121/path`).

### Per-Host Credentials
...
Credentials (passwords and keys) are **always per-host**. 

1. **SMB/CIFS Credentials:**
   Instead of putting passwords in the `.properties` file, use a dedicated credentials file in `/etc/automount/credentials/<hostname>.creds`:
   ```ini
   username=myuser
   password=mypassword
   domain=WORKGROUP
   ```
   Then in your `nas1.properties`:
   ```bash
   options=credentials=/etc/automount/credentials/nas1.creds,uid=automounter,gid=automounter
   ```

2. **FTP Credentials:**
   Stored directly in the `remote_path` within the per-host properties file:
   ```bash
   remote_path=ftp://user:password@host/path
   ```

3. **SFTP (SSH) Credentials:**
   Stored as per-host SSH keys in `/var/lib/automount/.ssh/` and referenced via the `IdentityFile` option.

### SFTP and SSH Keys
Since the daemon runs non-interactively, SFTP mounts using `sshfs` require SSH keys for authentication. 

1. **Generate a key for the automounter user (optional):**
   ```bash
   sudo -u automounter ssh-keygen -t rsa -b 4096 -f /var/lib/automount/.ssh/id_rsa -N ""
   ```
2. **Transfer the public key to the remote host:**
   ```bash
   sudo -u automounter ssh-copy-id -i /var/lib/automount/.ssh/id_rsa.pub user@remote-host
   ```
3. **Configure the host properties:**
   In `/etc/automount/config.d/myhost.properties`, use the `IdentityFile` option. You can use different keys for different hosts for better security:
   ```bash
   protocol=sftp
   remote_path=user@remote-host:/path
   mount_point=/mnt/automount/sftp_share
   # Point to a specific key for this host
   options=allow_other,IdentityFile=/var/lib/automount/.ssh/id_rsa_nas1,StrictHostKeyChecking=no,uid=automounter,gid=automounter
   ```

*Note: `StrictHostKeyChecking=no` is often necessary for the first connection in a non-interactive environment, or you can manually add the host key to `/var/lib/automount/.ssh/known_hosts` using `ssh-keyscan`.*

### Managing Services
The daemon uses systemd instantiation. To manage a mount for a specific host config (e.g., `nas1.properties`):

```bash
# Enable and start the mount
sudo systemctl enable automount@nas1 --now

# Stop the mount
sudo systemctl stop automount@nas1

# Restart/Reload config
sudo systemctl restart automount@nas1
```

### Monitoring Logs
Check the status and logs via `journalctl` or the dedicated log files:

```bash
# View journal logs
journalctl -u automount@nas1 -f

# View per-host log file
tail -f /var/log/automount/nas1.log
```

## Security Note
The daemon runs as the `automounter` user. When configuring `options` for SMB or FTP, ensure the `uid` and `gid` match the `automounter` user (or your target user) to ensure correct file permissions on the mount point.

## Troubleshooting
- **Permission Denied:** Ensure the mount point directory is accessible and the `automounter` user has sudo rights (configured automatically by the installer).
- **Dependency Missing:** Check `/var/log/automount/<host>.log`. The daemon will log if a required tool like `mount.cifs` is missing.
- **Config Errors:** If the properties file is missing or invalid, the daemon will log the error to the journal and exit.
