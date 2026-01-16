$FILE_NAME="README.md"

lftp -d -u "ftpuser,w" ftp://localhost -e "put \"$FILE_NAME\"; exit"