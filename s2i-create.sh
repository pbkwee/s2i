#!/bin/bash

#
# Copyright Rimuhosting.com
# https://rimuhosting.com

umask 077

# Keep this scope identical in create and restore; archives record absent roots too.
function system_recovery_set_scope() {
  systemrecoverypaths=(etc usr bin sbin lib lib32 lib64 libx32 boot opt
    var/lib/dpkg var/lib/apt var/lib/ucf
    var/lib/systemd/deb-systemd-helper-enabled var/lib/systemd/deb-systemd-helper-masked var/lib/initramfs-tools
    var/lib/grub var/lib/pam var/cache/debconf var/spool/cron
    var/lib/rpm var/lib/yum var/lib/dnf var/lib/alternatives
    var/lib/pkgtools var/lib/slackpkg
    var/log/packages var/log/scripts var/log/removed_packages var/log/removed_scripts var/log/setup var/log/pkgtools
    var/db/pkg var/lib/portage var/lib/apk)
  systemrecoveryparents=(var var/lib var/lib/systemd var/cache var/spool var/log var/db)
}

function system_recovery_output_manifest() {
  local tree=${1%/} require_package_database=${2:-true} path link database_found=false
  if $require_package_database; then
    # Read package records directly; do not run a package manager from the saved system.
    for path in var/lib/dpkg/status var/lib/rpm/Packages var/lib/rpm/Packages.db var/lib/rpm/rpmdb.sqlite \
        usr/lib/sysimage/rpm/Packages usr/lib/sysimage/rpm/Packages.db usr/lib/sysimage/rpm/rpmdb.sqlite \
        lib/apk/db/installed usr/lib/apk/db/installed var/lib/apk/db/installed var/lib/apk/installed; do
      case "$path" in
        var/lib/rpm/*) [ ! -L "$tree/var/lib/rpm" ] || continue;;
        lib/apk/*) [ ! -L "$tree/lib" ] || continue;;
      esac
      if [ -f "$tree/$path" ] && [ ! -L "$tree/$path" ]; then database_found=true; break; fi
    done
    for path in var/lib/pkgtools/packages var/log/packages var/db/pkg; do
      if [ -d "$tree/$path" ] && [ ! -L "$tree/$path" ]; then database_found=true; break; fi
    done
    if ! $database_found || [ ! -d "$tree/usr" ] || [ ! -d "$tree/etc" ]; then
      echo 'System scope requires /etc, /usr and a dpkg, RPM, pkgtools, Portage or APK package database.' >&2; return 1
    fi
  fi
  for path in etc usr "${systemrecoveryparents[@]}"; do
    [ ! -L "$tree/$path" ] || { echo "System recovery cannot follow a parent symlink: /$path" >&2; return 1; }
  done
  if [ -L "$tree/lib" ] && [ -L "$tree/lib64" ]; then
    case "$(readlink -- "$tree/lib"):$(readlink -- "$tree/lib64")" in
      lib64:lib|lib64:/lib|/lib64:lib|/lib64:/lib)
        echo 'System recovery cannot save or replace a /lib and /lib64 link cycle.' >&2; return 1;;
    esac
  fi
  printf '%s\n' s2i-system-recovery-v2
  for path in "${systemrecoverypaths[@]}"; do
    if [ -L "$tree/$path" ]; then
      link=$(readlink -- "$tree/$path") || return 1
      case "$path:$link" in
        bin:usr/bin|bin:/usr/bin|sbin:usr/sbin|sbin:/usr/sbin|\
        lib:usr/lib|lib:/usr/lib|lib:lib64|lib:/lib64|lib:usr/lib64|lib:/usr/lib64|\
        lib32:usr/lib32|lib32:/usr/lib32|\
        lib64:usr/lib64|lib64:/usr/lib64|lib64:lib|lib64:/lib|lib64:usr/lib|lib64:/usr/lib|\
        libx32:usr/libx32|libx32:/usr/libx32|\
        var/lib/rpm:../../usr/lib/sysimage/rpm|var/lib/rpm:/usr/lib/sysimage/rpm|\
        var/log/packages:../lib/pkgtools/packages|var/log/packages:/var/lib/pkgtools/packages|\
        var/log/scripts:../lib/pkgtools/scripts|var/log/scripts:/var/lib/pkgtools/scripts|\
        var/log/removed_packages:pkgtools/removed_packages|var/log/removed_packages:../lib/pkgtools/removed_packages|var/log/removed_packages:/var/lib/pkgtools/removed_packages|\
        var/log/removed_scripts:pkgtools/removed_scripts|var/log/removed_scripts:../lib/pkgtools/removed_scripts|var/log/removed_scripts:/var/lib/pkgtools/removed_scripts|\
        var/log/setup:../lib/pkgtools/setup|var/log/setup:/var/lib/pkgtools/setup) ;;
        *) echo "System recovery cannot save or replace this scope symlink: /$path" >&2; return 1;;
      esac
      printf 'link\t%s\t%s\n' "$path" "$link"
    elif [ -d "$tree/$path" ]; then printf 'directory\t%s\n' "$path"
    elif [ -e "$tree/$path" ]; then
      echo "System recovery scope must be a directory or a supported system alias: /$path" >&2; return 1
    else printf 'absent\t%s\n' "$path"; fi
  done
}


function usage {
  echo " 
  $0 Creates a backup of a Linux server.  It has options to let you download that via http (else you can scp it from the source).  It has options to encrypt the backup file (e.g. via openssl or zip).
  
  Usage: $0 
    --scope full|system (default full)
      full: normal whole-server image with the standard exclusions.
      system: complete programs, libraries, /etc, /boot, /opt and package records; omits home and application data under /var.
      Use system before an upgrade. Restore with the same scope to remove newer system files while preserving omitted data.
      Supports typical Debian/Ubuntu, RPM/Yum/DNF, Slackware, Gentoo and Alpine package paths.
      System scope needs complete trees (no --files, custom exclusions or --pipe). Database data needs a separate backup.
    --files (default to / )
    --root (defaults to an empty value meaning /.  If you are mounting a root filesystem elsewhere, you can use something like --root /mnt.  --files and --root are mutually exclusive.)

    --outputdir output directory [ /root/s2i.backup ]
    --outputfile output file [ s2i.backup-dt ]
    --outputextn output file extension [ gz | zip | gz.enc depending on encryption ]
    --outputpath output file full path (overrides other output options) [/root/s2i.backup/s2i.backup-{date} ]

    --encrypt openssl (default if using --http) | zip (not so secure) | none (default if not using --http)
    --password by default we will create a password for you.  And use the same password each time the same outputdir is used.  NA if encrypt==none.
    --http (serve file on an http url)
    --size output the size of the backup (without creating it or using any disk space)
    --pipe output backup to a pipe.  Can be used to directly transfer a backup to a separate server without creating an intermediary file on the server being backed up.
    
  
  Put files/directories you wish to exclude in [outputdir:-/root/s2i.backup]/exclude.log
  
  By default the script will exclude directories including /proc /tmp /mnt /dev /sys /run /media
  
  The default backup includes binary database files (if any, e.g. for postgres and mysql).  You may prefer to exclude them, and run a database dump instead (e.g. per mysqlbackup.sh).
  
  You can also stop database servers and other processes that may be updating files while you run this script.
  
  If you use the --http option we will put the file on a URL that should be secret.  However we still recommend you use one of the --encrypt options.
  
  There is a mysqlbackup.sh script that will let you run mysql database backups, prior to running s2i-create.sh
  
  You can use Unix pipes to create a backup on a remote server without using much space for the backup on the source server.
  
  Sample usage using pipes.  On the server being backed up:
  echo '/dont/backup/this/dir' > s2i.backup/exclude.log
  nohup bash ./s2i-create.sh --outputdir s2i.backup --pipe
  
  While this is running, go to the destination server:
    ssh backupserver cat s2i.backup/pipe > s2i.backup.gz
  or via curl sftp upload like:
    cat /root/s2i.backup/pipe | curl -vvv --config ~/.config/backup-curl.conf --fail -k  --show-error   --upload-file -   'sftp://targethost/backup.tar.gz'
    
  Then use the s2i-restore.sh script if/when you need to overwrite a server image with a backup image.
  
  "
  return 0
}

function select_tar() {
  local candidate
  tarcmd=
  tarmetadataopts=()
  for candidate in tar gtar; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    [ -n "$tarcmd" ] || tarcmd=$candidate
    if "$candidate" --acls --xattrs --xattrs-include='*' --version >/dev/null 2>&1; then
      tarcmd=$candidate
      tarmetadataopts=(--acls --xattrs --xattrs-include='*')
      return 0
    fi
  done
  [ -n "$tarcmd" ] && return 0
  echo "tar not installed." >&2
  return 1
}

# date like 2021-06-28-1624846640
dt="$(date +%Y-%m-%d-%s)"

# openssl, none, zip
encrypt=""
ishttp=""
filestobackup=/
filesprovided=false
systemrecovery=false
scopeprovided=false
root=
issize=""
ispipe=""
outputdir="${outputdir:-/root/s2i.backup}"

function parse() {
  local requested_system
  while [ -n "$1" ]; do
    case "$1" in
      --scope)
        shift
        case "$1" in
          full) requested_system=false;;
          system) requested_system=true;;
          *) echo 'Use --scope full (default) or --scope system.' >&2; return 1;;
        esac
        if $scopeprovided && [ "$systemrecovery" != "$requested_system" ]; then
          echo 'Conflicting backup/restore scopes.' >&2; return 1
        fi
        systemrecovery=$requested_system
        scopeprovided=true
        ;;
      --encrypt)
        shift
        if [ -z "$1" ]; then
          echo "Missing --encrypt type" >&2
          usage
          return 1
        elif [ "$1" == "openssl" ] ; then
          encrypt="openssl"
        elif [ "$1" == "zip" ]; then
           encrypt="zip"
        elif [ "$1" == "none" ]; then
           encrypt="none"
        else 
          echo "Unrecognized --encrypt type '$1'" >&2
          usage
          return 1
        fi
      ;;
      --outputdir)
        shift
        [ -z "$1" ] && echo "Missing output dir" >&2 && return 1
        [ -e "$1" ] && [ ! -d "$1" ] && echo "Output dir must be a directory" >&2 && return 1
        outputdir="$1"
        ;;
      --password)
        shift
        [ -z "$1" ] && echo "Missing password" >&2 && return 1
        password="$1"
        ;;
      --outputfile)
        shift
        [ -z "$1" ] && echo "Missing output file" >&2 && return 1
        [ -e "$1" ] && [ ! -f "$1" ] && echo "Output file must be a file" >&2 && return 1
        outputfile="$1"
        ;;
      --outputextn)
        shift
        [ -z "$1" ] && echo "Missing output extn" >&2 && return 1
        outputextn="$1"
        ;;
      --outputpath)
        shift
        [ -z "$1" ] && echo "Missing output path" >&2 && return 1
        [ -z "$(dirname "$1")" ] && echo "Need a full path and filename for outputpath" >&2 && return 1
        [ "." == "$(dirname "$1")" ] && echo "Need a full path and filename for outputpath" >&2 && return 1
        outputpath="$1"
        outputdir="$(dirname "$outputpath")"
        outputfile="$(basename "$outputpath")"
        ;;
        --size)
          issize="xxx"
        ;;
        --files)
          shift
          if [ -z "$1" ]; then
            echo "Missing --files argument" >&2
            usage
            return 1
          fi
          filestobackup="$1"
          filesprovided=true
          [ -n "$root" ] && [ "$filestobackup" != "/" ] && echo "Set --root or --files but not both" >&2 && return 1
          for i in $filestobackup; do 
            [ ! -e "$i" ] && echo "No such file as $i" >&2 && return 1
          done
        ;;
        --root)
          shift
          if [ -z "$1" ]; then
            echo "Missing --root argument" >&2
            usage
            return 1
          fi
          root="$1"
          [ -n "$root" ] && [ "$filestobackup" != "/" ] && echo "Set --root or --files but not both" >&2 && return 1
          [ ! -d "$root" ] && echo "No such directory as $root" >&2 && return 1
        ;;
        --http)
          ishttp="xxx"
        ;;
        --pipe)
          ispipe="xxx"
        ;;
        -? | --help)
          usage
          return 1
        ;;
        *)
          echo "Unrecognized parameter '$1'" >&2
          usage 
          return 1
        ;;
      esac
    shift
  done
}

parse "$@" || exit 1
if $systemrecovery; then
  unset TAR_OPTIONS
  system_recovery_set_scope
  if $filesprovided; then echo '--scope system cannot be combined with --files.' >&2; exit 1; fi
  if [ -n "$ispipe" ]; then echo '--scope system requires a completed archive file; --pipe is not supported.' >&2; exit 1; fi
  systemroot=$(cd -- "${root:-/}" && pwd -P) || exit 1
  systemroot=${systemroot%/}
  systemmanifest=$(system_recovery_output_manifest "$systemroot") || exit 1
fi

select_tar || exit 1
if $systemrecovery && ! "$tarcmd" --no-recursion --recursion --version >/dev/null 2>&1; then
  echo 'System scope requires GNU tar with --no-recursion and --recursion support.' >&2; exit 1
fi

# rsync typically needed on the restore side
if ! command -v rsync 1>/dev/null 2>&1; then
  if $systemrecovery; then echo 'Install rsync before creating a system recovery backup.' >&2; exit 1; fi
  command -v apt-get 1>/dev/null 2>&1 && apt-get -y install rsync
fi

[ -z "$ishttp" ] && [ -z "$encrypt" ] && encrypt="none"
[ -n "$ishttp" ] && [ -z "$encrypt" ] && encrypt="openssl"

#if [ ! -z "$ispipe" ]; then
#  outputextn="${outputextn:-}"
if [ "$encrypt" == "openssl" ]; then
  outputextn="${outputextn:-gz.enc}"
elif [ "$encrypt" == "zip" ]; then
  outputextn="${outputextn:-zip}"
elif [ "$encrypt" == "none" ]; then
  outputextn="${outputextn:-gz}"
else
  outputextn="${outputextn:-gz}"
fi

outputfile="${outputfile:-s2i.backup.$(hostname)-$dt.$outputextn}"
destinationoutputfile="$outputfile"
[ -n "$ispipe" ] && outputfile="pipe"

outputpath="${outputpath:-$outputdir/$outputfile}"

[ -n "$issize" ] && [ -n "$ispipe" ] && echo "--pipe and --size options are mutually exclusive." >&2 && exit 1
 
if $systemrecovery; then
  recoveryoutput=$(readlink -m -- "$(dirname "$outputpath")") || exit 1
  for path in "${systemrecoverypaths[@]}"; do
    case "$recoveryoutput/" in "$systemroot/$path/"*)
      echo "Put the recovery archive outside its saved system trees: /$path" >&2; exit 1;;
    esac
  done
fi

# create a backup directory
mkdir -p "$(dirname "$outputpath")" || exit 1

passwordfile="$(dirname "$outputpath")/.bupassword"
instructionsfile="$(dirname "$outputpath")/.buinstructions"
for file in "$passwordfile" "$instructionsfile"; do
  if [ -L "$file" ] || { [ -e "$file" ] && [ ! -f "$file" ]; }; then
    echo "Refusing an unsafe backup metadata file: $file" >&2; exit 1
  fi
  touch "$file" && chmod u=rw,go= "$file" || exit 1
done

if $systemrecovery && [ -n "$password" ] && [ -s "$passwordfile" ]; then
  recoverypassword=$(cat "$passwordfile") || exit 1
  if [ "$password" != "$recoverypassword" ]; then
    echo 'Use a new recovery output directory to change its encryption password.' >&2; exit 1
  fi
fi

if [ -z "$password" ]; then
  # random password of letters and digits
  [ -s "$passwordfile" ] || LC_ALL=C </dev/urandom tr -dc A-Z0-9 | head -c10 > "$passwordfile"

  password="$(cat "$passwordfile")" || exit 1
else 
  printf '%s\n' "$password" > "$passwordfile" || exit 1
fi
[ -n "$password" ] || { echo 'Unable to obtain a backup password.' >&2; exit 1; }
if [ "$encrypt" = openssl ]; then
  case "$password" in *$'\n'*|*$'\r'*) echo 'OpenSSL file passwords must be a single line.' >&2; exit 1;; esac
fi

#cd "$(dirname "$outputpath")"

if $systemrecovery; then
  if [ -s "$(dirname "$outputpath")/exclude.log" ]; then
    echo 'System recovery requires complete system trees; custom exclude.log is not supported.' >&2; exit 1
  fi
  recoverymetadata=$(mktemp -d "$(dirname "$outputpath")/.system-recovery.XXXXXX") || exit 1
  trap 'rm -rf -- "$recoverymetadata"; [ -z "${recoveryarchive:-}" ] || rm -f -- "$recoveryarchive"' EXIT
  printf '%s\n' "$systemmanifest" > "$recoverymetadata/.s2i-system-recovery" || exit 1
  taropts=(--numeric-owner --create --preserve-permissions "${tarmetadataopts[@]}" --gzip --file -
    --directory "$recoverymetadata" .s2i-system-recovery --directory "${systemroot:-/}" --no-recursion .)
  # Save parent metadata without copying omitted data or inheriting staging-directory permissions.
  for path in "${systemrecoveryparents[@]}"; do
    [ ! -d "$systemroot/$path" ] || taropts+=("$path")
  done
  taropts+=(--recursion)
  for path in "${systemrecoverypaths[@]}"; do
    if [ -e "$systemroot/$path" ] || [ -L "$systemroot/$path" ]; then taropts+=("$path"); fi
  done
else
# exclude mysql and log files, but keep directory structure
[ -d "$root/var/log" ] && find "$root/var/log" -type f | grep -E -v 'mysql|mariadb' > "$(dirname "$outputpath")/exclude-default.log"
[ -d "$root/var/cache/apt/archives" ] && find  "$root/var/cache/apt/archives" -type f >> "$(dirname "$outputpath")/exclude-default.log"
touch "$(dirname "$outputpath")/exclude.log" || exit 1

#find /var/lib/mysql -type f > "$(dirname "$outputpath")/exclude-default.log"

# exclude sockets and pipes
# cannot use -type s,p => Arguments to -type should contain only one letter
find "$([ -d "$root/tmp" ] && echo "$root/tmp")"  "$([ -d "$root/var" ] && echo "$root/var" )" "$([ -d "$root/run" ] && echo "$root/run")" -type s  -print 2>/dev/null >> "$(dirname "$outputpath")/exclude-default.log"
find "$([ -d "$root/tmp" ] && echo "$root/tmp")"  "$([ -d "$root/var" ] && echo "$root/var" )" "$([ -d "$root/run" ] && echo "$root/run")" -type p  -print 2>/dev/null >> "$(dirname "$outputpath")/exclude-default.log"

echo "/root/backup.* 
/root/s2i.backup*
/restore* 
/s2i.restore* 
/root/s2i* 
/s2i* 
" >> "$(dirname "$outputpath")/exclude-default.log"  

echo "$root/root/backup.* 
$root/root/s2i.backup*
$root/restore* 
$root/s2i.restore* 
$root/root/s2i* 
$root/s2i* 
$root/proc 
$root/tmp 
$root/mnt 
$root/dev 
$root/sys
$root/run 
$root/media 
$root/usr/src/linux-headers* 
$root/home/*/.gvfs 
$root/home/*/.cache 
$root/home/*/.local/share/Trash
" >> "$(dirname "$outputpath")/exclude-default.log"  

dirname "$outputpath" >> "$(dirname "$outputpath")/exclude-default.log"

# create a tar file, exclude certain directories
# encrypt the data using openssh with the provided password

# --files historically accepts a whitespace-separated list and shell patterns.
# shellcheck disable=SC2206
taropts=(--numeric-owner --create --preserve-permissions
"${tarmetadataopts[@]}" --gzip --file -
"--exclude-from=$(dirname "$outputpath")/exclude.log"
"--exclude-from=$(dirname "$outputpath")/exclude-default.log"
"$root"/$filestobackup
)

fi

ip="$(ifconfig eth0 2>/dev/null| grep 'inet ' | sed 's/inet addr:/inet /' | awk '{print $2}')"
# The following works on recent distros with iproute installed.
[ -z "$ip" ] && ip="$(ip --json route get 1 2>/dev/null | awk -vRS="," '/src/'|tr -d "\""|cut -d: -f2)"
[ -z "$ip" ] && echo "Could not determine IP address." >&2 && exit 1 

echo "" | tee "$instructionsfile"
{
[ -z "$ishttp" ] && echo "HTTP URL: NA.  Not making backup http accessible"
[ -n "$ishttp" ] && echo "HTTP URL: Will make backup http accessible"
echo "Encryption set to: '$encrypt'"
echo "IP: '$ip'"
echo "Output path: '$outputpath'"
echo "Disk:"
df -h "$root/"
echo "Starting server-to-image at $dt"
} | tee -a "$instructionsfile"

if [ -n "$issize" ]; then
  echo "Checking the file size of the backup..." | tee -a "$instructionsfile"
  bytes="$(
    set -o pipefail
    # Full backups tolerate changed files; recovery images require a clean tar result.
    if [ "$encrypt" == "openssl" ]; then
      { "$tarcmd" "${taropts[@]}" || { [ "$?" -eq 1 ] && ! $systemrecovery; }; } | openssl enc -aes-256-cbc -md sha256 -pass "file:$passwordfile" | wc -c
    elif [ "$encrypt" == "zip" ]; then
      { "$tarcmd" "${taropts[@]}" || { [ "$?" -eq 1 ] && ! $systemrecovery; }; } | zip --encrypt --password "$password" | wc -c
    elif [ "$encrypt" == "none" ]; then
      { "$tarcmd" "${taropts[@]}" || { [ "$?" -eq 1 ] && ! $systemrecovery; }; } | wc -c
    else
      exit 1
    fi
  )" || { echo "Backup size calculation failed." >&2; exit 1; }
  echo "The backup size is $bytes bytes $(command -v numfmt >/dev/null 2>&1 && numfmt --to=iec-i --suffix=B --padding=7 "$bytes")" | tee -a "$instructionsfile"
  exit 0
fi
ret=0
archiveoutputpath=$outputpath
if [ -L "$outputpath" ] || { [ -z "$ispipe" ] && [ -e "$outputpath" ] && [ ! -f "$outputpath" ]; }; then
  echo "Refusing an unsafe backup output file: $outputpath" >&2; exit 1
fi
if [ -n "$ispipe" ]; then
  [ ! -p "$outputpath" ] && [ -e "$outputpath" ] && echo "'$outputpath' already exists and is not a pipe." >&2 && exit 1
  [ ! -p "$outputpath" ] && { mkfifo "$outputpath" || { echo "Failed creating pipe $outputpath" >&2 && exit 1 ; } }
  echo "Performing a backup to a pipe.  To consume the backup use something like:"
  echo "ssh $ip cat \"$outputpath\" > \"$destinationoutputfile\""
  echo "or:"
  echo "cat \"$outputpath\" | curl -vvv --config ~/.config/backup-curl.conf --fail -k  --show-error   --upload-file -   'sftp://targethost/backup.tar.gz'"
  echo "where   ~/.config/backup-curl.conf could have user = 'username:password'"
elif $systemrecovery; then
  recoveryarchive=$(mktemp "$(dirname "$outputpath")/.system-recovery-archive.XXXXXX") || exit 1
  archiveoutputpath=$recoveryarchive
else
  : > "$outputpath" || exit 1
fi
chmod u=rw,go= "$archiveoutputpath" || exit 1
if [ "$encrypt" == "openssl" ]; then
  echo "Creating tar file, openssl encrypted, at $outputpath" | tee -a "$instructionsfile"
  "$tarcmd" "${taropts[@]}" | openssl enc -aes-256-cbc  -md sha256 -pass "file:$passwordfile"  > "$archiveoutputpath"
  RC=( "${PIPESTATUS[@]}" )
  tarret="${RC[0]}"
  ret="${RC[1]}"
  echo "Encryption password retained in $passwordfile; decryption will prompt for it." | tee -a "$instructionsfile"
  echo "OpenSSL command to decrypt: openssl enc -d -aes-256-cbc -md sha256 -in \"$outputpath\" -out s2i.backup.tar.gz" | tee -a "$instructionsfile"
elif [ "$encrypt" == "zip" ]; then
  echo "Creating zip file, password encrypted, at $outputpath. Password retained in $passwordfile." | tee -a "$instructionsfile"
  "$tarcmd" "${taropts[@]}" | zip --encrypt --password "$password"  > "$archiveoutputpath"
  RC=( "${PIPESTATUS[@]}" )
  tarret="${RC[0]}"
  ret="${RC[1]}"
elif [ "$encrypt" == "none" ]; then
  echo "Creating tar file, not encrypted, at $outputpath" | tee -a "$instructionsfile"
  "$tarcmd" "${taropts[@]}" > "$archiveoutputpath"
  tarret=$?
else
  echo "Unexpected encryption type '$encrypt'" >&2
  exit 1
fi
if [ "$ret" -ne 0 ] || [ "$tarret" -gt 1 ] || { $systemrecovery && [ "$tarret" -ne 0 ]; }; then
  echo "Backup creation failed." >&2
  [ "$ret" -ne 0 ] && exit "$ret"
  exit "$tarret"
fi
if $systemrecovery; then
  mv -f -- "$recoveryarchive" "$outputpath" || exit 1
  recoveryarchive=
fi
[ "$tarret" -eq 1 ] && echo "Backup created with tar warnings." >&2

echo "Backup created: $(ls -lh "$outputpath")" | tee -a "$instructionsfile"
secretdirname="$(LC_ALL=C </dev/urandom tr -dc A-Z0-9 | head -c10)"
if [ -n "$ishttp" ]; then
  # Serve only a fresh archive directory, never the working directory or password files.
  httpdir=$(mktemp -d "$(dirname "$outputpath")/http.XXXXXXXXXX") || exit 1
  chmod u=rwx,go= "$httpdir" || exit 1
  mkdir "$httpdir/$secretdirname" || exit 1
  mv "$outputpath" "$httpdir/$secretdirname/" || exit 1
  newoutputpath="$httpdir/$secretdirname/$(basename "$outputpath")"
  echo "Moving the output file from $outputpath file to $newoutputpath, to improve HTTP security" | tee -a "$instructionsfile"
  outputpath="$newoutputpath"
  # offer the file for download.  Kill this process off after you have downloaded the file.  
  # PHP has a built in web server
  # at job to kill off process after 24h?
  nohup php -S "$ip:32956" -t "$httpdir" &
  echo "Download your backup from http://$ip:32956/$secretdirname/$(basename "$outputpath")" | tee -a "$instructionsfile"
  phppid="$(netstat -ntpl  | grep 32956 | sed 's/.*LISTEN *//' | sed 's#/.*##')"
  [ -n "$phppid" ] && echo "After you have downloaded the file, stop the temporary web server with: kill $phppid" | tee -a "$instructionsfile"
fi

# Record the final path beside the password, outside any HTTP document root.
printf '%s\n' "$outputpath" > "$(dirname "$passwordfile")/.outputpath" || exit 1

if $systemrecovery; then
  echo 'System recovery archive: use the current s2i-restore.sh --scope system (defaults to /; stop writers first). For an offline restore, add --restoretopath /mnt/vm.' | tee -a "$instructionsfile"
  echo 'Do not use a whole-server restore for this archive. Database data and bootloader installation need separate recovery.' | tee -a "$instructionsfile"
fi

echo "You can access your backup file via scp:" | tee -a "$instructionsfile"
if [ "$encrypt" != zip ]; then
  # The destination may have different tar support from the backup host.
  {
    echo "Run these commands in Bash on the destination:"
    declare -f select_tar
    echo 'select_tar || exit 1'
  } | tee -a "$instructionsfile"
fi
if [ "$encrypt" == "openssl" ] ; then
  echo "mkdir s2i.restore.$dt && cd s2i.restore.$dt && scp root@$ip:$outputpath /dev/stdout | openssl enc -d -aes-256-cbc -md sha256 | \"\$tarcmd\" --extract --gunzip --numeric-owner --preserve-permissions \"\${tarmetadataopts[@]}\"" | tee -a "$instructionsfile"
  echo "Should you need openssl for windows, you may download that.  For example from https://curl.se/windows/" | tee -a "$instructionsfile"
elif [ "$encrypt" == "none" ] ; then
  echo "mkdir s2i.restore.$dt && cd s2i.restore.$dt && scp root@$ip:$outputpath /dev/stdout | \"\$tarcmd\" --extract --gunzip --numeric-owner --preserve-permissions \"\${tarmetadataopts[@]}\"" | tee -a "$instructionsfile"
elif [ "$encrypt" == "zip" ] ; then
  echo "scp root@$ip:$outputpath ." | tee -a "$instructionsfile"
else
  echo "Unrecognized encrypt type of '$encrypt'" >&2
  exit 1 
fi
exit 0
