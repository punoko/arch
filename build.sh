#!/bin/bash

echo "===== pacman ====="
pacman -Syu --noconfirm arch-install-scripts btrfs-progs

echo "===== truncate ====="
IMAGE="/image.img"
MOUNT="/mnt"
truncate -s 2G ${IMAGE}

echo "===== losetup ====="
LOOPDEV=$(losetup --find --partscan --show ${IMAGE})

echo "===== mkfs ====="
mkfs.btrfs "${LOOPDEV}"

echo "===== mount ====="
mount -o autodefrag,compress,noatime "${LOOPDEV}" "${MOUNT}"

echo "===== pacstrap ====="
pacstrap -cGM "${MOUNT}" base linux grub cloud-init cloud-guest-utils openssh sudo zsh

echo "===== grub ====="
arch-chroot "${MOUNT}" /usr/bin/grub-install "${LOOPDEV}"
arch-chroot "${MOUNT}" /usr/bin/grub-mkconfig -o /boot/grub/grub.cfg

# #add this to cloud init config :
# bootcmd:
# - [ cloud-init-per, instance, pacman-key-init, /usr/bin/pacman-key, --init ]
# - [ cloud-init-per, instance, pacman-key-populate, /usr/bin/pacman-key, --populate ]
