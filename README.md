# s2i

A set of scripts to help with Linux server backups and restores.

s2i-create.sh creates an archive of a Linux server.  One that can be extracted to / on another server to clone the original server.  This is handy if you wanted to take a full backup image of a server, that you may wish to restore at some point in the future.  e.g. after closing down some VM hosting, or in the event of a disaster.  For best results, stop services that may be writing to files prior to creating the archive.

backup.sh performs a database backup, uses s2i-create.sh to create an archive image of the server, provides a few options around encryption (openssl, none, or zip), and has an option to make that archive accessible via http (if you prefer not to use a more secure method, like scp/sftp, to access it).

s2i-restore.sh is a template script to restore that backup over top of an existing server (either the same one from which the backup was taken, or a different server).  It would need to be edited to exclude/include files that may be specific to your setup (e.g. typically networking files).

Should you need a location to store the backup you can setup an account at https://bakop.com/ which will provide a scp/sftp based storage location for the backup.  Which can be used later if you need to restore that image.

# s2i-create.sh

```bash
bash s2i-create.sh --help
  s2i-create.sh Creates a backup of a Linux server.  It has options to let you download that via http (else you can scp it from the source).  It has options to encrypt the backup file (e.g. via openssl or zip).
  
  Usage: s2i-create.sh 
    --files (default to / )

    --outputdir output directory [ /root/s2i.backup ]
    --outputfile output file [ s2i.backup-2023-03-30-1680128155 ]
    --outputextn output file extension [ gz | zip | gz.enc depending on encryption ]
    --outputpath output file full path (overrides other output options)

    --encrypt openssl (default if using --http) | zip (not so secure) | none (default if not using --http)
    --password by default we will create a password for you.  And use the same password each time the same outputdir is used.  NA if encrypt==none.
    --http (serve file on an http url)
    --size output the size of the backup (without creating it or using any disk space)
    
  
  Put files/directories you wish to exclude in /root/s2i.backup/exclude.log
  
  By default the script will exclude directories including /proc /tmp /mnt /dev /sys /run /media
  
  The default backup includes binary database files (if any, e.g. for postgres and mysql).  You may prefer to exclude them, and run a database dump instead (e.g. per mysqlbackup.sh).
  
  You can also stop database servers and other processes that may be updating files while you run this script.
  
  If you use the --http option we will put the file on a URL that should be secret.  However we still recommend you use one of the --encrypt options.
  
  There is a backup.sh script that will let you run mysql database backups, prior to running s2i-create.sh
  
  You can use Unix pipes to create a backup on a remote server without using much space for the backup on the source server.
  
  Sample usage using pipes.  On the server being backed up:
  mkdir s2i.backup
  mkfifo s2i.backup/fifo
  echo '/dont/backup/this/dir' > s2i.backup/exclude.log
  nohup bash ./s2i-create.sh --outputpath s2i.backup/fifo
  
  While this is running, go to the destination server:
  ssh backupserver cat s2i.backup/fifo > s2i.backup.gz
  
  Then use the s2i-restore.sh script if/when you need to overwrite a server image with a backup image.
 
  ```
  
# mysqlbackup.sh
 
 ```bash
 bash mysqlbackup.sh --help
 
mysqlbackup.sh Creates a mysql backup.  Optionally copy that to a backup host
  
  Usage: mysqlbackup.sh
    --databases mysql database names to backup.  defaults to none.  If .mysqlp is present it will be used for the pasword
    --all-databases backs up all user mysql databases
    --outputdir where to place the backup image [ defaults to ./mysqldump ]
    --remotehost IP address or hostname of host where you wish to copy the backup image
  
  Uses (or creates) an SSH key for backups at .backup.private.key
  
  Uses .mysqlp for a mysql password
```  

# s2i-restore.sh
Restores an s2i-create.sh backup.

s2i-restore.sh extracts the archive gz file (created by s2i-create.sh).  Then rsyncs that over top of the server on which you are running the restore.

It can also do a search/replace in /etc of the old and new IP addresses.

```
./s2i-restore.sh --help
./s2i-restore.sh usage:
  [ --oldip originalip ] [--newip newip/defaults to this server's IP ] set if you want to search/replace these IP values on the restored image
  [ --archivegz path ] defaults to the only and only big gz file in the current directory
  [ --restoretopath path ] defaults to the /
  [ --ignoreports ] lets the restore proceed even if ports are in use (a safety precaution)
  [ --ignorehostname ] lets the restore proceed even if the server hostname is not like backup.something (a safety precaution)
  [ --ignorespace ] lets the restore proceed even if the script reports there may be insufficient space (a safety precaution)
  Will extract the tar.gz archivegz to the restoretopath (default /)
```

Only run s2i-restore.sh on a server you are certain can be overwritten.

As a safeguard to overwriting a production system s2i-restore.sh checks for 'backup' in the hostname, and checks for network connections other than ssh to the server.  There are options to disable these checks.

After a restore, run a ```reboot --force```, fingers crossed, and you will be booted into a copy of the original server.

Tested on a few VMs.  Not tested on a physical server.  Use at your own risk.

RimuHosting offers this backup/restore (+ dist upgrade) as a service.  See https://blog.rimuhosting.com/2021/07/12/distro-upgrade-as-a-service/
