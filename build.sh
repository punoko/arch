#!/bin/bash

IMAGE="image.img"
OUTPUT="arch.qcow2"
MOUNT="/mnt"
PACKAGES=(base btrfs-progs cloud-guest-utils cloud-init grub linux openssh reflector sudo zsh)
SERVICES=(sshd systemd-networkd systemd-resolved systemd-timesyncd systemd-time-wait-sync)

echo -e "===== pacman ====="
pacman -Syu --noconfirm --quiet arch-install-scripts btrfs-progs qemu-img

echo "===== truncate ====="
truncate -s 2G ${IMAGE}

echo "===== losetup ====="
LOOPDEV=$(losetup --find --partscan --show ${IMAGE})

#LOLOLOL
sleep 5

echo "===== mkfs ====="
mkfs.btrfs "${LOOPDEV}"

echo "===== mount ====="
mount -o compress=zstd,noatime "${LOOPDEV}" "${MOUNT}"

echo "===== pacstrap ====="
pacstrap -cGM "${MOUNT}" "${PACKAGES[@]}"

echo "===== grub ====="
arch-chroot "${MOUNT}" /usr/bin/grub-install "${LOOPDEV}"
sed -i 's/^GRUB_TIMEOUT=.*$/GRUB_TIMEOUT=1/' "${MOUNT}/etc/default/grub"
sed -i 's/^GRUB_CMDLINE_LINUX=.*$/GRUB_CMDLINE_LINUX="net.ifnames=0"/' "${MOUNT}/etc/default/grub"
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"rootflags=compress=zstd console=tty0 console=ttyS0,115200\"/' "${MOUNT}/etc/default/grub"
echo 'GRUB_TERMINAL="serial console"' >>"${MOUNT}/etc/default/grub"
echo 'GRUB_SERIAL_COMMAND="serial --speed=115200"' >>"${MOUNT}/etc/default/grub"
arch-chroot "${MOUNT}" /usr/bin/grub-mkconfig -o /boot/grub/grub.cfg

# Setup pacman keyring initialization
cat <<EOF >"${MOUNT}/etc/cloud/cloud.cfg.d/pacman-key.cfg"
bootcmd:
- [ cloud-init-per, instance, pacman-key-init, /usr/bin/pacman-key, --init ]
- [ cloud-init-per, instance, pacman-key-populate, /usr/bin/pacman-key, --populate ]
EOF

# Setup mirror list to Geo IP mirrors
cat <<EOF >"${MOUNT}/etc/pacman.d/mirrorlist"
Server = https://geo.mirror.pkgbuild.com/\$repo/os/\$arch
Server = https://mirror.rackspace.com/archlinux/\$repo/os/\$arch
Server = https://mirror.leaseweb.net/archlinux/\$repo/os/\$arch
EOF

# Enabling important services
arch-chroot "${MOUNT}" /usr/bin/systemctl enable "${SERVICES[@]}"

cp --reflink=always -a "${MOUNT}/boot/"{initramfs-linux-fallback.img,initramfs-linux.img}
sync -f "$MOUNT/etc/os-release"
fstrim --verbose "${MOUNT}"

umount --recursive "${MOUNT}"
losetup -d "${LOOPDEV}"

qemu-img convert -f raw -O qcow2 "${IMAGE}" "${OUTPUT}"
rm "${IMAGE}"


















## OLD ATTEMPT

# #!/usr/bin/zsh

# IMAGE="image.img"
# IMAGE_SIZE="4G"
# MOUNT="/mnt"
# TYPE="BIOS" # pick BIOS or UEFI
# PACKAGES=(base linux sudo openssh btrfs-progs reflector)
# PACKAGES+=(cloud-init cloud-guest-utils)

# function clean() {
# 	log "removing existing image"
# 	umount -l $MOUNT
# 	losetup -D
# 	rm $IMAGE
# }

# function log() {
# 	print -P "%B%F{yellow}[$1]%f%b"
# }

# function image() {
# 	if [[ $TYPE == BIOS ]] ; then
# 		PART_SIZE="1M"
# 		PART_GUID="21686148-6449-6E6F-744E-656564454649"
# 		PACKAGES+=(grub)
# 	elif [[ $TYPE == UEFI ]] ; then
# 		echo "UEFI not supported yet"
# 		exit 1
# 		PART_SIZE="200M"
# 		PART_GUID="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
# 	else
# 		echo "Incorrect BIOS/UEFI setting"
# 		exit 1
# 	fi
# 	log "creating image"
# 	truncate -s "$IMAGE_SIZE" "$IMAGE"
# 	log "writing gpt partition table"
# 	echo -e "label: gpt\n,$PART_SIZE,$PART_GUID\n," | sfdisk "$IMAGE"
# 	log "setting up loop device"
# 	LOOP_DEV=$(losetup --find --partscan --show "$IMAGE") && print $LOOP_DEV
# 	log "formatting btrfs partition"
# 	mkfs.btrfs ${LOOP_DEV}p2
# 	log "mounting on $MOUNT"
# 	mount -o compress-force=zstd ${LOOP_DEV}p2 "$MOUNT"
# }

# function bootstrap() {
# 	pacstrap -cKM "$MOUNT" ${PACKAGES[@]}
# 	sync -f "$MOUNT"/etc/os-release
# 	cp --reflink=always -a "${MOUNT}/boot/"{initramfs-linux-fallback.img,initramfs-linux.img}
# 	fstrim --verbose "${MOUNT}"

# }

# function main() {
# 	[[ -f $IMAGE ]] && clean
# 	#image
# 	#bootstrap
# }

# main
