#!/bin/bash

pacman -Syu --noconfirm arch-install-scripts neofetch
neofetch

# IMAGE=image.img
# truncate -s 2G ${IMAGE}
# LOOPDEV=$(losetup --find --partscan --show ${IMAGE})
# mkfs.btrfs "${LOOPDEV}"
# mount -o autodefrag,compress,noatime "${LOOPDEV}" /mnt
# pacstrap -cGM /mnt base linux grub cloud-init cloud-guest-utils zsh sudo openssh 

# #arch-chroot
# arch-chroot "${MOUNT}" /usr/bin/grub-install "${LOOPDEV}"
# arch-chroot "${MOUNT}" /usr/bin/grub-mkconfig -o /boot/grub/grub.cfg

# #add this to cloud init config :
# bootcmd:
# - [ cloud-init-per, instance, pacman-key-init, /usr/bin/pacman-key, --init ]
# - [ cloud-init-per, instance, pacman-key-populate, /usr/bin/pacman-key, --populate ]
