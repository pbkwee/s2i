# System recovery before a distribution upgrade

Use `--scope system` to save system files before an upgrade.
Use the same scope to restore them if the upgrade fails.
Both scripts must be current versions with this scope.

| Scope | Backup | Restore |
| --- | --- | --- |
| `full` (default) | Whole-server image with the normal exclusions | Replace the server image; retain selected destination network, SSH and boot files |
| `system` | Complete system trees and selected package records | Replace those trees, delete newer files there, and keep omitted customer data; restore original network, SSH and boot files |

The scope selects which files are saved and replaced.
Both scopes use tar archives and rsync. `system` includes installed software, not only the minimum base packages.

This is a file-level recovery archive. It is smaller than a whole-server image.
It does not replace a complete VM snapshot or a separate database backup.

## What is saved and restored

| Paths | Purpose |
| --- | --- |
| `/etc` | Configuration, accounts, service setup, networking and SSH settings |
| `/usr`, `/bin`, `/sbin`, `/lib`, `/lib32`, `/lib64`, `/libx32` | Complete program and library trees, including `/usr/local` and kernel headers |
| `/boot` | Kernel, initramfs and boot configuration files |
| `/opt` | Complete vendor application tree, including any data stored there |
| `/var/lib/dpkg`, `/var/lib/apt`, `/var/lib/ucf` | Debian/Ubuntu package database, APT state and configuration registry |
| `/var/lib/rpm`, `/var/lib/yum`, `/var/lib/dnf`, `/var/lib/alternatives` | RPM, Yum and DNF state for Red Hat, CentOS and similar systems; newer RPM/DNF5 databases under `/usr/lib/sysimage` are already saved with `/usr` |
| `/var/lib/pkgtools`, `/var/lib/slackpkg`, `/var/log/packages`, `/var/log/scripts`, `/var/log/setup`, `/var/log/removed_packages`, `/var/log/removed_scripts`, `/var/log/pkgtools` | Slackware package records and history, including older layouts |
| `/var/db/pkg`, `/var/lib/portage` | Gentoo installed-package records and Portage state |
| `/var/lib/apk` | Legacy Alpine package state; current APK records under `/lib/apk/db` and `/etc/apk` are already saved with the complete trees |
| `/var/lib/systemd/deb-systemd-helper-enabled`, `/var/lib/systemd/deb-systemd-helper-masked`, `/var/lib/initramfs-tools`, `/var/lib/grub`, `/var/lib/pam` | Selected system and package-helper state |
| `/var/cache/debconf`, `/var/spool/cron` | Package configuration answers and user crontabs |

Optional paths that are absent at backup time are recorded as absent.
The restore removes paths introduced there after the backup.
It also deletes newer files inside every saved tree.
For example, `/bin` is restored as a complete tree; new binaries are removed.
Standard links between `/bin`, `/sbin`, library paths and `/usr` are restored too.
Checksums detect changed file contents even when file sizes and timestamps match.

Other paths are outside the backup and restore scope. These include `/home`, `/root`,
`/srv`, `/var/www`, `/var/mail`, `/var/vmail`, normal logs, systemd coredumps, database files and container storage
under `/var/lib`. The restore leaves these omitted paths alone.
Slackware package records under `/var/log` are included.
Data under `/usr/local` or `/opt` is included because these entire trees are restored.
Review those locations before using this mode.

The archive records its scope. The restore checks that record before copying.
A recovery archive cannot be passed to the normal whole-server restore by mistake.
Custom `--files`, nonempty `exclude.log` and `--pipe` are not supported in this mode.
They could produce incomplete system trees. Store the archive outside the saved trees.

## Supported layouts and tools

The scripts recognize typical dpkg, RPM, pkgtools, Portage and APK database locations.
No package-manager command runs as part of system backup or restore.
Custom package database locations need a separate review.
Gentoo repositories under `/var/db/repos` and package caches under `/var/cache` are omitted.
An older Gentoo repository under `/usr/portage` is included because the whole `/usr` tree is saved.

Run the scripts in Bash. System scope requires GNU tar, coreutils and rsync.
Stock Alpine BusyBox tools alone are insufficient. Install the required tools before making the backup.
The existing network and connection checks also need compatible `ip`/`ifconfig` and `netstat` tools.
ACLs and extended attributes require supporting tar, rsync and filesystems.
On SELinux systems, check restored labels before booting; this mode does not perform a relabel.

The path list follows the [RPM relocation](https://fedoraproject.org/wiki/Changes/RelocateRPMToUsr),
[DNF state paths](https://dnf.readthedocs.io/en/latest/conf_ref.html),
[Slackware package layout](https://docs.slackware.com/howtos:slackware_admin:querying_installed_packages),
[Gentoo directories](https://wiki.gentoo.org/wiki/Directories) and
[APK database specification](https://wiki.alpinelinux.org/wiki/Apk_spec).

## Create the backup

Run as root. First stop package installs, upgrades and jobs that change system files.
Do not run `distrorejuve` until the backup succeeds.

```bash
bash ./s2i-create.sh --scope system \
  --outputdir "/root/s2i.pre-upgrade-$(date +%Y%m%d-%H%M%S)" \
  --outputfile system-recovery.tar.gz \
  --encrypt none
```

`--root /mnt/vm` can instead capture a mounted system.
Mount its separate system filesystems, including `/usr`, `/boot` and EFI storage,
if present. Otherwise those files are not in the backup.
Existing encryption options and `--size` remain available.
Use a new output directory if you want to change an existing recovery encryption password.
Encrypted archives must be decrypted before passing the resulting `.gz` file to restore.
A recovery archive is published only after tar and encryption succeed.
A failed attempt leaves any previous archive unchanged.

## Prepare for restore

An offline mounted system is preferred. Mount its separate system filesystems first.
A mounted path must not be a bind mount of the running root or a running system tree.
Also stop containers, chroots or other workloads that use the target filesystem.

A live restore is allowed when an offline system is unavailable.
Keep an existing SSH session open. Have console access available if possible.
Stop unnecessary services and writers before starting:

- Web servers: Apache, NGINX or Caddy; PHP-FPM pools and application workers.
- Databases and caches: MySQL/MariaDB, PostgreSQL, MongoDB or Redis.
- Mail services: Postfix/Exim, Dovecot and mail-processing workers.
- Scheduled work: cron, atd, backup jobs and application schedulers.
- Package-update jobs: unattended upgrades, APT timers, Yum/DNF automatic updates and other package-manager jobs. Wait for current package operations to finish.
- Containers and guest VMs that could keep running programs from the restored filesystem.

Stop only services installed on that VM. For example, on a systemd host:

```bash
systemctl stop apache2
systemctl stop mariadb
systemctl stop postfix
systemctl stop cron
```

On an older SysV host, use the installed init script instead:

```bash
/etc/init.d/apache2 stop
/etc/init.d/mysql stop
/etc/init.d/postfix stop
/etc/init.d/cron stop
```

Keep `ssh`/`sshd`, networking, DHCP, DNS needed by the connection, and init/systemd running.
Do not restart SSH or networking during the copy.
Recovery mode does not stop services automatically and does not reboot the VM.

## Restore

To restore an offline mounted system:

```bash
bash ./s2i-restore.sh --scope system \
  --archivegz /root/s2i.pre-upgrade/system-recovery.tar.gz \
  --restoretopath /mnt/vm
```

Use the actual archive path printed by the create command.
To restore the running system, use the default destination `/`:

```bash
bash ./s2i-restore.sh --scope system \
  --archivegz /root/s2i.pre-upgrade/system-recovery.tar.gz
```

The existing hostname, connection and free-space checks still apply.
Their existing `--ignorehostname`, `--ignoreports` and `--ignorespace` options remain available
when the operator has checked the target and the reason for the warning.

Unlike a clone restore, system recovery restores the original `/etc` and `/boot` files.
It does not retain the newer network configuration or rewrite IP addresses.
SSH configuration can therefore return to its old listening port.
Check network, SSH and boot settings before rebooting.

After a successful live restore, reboot so processes load the restored programs and libraries.
A running process can still use the previous libraries until it exits.
If the restore fails, repair or retry it before rebooting. A partial copy is not a successful rollback.

## Limits

Package and service upgrades can change database formats or other application data.
Those data files are outside this archive. Restore compatible data from a separate backup
before starting an older database or application version. If an older database starts at boot,
restore compatible data or disable that service before rebooting.

Restoring `/boot` files does not restore the partition table, disk boot sectors or EFI variables.
Bootloader installation may need repair from a console or rescue system.
Keep the same VM disk layout and mount the correct filesystems.

Paths outside the fixed scope may also contain package-managed files or service state.
Review custom layouts separately. This mode is not a complete machine rollback.
