#!/bin/bash
# ============================================================
#  update.sh — Asterisk 22.7.0 Downgrade + Extension Fix
#  Fixes:  "AOR '1001' not found for endpoint '1001'"
#  Runs on: Asterisk server (Debian 12, NOT cPanel)
# ============================================================
set -euo pipefail

# ---------- Config ----------
TARGET_VERSION="${TARGET_VERSION:-22.7.0}"
API_URL="${API_URL:-https://pbx.registercamp.com/extenson.php?action=sync_extensions}"
API_TOKEN="${API_TOKEN:-}"
EXT_CONF="/etc/asterisk/pjsip_extensions.conf"
PJSIP_CONF="/etc/asterisk/pjsip.conf"
EXTENSIONS_CONF="/etc/asterisk/extensions.conf"
SYNC_SH="/usr/local/bin/pjsip_extensions_sync.sh"
SYNC_LOG="/var/log/pjsip_extensions_sync.log"
BUILD_DIR="/usr/local/src"

# ---------- Colors ----------
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; B='\033[0;34m'; N='\033[0m'
log()  { echo -e "${G}[+]${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }
err()  { echo -e "${R}[-]${N} $*"; }
step() { echo -e "\n${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"; echo -e "${B}  $*${N}"; echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"; }

# ---------- Root check ----------
[ "$EUID" -eq 0 ] || { err "Run as root: sudo bash update.sh"; exit 1; }

# ---------- Hostname warning fix ----------
grep -q "$(hostname)" /etc/hosts 2>/dev/null || \
    echo "127.0.1.1  $(hostname)" >> /etc/hosts

# ---------- Banner ----------
echo ""
echo "============================================================"
echo "  Asterisk Downgrade + Extension Fix"
echo "  Target Asterisk version : $TARGET_VERSION"
echo "  API URL                : $API_URL"
echo "============================================================"
echo ""

CURRENT_VERSION=$(asterisk -V 2>/dev/null | awk '{print $2}' || echo "unknown")
echo -e "  Current version : ${Y}${CURRENT_VERSION}${N}"
echo ""

# ============================================================
step "1/9  Pre-flight checks"
# ============================================================
[ -f "$PJSIP_CONF" ] || { err "Missing $PJSIP_CONF"; exit 1; }
command -v asterisk >/dev/null || { err "Asterisk not installed"; exit 1; }
command -v systemctl >/dev/null || { err "systemctl not available"; exit 1; }
log "Pre-flight OK"

# ============================================================
step "2/9  Backing up existing configuration"
# ============================================================
SUF=".updbak.$(date +%s)"
BACKUP_DIR="/root/asterisk-backup-$SUF"
mkdir -p "$BACKUP_DIR"

for f in pjsip.conf pjsip_gateway.conf pjsip_extensions.conf extensions.conf rtp.conf; do
    [ -f "/etc/asterisk/$f" ] && cp "/etc/asterisk/$f" "$BACKUP_DIR/" && log "  $f"
done
[ -f "$SYNC_SH" ] && cp "$SYNC_SH" "$BACKUP_DIR/" && log "  pjsip_extensions_sync.sh"
crontab -l 2>/dev/null > "$BACKUP_DIR/crontab.txt" || true

log "Backup saved to: $BACKUP_DIR"

# ============================================================
step "3/9  Installing build dependencies"
# ============================================================
log "Installing build tools (this may take a minute)..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    build-essential \
    libssl-dev \
    libncurses5-dev \
    libnewt-dev \
    libxml2-dev \
    linux-headers-$(uname -r) \
    libsqlite3-dev \
    uuid-dev \
    libjansson-dev \
    libedit-dev \
    libsrtp2-dev \
    wget \
    curl \
    jq \
    ca-certificates

log "Build dependencies installed"

# ============================================================
step "4/9  Downloading Asterisk $TARGET_VERSION"
# ============================================================
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

AST_TARBALL="asterisk-${TARGET_VERSION}.tar.gz"
AST_DIR="asterisk-${TARGET_VERSION}"
AST_URL="https://downloads.asterisk.org/pub/telephony/asterisk/${AST_TARBALL}"

if [ -d "$AST_DIR" ]; then
    warn "Directory $BUILD_DIR/$AST_DIR already exists"
    read -p "  Remove and re-download? (y/N): " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] && rm -rf "$AST_DIR"
fi

if [ ! -d "$AST_DIR" ]; then
    if [ ! -f "$AST_TARBALL" ]; then
        log "Downloading $AST_URL ..."
        wget -q --show-progress "$AST_URL" || {
            err "Download failed"
            exit 1
        }
    else
        log "Tarball already present: $AST_TARBALL"
    fi

    log "Extracting..."
    tar xzf "$AST_TARBALL"
    log "Extracted to $BUILD_DIR/$AST_DIR"
fi

# ============================================================
step "5/9  Building Asterisk $TARGET_VERSION (5-15 minutes)"
# ============================================================
cd "$BUILD_DIR/$AST_DIR"

if [ ! -f ".configured" ]; then
    log "Running ./configure ..."
    ./configure --with-pjproject-bundled --with-jansson-bundled \
        > /tmp/asterisk-configure.log 2>&1 || {
        err "configure failed — see /tmp/asterisk-configure.log"
        tail -20 /tmp/asterisk-configure.log
        exit 1
    }
    touch .configured
    log "configure completed"
fi

if [ ! -f ".built" ]; then
    log "Running make (this takes 5-15 min) ..."
    make -j"$(nproc)" > /tmp/asterisk-build.log 2>&1 || {
        err "make failed — see /tmp/asterisk-build.log"
        tail -20 /tmp/asterisk-build.log
        exit 1
    }
    touch .built
    log "make completed"
fi

# ============================================================
step "6/9  Installing Asterisk $TARGET_VERSION"
# ============================================================
log "Stopping Asterisk service before install..."
systemctl stop asterisk 2>/dev/null || true

log "Running make install ..."
make install > /tmp/asterisk-install.log 2>&1 || {
    err "make install failed — see /tmp/asterisk-install.log"
    tail -20 /tmp/asterisk-install.log
    systemctl start asterisk
    exit 1
}
log "make install completed"

# Install systemd service if missing
if [ ! -f /etc/systemd/system/asterisk.service ] && \
   [ ! -f /lib/systemd/system/asterisk.service ] && \
   [ -f "$BUILD_DIR/$AST_DIR/contrib/systemd/asterisk.service" ]; then
    cp "$BUILD_DIR/$AST_DIR/contrib/systemd/asterisk.service" /etc/systemd/system/
    systemctl daemon-reload
    log "systemd service installed"
fi

# Install samples if not present
if [ ! -f /etc/asterisk/asterisk.conf ]; then
    make samples > /tmp/asterisk-samples.log 2>&1 || true
    log "Sample configs installed"
fi

# Restore backups
log "Restoring your configuration files..."
for f in pjsip.conf pjsip_gateway.conf pjsip_extensions.conf extensions.conf rtp.conf; do
    [ -f "$BACKUP_DIR/$f" ] && cp "$BACKUP_DIR/$f" "/etc/asterisk/$f" && log "  restored $f"
done

chown -R asterisk:asterisk /etc/asterisk 2>/dev/null || true
chown -R asterisk:asterisk /var/lib/asterisk 2>/dev/null || true
chown -R asterisk:asterisk /var/log/asterisk 2>/dev/null || true
chown -R asterisk:asterisk /var/spool/asterisk 2>/dev/null || true

log "Asterisk $TARGET_VERSION installed"

# ============================================================
step "7/9  Rewriting pjsip_extensions.conf (AOR = endpoint)"
# ============================================================
log "Fetching fresh extensions from cPanel API..."

CURL_ARGS=(-sS --max-time 20)
[ -n "$API_TOKEN" ] && CURL_ARGS+=(-H "X-API-Token: $API_TOKEN")

API_RESP=$(curl "${CURL_ARGS[@]}" "$API_URL" 2>/dev/null || echo "")

if echo "$API_RESP" | jq -e '.status == "SUCCESS"' >/dev/null 2>&1; then
    COUNT=$(echo "$API_RESP" | jq '.count // 0')
    log "API returned $COUNT extensions"

    TMP=$(mktemp)
    {
        echo "; Auto-generated PJSIP Extensions"
        echo "; Version: Asterisk $TARGET_VERSION"
        echo "; Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "; Total: $COUNT"
        echo ""
    } > "$TMP"

    echo "$API_RESP" | jq -c '.extensions[]?' | while IFS= read -r row; do
        ext=$(echo "$row" | jq -r '.extension')
        pass=$(echo "$row" | jq -r '.password')
        name=$(echo "$row" | jq -r '.name // .extension')
        cid=$(echo "$row" | jq -r '.callerid // "'"$name"' <'"$ext"'>"')
        [ -z "$ext" ] || [ -z "$pass" ] && continue

        cat >> "$TMP" <<EOF

[$ext]
type=endpoint
transport=transport-udp
context=from-panel
disallow=all
allow=ulaw,alaw,g729,gsm
auth=${ext}_auth
aors=${ext}
callerid=${cid}
direct_media=no
force_rport=yes
rewrite_contact=yes

[${ext}_auth]
type=auth
auth_type=userpass
password=${pass}
username=${ext}

[$ext]
type=aor
max_contacts=3
remove_existing=yes
contact_user=${ext}

EOF
    done

    if [ -s "$TMP" ]; then
        mv "$TMP" "$EXT_CONF"
        chown asterisk:asterisk "$EXT_CONF"
        chmod 640 "$EXT_CONF"
        log "Written $EXT_CONF ($(wc -l < "$EXT_CONF") lines)"
    else
        warn "Generated config empty — keeping existing file"
        rm -f "$TMP"
    fi
else
    warn "API fetch failed — falling back to transforming existing config"
    # in-place transform if file exists
    if [ -f "$EXT_CONF" ]; then
        sed -i -E 's/^\[([^]]+)_aor\]$/[\1]/' "$EXT_CONF"
        sed -i -E 's/^aors=(.+)_aor$/aors=\1/' "$EXT_CONF"
        log "In-place transform applied (AOR = endpoint name)"
    fi
fi

# Ensure pjsip.conf includes our file
if ! grep -q 'pjsip_extensions.conf' "$PJSIP_CONF" 2>/dev/null; then
    echo '' >> "$PJSIP_CONF"
    echo '#include "pjsip_extensions.conf"' >> "$PJSIP_CONF"
    log "Added #include for pjsip_extensions.conf"
fi

# ============================================================
step "8/9  Reinstalling sync script + cron"
# ============================================================
log "Writing $SYNC_SH ..."
cat > "$SYNC_SH" <<SYNC_EOF
#!/bin/bash
# pjsip_extensions_sync.sh — AOR name = endpoint name
set -uo pipefail
API_URL="$API_URL"
API_TOKEN="$API_TOKEN"
CONF="$EXT_CONF"
TMP=\$(mktemp)
LOG="$SYNC_LOG"

log() { echo "[\$(date '+%F %T')] \$*" >> "\$LOG"; }

CURL_ARGS=(-sS --max-time 20)
[ -n "\$API_TOKEN" ] && CURL_ARGS+=(-H "X-API-Token: \$API_TOKEN")

RESP=\$(curl "\${CURL_ARGS[@]}" "\$API_URL" 2>/dev/null) || {
    log "curl failed"; rm -f "\$TMP"; exit 1; }

echo "\$RESP" | jq -e '.status=="SUCCESS"' >/dev/null 2>&1 || {
    log "API not SUCCESS: \$(echo "\$RESP" | head -c 200)"; rm -f "\$TMP"; exit 1; }

N=\$(echo "\$RESP" | jq '.count // 0')
log "Fetched \$N extensions"

{
    echo "; Auto-generated PJSIP Extensions"
    echo "; Generated: \$(date '+%F %T')"
    echo "; Total: \$N"
    echo ""
} > "\$TMP"

echo "\$RESP" | jq -c '.extensions[]?' | while IFS= read -r row; do
    ext=\$(echo "\$row" | jq -r '.extension')
    pass=\$(echo "\$row" | jq -r '.password')
    name=\$(echo "\$row" | jq -r '.name // .extension')
    cid=\$(echo "\$row" | jq -r '.callerid // "'"\$name"' <'"\$ext"'>"')
    [ -z "\$ext" ] || [ -z "\$pass" ] && continue

    cat >> "\$TMP" <<EOF

[\$ext]
type=endpoint
transport=transport-udp
context=from-panel
disallow=all
allow=ulaw,alaw,g729,gsm
auth=\${ext}_auth
aors=\$ext
callerid=\$cid
direct_media=no
force_rport=yes
rewrite_contact=yes

[\${ext}_auth]
type=auth
auth_type=userpass
password=\$pass
username=\$ext

[\$ext]
type=aor
max_contacts=3
remove_existing=yes
contact_user=\$ext

EOF
done

[ -s "\$TMP" ] || { log "empty config"; rm -f "\$TMP"; exit 1; }
[ -f "\$CONF" ] && cp "\$CONF" "\${CONF}.bak.\$(date +%s)"
mv "\$TMP" "\$CONF"
chown asterisk:asterisk "\$CONF"
chmod 640 "\$CONF"

asterisk -rx "pjsip reload" >/dev/null 2>&1 || systemctl restart asterisk
log "Config written (\$(wc -l < "\$CONF") lines) & reloaded"
ls -1t "\${CONF}".bak.* 2>/dev/null | tail -n +11 | xargs -r rm -f
SYNC_EOF

chmod +x "$SYNC_SH"
log "Sync script updated"

# Cron
crontab -l 2>/dev/null | grep -v "pjsip_extensions_sync.sh" | grep -v "sync_extensions.php" > /tmp/cron.new || true
echo "*/2 * * * * $SYNC_SH >/dev/null 2>&1" >> /tmp/cron.new
crontab /tmp/cron.new
rm -f /tmp/cron.new
log "Cron updated (every 2 minutes)"

# ============================================================
step "9/9  Starting Asterisk and verifying"
# ============================================================
log "Enabling & starting Asterisk..."
systemctl enable asterisk >/dev/null 2>&1 || true
systemctl start asterisk
sleep 4

if ! systemctl is-active asterisk >/dev/null; then
    err "Asterisk failed to start!"
    err "Check: journalctl -u asterisk -n 50"
    exit 1
fi
log "Asterisk running"

asterisk -rx "dialplan reload" >/dev/null 2>&1 || true
sleep 1

# ---------- Verification ----------
echo ""
echo -e "  ${B}=== Asterisk version ===${N}"
asterisk -V 2>/dev/null | sed 's/^/    /'

echo ""
echo -e "  ${B}=== Loaded AORs ===${N}"
AOR_OUT=$(asterisk -rx "pjsip show aors" 2>/dev/null || echo "")
echo "$AOR_OUT" | grep -E '^\s+Aor:' | sed 's/^/    /' || echo "    (none)"
AOR_COUNT=$(echo "$AOR_OUT" | grep -cE '^\s+Aor:' || true)

echo ""
echo -e "  ${B}=== Loaded Endpoints ===${N}"
asterisk -rx "pjsip show endpoints" 2>/dev/null | grep -E '^Endpoint:' | sed 's/^/    /' || echo "    (none)"

echo ""
echo -e "  ${B}=== Contacts ===${N}"
asterisk -rx "pjsip show contacts" 2>/dev/null | grep -E '^\s+Contact:' | sed 's/^/    /' || echo "    (no contacts yet)"

# ---------- Final summary ----------
echo ""
echo "============================================================"
echo -e "  ${G}✅ UPDATE COMPLETE${N}"
echo "============================================================"
echo ""
echo "  Version   : $(asterisk -V 2>/dev/null)"
echo "  AORs      : $AOR_COUNT loaded"
echo "  Backup    : $BACKUP_DIR"
echo ""
echo "  📱 Test registration now:"
echo "     Zoiper → Account 1001"
echo "       Server   : $(curl -s ifconfig.me 2>/dev/null || echo '<server-IP>')"
echo "       Port     : 5060 (UDP)"
echo "       Username : 1001"
echo "       Password : (from DB — SELECT password FROM extensions WHERE extension='1001')"
echo ""
echo "     Then run:  asterisk -rx 'pjsip show contacts'"
echo "     Success :  Contact: 1001/sip:1001@... Avail"
echo ""
echo "  🧪 Live log  :  asterisk -rvvvvv"
echo "  📋 Sync log  :  tail -f $SYNC_LOG"
echo ""
echo "  💾 If anything breaks, restore:"
echo "     cp $BACKUP_DIR/*.conf /etc/asterisk/"
echo "     systemctl restart asterisk"
echo ""
echo "============================================================"
