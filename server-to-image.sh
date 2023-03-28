#!/bin/bash

#
# Copyright Rimuhosting.com
# https://rimuhosting.com

function usage {
  echo " 
  $0 Creates a backup of a Linux server.  It has options to let you download that via http (else you can scp it from the source).  It has options to encrypt the backup file (e.g. via openssl or zip).
  
  Usage: $0 
    --files (default to / )

    --outputdir output directory [ /root/backup.s2i ]
    --outputfile output file [ backup-$dt ]
    --outputextn output file extension [ gz | zip | gz.enc depending on encryption ]
    --outputpath output file full path (overrides other output options)

    --encrypt openssl (default if using --http) | zip (not so secure) | none (default if not using --http)
    --password by default we will create a password for you.  And use the same password each time the same outputdir is used.  NA if encrypt==none.
    --http (serve file on an http url)
    --size output the size of the backup (without creating it or using any disk space)
    
  
  Put files/directories you wish to exclude in $(dirname "$outputpath")/exclude.log
  
  The default backup includes binary database files (if any, e.g. for postgres and mysql).  You may prefer to exclude them, and run a database dump instead (e.g. per mysqlbackup.sh).
  
  You can also stop database servers and other processes that may be updating files while you run this script.
  
  If you use the --http option we will put the file on a URL that should be secret.  However we still recommend you use one of the --encrypt options.
  
  There is a backup.sh script that will let you run mysql database backups, prior to running server-to-image.sh
  
  You can use Unix pipes to create a backup on a remote server without using much space for the backup on the source server.
  
  Sample usage using pipes.  On the server being backed up:
  mkdir bu
  mkfifo bu/fifo
  echo '/dont/backup/this/dir' > bu/exclude.log
  nohup bash ./s2i --outputpath bu/fifo
  
  While this is running, go to the destination server:
  ssh backupserver cat bu/fifo > backupserver.gz
  
  Then use the restore.sh script if/when you need to overwrite a server image with a backup image.
  
  "
  return 0
}

# date like 2021-06-28-1624846640
dt="$(date +%Y-%m-%d-%s)"

# openssl, none, zip
encrypt=""
ishttp=""
files=/
issize=""
outputdir="${outputdir:-/root/backup.s2i}"
outputfile="${outputfile:-backup-$dt}"
function parse() {
  while [ -n "$1" ]; do
    case "$1" in
      --encrypt)
        shift
        if [ -z "$1" ]; then
          echo "Missing --encrypt type" >&2
          isusage="xxx"
        elif [ "$1" == "openssl" ] ; then
          encrypt="openssl"
        elif [ "$1" == "zip" ]; then
           encrypt="zip"
        elif [ "$1" == "none" ]; then
           encrypt="none"
        else 
          echo "Unrecognized --encrypt type '$1'" >&2
          isusage="xxx"
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
        ;;
        --size)
          issize="xxx"
        ;;
        --files)
          shift
          if [ -z "$1" ]; then
            echo "Missing --files argument" >&2
            isusage="xxx"
          fi
          files="$1"
          for i in $files; do 
            [ ! -e "$i" ] && echo "No such file as $i" >&2 && return 1
          done
        ;;
        --http)
          ishttp="xxx"
        ;;
        -? | --help)
          isusage="xxx"
        ;;
        *)
          echo "Unrecognized parameter '$1'" >&2
          isusage="xxx"
        ;;
      esac
    shift
  done
}

# rsync typically needed on the restore side
if ! which rsync 1>/dev/null 2>&1; then 
  which apt-get 1>/dev/null 2>&1 && apt-get -y install rsync 
fi

if ! which tar 1>/dev/null 2>&1; then
  echo "tar not installed." >&2
  exit 1 
fi

parse "$@" || exit 1

[ -z "$ishttp" ] && [ -z "$encrypt" ] && encrypt="none" && echo "Not using http, not doing backup file encryption"
[ -n "$ishttp" ] && [ -z "$encrypt" ] && encrypt="openssl" && echo "Using http, enabling backup file openssl encryption"

if [ "$encrypt" == "openssl" ]; then
  outputextn="${outputextn:-gz.enc}"
elif [ "$encrypt" == "zip" ]; then
  outputextn="${outputextn:-zip}"
elif [ "$encrypt" == "none" ]; then
  outputextn="${outputextn:-gz}"
fi

outputpath="${outputpath:-$outputdir/$outputfile.$outputextn}"

# Now we are in a position to run usage if needed.
if [ -n "$isusage" ] ; then
  usage
  exit 1
fi

# create a backup directory
[ ! -d "$(dirname "$outputpath")" ] && mkdir -p "$(dirname "$outputpath")"

if [ -z "$password" ]; then
  # random password of letters and digits
  [ ! -f "$(dirname "$outputpath")/.bupassword" ] && LC_ALL=C </dev/urandom tr -dc A-Z0-9 | head -c10 > "$(dirname "$outputpath")/.bupassword"

  password="$(cat "$(dirname "$outputpath")/.bupassword")"
else 
  echo "$password" > "$(dirname "$outputpath")/.bupassword"
fi

#cd "$(dirname "$outputpath")"

# exclude mysql and log files, but keep directory structure
[ -d /var/log ] && find /var/log -type f | grep -E -v 'mysql|mariadb' > "$(dirname "$outputpath")/exclude-default.log"
[ -d /var/cache/apt/archives ] && find  /var/cache/apt/archives -type f >> "$(dirname "$outputpath")/exclude-default.log"
touch "$(dirname "$outputpath")/exclude.log"

#find /var/lib/mysql -type f > "$(dirname "$outputpath")/exclude-default.log"
# exclude sockets
# cannot use -type s,p => Arguments to -type should contain only one letter
find "$([ -d /tmp ] && echo /tmp)"  "$([ -d /var ] && echo /var )" "$([ -d /run ] && echo /run)" -type s  -print 2>/dev/null >> "$(dirname "$outputpath")/exclude-default.log"
find "$([ -d /tmp ] && echo /tmp)"  "$([ -d /var ] && echo /var )" "$([ -d /run ] && echo /run)" -type p  -print 2>/dev/null >> "$(dirname "$outputpath")/exclude-default.log"

# create a tar file, exclude certain directories
# encrypt the data using openssh with the provided password

taropts="--numeric-owner --create --preserve-permissions --gzip --file - 
--exclude-from=$(dirname "$outputpath")/exclude.log
--exclude-from=$(dirname "$outputpath")/exclude-default.log
--exclude=$(dirname "$outputpath")
--exclude=/root/backup.* 
--exclude=/restore* 
--exclude=/proc 
--exclude=/tmp 
--exclude=/mnt 
--exclude=/dev 
--exclude=/sys
--exclude=/run 
--exclude=/media 
--exclude=/usr/src/linux-headers* 
--exclude=/home/*/.gvfs 
--exclude=/home/*/.cache 
--exclude=/home/*/.local/share/Trash $files"

ip="$(ifconfig eth0 | grep 'inet ' | sed 's/inet addr:/inet /' | awk '{print $2}')"
# The following works on recent distros with iproute installed.
[ -z "$ip" ] && ip="$(ip --json route get 1|awk -vRS="," '/src/'|tr -d "\""|cut -d: -f2)"
[ -z "$ip" ] && echo "Could not determine IP address." >&2 && exit 1 

echo "Starting server-to-image at $dt" | tee "$(dirname "$outputpath")/.buinstructions"
if [ -n "$issize" ]; then
  echo "Checking the file size of the backup..." | tee -a "$(dirname "$outputpath")/.buinstructions"
  if [ "$encrypt" == "openssl" ]; then
    bytes="$(tar "$taropts" | openssl enc -aes-256-cbc  -md sha256 -pass "pass:$password"  | wc -c)"
  elif [ "$encrypt" == "zip" ]; then
    bytes="$(tar "$taropts" | zip --encrypt --password "$password"  | wc -c)"
  elif [ "$encrypt" == "none" ]; then
    bytes="$(tar "$taropts" | wc -c)"
  else
    bytes="NA"
  fi
  echo "The backup size is $bytes bytes $(which numfmt 2>&1 >/dev/null && numfmt --to=iec-i --suffix=B --padding=7 $bytes)" | tee -a "$(dirname "$outputpath")/.buinstructions"
  exit 0
fi
ret=0
if [ "$encrypt" == "openssl" ]; then
  echo "Creating tar file, openssl encrypted, at $outputpath" | tee -a "$(dirname "$outputpath")/.buinstructions"
  tar "$taropts" | openssl enc -aes-256-cbc  -md sha256 -pass "pass:$password"  > "$outputpath"
  RC=( "${PIPESTATUS[@]}" )
  [ "${RC[0]}" -ne 0 ] || [ "${RC[1]}" -ne 0 ] && ret=1
  echo "OpenSSL command to decrypt the $outputpath backup file openssl enc -d -aes-256-cbc  -md sha256 -pass "pass:$password" -in $outputpath -out backup.tar.gz" | tee -a "$(dirname "$outputpath")/.buinstructions" 
elif [ "$encrypt" == "zip" ]; then
  echo "Creating zip file, password encrypted (password is $password), at $outputpath" | tee -a "$(dirname "$outputpath")/.buinstructions"
  tar "$taropts" | zip --encrypt --password "$password"  > "$outputpath"
  RC=( "${PIPESTATUS[@]}" )
  [ "${RC[0]}" -ne 0 ] || [ "${RC[1]}" -ne 0 ] && ret=1
elif [ "$encrypt" == "none" ]; then
  echo "Creating tar file, not encrypted, at $outputpath" | tee -a "$(dirname "$outputpath")/.buinstructions"
  tar "$taropts" > "$outputpath"
  ret=$?
else
  echo "Unexpected encryption type '$encrypt'" >&2
  exit 1
fi
[ $ret -ne 0 ] && echo "Backup creation failed.">&2 && exit 1

echo "Backup created: $(ls -lh "$outputpath")" | tee -a "$(dirname "$outputpath")/.buinstructions"
# record the full path of the output
echo "$outputpath" > "$(dirname "$outputpath")/.outputpath"

secretdirname="$(LC_ALL=C </dev/urandom tr -dc A-Z0-9 | head -c10)"
if [ -n "$ishttp" ]; then
  mkdir -p "$(dirname "$outputpath")/$secretdirname"
  mv "$outputpath" "$(dirname "$outputpath")/$secretdirname/"
  newoutputpath="$(dirname "$outputpath")/$secretdirname/$(basename "$outputpath")"
  echo "Moving the output file from $outputpath file to $newoutputpath, to improve HTTP security" | tee -a "$(dirname "$outputpath")/.buinstructions"
  outputpath="$newoutputpath"
  # offer the file for download.  Kill this process off after you have downloaded the file.  
  # PHP has a built in web server
  # at job to kill off process after 24h?
  nohup php -S "$ip:32956" &
  echo "Download your backup from http://$ip:32956/$secretdirname/$(basename "$outputpath")" | tee -a "$(dirname "$outputpath")/.buinstructions"
  phppid="$(netstat -ntpl  | grep 32956 | sed 's/.*LISTEN *//' | sed 's#/.*##')"
  [ -n "$phppid" ] && echo "After you have downloaded the file, stop the temporary web server with: kill $phppid" | tee -a "$(dirname "$outputpath")/.buinstructions"
fi

echo "You can access your backup file via scp:" | tee -a "$(dirname "$outputpath")/.buinstructions"
if [ "$encrypt" == "openssl" ] ; then
  echo "mkdir restore.$dt && cd restore.$dt && scp root@$ip:$outputpath /dev/stdout | openssl enc -d -aes-256-cbc  -md sha256 -pass "pass:$password" | tar  --extract --gunzip --numeric-owner --preserve-permissions " | tee -a "$(dirname "$outputpath")/.buinstructions"
  echo "Should you need openssl for windows, you may download that.  For example from https://curl.se/windows/" | tee -a "$(dirname "$outputpath")/.buinstructions"
elif [ "$encrypt" == "none" ] ; then
  echo "mkdir restore.$dt && cd restore.$dt && scp root@$ip:$outputpath /dev/stdout | tar  --extract --gunzip --numeric-owner --preserve-permissions" | tee -a "$(dirname "$outputpath")/.buinstructions"  
elif [ "$encrypt" == "zip" ] ; then
  echo "scp root@$ip:$outputpath ." | tee -a "$(dirname "$outputpath")/.buinstructions"
else
  echo "Unrecognized encrypt type of '$encrypt'" >&2
  exit 1 
fi

