#!/bin/bash
#
# Copyright Rimuhosting.com
# https://rimuhosting.com

#change these to your IP.  old = original host's IP.  new = the IP on the server we are restoring to
oldip="${oldip:-127.0.0.3}"
newip="${newip:-127.0.0.4}"

# gzip file we'll be restoring from
[ -z "$archivegz" ] && [ "1" == "$(find . -maxdepth 1 -type f -size +100000 | grep '\.gz' | wc -l)" ] && archivegz="$(find . -maxdepth 1 -type f -size +100000 | grep '\.gz')"
archivegz="${archivegz:-/root/s2i.gz}"
archivegz="$(realpath "$archivegz")"

# location we will be restoring to, typically /
restoretopath="${restoretopath:-/}"
restorescratchdirdefault="/root/s2i.restore.$$"
restorescratchdir="$(compgen -G "/root/s2i.restore.*" >/dev/null && find /root/s2i.restore.* -maxdepth 0 -mtime -10 -type d  | head)"

function usage() {
echo "$0 usage:
  [ --oldip originalip ] [--newip newip ] set if you want to search/replace these IP values on the restored image
  [ --archivegz path ] defaults to the only and only big gz file in the current directory
  [ --restoretopath path ] defaults to the /
  [ --ignoreports ] lets the restore proceed even if ports are in use.
  [ --ignorehostname ] lets the restore proceed even if the server hostname is not like backup.something (a safety precaution)
  [ --ignorespace ] lets the restore proceed even if the there may be insufficient space (a safety precaution)
  Will extract the tar.gz archivegz to the restoretopath /
  "
}
function info() {
  echo "$0 info:"
  echo "Archive gz: $archivegz"
  ls -lh "$archivegz"
  echo "Restore path: $restoretopath"
  echo "Old IP: $oldip"
  echo "New IP: $newip"
  [ ! -z "$restorescratchdir" ] && echo "Reuse existing restore scratch dir: ${restorescratchdir}"
  [ -z "$restorescratchdir" ] && echo "Create restore scratch dir: ${restorescratchdirdefault}"
}

function parse() {
  while [ -n "$1" ]; do
    case "$1" in
      --oldip)
        shift
        if [ -z "$1" ]; then
          echo "Missing --oldip value" >&2
          return 1
        fi
        oldip="$1"
        ;;
      --newip)
        shift
        if [ -z "$1" ]; then
          echo "Missing --newip value" >&2
          return 1
        fi
        newip="$1"
        ;;
      --archivegz)
        shift
        if [ -z "$1" ]; then
          echo "Missing --archivegz value" >&2
          usage
          return 1
        fi
        archivegz="$1"
        ;;
      --restoretopath)
        shift
        if [ -z "$1" ]; then
          echo "Missing --restoretopath value" >&2
          usage
          return 1
        fi
        restoretopath="$1"
        ;;
      --ignoreports)
        isignoreports="xxx"
        ;;
      --ignorehostname)
        isignorehostname="xxx"
        ;;
        
      --ignorespace)
        isignorespace="xxx"
        ;;
        
      --help)
        usage
        return 1
        ;;
      *)
        echo "Unrecognized parameter '$1'" >&2
        usage
        return 1;
        ;;
      esac
    shift
  done
}        

parse "$@" || exit 1

if [ ! -z "$restorescratchdir" ]; then
  if [ $(find "$restorescratchdir" -type f | head -n 400 | wc -l) -lt 300 ]; then
    echo "The pre-existing restore directory ($restorescratchdir) does not appear to be complete.  Ignoring."
    restorescratchdir=""
  fi  
fi

info

ret=0
while true; do 
  [ -z "$isignorehostname" ] && ! grep -q  backup <(hostname) && echo 'hostname does not contain the "backup", exiting as a safety precaution.  If this is the right host, set a hostname like: hostname backup.$(hostname)  Disable this check with the --ignorehostname option' && ret=1 && break
  [ -z "$isignoreports" ] && [ 0 -ne $(netstat -ntp | egrep -v ':22|Foreign Address|Active Internet connections' | wc -l) ] && echo "There are some non ssh connections.  Wrong server?  Disable this check with the --ignoreports option" && netstat -ntp && ret=1 && break
  # Stop services not needed
  
  systemctl stop fail2ban  2>/dev/null
  systemctl stop apache2  2>/dev/null
  systemctl stop mysql  2>/dev/null
  systemctl stop postfix  2>/dev/null
  systemctl stop dovecot 2>/dev/null
  # df --block-size 1 /
  # Filesystem       1B-blocks        Used   Available Use% Mounted on
  #/dev/root      41972088832 17311182848 23785197568  43% /
  dffreeb="$(df --block-size 1 / | awk '{print $4}' | egrep -v Available | head -n 1)"
  [ -f "$archivegz" ] && archivesizeb="$(( $(stat  --format=%s "$archivegz") * 2))"
  if [ -z "$isignorespace" ] && [ ! -z "$dffreeb" ] && [ ! -z "$archivesizeb" ] && [[ $dffreeb -lt $archivesizeb ]]; then
    echo "There may be insufficient space to do a restore.  Disable this check with the --ignorespace option" >&2
    echo "Disk space:"
    df -h /
    exit 1
  fi
  
  if [ ! -z "$restorescratchdir" ]; then 
    echo "Restoring from pre-existing restore directory: $restorescratchdir"
  else
    [ ! -f "$archivegz" ] && echo "no backup file '$archivegz', exiting" && ret=1 && break
    restorescratchdir="${restorescratchdirdefault}"
    mkdir -p $restorescratchdir
    cd $restorescratchdir
    echo "Extracting backup to restore directory $restorescratchdir from $archivegz ($(ls -lh $archivegz))"
    tar xzf "$archivegz"
    [ $? -ne 0 ] && ret=1 && break
  fi
  [ -z "$restorescratchdir" ] && echo "no restore directory set" >&2 && ret=1 && break 
  echo "Rsync-ing from $restorescratchdir to ${restoretopath:-/}"
   # --force-change for immutables, but does not work on some distros. e.g. 311/2014
rsync --delete --archive --hard-links --acls --xattrs --perms --executability --acls --owner --group --specials --times --numeric-ids --ignore-errors \
--exclude 'etc/network/interfaces' \
--exclude=root/backup* \
--exclude=backup* \
--exclude=root/s2i* \
--exclude='root/s2i.restore*' \
--exclude='s2i.restore*' \
--exclude='s2i*' \
--exclude=root/rsync* \
--exclude=root/.ssh/authorized_keys \
--exclude='etc/fstab' \
--exclude='boot' \
--exclude=proc \
--exclude=etc/hostname \
--exclude=tmp \
--exclude=mnt \
--exclude=dev \
--exclude=sys \
--exclude=run \
--exclude=media \
--exclude=usr/src/linux-headers* \
--exclude=home/*/.gvfs \
--exclude=home/*/.cache \
--exclude=home/*/.local/share/Trash \
$restorescratchdir/* "${restoretopath:-/}" 2>&1 | tee -a rsync.log
  if [ ${PIPESTATUS[0]} -ne 1 ] ; then 
    echo "Error result from the rsync." >&2
    ret=1
    break
  fi
  if [  -z "$oldip" ]; then 
    echo "No oldip provided, not searching and replacing for that."
  elif [ -z "$newip" ]; then
    echo "No newip provided, not searching and replacing for that."
  else
    # find /etc/ -type f | xargs grep 206.123.106.136
    #/etc/hosts:206.123.106.136 prod-u20.example.com
    #/etc/apache2/sites-available/000-default.conf:NameVirtualHost 127.0.0.3:80
    #/etc/apache2/sites-available/000-default.conf:NameVirtualHost 127.0.0.3:443
    find /etc/ -type f | xargs grep -l "$oldip" | grep -v hosts | xargs --no-run-if-empty replace "$oldip" "$newip" --
   fi
   break
done
# set an exit code
if [ $ret -ne 0 ]; then 
  false;
else 
  true
fi
