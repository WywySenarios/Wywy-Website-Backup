#!/bin/bash
# Create secure chroot directory at runtime
mkdir -p /var/run/vsftpd/empty
chmod 755 /var/run/vsftpd/empty

# Ensure FTP home directory exists and owned by ftpuser
mkdir -p /srv/ftp
chown -R $FTP_UID:$FTP_GID /srv/ftp
chown -R $FTP_UID:$FTP_GID /srv
chmod -R 755 /srv/ftp

# logs
touch /var/log/vsftpd.log
chmod 644 /var/log/vsftpd.log
chown root:root /var/log/vsftpd.log

echo "Starting vsftpd..."

# Start vsftpd in foreground
exec /usr/sbin/vsftpd /etc/vsftpd.conf