#!/bin/bash
set -e

# Must be run as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo ./setup-usb-automount.sh"
    exit 1
fi

echo "==> Cleaning up any previous installation..."
# Stop any running usb-mount services
systemctl stop 'usb-mount@*' 2>/dev/null || true
# Unmount anything currently mounted in usb-drives
if [ -d /mnt/usb-drives ]; then
    for mount_point in /mnt/usb-drives/*/; do
        umount -l "$mount_point" 2>/dev/null || true
        rmdir "$mount_point" 2>/dev/null || true
    done
fi
# Remove old files if they exist
rm -f /usr/local/bin/usb-mount.sh
rm -f /etc/udev/rules.d/99-usb-automount.rules
rm -f /etc/systemd/system/usb-mount@.service

echo "==> Creating mount base directory..."
mkdir -p /mnt/usb-drives

echo "==> Writing mount script..."
cat > /usr/local/bin/usb-mount.sh << 'EOF'
#!/bin/bash
ACTION="$1"
DEVNAME="$2"
DEV="/dev/$DEVNAME"
MOUNT_BASE="/mnt/usb-drives"

log() { logger -t usb-mount "$*"; echo "[usb-mount] $(date '+%H:%M:%S') $*"; }

SKIP_LABELS="Recovery recovery RECOVERY WinRE System EFI"

should_skip() {
    local label
    label=$(blkid -s LABEL -o value "$DEV" 2>/dev/null || echo "")
    local type
    type=$(blkid -s TYPE -o value "$DEV" 2>/dev/null || echo "")

    if echo "$label" | grep -qiE "^(Recovery|WinRE|System|EFI)$"; then
        log "Skipping $DEV — system partition (label='$label')"
        return 0
    fi
    return 1
}

case "$ACTION" in
    add)
        should_skip && exit 0

        # Wait for device to settle
        sleep 1

        label=$(blkid -s LABEL -o value "$DEV" 2>/dev/null)
        [ -z "$label" ] && label="$DEVNAME"
        label=$(echo "$label" | tr ' /\\' '_')

        mount_point="$MOUNT_BASE/$label"
        mkdir -p "$mount_point"

        if mount "$DEV" "$mount_point" 2>/dev/null; then
            log "Mounted $DEV → $mount_point"
            exit 0
        fi

        for fs in vfat exfat ntfs ext4 ext3; do
            if mount -t "$fs" "$DEV" "$mount_point" 2>/dev/null; then
                log "Mounted $DEV ($fs) → $mount_point"
                exit 0
            fi
        done

        log "WARNING: Could not mount $DEV — skipping"
        rmdir "$mount_point" 2>/dev/null
        ;;

    remove)
        mount_point=$(grep "^$DEV " /proc/mounts | awk '{print $2}' | head -1)
        if [ -n "$mount_point" ]; then
            umount -l "$mount_point" && log "Unmounted $mount_point"
            rmdir "$mount_point" 2>/dev/null
        fi
        ;;
    *)
        echo "Usage: $0 {add|remove} <device>"
        exit 1
        ;;
esac
EOF
chmod +x /usr/local/bin/usb-mount.sh
echo "    ✓ /usr/local/bin/usb-mount.sh"

echo "==> Writing udev rule..."
cat > /etc/udev/rules.d/99-usb-automount.rules << 'EOF'
ACTION=="add", SUBSYSTEM=="block", KERNEL=="sd[b-z][0-9]", ENV{ID_BUS}=="usb", \
    TAG+="systemd", ENV{SYSTEMD_WANTS}="usb-mount@%k.service"

ACTION=="remove", SUBSYSTEM=="block", KERNEL=="sd[b-z][0-9]", ENV{ID_BUS}=="usb", \
    RUN+="/bin/systemctl stop usb-mount@%k.service"
EOF
echo "    ✓ /etc/udev/rules.d/99-usb-automount.rules"

echo "==> Writing systemd service..."
cat > /etc/systemd/system/usb-mount@.service << 'EOF'
[Unit]
Description=Mount USB %i
BindsTo=dev-%i.device
After=dev-%i.device

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/usb-mount.sh add %i
ExecStop=/usr/local/bin/usb-mount.sh remove %i

[Install]
WantedBy=multi-user.target
EOF
echo "    ✓ /etc/systemd/system/usb-mount@.service"

echo "==> Installing exfat and ntfs support..."
apt-get install -y -q exfatprogs ntfs-3g

echo "==> Reloading udev and systemd..."
udevadm control --reload-rules
udevadm trigger
systemctl daemon-reload

echo ""
echo "==> Done! USB drives will now auto-mount to /mnt/usb-drives/<label>"
echo "    Check logs with: journalctl -t usb-mount -f"