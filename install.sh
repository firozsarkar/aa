#!/bin/bash
# ==============================================================================
# Debian 12 Automated Asterisk 22 LTS + MariaDB ODBC + UFW + Fail2Ban Installer
# ==============================================================================

set -e

# --- কনফিগারেশন ভ্যারিয়েবল (প্রয়োজনে পরিবর্তন করুন) ---
SSH_PORT="22"
COUNTRY_CODE="880"          # বাংলাদেশ: 880, সৌদি আরব: 966
DB_NAME="asterisk_realtime"
DB_USER="asterisk_user"
DB_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
AMI_USER="panel_admin"
AMI_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)

# কালার কোড
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}[1/8] সিস্টেম আপডেট এবং প্রয়োজনীয় ডিপেন্ডেন্সি ইনস্টল হচ্ছে...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt update && apt upgrade -y
apt install -y build-essential git curl wget subversion libnewt-dev libssl-dev \
libncurses5-dev libsqlite3-dev libxml2-dev uuid-dev libjansson-dev \
unixodbc unixodbc-dev odbc-mariadb mariadb-server mariadb-client \
sox mpg123 ufw fail2ban iptables-persistent net-tools

echo -e "${GREEN}[2/8] MariaDB ডাটাবেস এবং ODBC ড্রাইভার কনফিগার হচ্ছে...${NC}"
systemctl enable mariadb
systemctl start mariadb

mysql -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

# MariaDB ODBC ড্রাইভার পাথ খুঁজে বের করা
ODBC_DRIVER=$(find /usr/lib -name "libmaodbc.so" | head -n 1)

cat <<EOF > /etc/odbcinst.ini
[MariaDB]
Description = MariaDB ODBC Driver
Driver      = ${ODBC_DRIVER}
Setup       = ${ODBC_DRIVER}
FileUsage   = 1
EOF

cat <<EOF > /etc/odbc.ini
[asterisk-connector]
Description = MariaDB connection to ${DB_NAME}
Driver      = MariaDB
Database    = ${DB_NAME}
Server      = localhost
User        = ${DB_USER}
Password    = ${DB_PASS}
Port        = 3306
Socket      = /var/run/mysqld/mysqld.sock
Option      = 3
EOF

echo -e "${GREEN}[3/8] Asterisk 22 LTS সোর্স কোড ডাউনলোড হচ্ছে...${NC}"
cd /usr/src
rm -rf asterisk-22*
wget -q https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-22-current.tar.gz
tar -zxvf asterisk-22-current.tar.gz
cd asterisk-22.*/

# অটোমেটেড ডিপেন্ডেন্সি ও MP3 সাপোর্ট
echo "libvpb1 libvpb1/countrycode string ${COUNTRY_CODE}" | debconf-set-selections
contrib/scripts/get_mp3_source.sh
contrib/scripts/install_prereq install

echo -e "${GREEN}[4/8] Asterisk কম্পাইল এবং ইনস্টল হচ্ছে (এটি ৫-১০ মিনিট সময় নেবে)...${NC}"
./configure --with-pjproject-bundled --with-jansson-bundled
make menuselect.makeopts
menuselect/menuselect \
  --enable format_mp3 \
  --enable res_odbc \
  --enable res_config_odbc \
  --enable CORE-SOUNDS-EN-WAV \
  --enable CORE-SOUNDS-EN-ULAW \
  --enable MOH-OPSOUND-WAV \
  --enable MOH-OPSOUND-ULAW \
  --enable EXTRA-SOUNDS-EN-WAV \
  menuselect.makeopts

make -j$(nproc)
make install
make samples
make config
ldconfig

echo -e "${GREEN}[5/8] Asterisk ইউজার তৈরি এবং পারমিশন সেট হচ্ছে...${NC}"
if ! id "asterisk" &>/dev/null; then
    groupadd asterisk
    useradd -r -d /var/lib/asterisk -g asterisk asterisk
    usermod -aG audio,dialout asterisk
fi

chown -R asterisk:asterisk /etc/asterisk /var/{lib,log,spool}/asterisk /usr/lib/asterisk

sed -i 's/#AST_USER="asterisk"/AST_USER="asterisk"/' /etc/default/asterisk
sed -i 's/#AST_GROUP="asterisk"/AST_GROUP="asterisk"/' /etc/default/asterisk

echo -e "${GREEN}[6/8] কাস্টম প্যানেলের জন্য AMI এবং ODBC কনফিগার হচ্ছে...${NC}"
# res_odbc.conf সেটআপ
cat <<EOF > /etc/asterisk/res_odbc.conf
[asterisk]
enabled => yes
dsn => asterisk-connector
username => ${DB_USER}
password => ${DB_PASS}
pre-connect => yes
max_connections => 20
EOF

# manager.conf (AMI) সেটআপ - কাস্টম ওয়েব প্যানেল কানেকশনের জন্য
cat <<EOF > /etc/asterisk/manager.conf
[general]
enabled = yes
port = 5038
bindaddr = 127.0.0.1

[${AMI_USER}]
secret = ${AMI_PASS}
deny = 0.0.0.0/0.0.0.0
permit = 127.0.0.1/255.255.255.0
read = all
write = all
EOF

# Security লগিং নিশ্চিত করা (Fail2Ban এর জন্য আবশ্যক)
sed -i 's/^;security => security/security => security/' /etc/asterisk/logger.conf
sed -i 's/^messages => notice,warning,error/messages => notice,warning,error,security/' /etc/asterisk/logger.conf

chown -R asterisk:asterisk /etc/asterisk

systemctl enable asterisk
systemctl restart asterisk

echo -e "${GREEN}[7/8] UFW ফায়ারওয়াল কনফিগার হচ্ছে...${NC}"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ${SSH_PORT}/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP Panel'
ufw allow 443/tcp comment 'HTTPS Panel'
ufw allow 5060/udp comment 'PJSIP UDP'
ufw allow 5060/tcp comment 'PJSIP TCP'
ufw allow 5061/tcp comment 'PJSIP TLS'
ufw allow 10000:20000/udp comment 'RTP Media'
ufw --force enable

echo -e "${GREEN}[8/8] Fail2Ban SIP ব্রুট-ফোর্স প্রোটেকশন সেটআপ হচ্ছে...${NC}"
cat <<EOF > /etc/fail2ban/jail.d/asterisk.conf
[asterisk]
enabled  = true
filter   = asterisk
action   = iptables-allports[name=ASTERISK, protocol=all]
logpath  = /var/log/asterisk/messages
maxretry = 5
findtime = 600
bantime  = 86400

[sshd]
enabled  = true
port     = ${SSH_PORT}
maxretry = 5
bantime  = 86400
EOF

systemctl enable fail2ban
systemctl restart fail2ban

# ক্রেডেনশিয়াল সেভ করে রাখা
CREDS_FILE="/root/asterisk_credentials.txt"
cat <<EOF > ${CREDS_FILE}
====================================================
Asterisk 22 LTS Custom Panel Credentials
====================================================
Database Name : ${DB_NAME}
Database User : ${DB_USER}
Database Pass : ${DB_PASS}
ODBC DSN Name : asterisk-connector

AMI Host      : 127.0.0.1
AMI Port      : 5038
AMI Username  : ${AMI_USER}
AMI Secret    : ${AMI_PASS}
====================================================
EOF
chmod 600 ${CREDS_FILE}

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN} ইনস্টলেশন সম্পূর্ণ সফল হয়েছে!${NC}"
echo -e "${YELLOW} আপনার ডাটাবেস ও AMI পাসওয়ার্ড সেভ করা আছে: ${CREDS_FILE}${NC}"
echo -e "${GREEN}====================================================${NC}"
cat ${CREDS_FILE}
