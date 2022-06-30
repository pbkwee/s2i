 s2i

A set of scripts to help with Linux server backups and restores.

server-to-image.sh creates an archive of a Linux server.  One that can be extracted to / on another server to clone the original server.  This is handy if you wanted to take a full backup image of a server, that you may wish to restore at some point in the future.  e.g. after closing down some VM hosting, or in the event of a disaster.

backup.sh performs a database backup, uses server-to-image.sh to create an archive image of the server, provides a few options around encryption (openssl, none, or zip), and has an option to make that archive accessible via http (if you prefer not to use a more secure method, like scp/sftp, to access it).

restore.sh is a template script to restore that backup over top of an existing server (either the same one from which the backup was taken, or a different server).  It would need to be edited to exclude/include files that may be specific to your setup (e.g. typically networking files).

# server-to-image.sh

```bash
bash server-to-image.sh --help
```
 
server-to-image.sh Creates a backup of a Linux server.  It has options to let you download that via http (else you can scp it from the source).  It has options to encrypt the backup file (e.g. via openssl or zip).
  
    --encrypt openssl (default if using --http) | zip (not so secure) | none (default if not using --http)
    
    --http (serve file on an http url)
    
    --files (default to / )
    
    --size output the size of the backup (without creating it or using any disk space)
    
    --outputdir output directory [ /root/backup.s2i ]
    
    --outputfile output file [ backup-2021-11-28-1638053991 ]
    
    --outputextn output file extension [ gz | zip | gz.enc depending on encryption ]
    
    --outputpath output file full path (overrides other output options)
    
    --password by default we will create a password for you.  And use the 
    same password each time the same outputdir is used.
  
We recommend you stop database servers and other processes that may be updating files while you run this script.
  
# backup.sh
 
 ```bash
 bash backup.sh --help
 ```
 
backup.sh Creates a backup of a Linux server.  Runs a database backup.  Then creates an image from the server.  Then copies that to a backup host
  
    --databases mysql database names to backup.  defaults to none.  If /root/.mysqlp is present it will be used for the pasword
    
    --outputpath where to place the backup image [ defaults to /root/s2i/s2i.gz ]
    
    --remotehost IP address or hostname of host where you wish to copy the backup image

Sample output:

```bash
   bash -x backup3.sh --databases dbname --remotehost 185.x.x.x --outputpath s2i/s2i.gz 
   
   Backing up databases: dbname
   
   Using the contents of /root/.mysqlp for the mysql password.
   
   Creating a backup archive file.
   
   Not using http, not doing backup file encryption
   
   Starting server-to-image at 2021-11-27-1638053175
   
   Creating tar file, not encrypted, at s2i/s2i.gz
   
   Backup created: -rw-r--r-- 1 root root 7.9G Nov 27 22:59 s2i/s2i.gz
   
   Creating an agent...
   
   Agent pid 34123
   
   Identity added: /root/.backup.private.key (backupkey)
   
   Copying backup file to 185.x.x.x
   
   s2i.gz                                                                                         100% 8073MB   7.5MB/s   18:02    
```

# restore.sh
A template for restoring a backup.  Edit as appropriate for your setup.
