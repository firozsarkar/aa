#!/bin/bash
# fix-pjsip-aor.sh — Asterisk 22 "AOR '' not found" fixer
set -euo pipefail

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; B='\033[0;34m'; N='\033[0m'
log()  { echo -e "${G}[+]${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }
err()  { echo -e "${R}[-]${N} $*"; }
step() { echo -e "\n${B}━━━ $* ━━━${N}"; }

[ "$EUID" -eq 0 ] || { err "Run as root"; exit 1; }

EXT_CONF="/etc/asterisk/pjsip_extensions.conf"
PJSIP_CONF="/etc/asterisk/pjsip.conf"
SYNC_SH="/usr/local/bin/pjsip_extensions_sync.sh"
OLD_SYNC_PHP="/usr/local/bin/sync_extensions.php"
LOG="/var/log/pjsip_extensions_sync.log"
BACKUP_SUFFIX=".fixbak.$(date +%s)"

# Pre-flight
[ -f "$EXT_CONF" ] || { err "Missing $EXT_CONF — run extensionsetup first"; exit 1; }
[ -f "$PJSIP_CONF" ] || { err "Missing $PJSIP_CONF"; exit 1; }

step "1/6  Backup"
for f in "$EXT_CONF" "$PJSIP_CONF" "/etc/asterisk/extensions.conf"; do
    [ -f "$f" ] && cp "$f" "$f$BACKUP_SUFFIX" && log "Backed up $f"
done

step "2/6  Transform pjsip_extensions.conf (AOR name = endpoint name)"
# Transform pattern:
#   aors=XXXX_aor  →  aors=XXXX
#   [XXXX_aor]     →  [XXXX]  (only when followed by type=aor)
#   Add contact_user=XXXX inside AOR if missing

# Use awk for reliability
awk '
BEGIN { RS=""; FS="\n"; ORS="\n\n" }
{
    # Detect if this is an AOR block
    is_aor = 0
    aor_name = ""
    for (i=1; i<=NF; i++) {
        if ($i ~ /^type=aor$/) is_aor = 1
        if ($i ~ /^\[[^]]+\]$/) {
            name = $i
            gsub(/^\[/, "", name)
            gsub(/\]$/, "", name)
            if (name ~ /_aor$/) aor_name = name
        }
    }

    # Rename AOR section
    if (is_aor && aor_name != "") {
        new_name = aor_name
        sub(/_aor$/, "", new_name)
        # Extract just base name (e.g. 1001)
        base = new_name

        # Build new block
        print "[" base "]"
        has_contact_user = 0
        for (i=1; i<=NF; i++) {
            if ($i ~ /^\[/) continue
            if ($i ~ /^contact_user=/) has_contact_user = 1
            # Rewrite aors=XXXX_aor → aors=XXXX
            if ($i ~ /^aors=/) {
                val = $i
                sub(/^aors=/, "", val)
                sub(/_aor$/, "", val)
                print "aors=" val
                continue
            }
            print $i
        }
        if (!has_contact_user) print "contact_user=" base
        next
    }

    # For endpoint blocks - rewrite aors=XXXX_aor → aors=XXXX
    for (i=1; i<=NF; i++) {
        if ($i ~ /^aors=/) {
            val = $i
            sub(/^aors=/, "", val)
            sub(/_aor$/, "", val)
            $i = "aors=" val
        }
        if ($i ~ /^\[[^]]+\]$/) {
            name = $i
            gsub(/^\[/, "", name)
            gsub(/\]$/, "", name)
            if (name ~ /_aor$/) {
                sub(/_aor$/, "", name)
                $i = "[" name "]"
            }
        }
    }
    # Print block
    for (i=1; i<=NF; i++) print $i
}
' "$EXT_CONF" > /tmp/pjsip_ext_new.conf

# Validate: no more _aor and AOR sections match endpoints
if grep -qE '^\[[0-9]+_aor\]' /tmp/pjsip_ext_new.conf; then
    err "Transform failed — still has _aor sections"
    exit 1
fi

mv /tmp/pjsip_ext_new.conf "$EXT_CONF"
chown asterisk:asterisk "$EXT_CONF"
chmod 640 "$EXT_CONF"
log "Transformed — no more _aor references"

# Show sample
echo ""
echo "  First 30 lines of new config:"
head -30 "$EXT_CONF" | sed 's/^/    /'
echo ""

step "3/6  Install new sync script"
cat > "$SYNC_SH" <<'SYNC'
#!/bin/bash
# pjsip_extensions_sync.sh — generates AOR name = endpoint name
# Fixes Asterisk 22 "AOR '' not found"
set -uo pipefail

# ---- CONFIG ----
# Adjust if your cPanel URL differs
API_URL="${API_URL:-https://pbx.registercamp.com/extenson.php?action=sync_extensions}"
API_TOKEN="${API_TOKEN:-}"
CONF="/etc/asterisk/pjsip_extensions.conf"
TMP=$(mktemp)
LOG="/var/log/pjsip_extensions_sync.log"

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

# Build curl args
CURL=(curl -sS --max-time 15)
[ -n "$API_TOKEN" ] && CURL+=(-H "X-API-Token: $API_TOKEN")

# ---- Fetch ----
RESP=$("${CURL[@]}" "$API_URL" 2>/dev/null) || {
    log "curl failed — keeping existing config"
    rm -f "$TMP"; exit 1
}

if ! echo "$RESP" | jq -e '.status=="SUCCESS"' >/dev/null 2>&1; then
    log "API not SUCCESS: $(echo "$RESP" | head -c 200)"
    rm -f "$TMP"; exit 1
fi

COUNT=$(echo "$RESP" | jq '.count // 0')
log "Fetch OK — $COUNT extensions"

# ---- Generate ----
{
    echo "; Auto-generated PJSIP Extensions"
    echo "; Generated: $(date '+%F %T')"
    echo "; Total: $COUNT"
    echo ""
} > "$TMP"

echo "$RESP" | jq -c '.extensions[]?' | while IFS= read -r row; do
    ext=$(echo "$row" | jq -r '.extension')
    pass=$(echo "$row" | jq -r '.password')
    name=$(echo "$row" | jq -r '.name // .extension')
    cid=$(echo "$row" | jq -r '.callerid // "'"$name"' <'"$ext"'>"')

    [ -z "$ext" ] || [ -z "$pass" ] && continue

    cat >> "$TMP" <<EOF

; ---------- $ext ----------
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

# ---- Validate ----
[ -s "$TMP" ] || { log "empty config"; rm -f "$TMP"; exit 1; }

# ---- Install ----
[ -f "$CONF" ] && cp "$CONF" "${CONF}.bak.$(date +%s)"
mv "$TMP" "$CONF"
chown asterisk:asterisk "$CONF"
chmod 640 "$CONF"

# ---- Reload ----
asterisk -rx "pjsip reload" >/dev/null 2>&1 || systemctl restart asterisk
log "Config written ($(wc -l < "$CONF") lines) & reloaded"

# Keep last 10 backups
ls -1t "${CONF}".bak.* 2>/dev/null | tail -n +11 | xargs -r rm -f
SYNC

chmod +x "$SYNC_SH"
log "Installed $SYNC_SH"

step "4/6  Update cron"
# Remove old entries
crontab -l 2>/dev/null | grep -v "sync_extensions.php" | grep -v "pjsip_extensions_sync.sh" > /tmp/cron.new || true
# Add new
echo "*/2 * * * * $SYNC_SH >/dev/null 2>&1" >> /tmp/cron.new
crontab /tmp/cron.new
rm -f /tmp/cron.new
log "Cron: every 2 min → $SYNC_SH"

step "5/6  Restart Asterisk"
log "Restarting Asterisk (clears AOR cache)..."
systemctl restart asterisk
sleep 4
systemctl is-active asterisk || { err "Asterisk failed to start"; exit 1; }
log "Asterisk running"

asterisk -rx "pjsip reload"    >/dev/null 2>&1 || true
asterisk -rx "dialplan reload" >/dev/null 2>&1 || true

step "6/6  Verify"
echo ""
echo "  === pjsip show aors ==="
asterisk -rx "pjsip show aors" | sed 's/^/    /'
echo ""
echo "  === pjsip show endpoints ==="
asterisk -rx "pjsip show endpoints" | sed 's/^/    /'
echo ""
echo "  === Count AOR sections in pjsip_extensions.conf ==="
echo "    $(grep -c '^type=aor$' "$EXT_CONF") AORs"
echo "    $(grep -c '^type=endpoint$' "$EXT_CONF") endpoints"
echo ""

# ---- Success ----
echo ""
echo "============================================================"
echo -e "  ${G}✅ AOR FIX APPLIED${N}"
echo "============================================================"
echo ""
echo "  🔧 What changed:"
echo "     [1001_aor]  →  [1001]"
echo "     aors=1001_aor → aors=1001"
echo "     + contact_user=1001"
echo ""
echo "  📱 Now do this in Zoiper:"
echo "     Username: 1001"
echo "     Password: (from database)"
echo "     Server  : $(curl -s ifconfig.me 2>/dev/null || echo '<this-IP>')"
echo "     Port    : 5060"
echo "     Disable → Enable"
echo ""
echo "  🔍 Then verify:"
echo "     asterisk -rx 'pjsip show contacts'"
echo ""
echo "  🧪 Live log:"
echo "     asterisk -rvvvvv"
echo ""
echo "  📋 Sync log:"
echo "     tail -f /var/log/pjsip_extensions_sync.log"
echo ""
echo "============================================================"
