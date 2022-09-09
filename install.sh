#!/usr/bin/env sh

set -o errexit -o nounset

WORKDIR=/mnt
USERNAME="null"

# Connect to wifi
# iwctl
# > station wlan0 get-networks
# > station wlan0 connect openwrt
# > exit

# Grab the last script
# cd /tmp
# curl -sSL https://transfer.sh/ID/install.sh -o install.sh
# chmod 700 install.sh
# install.sh -d /dev/<DISK>

echo "A script to install Archlinux."

die() { echo "$1"; exit 1; }

in_chroot() {
  chroot "$WORKDIR" /bin/bash -c "source /etc/profile && $1"
}

start_service() {
  src=/usr/lib/systemd/system/"$1"
  dest=/etc/systemd/system/multi-user.target.wants/
  [ -f "$WORKDIR$src" ] || die "Service no found, no path $WORKDIR$src exist."
  in_chroot "ln -sf $src $dest"
}

usage() {
  printf "\\nUsage:\\n"
  printf "%s\\t%s\\n", "-d, --disk PATH_DISK" "Path of the disk to use."
  printf "%s\\t%s\\n", "-u, --username NAME" "Create a new user NAME."
  printf "\\n"
}

no_args() {
  if [ "$#" -eq 0 ] ; then
    printf "\\n%s\\n" "$0: Argument required"
    usage
    exit 1
  fi
}

options() {
  no_args "$@"
  while [ "$#" -gt 0 ] ; do
    case "$1" in
      -d | --disk) DISK="$2" ; shift ; shift ;;
      -u | --username) USERNAME="$2" ; shift ; shift ;;
      *)
        printf "\\n%s\\n" "$0: Invalid argument $1"
        exit 1
        ;;
    esac
  done
}

to_transfer() {
  echo "Uploading to transfer.sh..."
  curl --upload-file ./install.sh https://transfer.sh/install-arch.sh
}

time_date_ctl() {
  echo "Updating time..."
  timedatectl set-ntp true
}

clean_disk() {
  echo "Cleaning disk $DISK..."
  sgdisk --zap-all "$DISK"
  swapoff --all
}

partition_disk() {
  echo "Partition disk $DISK using sgdisk..."
  sgdisk -n1:1M:+300M -t1:EF00 "$DISK" # UEFI
  sgdisk -n2:0:-4G -t2:8300 "$DISK" # Swap
  sgdisk -n3:0:0 -t3:8300 "$DISK" # System
}

format_partition() {
  echo "Formatting disk $DISK..."
  mkfs.fat -F32 "$DISK"1
  mkfs.ext4 -F "$DISK"2
  mkswap -f "$DISK"3
}

mount_partition() {
  echo "Mounting partition..."
  mount "$DISK"2 "$WORKDIR"
  mount --mkdir "$DISK"1 "$WORKDIR"/efi
  swapon "$DISK"3
}

arch_install() {
  echo "Installing Arch..."
  pacstrap /mnt base linux linux-firmware
  genfstab -U /mnt >> /mnt/etc/fstab
}

# https://wiki.archlinux.org/title/Chroot#Using_chroot
make_chroot() {
  echo "Preparing the system..."
  mount -t proc /proc "$WORKDIR"/proc/
  mount -t sysfs /sys "$WORKDIR"/sys/
  mount --rbind /dev "$WORKDIR"/dev/
  mount --rbind /run "$WORKDIR"/run/
  mount --rbind /sys/firmware/efi/efivars "$WORKDIR"/sys/firmware/efi/efivars/
  cp /etc/resolv.conf "$WORKDIR"/etc/resolv.conf
}

configure() {
  echo "Configuring the system..."

  in_chroot "ln -sf /usr/share/zoneinfo/UTC /etc/localtime"
  in_chroot "hwclock --systohc"
  echo "en_US.UTF-8 UTF-8" > "$WORKDIR"/etc/locale.gen
  in_chroot "locale-gen"
  echo "LANG=en_US.UTF-8" > "$WORKDIR"/etc/locale.conf
  echo "KEYMAP=fr" > "$WORKDIR"/etc/vconsole.conf

  cat > "$WORKDIR"/etc/systemd/network/50-dhcp.network << EOF
[Match]
Name=en*
Name=wl*
[Network]
DHCP=yes
EOF

  cat > "$WORKDIR"/etc/systemd/resolved.conf << EOF
[Resolve]
DNS=127.0.0.1
FallbackDNS=9.9.9.9#dns.quad9.net
EOF

  start_service systemd-networkd.service
  start_service systemd-resolved.service
}

last_tools() {
  echo "Installing last tools..."
  in_chroot "pacman -S --noconfirm vim iwd cryptsetup"

  # Copying credential of connected network
  [ -d /var/lib/iwd ] && cp -a /var/lib/iwd "$WORKDIR"/var/lib/iwd

  start_service iwd.service
}

install_boot_loader() {
  in_chroot "grub-install --target=x86_64-efi --efi-directory=/efi \
    --bootloader-id=GRUB --recheck --no-floppy"
}

grub_install() {
  echo "Installing Grub..."
  in_chroot "pacman -S --noconfirm grub efibootmgr"
  install_boot_loader || install_boot_loader

  in_chroot "grub-mkconfig -o /boot/grub/grub.cfg"
}

root_password() {
  echo "Password for root..."
  in_chroot "passwd"
}

new_user() {
  echo "Creating a new user $USERNAME..."
  in_chroot "pacman -S --noconfirm zsh chezmoi sudo git"
  in_chroot "useradd -m -G users,wheel,audio,video -s /bin/zsh $USERNAME"
  echo "$USERNAME ALL=(ALL) ALL" > "$WORKDIR/etc/sudoers.d/$USERNAME"
  touch "$WORKDIR/home/$USERNAME/.zshrc"
  in_chroot "passwd $USERNAME"
}

main() {
  options "$@"
  [ -n "$DISK" ] && {
    [ -b "$DISK" ] || die "No path $DISK"

    echo "Using disk $DISK"
    time_date_ctl
    clean_disk
    partition_disk
    format_partition
    mount_partition
    arch_install
    make_chroot
    configure
    last_tools
    grub_install
    root_password
    [ "$USERNAME" == "null" ] || new_user
  }
  to_transfer
}

main "$@"
