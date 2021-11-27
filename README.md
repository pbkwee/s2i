# s2i

# server-to-image.sh

 bash server-to-image.sh --help
 
  server-to-image.sh Creates a backup of a Linux server.  It has options to let you download that via http (else you can scp it from the source).  It has options to encrypt the backup file (e.g. via openssl or zip).
  
  Usage: server-to-image.sh 
  
    --encrypt openssl (default if using --http) | zip (not so secure) | none (default if not using --http)
    
    --http (serve file on an http url)
    
    --files (default to / )
    
    --size output the size of the backup (without creating it or using any disk space)
    
    --outputdir output directory [ /root/backup.s2i ]
    
    --outputfile output file [ backup-2021-11-28-1638053991 ]
    
    --outputextn output file extension [ gz | zip | gz.enc depending on encryption ]
    
    --outputpath output file full path (overrides other output options)
    
    --password by default we will create a password for you.  And use the same password each time the same outputdir is used.
  
  We recommend you stop database servers and other processes that may be updating files while you run this script.
  
  If you use the --http option we will put the file on a URL that should be secret.  However we still recommend you use one of the --encrypt options.
  
 # backup.sh
 
 bash backup.sh --help
 
  backup.sh Creates a backup of a Linux server.  Runs a database backup.  Then creates an image from the server.  Then copies that to a backup host
  
  Usage: backup.sh
  
    --databases mysql database names to backup.  defaults to none.  If /root/.mysqlp is present it will be used for the pasword
    
    --outputpath where to place the backup image [ defaults to /root/s2i/s2i.gz ]
    
    --remotehost IP address or hostname of host where you wish to copy the backup image

# restore.sh
A template for restoring a backup.  Edit as appropriate for your setup.
