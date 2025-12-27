FROM debian:bookworm

ARG FTP_UID
ARG FTP_GID
ARG FTP_USER
ARG FTP_PASSWORD

RUN apt update && apt install -y vsftpd

RUN groupadd -g ${FTP_GID} ${FTP_USER} \
    && useradd -u ${FTP_UID} -g ${FTP_GID} -m ${FTP_USER} \
    && echo "${FTP_USER}:${FTP_PASSWORD}" | chpasswd
RUN mkdir -p /srv/ftp && chown ftpuser:ftpuser /srv/ftp

COPY apps/backup/vsftpd.conf /etc/vsftpd.conf

COPY apps/backup/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 21
EXPOSE 30000-30009