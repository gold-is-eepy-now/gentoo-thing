# gentoo-thing

`gentoo-install.sh` is a guided Gentoo Linux installer inspired by the interactive flow of tools like `archinstall`.

## Features
- Interactive prompts for disk, hostname, locale, timezone, users, and passwords.
- Supports UEFI and BIOS boot mode detection.
- Optional automatic repartitioning and swap setup.
- Stage3 download/bootstrap, chroot setup, kernel install, and GRUB configuration.
- Dry-run mode enabled by default to preview all destructive commands.

## Usage

> **Warning:** This script can erase disks and should only be run from a live environment where you fully understand the target disk selection.

```bash
sudo ./gentoo-install.sh
```

Set **Dry run mode?** to `no` when you are ready for real execution.
