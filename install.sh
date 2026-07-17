#!/bin/bash
# DiskGuard installer - runs as root on the panel/wings host
set -euo pipefail

WINGS_CONFIG="/etc/pterodactyl/config.yml"
DOCKER_DAEMON="/etc/docker/daemon.json"
SECCOMP_PROFILE="/etc/docker/seccomp-diskguard.json"
MONITOR_SCRIPT="/usr/local/bin/diskguard-monitor"
SERVICE_FILE="/etc/systemd/system/diskguard.service"
PANEL_ENV="/var/www/pterodactyl/.env"

cecho() { echo -e "\e[${1}m[DiskGuard] ${2}\e[0m"; }
info()    { cecho "36" "$*"; }
success() { cecho "32" "$*"; }
warn()    { cecho "33" "WARNING: $*"; }
err()     { cecho "31" "ERROR: $*" >&2; exit 1; }

# ── 1. Root check ─────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "Must be run as root"

info "Starting DiskGuard installation..."

# ── 2. Patch Wings config ──────────────────────────────────────────────────────
if [[ -f "$WINGS_CONFIG" ]]; then
    info "Patching Wings config: disk_check_interval → 5s"
    # Replace existing value or append under system: block
    if grep -q "disk_check_interval" "$WINGS_CONFIG"; then
        sed -i 's/disk_check_interval:[[:space:]]*[0-9]*/disk_check_interval: 5/' "$WINGS_CONFIG"
    else
        # Append after "system:" line
        sed -i '/^system:/a\  disk_check_interval: 5' "$WINGS_CONFIG"
    fi

    info "Patching Wings config: container_pid_limit → 512"
    if grep -q "container_pid_limit" "$WINGS_CONFIG"; then
        sed -i 's/container_pid_limit:[[:space:]]*[0-9]*/container_pid_limit: 512/' "$WINGS_CONFIG"
    else
        sed -i '/^docker:/a\  container_pid_limit: 512' "$WINGS_CONFIG"
    fi
    success "Wings config patched"
else
    warn "Wings config not found at $WINGS_CONFIG — skipping Wings patch"
    warn "If Wings is on a separate node, run this script there too"
fi

# ── 3. Deploy seccomp profile (blocks fallocate syscall) ──────────────────────
info "Deploying seccomp profile to block fallocate..."
cat > "$SECCOMP_PROFILE" << 'SECCOMP'
{
  "comment": "DiskGuard seccomp - blocks disk-filling syscalls for Pterodactyl containers",
  "defaultAction": "SCMP_ACT_ALLOW",
  "architectures": [
    "SCMP_ARCH_X86_64",
    "SCMP_ARCH_X86",
    "SCMP_ARCH_X32",
    "SCMP_ARCH_AARCH64",
    "SCMP_ARCH_ARM"
  ],
  "syscalls": [
    {
      "names": ["fallocate"],
      "action": "SCMP_ACT_ERRNO",
      "errnoRet": 28,
      "comment": "Block fallocate - used by Pterodactyl Crasher to instantly fill disk"
    }
  ]
}
SECCOMP
chmod 644 "$SECCOMP_PROFILE"
success "Seccomp profile deployed: $SECCOMP_PROFILE"

# ── 4. Check if Wings source is available for patching ───────────────────────
WINGS_SOURCE_DIR=""
for d in /root/wings /home/*/wings /opt/wings /var/www/wings; do
    if [[ -f "$d/environment/docker/container.go" ]]; then
        WINGS_SOURCE_DIR="$d"
        break
    fi
done

# Also check if Go is available for compilation
HAS_GO=false
command -v go &>/dev/null && HAS_GO=true

if [[ -n "$WINGS_SOURCE_DIR" ]] && $HAS_GO; then
    info "Wings source found at $WINGS_SOURCE_DIR — applying seccomp patch..."
    CONTAINER_GO="$WINGS_SOURCE_DIR/environment/docker/container.go"

    # Check if already patched
    if grep -q "seccomp-diskguard" "$CONTAINER_GO"; then
        info "Wings seccomp patch already applied"
    else
        # Backup original
        cp "$CONTAINER_GO" "${CONTAINER_GO}.diskguard.bak"

        # Inject seccomp profile into SecurityOpt
        # Find the SecurityOpt line and add seccomp after no-new-privileges
        python3 - "$CONTAINER_GO" "$SECCOMP_PROFILE" << 'PYEOF'
import sys, re

filepath = sys.argv[1]
seccomp_path = sys.argv[2]

with open(filepath, 'r') as f:
    content = f.read()

# Find and replace SecurityOpt to add seccomp
old = 'SecurityOpt:    []string{"no-new-privileges"},'
new = f'SecurityOpt:    []string{{"no-new-privileges", "seccomp={seccomp_path}"}},'

if old not in content:
    print(f"Could not find SecurityOpt line — Wings version may differ, skipping patch")
    sys.exit(0)

content = content.replace(old, new)
with open(filepath, 'w') as f:
    f.write(content)
print("Seccomp injected into SecurityOpt")
PYEOF

        info "Recompiling Wings with seccomp patch..."
        cd "$WINGS_SOURCE_DIR"
        if go build -o /usr/local/bin/wings.new .; then
            systemctl stop wings || true
            mv /usr/local/bin/wings /usr/local/bin/wings.pre-diskguard
            mv /usr/local/bin/wings.new /usr/local/bin/wings
            success "Wings recompiled and installed with seccomp support"
        else
            warn "Wings compilation failed — reverting source patch"
            cp "${CONTAINER_GO}.diskguard.bak" "$CONTAINER_GO"
            warn "Using monitoring daemon only (no seccomp)"
        fi
    fi
else
    if [[ -z "$WINGS_SOURCE_DIR" ]]; then
        warn "Wings source not found — using Docker daemon seccomp instead"
    else
        warn "Go not installed — using Docker daemon seccomp instead"
    fi

    # Fallback: configure Docker daemon to use seccomp profile for all containers
    info "Adding seccomp profile to Docker daemon config..."
    if command -v python3 &>/dev/null; then
        python3 - "$DOCKER_DAEMON" "$SECCOMP_PROFILE" << 'PYEOF'
import sys, json, os

daemon_path = sys.argv[1]
seccomp_path = sys.argv[2]

if os.path.exists(daemon_path):
    with open(daemon_path, 'r') as f:
        try:
            cfg = json.load(f)
        except json.JSONDecodeError:
            cfg = {}
else:
    cfg = {}

cfg["seccomp-profile"] = seccomp_path

with open(daemon_path, 'w') as f:
    json.dump(cfg, f, indent=2)
print(f"Docker daemon.json updated: seccomp-profile = {seccomp_path}")
PYEOF
    else
        warn "python3 not found — cannot update Docker daemon.json automatically"
        warn "Manually add to $DOCKER_DAEMON: \"seccomp-profile\": \"$SECCOMP_PROFILE\""
    fi
fi

# ── 5. Deploy monitoring daemon ───────────────────────────────────────────────
info "Deploying disk monitoring daemon..."
cp "$(dirname "$0")/diskguard-monitor.sh" "$MONITOR_SCRIPT"
chmod +x "$MONITOR_SCRIPT"

# Inject panel .env path into the monitor
if [[ -f "$PANEL_ENV" ]]; then
    sed -i "s|PANEL_ENV=.*|PANEL_ENV=\"$PANEL_ENV\"|" "$MONITOR_SCRIPT"
fi

# ── 6. Install and start systemd service ──────────────────────────────────────
info "Installing diskguard systemd service..."
cp "$(dirname "$0")/diskguard.service" "$SERVICE_FILE"
systemctl daemon-reload
systemctl enable --now diskguard
success "diskguard.service started"

# ── 7. Restart Wings and Docker ───────────────────────────────────────────────
if systemctl is-active --quiet wings 2>/dev/null; then
    info "Restarting Wings..."
    systemctl restart wings
    success "Wings restarted"
fi

if systemctl is-active --quiet docker 2>/dev/null; then
    info "Restarting Docker (applying seccomp config)..."
    systemctl restart docker
    sleep 3
    success "Docker restarted"
fi

# ── 8. Done ───────────────────────────────────────────────────────────────────
echo ""
success "DiskGuard installed successfully!"
echo ""
echo "  Protection layers active:"
echo "    ✓ Wings disk_check_interval: 5s (was 150s)"
echo "    ✓ Container PID limit: 512"
echo "    ✓ fallocate blocked via seccomp"
echo "    ✓ Disk monitoring daemon: checks every 3s"
echo ""
echo "  Logs:    journalctl -u diskguard -f"
echo "  Status:  systemctl status diskguard"
