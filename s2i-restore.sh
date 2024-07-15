#!/bin/bash
#
# Copyright Rimuhosting.com
# https://rimuhosting.com

ip="$(ifconfig eth0 2>/dev/null| grep 'inet ' | sed 's/inet addr:/inet /' | awk '{print $2}')"
# The following works on recent distros with iproute installed.
[ -z "$ip" ] && ip="$(ip --json route get 1 2>/dev/null | awk -vRS="," '/src/'|tr -d "\""|cut -d: -f2)"

#change these to your IP.  old = original host's IP.  new = the IP on the server we are restoring to
oldip="${oldip:-127.0.0.3}"
newip="${newip:-$ip}"

# gzip file we'll be restoring from
[ -z "$archivegz" ] && [ "1" == "$(find . -maxdepth 1 -type f -size +100000 -mmin -200 | grep '\.gz' | wc -l)" ] && archivegz="$(find . -maxdepth 1 -type f -mmin -200 -size +100000 | grep '\.gz')"
[ ! -z "$archivegz" ] && archivegz="$(realpath "$archivegz")"

# location we will be restoring to, typically /
restoretopath="${restoretopath:-/}"
restorescratchdirdefault="/root/s2i.restore"
#restorescratchdir="$(compgen -G "/root/s2i.restore.*" >/dev/null && find /root/s2i.restore.* -maxdepth 0 -mtime -10 -type d  | head)"
restorescratchdir="/root/s2i.restore"

# previously had run find / -type d -print0 | xargs -0 -I{} touch  "{}/958567675843" to put this file in all directories.
# then test after a restore (they should all be cleared).

function usage() {
echo "$0 usage:
  [ --oldip originalip ] [--newip newip/defaults to this server's IP ] set if you want to search/replace these IP values on the restored image
  [ --archivegz path ] defaults to the only and only big gz file in the current directory
  [ --restoretopath path ] defaults to the /
  [ --ignoreports ] lets the restore proceed even if ports are in use (a safety precaution)
  [ --ignorehostname ] lets the restore proceed even if the server hostname is not like backup.something (a safety precaution)
  [ --ignorespace ] lets the restore proceed even if the script reports there may be insufficient space (a safety precaution)
  Will extract the tar.gz archivegz to the restoretopath (default /)
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


[ ! -e "$restorescratchdir" ] && restorescratchdir=""

if [ ! -z "$restorescratchdir" ]; then
  if [ $(find "$restorescratchdir" -type f | head -n 400 | wc -l) -lt 300 ]; then
    echo "The pre-existing restore directory ($restorescratchdir) does not appear to be complete.  Ignoring."
    restorescratchdir=""
  fi  
fi

[ ! -z "$archivegz" ] && [ ! -z "$restorescratchdir" ] && [ -e "$archivegz" ] && [ -e "$restorescratchdir"] && [ ! -z "$archivegz" ] && [ ! -z "$restorescratchdir" ] && [ -e "$archivegz" ] && [ -e "$restorescratchdir" ] && ! find "$restorescratchdir" -maxdepth 0 -newer "$archivegz" && echo "Restore scratch directory ($restorescratchdir) is not newer than the backup ($archivegz).  Will not proceed." >&2 && exit 1 

[ -z "$restorescratchdir" ] && [ -z "$archivegz" ] && echo "Use --archivegz file to specify the archive to use." >&2 && exit 1
[ -z "$restorescratchdir" ] && [ ! -f "$archivegz" ] && echo "--archivegz file $archivegz not found." >&2 && exit 1
 
info

ret=0
while true; do 

  [ -z "$isignorehostname" ] && ! grep -q  backup <(hostname) && echo 'hostname ($(hostname)) does not contain the "backup", exiting as a safety precaution.  If this is the right host, set a hostname like: hostname backup.$(hostname)  Disable this check with the --ignorehostname option' && ret=1 && break
  [ -z "$isignoreports" ] && [ 0 -ne $(netstat -ntp | egrep -v ':22|Foreign Address|Active Internet connections' | wc -l) ] && echo "There are some non ssh connections.  Wrong server?  Disable this check with the --ignoreports option" && netstat -ntp && ret=1 && break
  echo "Stopping services that may interfere with the restore."
  
  # systemctl list-unit-files | cat | grep 'enabled$' 
  #amavis-mc.service                      disabled        enabled
  #amavis.service                         enabled         enabled
  #amavisd-snmp-subagent.service          disabled        enabled
  #apache-htcacheclean.service            disabled        enabled
  #apache-htcacheclean@.service           disabled        enabled
  for i in $(systemctl list-unit-files | grep -v '@' | egrep 'redis|fail2ban|postfix|virtualmin|webmin|usermin|named|dovecot|proftp|exim|spamass|php|postgres|mailman|mysql|mariadb|amavis|apache' | awk '{print $1}' ); do 
    echo "Stopping: $i"
    systemctl stop $i 
  done

  # Stop services not needed
  
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
    echo "Extracting backup to restore directory $restorescratchdir from $archivegz ($(ls -lh $archivegz))"
    tar xzf "$archivegz" --directory "$restorescratchdir"
    [ $? -ne 0 ] && ret=1 && break
  fi
  [ -z "$restorescratchdir" ] && echo "no restore directory set" >&2 && ret=1 && break
  
  # root@2023-05:~# rsync --exclude-from /asdf/asdf t t2
  # rsync: [client] failed to open exclude file /asdf/asdf: No such file or directory (2)
  echo "Rsync-ing from $restorescratchdir to ${restoretopath:-/}"
   # --force-change for immutables, but does not work on some distros. e.g. 311/2014
   # --force = force deletion of dirs even if not empty
   # using realpath below since "rsync /root/s2i.restore /" creates /s2i.restore.  Rather we need "rsync /root/s2i.restore/ /" 
rsync --force --delete --archive --hard-links --xattrs --perms --executability --acls --owner --group --specials --times --numeric-ids --ignore-errors \
--exclude=/etc/network/interfaces \
--exclude='/root/s2i*' \
--exclude=/root/rsync* \
--exclude=/root/.ssh/authorized_keys \
--exclude=/etc/fstab \
--exclude=/boot \
--exclude=/proc \
--exclude=/etc/hostname \
--exclude=/tmp \
--exclude=/mnt \
--exclude=/dev \
--exclude=/sys \
--exclude=/run \
--exclude=/media \
--exclude=/usr/src/linux-headers* \
--exclude=/home/*/.gvfs \
--exclude=/home/*/.cache \
--exclude=/home/*/.local/share/Trash \
"$(realpath "$restorescratchdir")/" "${restoretopath:-/}" 2>&1 | tee -a rsync.log
  if [ ${PIPESTATUS[0]} -ne 1 ] ; then 
    echo "Error or warning from rsync." >&2
    ret=1
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
