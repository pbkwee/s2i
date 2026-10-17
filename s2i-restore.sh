#!/bin/bash
#
# Copyright Rimuhosting.com
# https://rimuhosting.com

ip="$(ifconfig eth0 2>/dev/null| grep 'inet ' | sed 's/inet addr:/inet /' | awk '{print $2}')"
# The following works on recent distros with iproute installed.
[ -z "$ip" ] && ip="$(ip --json route get 1 2>/dev/null | awk -vRS="," '/src/'|tr -d "\""|cut -d: -f2)"

#change these to your IP.  old = original host's IP.  new = the IP on the server we are restoring to
oldip="${oldip-127.0.0.3}"
newip="${newip:-$ip}"

# gzip file we'll be restoring from
[ -z "$archivegz" ] && [ "1" == "$(find . -maxdepth 1 -type f -size +100000 -mmin -200 | grep '\.gz' | wc -l)" ] && archivegz="$(find . -maxdepth 1 -type f -mmin -200 -size +100000 | grep '\.gz')"
[ -n "$archivegz" ] && archivegz="$(realpath "$archivegz")"

# location we will be restoring to, typically /
restoretopath="${restoretopath:-/}"
restorecache="/root/s2i.restore-cache"
restorescratchdir=
restorestagingdir=

# Keep the destination's network identity, including absent paths: importing an image's
# alternate network manager configuration can otherwise take over on the next boot.
# Use the same rooted patterns for rsync and the later IP replacement pass.
networkpreservepaths=(
  /etc/hostname /etc/hosts
  /etc/network/interfaces /etc/network/interfaces.d
  /etc/netplan /lib/netplan /usr/lib/netplan
  /etc/NetworkManager
  /lib/NetworkManager/system-connections /usr/lib/NetworkManager/system-connections
  /etc/systemd/network /etc/systemd/networkd.conf /etc/systemd/networkd.conf.d
  /etc/systemd/resolved.conf /etc/systemd/resolved.conf.d
  /etc/sysconfig/network /etc/sysconfig/networking
  '/etc/sysconfig/network-scripts/ifcfg-*'
  '/etc/sysconfig/network-scripts/route-*' '/etc/sysconfig/network-scripts/route6-*'
  '/etc/sysconfig/network-scripts/rule-*' '/etc/sysconfig/network-scripts/rule6-*'
  '/etc/sysconfig/network-scripts/keys-*'
  /etc/sysconfig/static-routes /etc/sysconfig/static-routes-ipv6
  /etc/cloud /var/lib/cloud
  /etc/resolv.conf /etc/resolvconf /etc/resolvconf.conf
  '/etc/dhcp/dhclient*' '/etc/dhcp3/dhclient*' /etc/dhclient.conf /etc/dhcpcd.conf
  '/etc/udev/rules.d/*net*.rules'
)
networkexcludeopts=()
for networkpath in "${networkpreservepaths[@]}"; do
  networkexcludeopts+=("--exclude=$networkpath")
done

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
  [ --ignorenetwork ] skips the live-root network compatibility check after manual review
  Will extract the tar.gz archivegz to the restoretopath (default /)
  Retains common destination network, resolver and cloud-init configuration; review compatibility before restoring a different distro.
  "
}
function is_preserved_network_path() {
  local pattern parent name
  for pattern in "${networkpreservepaths[@]}"; do
    # Globs in this list apply only to the last component. Unlike rsync, Bash * matches /.
    parent=${pattern%/*}
    case "$1" in "$parent"/*)
      name=${1#"$parent/"}
      name=${name%%/*}
      # shellcheck disable=SC2254
      case "$name" in ${pattern##*/}) return 0;; esac
    esac
  done
  return 1
}

# Resolve within the supplied tree; an image's absolute symlink must not select a host tool.
function restore_network_has_tool() {
  local root=$1 path resolved
  shift
  for path in "$@"; do
    resolved=$(realpath -e -- "$root$path" 2>/dev/null) || continue
    case "$resolved" in "$root"/*) [ -f "$resolved" ] && [ -x "$resolved" ] && return 0;; esac
  done
  return 1
}

# Read configuration as data, never source it. Examples: iface eth0 inet dhcp;
# ONBOOT=yes/BOOTPROTO=dhcp; [Network] DHCP=yes; Netplan ethernets/eth0/dhcp4: true.
function restore_network_configured() {
  local format=$1 root=$2 path resolved
  shift 2
  local -a files=()
  for path in "$@"; do
    resolved=$(realpath -e -- "$path" 2>/dev/null) || continue
    case "$resolved" in "$root"/*) [ -f "$resolved" ] && [ -r "$resolved" ] && files+=("$resolved");; esac
  done
  [ "${#files[@]}" -gt 0 ] || return 1
  awk -v format="$format" -v networkd="${networkd:-false}" -v manager="${manager:-false}" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function yes(s) { return s ~ /^(yes|true|1|on)$/ }
    function finish( dev, renderer) {
      if (format ~ /^ifcfg/) return device != "" && device != "lo" && yes(onboot) && (format != "ifcfg-nm" || nmcontrolled !~ /^(no|false|0)$/) && (bootproto == "dhcp" || address)
      if (format == "nm") return type ~ /^(ethernet|802-3-ethernet|wifi|802-11-wireless|bridge|bond|vlan|team|infiniband)$/ && device != "lo" && autoconnect !~ /^(no|false|0)$/ && (dynamic || (methods["[ipv4]"] == "manual" && addresses["[ipv4]"]) || (methods["[ipv6]"] == "manual" && addresses["[ipv6]"]))
      if (format == "networkd") return matched && !loopback && (dynamic || address)
      for (dev in usable) {
        if (format == "ifupdown" && active[dev]) return 1
        renderer=(renderers[dev] ? renderers[dev] : default_renderer)
        if (format == "netplan" && ((renderer == "networkd" && networkd == "true") || (renderer == "NetworkManager" && manager == "true"))) return 1
      }
      return 0
    }
    FNR == 1 {
      if (NR > 1 && format != "ifupdown" && finish()) found=1
      if (format != "ifupdown") { delete usable; delete renderers; delete methods; delete addresses }
      iface=""; section=""; device=""; onboot=""; bootproto=""; address=0; dynamic=0
      type=""; autoconnect=""; nmcontrolled=""; matched=0; loopback=0; default_renderer="networkd"; group_indent=-1; iface_indent=-1; property_indent=-1; address_list=0
    }
    {
      sub(/\r$/, ""); sub(/[ \t]*#.*/, ""); line=trim($0)
      if (!line) next
      if (format == "ifupdown") {
        if ($1 == "auto" || $1 == "allow-hotplug") for (i=2;i<=NF;i++) if ($i != "lo") active[$i]=1
        if ($1 == "iface") { iface=($2 != "lo" && $3 ~ /^inet6?$/ ? $2 : ""); method=$4; if (iface && method ~ /^(dhcp|auto)$/) usable[iface]=1 }
        if (iface && method == "static" && $1 == "address" && $2 != "") usable[iface]=1
        next
      }
      if (format == "netplan") {
        indent=match($0,/[^ \t]/)-1
        if (iface && address_list && indent > property_indent && line ~ /^-[ \t]+[0-9a-fA-F:]/) { usable[iface]=1; next }
        if (line ~ /^(ethernets|wifis|bridges|bonds|vlans):[ \t]*$/) { group_indent=indent; iface=""; next }
        if (line ~ /^[^:]+:/) {
          key=line; sub(/:.*/, "", key); value=line; sub(/^[^:]+:[ \t]*/, "", value)
          if (key == "renderer") { if (iface && indent > iface_indent) renderers[iface]=value; else default_renderer=value; next }
          if (group_indent >= 0 && indent <= group_indent) { group_indent=-1; iface="" }
          if (group_indent >= 0 && indent > group_indent && (iface == "" || indent <= iface_indent)) {
            iface=(key != "lo" && value == "" ? key : ""); iface_indent=indent; property_indent=-1; address_list=0; next
          }
          if (iface && indent > iface_indent) {
            if (property_indent < 0) property_indent=indent
            if (indent == property_indent) {
              address_list=(key == "addresses" && value == "")
              if (key ~ /^dhcp[46]$/ && yes(value)) usable[iface]=1
              if (key == "addresses" && value ~ /^\[[ \t]*[0-9a-fA-F:]/) usable[iface]=1
            }
          }
        }
        next
      }
      if (line ~ /^\[/) { section=tolower(line); next }
      if (line !~ /^[A-Za-z0-9_-]+[ \t]*=/) next
      key=line; sub(/[ \t]*=.*/, "", key); value=line; sub(/^[^=]*=[ \t]*/, "", value); value=trim(value)
      gsub(/^[\042\047]|[\042\047]$/, "", value)
      if (format ~ /^ifcfg/) {
        if (key == "DEVICE") device=value
        if (key == "ONBOOT") onboot=tolower(value)
        if (key == "BOOTPROTO") bootproto=tolower(value)
        if (key == "NM_CONTROLLED") nmcontrolled=tolower(value)
        if (key ~ /^IPADDR[0-9]*$/ || key == "IPV6ADDR") address=(value != "")
      } else if (format == "nm") {
        if (section == "[connection]" && key == "type") type=value
        if (section == "[connection]" && key == "interface-name") device=value
        if (section == "[connection]" && key == "autoconnect") autoconnect=tolower(value)
        if (section ~ /^\[ipv[46]\]$/ && key == "method") { methods[section]=value; if (value ~ /^(auto|dhcp)$/) dynamic=1 }
        if (section ~ /^\[ipv[46]\]$/ && key ~ /^address[0-9]+$/ && value != "") addresses[section]=1
      } else if (format == "networkd") {
        if (section == "[match]" && key ~ /^(Name|MACAddress|PermanentMACAddress|Type)$/ && value != "" && value != "lo") matched=1
        if (section == "[match]" && key == "Name" && value == "lo") loopback=1
        if (section == "[network]" && ((key == "DHCP" && (yes(value) || value ~ /^ipv[46]$/)) || (key == "IPv6AcceptRA" && yes(value)))) dynamic=1
        if (section ~ /^\[(network|address)\]$/ && key == "Address" && value != "") address=1
      }
    }
    END { exit !(found || finish()) }
  ' "${files[@]}"
}

# Filesystem-only sanity check, also usable for an independently mounted restore target.
function check_restore_network_compatibility() {
  local image target path interfacesfile
  local supported=""
  local networkd=false manager=false ifcfg=false ifcfg_format=ifcfg
  image=$(realpath -e -- "$1") && target=$(realpath -e -- "$2") || return 1
  image=${image%/}; target=${target%/}
  restore_network_has_tool "$image" /lib/systemd/systemd-networkd /usr/lib/systemd/systemd-networkd && networkd=true
  restore_network_has_tool "$image" /usr/sbin/NetworkManager /sbin/NetworkManager && manager=true
  if [ -f "$image/etc/debian_version" ] || [ -d "$image/lib/ifupdown" ] || [ -d "$image/usr/share/ifupdown" ]; then
    if restore_network_has_tool "$image" /sbin/ifup /usr/sbin/ifup; then
      supported="$supported ifupdown"
      local -a interfaces=("$target/etc/network/interfaces")
      interfacesfile=$(realpath -e -- "$target/etc/network/interfaces" 2>/dev/null) || interfacesfile=
      case "$interfacesfile" in "$target"/*)
        if grep -Eq '^[[:space:]]*source[[:space:]]+(/etc/network/)?interfaces\.d/\*([[:space:]]|$)' "$interfacesfile"; then
          interfaces+=("$target/etc/network/interfaces.d/"*)
        elif grep -Eq '^[[:space:]]*source-directory[[:space:]]+(/etc/network/)?interfaces\.d([[:space:]]|$)' "$interfacesfile"; then
          for path in "$target/etc/network/interfaces.d/"*; do
            case "${path##*/}" in *[!a-zA-Z0-9_-]*) continue;; esac
            interfaces+=("$path")
          done
        fi;;
      esac
      restore_network_configured ifupdown "$target" "${interfaces[@]}" && return 0
    fi
  fi
  if restore_network_has_tool "$image" /sbin/ifup /usr/sbin/ifup /etc/sysconfig/network-scripts/ifup &&
      restore_network_has_tool "$image" /etc/sysconfig/network-scripts/ifup-eth; then
    ifcfg=true
  fi
  if $manager; then
    for path in "$image"/usr/lib*/NetworkManager/*ifcfg-rh*.so "$image"/usr/lib*/NetworkManager/*/*ifcfg-rh*.so; do
      if [ -f "$path" ] && ! $ifcfg; then ifcfg=true; ifcfg_format="ifcfg-nm"; fi
    done
    supported="$supported NetworkManager"
    restore_network_configured nm "$target" "$target/etc/NetworkManager/system-connections/"* "$target/lib/NetworkManager/system-connections/"* "$target/usr/lib/NetworkManager/system-connections/"* && return 0
  fi
  if $ifcfg; then
    supported="$supported ifcfg"
    restore_network_configured "$ifcfg_format" "$target" "$target/etc/sysconfig/network-scripts/"ifcfg-* && return 0
  fi
  if restore_network_has_tool "$image" /usr/sbin/netplan /sbin/netplan && { $networkd || $manager; }; then
    supported="$supported Netplan"
    restore_network_configured netplan "$target" "$target/lib/netplan/"*.yaml "$target/usr/lib/netplan/"*.yaml "$target/etc/netplan/"*.yaml && return 0
  fi
  if $networkd; then
    supported="$supported systemd-networkd"
    restore_network_configured networkd "$target" "$target/etc/systemd/network/"*.network && return 0
  fi
  echo "No compatible retained network configuration found for the image backends:${supported:- none recognized}. Configure destination networking for the image, or use --ignorenetwork after manual review." >&2
  return 1
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
function info() {
  echo "$0 info:"
  echo "Archive gz: $archivegz"
  ls -lh "$archivegz"
  echo "Restore path: $restoretopath"
  echo "Old IP: $oldip"
  echo "New IP: $newip"
  echo "Verified extractions are cached under $restorecache."
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
      --ignorenetwork)
        isignorenetwork="xxx"
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

restoretopath=$(realpath -m -- "$restoretopath") || exit 1

[ -z "$archivegz" ] && echo "Use --archivegz file to specify the archive to use." >&2 && exit 1
[ ! -f "$archivegz" ] && echo "--archivegz file $archivegz not found." >&2 && exit 1
select_tar || exit 1
tarprofile=basic
if [ "${#tarmetadataopts[@]}" -gt 0 ]; then
  tarprofile=metadata
fi
if ! command -v sha256sum >/dev/null 2>&1; then
  echo "sha256sum is required for verified extraction reuse." >&2
  exit 1
fi
 
info

ret=0
while true; do 

  [ -z "$isignorehostname" ] && ! grep -q  backup <(hostname) && echo 'hostname ($(hostname)) does not contain the "backup", exiting as a safety precaution.  If this is the right host, set a hostname like: hostname backup.$(hostname)  Disable this check with the --ignorehostname option' && ret=1 && break
  [ -z "$isignoreports" ] && [ 0 -ne "$(netstat -ntp | grep -E -v ':22|Foreign Address|Active Internet connections' | wc -l)" ] && echo "There are some non ssh connections.  Wrong server?  Disable this check with the --ignoreports option" && netstat -ntp && ret=1 && break
  if [ -L "$restorecache" ]; then
    echo "Restore cache must not be a symbolic link: $restorecache" >&2
    ret=1
    break
  fi
  restorecache=$(realpath -m -- "$restorecache") || { ret=1; break; }
  if [ "$restoretopath" != / ]; then
    case "$restoretopath/" in "$restorecache/"*)
      echo "Restore destination overlaps the extraction cache." >&2
      ret=1; break;;
    esac
    case "$restorecache/" in "$restoretopath/"*)
      echo "Restore destination overlaps the extraction cache." >&2
      ret=1; break;;
    esac
  fi
  (umask u=rwx,go=; mkdir -p -- "$restorecache") || { ret=1; break; }
  if command -v flock >/dev/null 2>&1; then
    cachelock="$restorecache/.lock"
    if [ -L "$cachelock" ] || { [ -e "$cachelock" ] && [ ! -f "$cachelock" ]; }; then
      echo "Restore cache lock must be a regular file: $cachelock" >&2
      ret=1
      break
    fi
    exec 9>>"$cachelock" || { ret=1; break; }
    if ! flock --nonblock 9; then
      echo "Another restore is using $restorecache; retry after it finishes." >&2
      ret=1
      break
    fi
  fi
  # Hash stdin so unusual archive filenames cannot alter sha256sum's output format.
  archivesha=$(sha256sum < "$archivegz") || { ret=1; break; }
  archivesha=${archivesha%% *}
  cacheentry="$restorecache/$archivesha-$tarprofile"
  if [ ! -L "$cacheentry" ] && [ -d "$cacheentry/tree" ] &&
      [ ! -L "$cacheentry/tree" ] && [ -f "$cacheentry/complete" ] &&
      [ ! -L "$cacheentry/complete" ] &&
      cachemarker=$(cat "$cacheentry/complete") &&
      [ "$cachemarker" = "s2i-restore-v2:$archivesha:$tarprofile" ]; then
    restorescratchdir="$cacheentry/tree"
    echo "Reusing verified extraction: $restorescratchdir"
  elif [ -e "$cacheentry" ] || [ -L "$cacheentry" ]; then
    echo "Unverified extraction cache: $cacheentry. Move it aside before retrying." >&2
    ret=1
    break
  else
    restorestagingdir=$(mktemp -d "$restorecache/.extract.XXXXXX") || { ret=1; break; }
    # Only unpublished staging data owned by this invocation is removed on exit.
    trap 'if [ -n "$restorestagingdir" ]; then rm -rf -- "$restorestagingdir"; fi' EXIT
    restorescratchdir="$restorestagingdir/tree"
    mkdir -m u=rwx,go= -- "$restorescratchdir" || { ret=1; break; }
  fi
  
  # df --block-size 1 /
  # Filesystem       1B-blocks        Used   Available Use% Mounted on
  #/dev/root      41972088832 17311182848 23785197568  43% /
  dffreeb="$(df --block-size 1 / | awk '{print $4}' | grep -E -v Available | head -n 1)"
  [ -f "$archivegz" ] && archivesizeb="$(( $(stat  --format=%s "$archivegz") * 2))"
  if [ -z "$isignorespace" ] && [ -n "$dffreeb" ] && [ -n "$archivesizeb" ] && [[ $dffreeb -lt $archivesizeb ]]; then
    echo "There may be insufficient space to do a restore.  Disable this check with the --ignorespace option" >&2
    echo "Disk space:"
    df -h /
    exit 1
  fi
  
  if [ -n "$restorestagingdir" ]; then
    echo "Extracting backup to restore directory $restorescratchdir from $archivegz ($(ls -lh "$archivegz"))"
    if ! "$tarcmd" --extract --gzip --file "$archivegz" --directory "$restorescratchdir" \
        --numeric-owner --preserve-permissions "${tarmetadataopts[@]}"; then
      ret=1
      break
    fi
    extractedsha=$(sha256sum < "$archivegz") || { ret=1; break; }
    if [ "${extractedsha%% *}" != "$archivesha" ]; then
      echo "Archive changed during extraction; the extraction will not be reused." >&2
      ret=1
      break
    fi
    # Publish the completion record with its tree; never copy it to the restore target.
    printf '%s\n' "s2i-restore-v2:$archivesha:$tarprofile" > "$restorestagingdir/complete" || { ret=1; break; }
    mv --no-target-directory -- "$restorestagingdir" "$cacheentry" || { ret=1; break; }
    restorestagingdir=
    restorescratchdir="$cacheentry/tree"
  fi
  [ -z "$restorescratchdir" ] && echo "no restore directory set" >&2 && ret=1 && break
  
  # root@2023-05:~# rsync --exclude-from /asdf/asdf t t2
  # rsync: [client] failed to open exclude file /asdf/asdf: No such file or directory (2)
  restorescratchdir="$(realpath "$restorescratchdir")" || { ret=1; break; }
  if [ "$restoretopath" = / ]; then
    if [ -z "$isignorenetwork" ]; then
      check_restore_network_compatibility "$restorescratchdir" "$restoretopath" || { ret=1; break; }
    fi
    echo "Stopping services that may interfere with the restore."
    # Example: systemctl list-unit-files => mysql.service enabled
    for i in $(systemctl list-unit-files | grep -v '@' | grep -E 'redis|fail2ban|postfix|virtualmin|webmin|usermin|named|dovecot|proftp|exim|spamass|php|postgres|mailman|mysql|mariadb|amavis|apache' | awk '{print $1}' ); do
      echo "Stopping: $i"
      systemctl stop "$i"
    done
  fi
  echo "Rsync-ing from $restorescratchdir to ${restoretopath:-/}"
   # --force-change for immutables, but does not work on some distros. e.g. 311/2014
   # --force = force deletion of dirs even if not empty
   # using realpath below since "rsync /root/s2i.restore /" creates /s2i.restore.  Rather we need "rsync /root/s2i.restore/ /" 
rsync --force --delete --archive --hard-links --xattrs --perms --executability --acls --owner --group --specials --times --numeric-ids --ignore-errors \
--exclude="$restorecache/" \
"${networkexcludeopts[@]}" \
--exclude='/root/s2i*' \
--exclude=/root/rsync* \
--exclude=/root/.ssh/authorized_keys \
--exclude='/etc/ssh/ssh_host_*' \
--exclude=/etc/fstab \
--exclude=/boot \
--exclude=/proc \
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
"$restorescratchdir/" "${restoretopath:-/}" 2>&1 | tee -a rsync.log
  RC=( "${PIPESTATUS[@]}" )
  if [ "${RC[0]}" -ne 0 ] || [ "${RC[1]}" -ne 0 ]; then
    echo "Error or warning from rsync." >&2
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
    find "${restoretopath%/}/etc/" -type f ! -name hosts -print0 | (
      while IFS= read -r -d '' configfile; do
        # rsync exclusions alone do not protect retained files from this second pass.
        is_preserved_network_path "${configfile#"${restoretopath%/}"}" && continue
        if grep -q -F -- "$oldip" "$configfile"; then
          replace "$oldip" "$newip" -- "$configfile" || exit 1
        else
          grepstatus=$?
          [ "$grepstatus" -eq 1 ] || exit 1
        fi
      done
    )
    RC=( "${PIPESTATUS[@]}" )
    if [ "${RC[0]}" -ne 0 ] || [ "${RC[1]}" -ne 0 ]; then
      echo "Failed to update IP addresses under ${restoretopath%/}/etc/." >&2
      ret=1
    fi
   fi
   break
done
# set an exit code
if [ "$ret" -ne 0 ]; then
  false;
else 
  true
fi
