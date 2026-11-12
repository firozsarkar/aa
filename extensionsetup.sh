#!/bin/bash
# ============================================================
#  extensionsetup.sh
#  Full Extension Setup for Asterisk PBX (RegisterCamp)
#  - Extension registration via database API
#  - Internal / Inbound / Outbound call routing
#  - CDR reporting
#  - Auto-sync via cron (every 2 minutes)
# ============================================================

if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run as root (sudo bash extensionsetup.sh)"
  exit 1
fi

echo "[+] Starting Full Extension Automation Setup..."

# ------------------------------------------------------------
# ১. Dependency Install
# ------------------------------------------------------------
echo "[+] Installing PHP, cURL, Asterisk, curl..."
apt update && apt install -y php-cli php-curl asterisk curl

# ------------------------------------------------------------
# ২. Directory Setup
# ------------------------------------------------------------
echo "[+] Setting up directories..."
mkdir -p /var/lib/asterisk/agi-bin
mkdir -p /etc/asterisk

# নিশ্চিত করা যে include ফাইলগুলো না থাকলে Asterisk ক্র্যাশ না করে
[ -f /etc/asterisk/pjsip_gateway.conf ] || echo "; (empty - gateway not configured yet)" > /etc/asterisk/pjsip_gateway.conf
[ -f /etc/asterisk/pjsip_extensions.conf ] || echo "; (empty - run sync_extensions.php)" > /etc/asterisk/pjsip_extensions.conf

# ------------------------------------------------------------
# ৩. Master Panel AGI (ডাটাবেস API থেকে ডেটা আনে)
# ------------------------------------------------------------
echo "[+] Creating master_panel.php..."
cat << 'EOF' > /var/lib/asterisk/agi-bin/master_panel.php
#!/usr/bin/php -q
<?php
set_time_limit(0);
ob_implicit_flush(true);

/* ---- AGI ভেরিয়েবল পড়া ---- */
$agi_vars = [];
while (!feof(STDIN)) {
    $line = trim(fgets(STDIN));
    if ($line === '') break;
    if (preg_match('/^agi_(\w+):\s*(.*)$/', $line, $matches)) {
        $agi_vars[$matches[1]] = $matches[2];
    }
}

$module   = $argv[1] ?? 'inbound_outbound';
$caller   = $agi_vars['callerid']   ?? '';
$callee   = $agi_vars['extension']  ?? '';
$uniqueid = $agi_vars['uniqueid']   ?? '';
$channel  = $agi_vars['channel']    ?? '';
$extra    = $argv[2] ?? '';

/* ---- API এন্ডপয়েন্ট ম্যাপিং ---- */
$urls = [
    'inbound_outbound' => 'https://pbx.registercamp.com/Inbound-Outbound.php',
    'extension'        => 'https://pbx.registercamp.com/extenson.php',
    'gateway'          => 'https://pbx.registercamp.com/geteway.php',
    'ivr'              => 'https://pbx.registercamp.com/ivr.php',
    'ring_group'       => 'https://pbx.registercamp.com/Ring-Groups.php',
    'cdr'              => 'https://pbx.registercamp.com/CDR.php'
];

$target_url = $urls[$module] ?? $urls['inbound_outbound'];

$post_data = http_build_query([
    'caller'   => $caller,
    'callee'   => $callee,
    'uniqueid' => $uniqueid,
    'channel'  => $channel,
    'extra'    => $extra
]);

/* ---- API কল ---- */
$ch = curl_init($target_url);
curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
curl_setopt($ch, CURLOPT_POST, true);
curl_setopt($ch, CURLOPT_POSTFIELDS, $post_data);
curl_setopt($ch, CURLOPT_TIMEOUT, 10);
curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, true);
$response = trim(curl_exec($ch));
curl_close($ch);

$data = json_decode($response, true);

/* ---- AGI ভেরিয়েবল সেট করা ---- */
if (is_array($data)) {
    foreach ($data as $key => $value) {
        echo "SET VARIABLE PANEL_" . strtoupper($key) . " \"" . addslashes($value) . "\"\n";
        fgets(STDIN);
    }
} else {
    echo "SET VARIABLE PANEL_RESPONSE \"" . addslashes($response) . "\"\n";
    fgets(STDIN);
}
?>
EOF

chmod +x /var/lib/asterisk/agi-bin/master_panel.php
chown asterisk:asterisk /var/lib/asterisk/agi-bin/master_panel.php

# ------------------------------------------------------------
# ৪. Extension Sync Script (ডাটাবেস → PJSIP কনফিগ)
# ------------------------------------------------------------
echo "[+] Creating sync_extensions.php..."
cat << 'EOF' > /usr/local/bin/sync_extensions.php
<?php
/* =============================================================
   Database → /etc/asterisk/pjsip_extensions.conf
   ডাটাবেসে extension যোগ/পরিবর্তন/ডিলিট হলে ২ মিনিটে রিফ্লেক্ট হবে
   ============================================================= */

$url = "https://pbx.registercamp.com/extenson.php?action=sync_extensions";

$ch = curl_init($url);
curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, true);
curl_setopt($ch, CURLOPT_TIMEOUT, 15);
$response = curl_exec($ch);
$http_code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
curl_close($ch);

if ($http_code !== 200) {
    exit("Error: HTTP {$http_code} from extenson.php\n");
}

$data = json_decode($response, true);

if (!$data || ($data['status'] ?? '') !== 'SUCCESS') {
    exit("Failed to fetch extensions from extenson.php\n");
}

/* রেসপন্সে extensions অথবা data যেকোনো কী সাপোর্ট */
$extensions = $data['extensions'] ?? $data['data'] ?? [];

$config  = "; ============================================\n";
$config .= "; Auto-generated PJSIP Extensions\n";
$config .= "; Generated: " . date('Y-m-d H:i:s') . "\n";
$config .= "; ============================================\n\n";

if (empty($extensions)) {
    $config .= "; (no extensions found in database)\n";
} else {
    foreach ($extensions as $e) {
        $ext     = $e['extension']     ?? '';
        $pass    = $e['password']      ?? '';
        $name    = $e['name']          ?? $ext;
        $enabled = $e['enabled']       ?? 'yes';
        $callerid= $e['callerid']      ?? "{$name} <{$ext}>";

        if ($ext === '' || $pass === '' || strtolower($enabled) === 'no') {
            $config .= "; Extension '{$ext}' skipped (disabled/empty)\n\n";
            continue;
        }

        $config .= <<<EOT
[{$ext}]
type=endpoint
transport=transport-udp
context=from-panel
disallow=all
allow=ulaw,alaw,g729,gsm
auth={$ext}_auth
aors={$ext}_aor
callerid={$callerid}
direct_media=no
force_rport=yes
rewrite_contact=yes

[{$ext}_auth]
type=auth
auth_type=userpass
password={$pass}
username={$ext}

[{$ext}_aor]
type=aor
max_contacts=3
remove_existing=yes

; ---------------------------------------------

EOT;
    }
}

file_put_contents('/etc/asterisk/pjsip_extensions.conf', $config);
shell_exec('asterisk -rx "pjsip reload"');
echo "Extensions synchronized & PJSIP reloaded!\n";
?>
EOF

chmod +x /usr/local/bin/sync_extensions.php
chown asterisk:asterisk /usr/local/bin/sync_extensions.php

# ------------------------------------------------------------
# ৫. pjsip.conf (base — গেটওয়ে ও এক্সটেনশন 둘 다 include)
# ------------------------------------------------------------
echo "[+] Configuring /etc/asterisk/pjsip.conf..."
cat << 'EOF' > /etc/asterisk/pjsip.conf
[global]
type=global
user_agent=Asterisk PBX RegisterCamp
debug=no

[system]
type=system
timer_t1=500
timer_b=32000
compact_headers=yes

[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060
allow_reload=yes

[transport-tcp]
type=transport
protocol=tcp
bind=0.0.0.0:5060
allow_reload=yes

[default-aor]
type=aor
max_contacts=3
remove_existing=yes

[global-endpoint-defaults](!)
type=endpoint
transport=transport-udp
context=from-panel
disallow=all
allow=ulaw,alaw,g729,gsm
direct_media=no
force_rport=yes
rewrite_contact=yes

; ---- গেটওয়ে ট্রাংক (আগের স্ক্রিপ্ট থেকে অটো-জেনারেটেড) ----
#include "pjsip_gateway.conf"

; ---- এক্সটেনশন (এই স্ক্রিপ্ট থেকে অটো-জেনারেটেড) ----
#include "pjsip_extensions.conf"
EOF

# ------------------------------------------------------------
# ৬. extensions.conf (ডায়ালপ্ল্যান — এক্সটেনশন/ইনবাউন্ড/আউটবাউন্ড)
# ------------------------------------------------------------
echo "[+] Configuring /etc/asterisk/extensions.conf..."
cat << 'EOF' > /etc/asterisk/extensions.conf
[general]
static=yes
writeprotect=no
clearglobalvars=no

; ==========================================================
;  [from-panel] — সমস্ত কলের এন্ট্রি পয়েন্ট
;  (এক্সটেনশন থেকে কল এবং ট্রাংক থেকে কল — দুইটাই এখানে আসে)
; ==========================================================
[from-panel]
exten => _X.,1,NoOp(=== Call: ${CALLERID(num)} -> ${EXTEN} | ch=${CHANNEL} ===)
same => n,AGI(master_panel.php,inbound_outbound)

; PANEL_ACTION অনুযায়ী রাউটিং
same => n,GotoIf($["${PANEL_ACTION}" = "extension"]?to-extension,s,1)
same => n,GotoIf($["${PANEL_ACTION}" = "outbound"]?to-gateway,s,1)
same => n,GotoIf($["${PANEL_ACTION}" = "ivr"]?to-ivr,s,1)
same => n,GotoIf($["${PANEL_ACTION}" = "ring_group"]?to-ringgroup,s,1)

; ডিফল্ট: সরাসরি এক্সটেনশন ডায়াল করার চেষ্টা
same => n,Goto(to-extension,s,1)

; ---- Hangup CDR ----
exten => h,1,NoOp(=== Call Ended | billsec=${CDR(billsec)} | disp=${CDR(disposition)} ===)
same => n,AGI(master_panel.php,cdr,${CDR(billsec)}|${CDR(disposition)})
same => n,Hangup()

; ==========================================================
;  [to-extension] — এক্সটেনশন ডায়াল (internal / inbound)
; ==========================================================
[to-extension]
exten => s,1,NoOp(=== Dialing Extension: ${EXTEN} ===)
same => n,AGI(master_panel.php,extension)
same => n,GotoIf($["${PANEL_TARGET}" != ""]?dial)
same => n,Set(PANEL_TARGET=${EXTEN})
same => n(dial),Dial(PJSIP/${PANEL_TARGET},30,tT)
same => n,GotoIf($["${DIALSTATUS}" = "BUSY"]?busy)
same => n,GotoIf($["${DIALSTATUS}" = "NOANSWER"]?noanswer)
same => n,GotoIf($["${DIALSTATUS}" = "CHANUNAVAIL"]?noanswer)
same => n,Hangup()
same => n(busy),Playback(user-busy)
same => n,Hangup()
same => n(noanswer),Playback(user-no-answer)
same => n,Hangup()

; ==========================================================
;  [to-gateway] — আউটবাউন্ড কল (ট্রাংক দিয়ে)
; ==========================================================
[to-gateway]
exten => s,1,NoOp(=== Outbound via Gateway ===)
same => n,AGI(master_panel.php,gateway)
same => n,GotoIf($["${PANEL_STATUS}" != "ALLOW"]?hangup)
same => n,Dial(PJSIP/${EXTEN}@${PANEL_TRUNK},60,L(${PANEL_MAX_DURATION}))
same => n(hangup),Hangup()

; ==========================================================
;  [to-ivr]
; ==========================================================
[to-ivr]
exten => s,1,Answer()
same => n,AGI(master_panel.php,ivr)
same => n,GotoIf($["${PANEL_AUDIO_FILE}" = ""]?hangup)
same => n,Background(${PANEL_AUDIO_FILE})
same => n,WaitExten(5)
same => n,Hangup()
same => n(hangup),Hangup()

; ==========================================================
;  [to-ringgroup]
; ==========================================================
[to-ringgroup]
exten => s,1,AGI(master_panel.php,ring_group)
same => n,GotoIf($["${PANEL_RING_TARGETS}" = ""]?hangup)
same => n,Dial(${PANEL_RING_TARGETS},${PANEL_TIMEOUT:-30})
same => n,Hangup()
same => n(hangup),Hangup()
EOF

# ------------------------------------------------------------
# ৭. Cron Job — প্রতি ২ মিনিটে এক্সটেনশন সিঙ্ক
# ------------------------------------------------------------
echo "[+] Setting up Cron Job for extension auto-sync (every 2 min)..."
(crontab -l 2>/dev/null | grep -v "sync_extensions.php"; \
 echo "*/2 * * * * /usr/bin/php /usr/local/bin/sync_extensions.php > /dev/null 2>&1") | crontab -

# ------------------------------------------------------------
# ৮. Initial Sync + Asterisk Reload
# ------------------------------------------------------------
echo "[+] Running initial extension sync..."
php /usr/local/bin/sync_extensions.php

echo "[+] Reloading Asterisk..."
systemctl restart asterisk
sleep 2
asterisk -rx "dialplan reload"
asterisk -rx "pjsip reload"

# ------------------------------------------------------------
# ৯. Summary
# ------------------------------------------------------------
echo ""
echo "======================================================"
echo " [✔] EXTENSION SETUP COMPLETED SUCCESSFULLY!"
echo "======================================================"
echo ""
echo "📁  Files created / updated:"
echo "    /var/lib/asterisk/agi-bin/master_panel.php"
echo "    /usr/local/bin/sync_extensions.php"
echo "    /etc/asterisk/pjsip.conf"
echo "    /etc/asterisk/pjsip_extensions.conf"
echo "    /etc/asterisk/extensions.conf"
echo ""
echo "🔧  Verify commands:"
echo "    asterisk -rx 'pjsip show endpoints'"
echo "    asterisk -rx 'pjsip show aors'"
echo "    asterisk -rx 'dialplan show from-panel'"
echo "    cat /etc/asterisk/pjsip_extensions.conf"
echo "    crontab -l | grep sync_extensions"
echo ""
echo "📱  App registration info (SIP client):"
echo "    Server : <your-server-IP>"
echo "    Port   : 5060 (UDP)"
echo "    Username: <extension number>"
echo "    Password: <password from database>"
echo ""
echo "🧪  Test calls:"
echo "    1) Extension→Extension : 1001 dials 1002"
echo "    2) Extension→Outbound  : 1001 dials 01XXXXXXXXX (via gateway)"
echo "    3) Inbound→Extension   : external call lands on 1001"
echo ""
echo "📝  Asterisk live log:"
echo "    asterisk -rvvv"
