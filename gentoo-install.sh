#!/usr/bin/env bash
set -euo pipefail

# gentoo-install.sh
# Guided Gentoo installer inspired by archinstall-style prompts.

DRY_RUN=1
MNT="/mnt/gentoo"
SWAP_SIZE_GB=""
DISK=""
HOSTNAME="gentoo"
TIMEZONE="UTC"
LOCALE="en_US.UTF-8"
KEYMAP="us"
ROOT_PASS=""
USERNAME=""
USER_PASS=""
EFI_PART=""
ROOT_PART=""
SWAP_PART=""
BOOT_MODE=""

log() { printf "\n[+] %s\n" "$*"; }
warn() { printf "\n[!] %s\n" "$*"; }
die() { printf "\n[x] %s\n" "$*" >&2; exit 1; }

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf "[dry-run] %s\n" "$*"
  else
    printf "[run] %s\n" "$*"
    eval "$*"
  fi
}

ask() {
  local prompt="$1" default="${2:-}" out
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " out
    printf "%s" "${out:-$default}"
  else
    read -r -p "$prompt: " out
    printf "%s" "$out"
  fi
}

ask_secret() {
  local prompt="$1" out
  read -r -s -p "$prompt: " out
  echo
  printf "%s" "$out"
}

require_root() {
  [[ "$EUID" -eq 0 ]] || die "Run as root."
}

detect_boot_mode() {
  if [[ -d /sys/firmware/efi ]]; then
    BOOT_MODE="uefi"
  else
    BOOT_MODE="bios"
  fi
}

show_disks() {
  log "Available disks"
  lsblk -dpno NAME,SIZE,MODEL | sed 's/^/  /'
}

partition_disk() {
  log "Partitioning $DISK"
  if [[ "$BOOT_MODE" == "uefi" ]]; then
    run "parted -s $DISK mklabel gpt"
    run "parted -s $DISK mkpart ESP fat32 1MiB 513MiB"
    run "parted -s $DISK set 1 esp on"
    if [[ -n "$SWAP_SIZE_GB" && "$SWAP_SIZE_GB" != "0" ]]; then
      run "parted -s $DISK mkpart primary linux-swap 513MiB ${SWAP_SIZE_GB}GiB"
      run "parted -s $DISK mkpart primary ext4 ${SWAP_SIZE_GB}GiB 100%"
      EFI_PART="${DISK}1"; SWAP_PART="${DISK}2"; ROOT_PART="${DISK}3"
    else
      run "parted -s $DISK mkpart primary ext4 513MiB 100%"
      EFI_PART="${DISK}1"; ROOT_PART="${DISK}2"
    fi
  else
    run "parted -s $DISK mklabel msdos"
    if [[ -n "$SWAP_SIZE_GB" && "$SWAP_SIZE_GB" != "0" ]]; then
      run "parted -s $DISK mkpart primary linux-swap 1MiB ${SWAP_SIZE_GB}GiB"
      run "parted -s $DISK mkpart primary ext4 ${SWAP_SIZE_GB}GiB 100%"
      SWAP_PART="${DISK}1"; ROOT_PART="${DISK}2"
    else
      run "parted -s $DISK mkpart primary ext4 1MiB 100%"
      ROOT_PART="${DISK}1"
    fi
  fi
}

format_and_mount() {
  log "Formatting partitions"
  [[ -n "$ROOT_PART" ]] || die "ROOT_PART not set"
  run "mkfs.ext4 -F $ROOT_PART"
  if [[ -n "$EFI_PART" ]]; then
    run "mkfs.fat -F32 $EFI_PART"
  fi
  if [[ -n "$SWAP_PART" ]]; then
    run "mkswap $SWAP_PART"
    run "swapon $SWAP_PART"
  fi

  log "Mounting target"
  run "mkdir -p $MNT"
  run "mount $ROOT_PART $MNT"
  if [[ -n "$EFI_PART" ]]; then
    run "mkdir -p $MNT/boot"
    run "mount $EFI_PART $MNT/boot"
  fi
}

install_base() {
  log "Selecting stage3 and syncing Portage"
  run "mkdir -p $MNT"
  run "bash -c 'wget -O /tmp/latest-stage3.txt https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt'"
  run "bash -c 'STAGE3=$(awk \"!/^[#]/ {print \\\$1; exit}\" /tmp/latest-stage3.txt) && wget -P /tmp https://distfiles.gentoo.org/releases/amd64/autobuilds/$STAGE3'"
  run "bash -c 'STAGE3_FILE=$(basename $(awk \"!/^[#]/ {print \\\$1; exit}\" /tmp/latest-stage3.txt)) && tar xpvf /tmp/$STAGE3_FILE --xattrs-include=\"*.*\" --numeric-owner -C $MNT'"

  run "cp --dereference /etc/resolv.conf $MNT/etc/"
  run "mount --types proc /proc $MNT/proc"
  run "mount --rbind /sys $MNT/sys && mount --make-rslave $MNT/sys"
  run "mount --rbind /dev $MNT/dev && mount --make-rslave $MNT/dev"
}

configure_chroot() {
  log "Creating chroot setup script"
  cat > /tmp/gentoo-chroot-setup.sh <<CHROOT
#!/usr/bin/env bash
set -euo pipefail
source /etc/profile
export PS1="(chroot) \$PS1"

echo "$TIMEZONE" > /etc/timezone
emerge --config sys-libs/timezone-data

echo "$LOCALE UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set $LOCALE
env-update && source /etc/profile

echo "KEYMAP=\"$KEYMAP\"" > /etc/conf.d/keymaps
echo "$HOSTNAME" > /etc/hostname

echo "sys-kernel/gentoo-kernel-bin" >> /etc/portage/package.accept_keywords/install-kernel
emerge-webrsync
emerge --sync
emerge --quiet net-misc/dhcpcd sys-kernel/gentoo-kernel-bin sys-kernel/linux-firmware grub

if [[ "$BOOT_MODE" == "uefi" ]]; then
  emerge --quiet sys-boot/efibootmgr
  grub-install --target=x86_64-efi --efi-directory=/boot
else
  grub-install $DISK
fi

grub-mkconfig -o /boot/grub/grub.cfg

rc-update add dhcpcd default
rc-update add sshd default || true

echo "root:$ROOT_PASS" | chpasswd
if [[ -n "$USERNAME" ]]; then
  useradd -m -G wheel,audio,video -s /bin/bash "$USERNAME"
  echo "$USERNAME:$USER_PASS" | chpasswd
  sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
fi
CHROOT

  run "chmod +x /tmp/gentoo-chroot-setup.sh"
  run "cp /tmp/gentoo-chroot-setup.sh $MNT/root/"
  run "chroot $MNT /bin/bash /root/gentoo-chroot-setup.sh"
}

finish() {
  log "Installation complete"
  warn "Unmount and reboot when ready:"
  echo "  umount -lR $MNT"
  echo "  reboot"
}

main() {
  require_root
  detect_boot_mode

  log "Gentoo guided installer"
  echo "Boot mode detected: $BOOT_MODE"
  local dry
  dry=$(ask "Dry run mode? (yes/no)" "yes")
  [[ "$dry" =~ ^([nN]|no|NO)$ ]] && DRY_RUN=0

  show_disks
  DISK=$(ask "Target disk (e.g. /dev/sda)")
  [[ -b "$DISK" ]] || die "Disk not found: $DISK"

  local wipe
  wipe=$(ask "Wipe and repartition disk? (yes/no)" "yes")
  SWAP_SIZE_GB=$(ask "Swap end size in GiB (0 for no swap; e.g. 8)" "8")
  HOSTNAME=$(ask "Hostname" "$HOSTNAME")
  TIMEZONE=$(ask "Timezone (e.g. UTC, Europe/Berlin)" "$TIMEZONE")
  LOCALE=$(ask "Locale" "$LOCALE")
  KEYMAP=$(ask "Console keymap" "$KEYMAP")
  ROOT_PASS=$(ask_secret "Root password")
  USERNAME=$(ask "Optional username (blank to skip)" "")
  if [[ -n "$USERNAME" ]]; then
    USER_PASS=$(ask_secret "Password for $USERNAME")
  fi

  if [[ "$wipe" =~ ^([yY]|yes|YES)$ ]]; then
    partition_disk
  else
    ROOT_PART=$(ask "Root partition (e.g. ${DISK}2)")
    if [[ "$BOOT_MODE" == "uefi" ]]; then
      EFI_PART=$(ask "EFI partition (e.g. ${DISK}1)")
    fi
    local sw
    sw=$(ask "Swap partition (blank for none)" "")
    SWAP_PART="$sw"
  fi

  format_and_mount
  install_base
  configure_chroot
  finish
}

main "$@"
