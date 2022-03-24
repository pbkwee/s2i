#!/bin/bash
#
# Copyright Rimuhosting.com
# https://rimuhosting.com

function usage {
  echo " 
  $0 Creates a backup of a Linux server.  Runs a database backup.  Then creates an image from the server.  Then copies that to a backup host
  
  Usage: $0
    --databases mysql database names to backup.  defaults to none.  If .mysqlp is present it will be used for the pasword
    --all-databases backs up all user mysql databases
    --outputpath where to place the backup image [ defaults to s2i/s2i.gz ]
    --remotehost IP address or hostname of host where you wish to copy the backup image
  
  "
  return 0
}

outputpath=s2i/s2i.gz

function parse() {
  while [ -n "$1" ]; do
    case "$1" in
      --outputpath)
        shift
        [ -z "$1" ] && echo "Missing output path" >&2 && return 1
        [ -z "$(dirname $1)" ] && echo "Need a full path and filename for outputpath" >&2 && return 1
        [ "." == "$(dirname $1)" ] && echo "Need a full path and filename for outputpath" >&2 && return 1
        outputpath="$1"
        ;;
      --all-databases)
        databases="$(mysql $([ -f .mysqlp ] && echo "--password $(cat .mysqlp)") -e 'show databases' | cat | egrep -v 'Database|^mysql$|information_schema|performance_schema')"
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


parse $*
[ $? -ne 0 ] && exit 1

dpkg -l | grep -qai mydumper || apt-get -y install mydumper
dpkg -l | grep -qai percona-toolkit || apt-get -y install percona-toolkit

[ ! -f .backup.private.key ] && ssh-keygen -f .backup.private.key -t rsa -C "backupkey" -N "" 
if [ ! -z "$remotehost" ] && [ ! -z "$SSH_AUTH_SOCK" ]; then
  [ -f .backup.private.key.pub ] && scp .backup.private.* $remotehost: && ssh $remotehost 'mkdir -p .ssh; [ ! -f .ssh/authorized_keys ] && touch .ssh/authorized_keys; ! grep --fixed-strings "$(cat .backup.private.key.pub)" .ssh/authorized_keys && cat .backup.private.key.pub >> .ssh/authorized_keys'    
fi

ret=0
[ -z "$databases" ] && echo "No --databases provided.  Skipping mysql backups."
# creates a file per db table
if [ ! -z "$databases" ]; then
  echo "Backing up databases: $databases"
  [ ! -d mysqlbackup ] && mkdir mysqlbackup
  [ ! -f .mysqlp ] && echo "No .mysqlp, not setting a password parameter."
  [ -f .mysqlp ] && echo "Using the contents of .mysqlp for the mysql password."
  pt-show-grants $([ -f .mysqlp ] && echo "-p$(cat .mysqlp)") > mysqlbackup/grants.sql
  [ $? -ne 0 ] && ret=1
  for db in $databases; do
    if [ -z "$MYSQLDUMP" ] ; then
      mydumper $([ -f .mysqlp ] && echo "--password $(cat .mysqlp)") --outputdir mysqlbackup --compress --routines --triggers --events --complete-insert --tz-utc $( [ ! -z "$db" ] && echo " --database $db" )
      [ $? -ne 0 ] && ret=1
    else 
      mysqldump $([ -f .mysqlp ] && echo "--password=$(cat .mysqlp)") --routines --triggers --events --complete-insert --tz-utc $db | gzip > mysqlbackup/"${db}".sql.gz
      [ $? -ne 0 ] && ret=1
    fi
  done
  [ $ret -ne 0 ] && exit 1
fi

echo "Creating a backup archive file."
# $- lists the set options.  e.g. echo $-=>himBH .  If we are -x keep on being -x
bash $( [ ! -z "${-//[^x]/}" ] && echo "-x") server-to-image.sh --outputpath "$outputpath"
[ $? -ne 0 ] && ret=1

[ -z "$remotehost" ] && echo "No --remotehost provided.  Skipping copying backup to any remote host."
if [ ! -z "$remotehost" ]; then
  SSHAGENT=/usr/bin/ssh-agent
  SSHAGENTARGS="-s"
  if [ -z "$SSH_AUTH_SOCK" -a -x "$SSHAGENT" ]; then
    echo "Creating an agent..."
    eval $($SSHAGENT $SSHAGENTARGS)
    trap "kill $SSH_AGENT_PID && echo killing agent $SSH_AGENT_PID" 0
  fi
  chmod u=rw,og=  .backup.private.key
  ssh-add -l | grep -qai backup || ssh-add .backup.private.key
  echo "Copying backup file to $remotehost"
  scp $outputpath $remotehost:
  [ $? -ne 0 ] && ret=1
fi

exit $ret
