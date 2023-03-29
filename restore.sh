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
restorescratchdir="$(compgen -G "/root/restore.*" >/dev/null && find /root/restore.* -maxdepth 0 -mtime -10 -type d  | head)"

function usage() {
echo "$0 usage:
  [ --oldip originalip ] [--newip newip ] set if you want to search/replace these IP values on the restored image
  [ --archivegz path ] defaults to the only and only big gz file in the current directory
  [ --restoretopath path ] defaults to the /
  
  Will extract the tar.gz archivegz to the restoretopath /
  "
}
function info() {
  echo "Info:"
  echo "Archive gz: $archivegz"
  ls -lh "$archivegz"
  echo "Restore path: $restoretopath"
  echo "Old IP: $oldip"
  echo "New IP: $newip"
  echo "Restore scratch dir: $restorescratchdir"
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

parse || exit 1

info

ret=0
while true; do 
  ! grep -q  backup <(hostname) && echo 'hostname does not contain the "backup", exiting as a safety precaution.  If this is the right host, set a hostname like: hostname backup.example.com' && ret=1 && break
  [ 0 -ne $(netstat -ntp | egrep -v ':22|Foreign Address|Active Internet connections' | wc -l) ] && echo "There are some non ssh connections.  wrong server?  exiting." && netstat -ntp && ret=1 && break
  # Stop services not needed
  systemctl stop fail2ban
  systemctl stop apache2
  systemctl stop mysql
  systemctl stop postfix
  if [ ! -z "$restorescratchdir" ]; then
    if [ $(find "$restorescratchdir" -type f | head -n 400 | wc -l) -lt 300 ]; then
      echo "The pre-existing restore directory ($restorescratchdir) does not appear to be complete.  Ignoring."
      restorescratchdir=""
    fi  
  fi
  # df --block-size 1 /
  # Filesystem       1B-blocks        Used   Available Use% Mounted on
  #/dev/root      41972088832 17311182848 23785197568  43% /
  dffreeb="$(df --block-size 1 / | awk '{print $4}' | egrep -v Available | head -n 1)"
  archivesizeb="$(( $(stat  --format=%s "$archivegz") * 2))"
  [ ! -z "$dffreeb" ] && [ ! -z "$archivesizeb" ] && [[ $dffreeb -lt $archivesizeb ]] && echo "There may be insufficient space to do a restore." >&2 && exit 1
  
  if [ ! -z "$restorescratchdir" ]; then 
    echo "Restoring from pre-existing restore directory: $restorescratchdir"
  else
    [ ! -f "$archivegz" ] && echo "no backup file '$archivegz', exiting" && ret=1 && break
    restorescratchdir="/root/restore.$$"
    mkdir -p $restorescratchdir
    cd $restorescratchdir
    echo "Extracting backup from $archivegz $(ls -lh $archivegz) to restore directory $restorescratchdir"
    tar xzf "$archivegz"
    [ $? -ne 0 ] && ret=1 && break
  fi
  [ -z "$restorescratchdir" ] && echo "no restore directory set" >&2 && ret=1 && break 
   # --force-change for immutables, but does not work on some distros. e.g. 311/2014
rsync --delete --archive --hard-links --acls --xattrs --perms --executability --acls --owner --group --specials --times --numeric-ids --ignore-errors \
--exclude 'etc/network/interfaces' \
--exclude=root/backup* \
--exclude=root/s2i* \
--exclude=root/rsync* \
--exclude=root/.ssh/authorized_keys \
--exclude='restore*' \
--exclude='root/restore*' \
--exclude='etc/fstab' \
--exclude='boot' \
--exclude=proc \
--exclude=etc/hostname \
--exclude=tmp \
--exclude=mnt \
--exclude=dev \
--exclude=sys \
--exclude=run \
--exclude=backup* \
--exclude=s2i* \
--exclude=media \
--exclude=etc/hostname \
--exclude=usr/src/linux-headers* \
--exclude=home/*/.gvfs \
--exclude=home/*/.cache \
--exclude=home/*/.local/share/Trash \
$restorescratchdir/* "${restoretopath:-/}" 2>&1 | tee -a rsync.log
  if [ ${PIPESTATUS[0]} -ne 1 ] ; then 
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
