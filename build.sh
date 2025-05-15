#!/usr/bin/env bash
set -euo pipefail

HOSTNAME="arch"
KEYMAP="us"
LOCALE="C.UTF-8"
TIMEZONE="UTC"

IMG_SIZE="2G"
IMG_FILE="image.img"
QCOW_FILE="image.qcow2"

# This setup makes writing fstab unnecessary because :
#   - root partition is automatically mounted according to its GPT partition type
#   - rootflags including subvol are set with kernel cmdline
# https://uapi-group.org/specifications/specs/discoverable_partitions_specification/

ESP_GPT_TYPE="C12A7328-F81F-11D2-BA4B-00A0C93EC93B" # EFI System
ESP_LABEL="ESP"
ESP_SIZE="100M"
ESP_DIR="efi"
ROOT_GPT_TYPE="4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709" # Linux root (x86-64)
ROOT_LABEL="Arch"
ROOT_SUBVOL="@arch"
ROOT_FLAGS="compress=zstd,noatime,subvol=$ROOT_SUBVOL"

BUILD_DEPENDENCIES+=(
    arch-install-scripts
    btrfs-progs
    dosfstools
    qemu-img
    util-linux
)
PACKAGES+=(
    base
    btrfs-progs
    cloud-init
    fzf
    grml-zsh-config
    htop
    iptables-nft
    linux
    man-db
    mkinitcpio
    neovim
    openssh
    pacman-contrib
    polkit
    sudo
    systemd-ukify
    zsh
    zsh-autosuggestions
    zsh-syntax-highlighting
)
UNITS_ENABLE+=(
    cloud-init-main
    cloud-init-local
    cloud-init-network
    cloud-config
    cloud-final
    pacman-init
    sshd
    systemd-boot-update
    systemd-networkd
    systemd-resolved
    systemd-timesyncd
    systemd-time-wait-sync

    btrfs-scrub@-.timer
    paccache.timer
)
UNITS_MASK+=(
    systemd-homed.service
    systemd-nsresourced.socket
    systemd-userdbd.socket
)

MOUNT="$(mktemp --directory)"

# Cleanup trap
cleanup() {
    if findmnt --mountpoint "$MOUNT" >/dev/null; then
        umount --recursive "$MOUNT"
    fi
    if [[ -n $LOOPDEV ]]; then
        losetup --detach "$LOOPDEV"
    fi
    rm -rf "$MOUNT"
}
trap cleanup ERR

echo "### DEPENDENCIES" >&2
sed -i 's/^#ParallelDownloads/ParallelDownloads/' "/etc/pacman.conf"
pacman -Syu --needed --noconfirm "${BUILD_DEPENDENCIES[@]}"

echo "### IMAGE SETUP" >&2
rm -f $IMG_FILE
truncate --size $IMG_SIZE $IMG_FILE

echo "### PARTITIONING" >&2
# Flag 59 marks the partition for automatic growing of the contained file system
# https://uapi-group.org/specifications/specs/discoverable_partitions_specification/
sfdisk --label gpt $IMG_FILE <<EOF
type=$ESP_GPT_TYPE,name="$ESP_LABEL",size=$ESP_SIZE
type=$ROOT_GPT_TYPE,name="$ROOT_LABEL",attrs=59
EOF

echo "### LOOP DEVICE SETUP" >&2
LOOPDEV=$(losetup --find --partscan --show $IMG_FILE)
PART1="$LOOPDEV"p1
PART2="$LOOPDEV"p2
sleep 1

echo "### FORMATTING" >&2
mkfs.vfat -F 32 -n "$ESP_LABEL" "$PART1"
mkfs.btrfs --label "$ROOT_LABEL" "$PART2"

echo "### MOUNTING" >&2
mount "$PART2" "$MOUNT"
btrfs subvolume create "$MOUNT/$ROOT_SUBVOL"
btrfs subvolume set-default "$MOUNT/$ROOT_SUBVOL"
umount "$MOUNT"
mount --options "$ROOT_FLAGS" "$PART2" "$MOUNT"
mount --mkdir=700 "$PART1" "$MOUNT/$ESP_DIR"

echo "### KERNEL CMDLINE CONFIG" >&2
# Not specifying `rw` in cmdline breaks boot
mkdir --parents "$MOUNT/etc/kernel"
cat <<EOF >"$MOUNT/etc/kernel/cmdline"
rootflags=$ROOT_FLAGS rw
EOF

echo "### INITRD CONFIG" >&2
mkdir --parents "$MOUNT/etc/mkinitcpio.conf.d"
cat <<EOF >"$MOUNT/etc/mkinitcpio.conf.d/custom.conf"
MODULES=(btrfs)
HOOKS=(systemd autodetect microcode modconf keyboard block)
EOF

echo "### UKI CONFIG" >&2
mkdir --parents "$MOUNT/etc/mkinitcpio.d"
mkdir --parents "$MOUNT/$ESP_DIR/EFI/Linux/"
cat <<EOF >"$MOUNT/etc/mkinitcpio.d/linux.preset"
PRESETS=('default')
default_kver="/boot/vmlinuz-linux"
default_uki="/$ESP_DIR/EFI/Linux/arch.efi"
default_options="--splash /usr/share/systemd/bootctl/splash-arch.bmp -S autodetect"
EOF

echo "### PACSTRAP" >&2
pacstrap -cGM "$MOUNT" "${PACKAGES[@]}"
sed -i "s/ -S autodetect//" "$MOUNT/etc/mkinitcpio.d/linux.preset"

echo "### BOOTLOADER INSTALL" >&2
bootctl install --root "$MOUNT" --no-variables

echo "### FIRSTBOOT SETTINGS" >&2
systemd-firstboot \
    --root="$MOUNT" \
    --force \
    --keymap="$KEYMAP" \
    --locale="$LOCALE" \
    --hostname="$HOSTNAME" \
    --timezone="$TIMEZONE" \
    --root-shell=/usr/bin/zsh \
    ;

echo "### NETWORK SETTINGS" >&2
ln -sf /run/systemd/resolve/stub-resolv.conf "$MOUNT/etc/resolv.conf"
cat <<EOF >"$MOUNT/etc/systemd/network/99-ethernet.network"
[Match]
Name=en*
Type=ether

[Network]
DHCP=yes
EOF

echo "### CLOUD IMAGE SETTINGS" >&2
# https://systemd.io/BUILDING_IMAGES/
rm -f "$MOUNT/etc/machine-id"
rm -f "$MOUNT/var/lib/systemd/random-seed"
rm -f "$MOUNT/$ESP_DIR/loader/random-seed"
# Use systemd-repart to grow the root partition
mkdir --parents "$MOUNT/etc/repart.d"
cat <<EOF >"$MOUNT/etc/repart.d/root.conf"
[Partition]
Type=root
EOF
# Pacman Keyring Initialization
cat <<EOF >"$MOUNT/etc/systemd/system/pacman-init.service"
[Unit]
Description=Pacman Keyring Initialization
After=systemd-growfs-root.service
Before=cloud-final.service
ConditionFirstBoot=yes

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/pacman-key --init
ExecStart=/usr/bin/pacman-key --populate

[Install]
WantedBy=multi-user.target
EOF
# Cloud Init Settings
cat <<EOF >"$MOUNT/etc/cloud/cloud.cfg.d/custom.cfg"
system_info:
  default_user:
    shell: /usr/bin/zsh
    gecos:
growpart:
  mode: off
resize_rootfs: false
ssh_deletekeys: false
ssh_genkeytypes: []
disable_root: true
disable_root_opts: "#"
EOF
mkdir --parents "$MOUNT/etc/systemd/system/getty@.service.d"
cat <<EOF >"$MOUNT/etc/systemd/system/getty@.service.d/autologin.conf"
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --autologin root --noclear %I $TERM
EOF

echo "### MISC SETTINGS" >&2
# Pacman config
sed -i 's/^#Color/Color/' "$MOUNT/etc/pacman.conf"
sed -i 's/^#ParallelDownloads/ParallelDownloads/' "$MOUNT/etc/pacman.conf"
sed -i 's/^#VerbosePkgLists/VerbosePkgLists/' "$MOUNT/etc/pacman.conf"
# Mirror list
cat <<EOF >"$MOUNT/etc/pacman.d/mirrorlist"
Server = https://geo.mirror.pkgbuild.com/\$repo/os/\$arch
EOF
# Disable SSH password and root login
cat <<EOF >"$MOUNT/etc/ssh/sshd_config.d/custom.conf"
PermitRootLogin no
PasswordAuthentication no
EOF
# ZSH plugins
cat <<EOF >>"$MOUNT/etc/zsh/zshrc"
source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
source <(fzf --zsh)
EOF
# Neovim Symlinks
ln -s /usr/bin/nvim "$MOUNT/usr/local/bin/vim"
ln -s /usr/bin/nvim "$MOUNT/usr/local/bin/vi"

echo "### ENABLE UNITS" >&2
systemctl --root="$MOUNT" enable "${UNITS_ENABLE[@]}"

echo "### MASK UNITS" >&2
systemctl --root="$MOUNT" mask "${UNITS_MASK[@]}"

echo "### CLEANUP" >&2
sync -f "$MOUNT/etc/os-release"
fstrim --verbose "$MOUNT/$ESP_DIR"
fstrim --verbose "$MOUNT"
cleanup

echo "### CREATE QCOW2" >&2
qemu-img convert -f raw -O qcow2 "$IMG_FILE" "$QCOW_FILE"

echo "### FINISHED WITHOUT ERRORS" >&2
