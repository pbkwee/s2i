#!/bin/bash
#
# Copyright Rimuhosting.com
# https://rimuhosting.com

function usage {
  echo " 
  $0 Creates a mysql backup.  Optionally copy that to a backup host
  
  Usage: $0
    --databases mysql database names to backup.  defaults to none.  If .mysqlp is present it will be used for the pasword
    --all-databases backs up all user mysql databases
    --mysqldump use mysqldump instead of mydumper
    --outputdir where to place the backup image [ defaults to ./mysqldump ]
    --remotehost IP address or hostname of host where you wish to copy the backup image
  
  Uses (or creates) an SSH key for backups at .backup.private.key
  
  Uses .mysqlp for a mysql password
  "
  return 0
}

outputdir="./mysqldump-$(date +%Y-%m-%d-%s)"

function parse() {
  while [ -n "$1" ]; do
    case "$1" in
      --outputdir)
        shift
        [ -z "$1" ] && echo "Missing output path" >&2 && return 1
        [ -z "$(dirname "$1")" ] && echo "Need a full path and filename for outputdir" >&2 && return 1
        [ "." == "$(dirname "$1")" ] && echo "Need a full path and filename for outputdir" >&2 && return 1
        outputdir="$1"
        ;;
      --all-databases)
        mysqlargs=()
        if [ -f .mysqlp ]; then
          mysqlpassword="$(cat .mysqlp)" || return 1
          mysqlargs=("--password=$mysqlpassword")
        fi
        databaseoutput="$(mysql "${mysqlargs[@]}" -e 'show databases')" || {
          echo "Unable to get a list of the databases from mysql." >&2
          return 1
        }
        databases="$(printf '%s\n' "$databaseoutput" | grep -E -v '^(Database|mysql|information_schema|performance_schema)$')"
        [ -z "$databases" ] && echo "Unable to get a list of the databases.  If a password is necessary you may put it in a file .mysqlp " >&2 && return 1
        ;;
      --mysqldump)
        MYSQLDUMP="x"
        ;;
      --remotehost)
        shift
        if [ -z "$1" ]; then
          echo "Missing --remotehost argument" >&2
          usage
          return 1
        fi
        remotehost="$1"
      ;;
      --databases)
        shift
        if [ -z "$1" ]; then
          echo "Missing --databases argument" >&2
          usage
          return 1
        fi
        databases="$1"
      ;;
      -? | --help)
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

[ -e "$outputdir" ] && echo "--outputdir already exists" >&2 && exit 1

mkdir -p "$outputdir" || exit 1

if command -v dpkg 2>/dev/null >/dev/null; then
  if ! dpkg -l | grep -qai mydumper; then 
    echo "Installing mydumper tool..."
    apt-get -y install mydumper
  fi
  if ! dpkg -l | grep -qai percona-toolkit; then
     echo "Installing percona toolkit (for grants)..."
     apt-get -y install percona-toolkit
  fi
fi

[ ! -f .backup.private.key ] && ssh-keygen -f .backup.private.key -t rsa -C "backupkey" -N "" 
if [ -n "$remotehost" ] && [ -n "$SSH_AUTH_SOCK" ]; then
  [ -f .backup.private.key.pub ] && scp .backup.private.* "$remotehost:" && ssh "$remotehost" 'mkdir -p .ssh; [ ! -f .ssh/authorized_keys ] && touch .ssh/authorized_keys; ! grep --fixed-strings "$(cat .backup.private.key.pub)" .ssh/authorized_keys && cat .backup.private.key.pub >> .ssh/authorized_keys'
fi

ret=0

if ! command -v mydumper 2>/dev/null >/dev/null && [ -z "$MYSQLDUMP" ] ; then
    echo "Unable to install mydumper, falling back to mysqldump." >&2
    MYSQLDUMP="x"
fi 

[ -z "$databases" ] && echo "No --databases db1,db2 provided, no --all-databases set.  Skipping mysql backups."

# creates a file per db table
if [ -n "$databases" ]; then
  echo "Backing up databases: $databases to $outputdir"
  [ ! -f .mysqlp ] && echo "No .mysqlp file, not setting a password parameter."
  [ -f .mysqlp ] && echo "Using the contents of .mysqlp file for the mysql password."
  mysqlargs=()
  mysqldumpargs=()
  grantsargs=()
  if [ -f .mysqlp ]; then
    mysqlpassword="$(cat .mysqlp)" || exit 1
    mysqlargs=(--password "$mysqlpassword")
    mysqldumpargs=("--password=$mysqlpassword")
    grantsargs=("-p$mysqlpassword")
  fi
  if command -v pt-show-grants 2>/dev/null >/dev/null ; then
    echo "Saving database grants/permissions to $outputdir/grants.sql"  
    pt-show-grants "${grantsargs[@]}" > "$outputdir/grants.sql" || ret=1
  fi
  echo "Backing up $databases..."
  # Database names are a whitespace-separated list, as in the existing interface.
  for db in $databases; do
    if [ -z "$MYSQLDUMP" ] ; then
      mydumper "${mysqlargs[@]}" --outputdir "$outputdir" --compress --routines --triggers --events --complete-insert --tz-utc --database "$db" || ret=1
    else 
      mysqldump "${mysqldumpargs[@]}" --routines --triggers --events --complete-insert --tz-utc "$db" | gzip > "$outputdir"/"${db}".sql.gz
      RC=( "${PIPESTATUS[@]}" )
      if [ "${RC[0]}" -ne 0 ] || [ "${RC[1]}" -ne 0 ]; then
        ret=1
      fi
    fi
  done
  [ $ret -ne 0 ] && exit 1
fi

echo "Creating a backup archive file."
# $- lists the set options.  e.g. echo $-=>himBH .  If we are -x keep on being -x
#bash $( [ ! -z "${-//[^x]/}" ] && echo "-x") s2i-create.sh --outputpath "$outputpath"
#[ $? -ne 0 ] && ret=1

[ -z "$remotehost" ] && echo "No --remotehost provided.  Skipping copying backup to any remote host."
if [ -n "$remotehost" ]; then
  SSHAGENT=/usr/bin/ssh-agent
  SSHAGENTARGS="-s"
  if [ -z "$SSH_AUTH_SOCK" ] && [ -x "$SSHAGENT" ]; then
    echo "Creating an agent..."
    eval "$("$SSHAGENT" "$SSHAGENTARGS")"
    # Capture the PID of the agent this script started.
    # shellcheck disable=SC2064
    trap "kill $SSH_AGENT_PID && echo killing agent $SSH_AGENT_PID" 0
  fi
  chmod u=rw,og=  .backup.private.key
  ssh-add -l | grep -qai backup || ssh-add .backup.private.key
  echo "Copying backup file to $remotehost"
  scp -r "$outputdir" "$remotehost:" || ret=1
fi

exit "$ret"
