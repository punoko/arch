#!/bin/bash
set -euo pipefail

MOUNT="$(mktemp --directory)"

IMG_SIZE="2G"
IMG_FILE="image.img"
QCOW_FILE="image.qcow2"

ROOT_LABEL="Arch Linux"
ROOT_SUBVOL="@arch"
ROOT_FLAGS="compress=zstd,noatime"
ROOT_GPT_TYPE="4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709" # Linux root (x86-64)

ESP_LABEL="ESP"
ESP_SIZE="100M"
ESP_DIR="boot"
ESP_GPT_TYPE="C12A7328-F81F-11D2-BA4B-00A0C93EC93B" # EFI System

PACKAGES=(
    base
    btrfs-progs
    cloud-init
    cloud-guest-utils
    grml-zsh-config
    iptables-nft
    linux
    man-db
    neovim
    openssh
    pacman-contrib
    reflector
    sbctl
    sudo
    zsh
)
SERVICES=(
    cloud-init
    cloud-init-local
    cloud-config
    cloud-final
    pacman-init
    secure-boot-init
    sshd
    systemd-boot-update
    systemd-networkd
    systemd-resolved
    systemd-timesyncd
    systemd-time-wait-sync

    paccache.timer
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

mkfs.vfat -F 32 -n "${ESP_LABEL}" "${LOOPDEV}p1"
mkfs.btrfs -L "${ROOT_LABEL}" "${LOOPDEV}p2"

# Image mount
mount "${LOOPDEV}p2" "${MOUNT}"
btrfs subvolume create "${MOUNT}/${ROOT_SUBVOL}"
btrfs subvolume set-default "${MOUNT}/${ROOT_SUBVOL}"
umount "${MOUNT}"
mount -o "${ROOT_FLAGS}" "${LOOPDEV}p2" "${MOUNT}"
mkdir "${MOUNT}/${ESP_DIR}"
mount "${LOOPDEV}p1" "${MOUNT}/${ESP_DIR}"

# Install
pacstrap -cGM "${MOUNT}" "${PACKAGES[@]}"

# Setting fstab is unnecessary for the following reasons:
#   root partition is automatically mounted with its GPT partition type
#   root partition grows thanks to GPT flag 59 set with sfdisk earlier https://github.com/systemd/systemd/pull/30030
#   subvol is implicit from `btrfs subvolume set-default`
#   compress & noatime are set by cmdline
# Removing `rw` breaks boot
#echo "UUID=$(blkid -s UUID -o value ${LOOPDEV}p2) / btrfs rw,x-systemd.growfs,${ROOT_FLAGS} 0 0" >>"${MOUNT}/etc/fstab"
#CMDLINE="root=UUID=$(blkid -s UUID -o value ${LOOPDEV}p2) rootflags=${ROOT_FLAGS} rw"
CMDLINE="rootflags=${ROOT_FLAGS} rw"

# /etc/kernel/cmdline is only necessary when using UKI instead of type 1 drop-in bootloader entry
arch-chroot "${MOUNT}" systemd-firstboot \
    --force \
    --keymap=us \
    --locale=C.UTF-8 \
    --timezone=UTC \
    --root-shell=/usr/bin/zsh \
    ;
    # --kernel-command-line="${CMDLINE}" \

# Bootloader
arch-chroot "${MOUNT}" bootctl install --no-variables
sed -i "s/^MODULES.*$/MODULES=(btrfs)/" "${MOUNT}/etc/mkinitcpio.conf"
sed -i "s/^HOOKS.*$/HOOKS=(systemd autodetect modconf block keyboard)/" "${MOUNT}/etc/mkinitcpio.conf"
arch-chroot "${MOUNT}" mkinitcpio --allpresets
mv "${MOUNT}/${ESP_DIR}/"{initramfs-linux-fallback.img,initramfs-linux.img}
sed -i "s/^PRESETS.*$/PRESETS=('default')/" "${MOUNT}/etc/mkinitcpio.d/linux.preset"
cat <<EOF >"${MOUNT}/${ESP_DIR}/loader/entries/arch.conf"
title    Arch Linux
sort-key arch
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options ${CMDLINE}
EOF

# https://systemd.io/BUILDING_IMAGES/
rm -f "$MOUNT/etc/machine-id"
rm -f "$MOUNT/var/lib/systemd/random-seed"
rm -f "$MOUNT/$ESP_DIR/loader/random-seed"

# Use systemd-repart to grow the root partition
mkdir "$MOUNT/etc/repart.d"
cat <<EOF >"${MOUNT}/etc/repart.d/root.conf"
[Partition]
Type=root
EOF

# Basic Network DHCP Setup
cat <<EOF >"${MOUNT}/etc/systemd/network/99-ethernet.network"
[Match]
Name=en*
Type=ether

[Network]
DHCP=yes
EOF

# Pacman Keyring Initialization
cat <<EOF >"${MOUNT}/etc/systemd/system/pacman-init.service"
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

# Secure Boot Initialization
cat <<EOF >"${MOUNT}/etc/systemd/system/secure-boot-init.service"
[Unit]
Description=Secure Boot Initialization
After=systemd-growfs-root.service
ConditionFirstBoot=yes

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/sbctl create-keys
ExecStart=/usr/bin/sbctl sign -s /boot/vmlinuz-linux
ExecStart=/usr/bin/sbctl sign -s /boot/EFI/BOOT/BOOTX64.EFI
ExecStart=/usr/bin/sbctl sign -s /boot/EFI/systemd/systemd-bootx64.efi
ExecStart=/usr/bin/sbctl sign -s /usr/lib/systemd/boot/efi/systemd-bootx64.efi
ExecStart=/usr/bin/sbctl enroll-keys --yes-this-might-brick-my-machine

[Install]
WantedBy=multi-user.target
EOF

# Cloud Init Settings
cat <<EOF >"${MOUNT}/etc/cloud/cloud.cfg.d/custom.cfg"
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

# Neovim Symlinks
ln -sf /usr/bin/nvim "${MOUNT}/usr/local/bin/vim"
ln -sf /usr/bin/nvim "${MOUNT}/usr/local/bin/vi"

# Services
arch-chroot "${MOUNT}" /usr/bin/systemctl enable "${SERVICES[@]}"
arch-chroot "${MOUNT}" /usr/bin/systemctl mask systemd-homed systemd-userdbd
ln -sf /run/systemd/resolve/stub-resolv.conf "${MOUNT}/etc/resolv.conf"

# Pacman config
sed -i 's/^#Color/Color/' "${MOUNT}/etc/pacman.conf"
sed -i 's/^#ParallelDownloads/ParallelDownloads/' "${MOUNT}/etc/pacman.conf"

# Mirror list
cat <<EOF >"${MOUNT}/etc/pacman.d/mirrorlist"
Server = https://geo.mirror.pkgbuild.com/\$repo/os/\$arch
EOF

# Disable SSH password and root login
cat <<EOF >"${MOUNT}/etc/ssh/sshd_config.d/custom.conf"
PermitRootLogin no
PasswordAuthentication no
EOF

# Image cleanup
sync -f "$MOUNT/etc/os-release"
fstrim --verbose "${MOUNT}/${ESP_DIR}"
fstrim --verbose "${MOUNT}"
cleanup
qemu-img convert -f raw -O qcow2 "${IMG_FILE}" "${QCOW_FILE}"
