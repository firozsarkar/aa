#!/bin/bash
# ============================================================
#  update.sh — Asterisk 22.7.0 Downgrade + Extension Fix
#  Fixes: "AOR '1001' not found for endpoint '1001'"
#  Runs on: Asterisk server (Debian 12, NOT cPanel)
# ============================================================
set -euo pipefail

# ---------- Config ----------
TARGET_VERSION="${TARGET_VERSION:-22.7.0}"
API_URL="${API_URL:-https://pbx.registercamp.com/extenson.php?action=sync_extensions}"
API_TOKEN="${API_TOKEN:-}"
EXT_CONF="/etc/asterisk/pjsip_extensions.conf"
PJSIP_CONF="/etc/asterisk/pjsip.conf"
BUILD_DIR="/usr/local/src"
SYNC_SH="/usr/local/bin/pjsip_extensions_sync.sh"
SYNC_LOG="/var/log/pjsip_extensions_sync.log"

# ---------- Colors ----------
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; B='\033[0;34m'; N='\033[0m'
log()  { echo -e "${G}[+]${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }
err()  { echo -e "${R}[-]${N} $*"; }
step() { echo -e "\n${B}━━━ $* ━━━${N}"; }

[ "$EUID" -eq 0 ] || { err "Run as root: sudo bash update.sh"; exit 1; }
grep -q "$(hostname)" /etc/hosts 2>/dev/null || echo "127.0.1.1  $(hostname)" >> /etc/hosts

echo ""
echo "============================================================"
echo "  Asterisk Downgrade to $TARGET_VERSION"
echo "  API: $API_URL"
echo "============================================================"

CURRENT=$(asterisk -V 2>/dev/null | awk '{print $2}' || echo "unknown")
echo -e "  Current version: ${Y}${CURRENT}${N}"
if [[ "$CURRENT" == "$TARGET_VERSION" ]]; then
    log "Already on $TARGET_VERSION — no downgrade needed."
    # Still ensure config is correct, then exit
    SKIP_BUILD=1
else
    SKIP_BUILD=0
fi

# ============================================================
step "1/8  Backup configuration"
# ============================================================
SUF=".updbak.$(date +%s)"
BACKUP_DIR="/root/asterisk-backup-$SUF"
mkdir -p "$BACKUP_DIR"
for f in pjsip.conf pjsip_gateway.conf pjsip_extensions.conf extensions.conf rtp.conf; do
    [ -f "/etc/asterisk/$f" ] && cp "/etc/asterisk/$f" "$BACKUP_DIR/" && log "  $f"
done
crontab -l 2>/dev/null > "$BACKUP_DIR/crontab.txt" || true
log "Backup: $BACKUP_DIR"

if [ "$SKIP_BUILD" = "0" ]; then
    # ============================================================
    step "2/8  Installing build dependencies"
    # ============================================================
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        build-essential libssl-dev libncurses5-dev libnewt-dev libxml2-dev \
        linux-headers-$(uname -r) libsqlite3-dev uuid-dev libjansson-dev \
        libedit-dev libsrtp2-dev wget curl jq ca-certificates
    log "Dependencies installed"

    # ============================================================
    step "3/8  Downloading Asterisk $TARGET_VERSION"
    # ============================================================
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"
    TARBALL="asterisk-${TARGET_VERSION}.tar.gz"
    SRC_DIR="asterisk-${TARGET_VERSION}"
    URL="https://downloads.asterisk.org/pub/telephony/asterisk/${TARBALL}"

    if [ -d "$SRC_DIR" ]; then
        warn "Directory exists: $SRC_DIR"
        read -p "  Remove and re-download? (y/N): " -n 1 -r
        echo
        [[ $REPLY =~ ^[Yy]$ ]] && rm -rf "$SRC_DIR"
    fi

    if [ ! -d "$SRC_DIR" ]; then
        [ -f "$TARBALL" ] || wget -q --show-progress "$URL" || { err "Download failed"; exit 1; }
        tar xzf "$TARBALL"
    fi
    log "Source ready: $BUILD_DIR/$SRC_DIR"

    # ============================================================
    step "4/8  Building Asterisk $TARGET_VERSION (5-15 min)"
    # ============================================================
    cd "$SRC_DIR"
    if [ ! -f ".configured" ]; then
        log "Configure..."
        ./configure --with-pjproject-bundled --with-jansson-bundled > /tmp/ast-configure.log 2>&1 || {
            err "configure failed"; tail -20 /tmp/ast-configure.log; exit 1;
        }
        touch .configured
    fi
    if [ ! -f ".built" ]; then
        log "Make (this will take a while)..."
        make -j"$(nproc)" > /tmp/ast-build.log 2>&1 || {
            err "make failed"; tail -20 /tmp/ast-build.log; exit 1;
        }
        touch .built
    fi
    log "Build complete"

    # ============================================================
    step "5/8  Installing Asterisk $TARGET_VERSION"
    # ============================================================
    systemctl stop asterisk 2>/dev/null || true
    make install > /tmp/ast-install.log 2>&1 || {
        err "make install failed"; tail -20 /tmp/ast-install.log;
        systemctl start asterisk; exit 1;
    }
    log "Installed"

    # Restore configs
    for f in pjsip.conf pjsip_gateway.conf pjsip_extensions.conf extensions.conf rtp.conf; do
        [ -f "$BACKUP_DIR/$f" ] && cp "$BACKUP_DIR/$f" "/etc/asterisk/$f"
    done
    chown -R asterisk:asterisk /etc/asterisk /var/lib/asterisk /var/log/asterisk /var/spool/asterisk 2>/dev/null || true
    log "Configs restored"

    # ============================================================
    step "6/8  Configuring PJSIP extensions (AOR = endpoint)"
    # ============================================================
    log "Fetching extensions from cPanel API..."
    CURL_ARGS=(-sS --max-time 20)
    [ -n "$API_TOKEN" ] && CURL_ARGS+=(-H "X-API-Token: $API_TOKEN")
    RESP=$(curl "${CURL_ARGS[@]}" "$API_URL" 2>/dev/null || echo "")

    if echo "$RESP" | jq -e '.status == "SUCCESS"' >/dev/null 2>&1; then
        N=$(echo "$RESP" | jq '.count // 0')
        log "API returned $N extensions"
        TMP=$(mktemp)
        {
            echo "; Auto-generated PJSIP Extensions"
            echo "; Generated: $(date '+%F %T')"
            echo "; Total: $N"
            echo ""
        } > "$TMP"

        echo "$RESP" | jq -c '.extensions[]?' | while IFS= read -r row; do
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
            warn "Generated config empty — keeping existing"
            rm -f "$TMP"
        fi
    else
        warn "API fetch failed — transforming existing config"
        if [ -f "$EXT_CONF" ]; then
            sed -i -E 's/^\[([^]]+)_aor\]$/[\1]/' "$EXT_CONF"
            sed -i -E 's/^aors=(.+)_aor$/aors=\1/' "$EXT_CONF"
            log "In-place transform applied"
        fi
    fi

    # Ensure pjsip.conf includes our file
    grep -q 'pjsip_extensions.conf' "$PJSIP_CONF" 2>/dev/null || {
        echo '' >> "$PJSIP_CONF"
        echo '#include "pjsip_extensions.conf"' >> "$PJSIP_CONF"
        log "Added include directive"
    }
fi  # end SKIP_BUILD==0

# ============================================================
step "7/8  Reinstalling sync script + cron"
# ============================================================
log "Writing $SYNC_SH ..."
cat > "$SYNC_SH" <<SYNC_EOF
#!/bin/bash
set -uo pipefail
API_URL="$API_URL"
API_TOKEN="$API_TOKEN"
CONF="$EXT_CONF"
TMP=\$(mktemp)
LOG="$SYNC_LOG"
log() { echo "[\$(date '+%F %T')] \$*" >> "\$LOG"; }
CURL_ARGS=(-sS --max-time 20)
[ -n "\$API_TOKEN" ] && CURL_ARGS+=(-H "X-API-Token: \$API_TOKEN")
RESP=\$(curl "\${CURL_ARGS[@]}" "\$API_URL" 2>/dev/null) || { log "curl failed"; rm -f "\$TMP"; exit 1; }
echo "\$RESP" | jq -e '.status=="SUCCESS"' >/dev/null 2>&1 || { log "API not SUCCESS"; rm -f "\$TMP"; exit 1; }
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

crontab -l 2>/dev/null | grep -v "pjsip_extensions_sync.sh" | grep -v "sync_extensions.php" > /tmp/cron.new || true
echo "*/2 * * * * $SYNC_SH >/dev/null 2>&1" >> /tmp/cron.new
crontab /tmp/cron.new
rm -f /tmp/cron.new
log "Cron updated (every 2 minutes)"

# ============================================================
step "8/8  Start Asterisk and verify"
# ============================================================
log "Starting Asterisk..."
systemctl enable asterisk >/dev/null 2>&1 || true
systemctl start asterisk
sleep 5

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
echo -e "  ${B}=== Version ===${N}"
asterisk -V 2>/dev/null | sed 's/^/    /'

echo ""
echo -e "  ${B}=== Loaded AORs ===${N}"
AOR_OUT=$(asterisk -rx "pjsip show aors" 2>/dev/null || echo "")
echo "$AOR_OUT" | grep -E '^\s+Aor:' | sed 's/^/    /' || echo "    (none)"
AOR_COUNT=$(echo "$AOR_OUT" | grep -cE '^\s+Aor:' || true)

echo ""
echo -e "  ${B}=== Endpoints ===${N}"
asterisk -rx "pjsip show endpoints" 2>/dev/null | grep -E '^Endpoint:' | sed 's/^/    /' || echo "    (none)"

echo ""
echo -e "  ${B}=== Contacts ===${N}"
asterisk -rx "pjsip show contacts" 2>/dev/null | grep -E '^\s+Contact:' | sed 's/^/    /' || echo "    (no contacts yet)"

# ---------- Final ----------
echo ""
echo "============================================================"
echo -e "  ${G}✅ UPDATE COMPLETE${N}"
echo "============================================================"
echo ""
echo "  Version : $(asterisk -V 2>/dev/null)"
echo "  AORs    : $AOR_COUNT loaded"
echo "  Backup  : $BACKUP_DIR"
echo ""
echo "  📱 Register in Zoiper:"
echo "     Server: $(curl -s ifconfig.me 2>/dev/null || echo '<IP>')"
echo "     Port:   5060 (UDP)"
echo "     User:   1001"
echo "     Pass:   (from DB)"
echo ""
echo "  🔍 Then run:  asterisk -rx 'pjsip show contacts'"
echo "     Success:  Contact: 1001/sip:1001@... Avail"
echo ""
echo "  🧪 Live log:  asterisk -rvvvvv"
echo "  📋 Sync log:  tail -f $SYNC_LOG"
echo ""
echo "============================================================"
