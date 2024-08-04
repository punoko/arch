#!/usr/bin/env bash
set -euo pipefail

MOUNT="$(mktemp --directory)"

HOSTNAME="arch"
KEYMAP="us"
LOCALE="C.UTF-8"
TIMEZONE="UTC"

IMG_SIZE="2G"
IMG_FILE="image.img"
QCOW_FILE="image.qcow2"

ESP_LABEL="ESP"
ESP_SIZE="100M"
ESP_DIR="efi"
ESP_GPT_TYPE="C12A7328-F81F-11D2-BA4B-00A0C93EC93B" # EFI System

ROOT_LABEL="Arch Linux"
ROOT_SUBVOL="@arch"
ROOT_FLAGS="compress=zstd,noatime,subvol=$ROOT_SUBVOL"
ROOT_GPT_TYPE="4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709" # Linux root (x86-64)

PACKAGES=(
    base
    btrfs-progs
    cloud-init
    cloud-guest-utils
    fzf
    grml-zsh-config
    htop
    iptables-nft
    # linux
    man-db
    mkinitcpio
    neovim
    openssh
    pacman-contrib
    polkit
    reflector
    sudo
    systemd-ukify
    zsh
    zsh-autosuggestions
    zsh-completions
    zsh-syntax-highlighting
)
UNITS_ENABLE=(
    cloud-init
    cloud-init-local
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
UNITS_DISABLE=(
    systemd-userdbd.socket
)

# Cleanup
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

# Image setup
rm -f $IMG_FILE
truncate --size $IMG_SIZE $IMG_FILE

# Image format
sfdisk --label gpt $IMG_FILE <<EOF
type=$ESP_GPT_TYPE,name="$ESP_LABEL",size=$ESP_SIZE
type=$ROOT_GPT_TYPE,name="$ROOT_LABEL",attrs=59
EOF
LOOPDEV=$(losetup --find --partscan --show $IMG_FILE)
sleep 1

mkfs.vfat -F 32 -n "$ESP_LABEL" "$LOOPDEV"p1
mkfs.btrfs -L "$ROOT_LABEL" "$LOOPDEV"p2

# Image mount
mount "$LOOPDEV"p2 "$MOUNT"
btrfs subvolume create "$MOUNT/$ROOT_SUBVOL"
btrfs subvolume set-default "$MOUNT/$ROOT_SUBVOL"
umount "$MOUNT"
mount -o "$ROOT_FLAGS" "$LOOPDEV"p2 "$MOUNT"
mount --mkdir=700 "$LOOPDEV"p1 "$MOUNT/$ESP_DIR"

# Install
pacstrap -cGM "$MOUNT" "${PACKAGES[@]}"

# Setting fstab is unnecessary for the following reasons:
#   root partition is automatically mounted with its GPT partition type
#   root partition grows thanks to GPT flag 59 set with sfdisk earlier https://github.com/systemd/systemd/pull/30030
#   subvol is implicit from `btrfs subvolume set-default` and set with cmdline anyway
#   compress & noatime are set by cmdline
# Not specifying `rw` in cmdline breaks boot
CMDLINE="rootflags=$ROOT_FLAGS rw"
systemd-firstboot \
    --root="$MOUNT" \
    --force \
    --keymap="$KEYMAP" \
    --locale="$LOCALE" \
    --hostname="$HOSTNAME" \
    --timezone="$TIMEZONE" \
    --root-shell=/usr/bin/zsh \
    --kernel-command-line="$CMDLINE" \
    ;

# Bootloader
bootctl install --root "$MOUNT" --no-variables
cat <<EOF >"$MOUNT/etc/mkinitcpio.conf.d/custom.conf"
MODULES=(btrfs)
HOOKS=(systemd autodetect microcode modconf keyboard block)
EOF
cat <<EOF >"$MOUNT/etc/mkinitcpio.d/linux.preset"
PRESETS=('default')
default_kver="/boot/vmlinuz-linux"
default_uki="/$ESP_DIR/EFI/Linux/arch.efi"
default_options="--splash /usr/share/systemd/bootctl/splash-arch.bmp -S autodetect"
EOF

# Kernel
pacstrap -cGM "$MOUNT" linux
sed -i "s/ -S autodetect//" "$MOUNT/etc/mkinitcpio.d/linux.preset"

# https://systemd.io/BUILDING_IMAGES/
rm -f "$MOUNT/etc/machine-id"
rm -f "$MOUNT/var/lib/systemd/random-seed"
rm -f "$MOUNT/$ESP_DIR/loader/random-seed"

# Use systemd-repart to grow the root partition
mkdir "$MOUNT/etc/repart.d"
cat <<EOF >"$MOUNT/etc/repart.d/root.conf"
[Partition]
Type=root
EOF

# Basic Network DHCP Setup
cat <<EOF >"$MOUNT/etc/systemd/network/99-ethernet.network"
[Match]
Name=en*
Type=ether

[Network]
DHCP=yes
EOF
ln -sf /run/systemd/resolve/stub-resolv.conf "$MOUNT/etc/resolv.conf"

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

# Services
systemctl --root="$MOUNT" enable "${UNITS_ENABLE[@]}"
systemctl --root="$MOUNT" disable "${UNITS_DISABLE[@]}"

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
ln -sf /usr/bin/nvim "$MOUNT/usr/local/bin/vim"
ln -sf /usr/bin/nvim "$MOUNT/usr/local/bin/vi"

# Image cleanup
sync -f "$MOUNT/etc/os-release"
fstrim --verbose "$MOUNT/$ESP_DIR"
fstrim --verbose "$MOUNT"
cleanup
qemu-img convert -f raw -O qcow2 "$IMG_FILE" "$QCOW_FILE"
