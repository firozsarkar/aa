#!/bin/bash

# সুনিশ্চিত করা যে স্ক্রিপ্টটি root পারমিশনে রান হচ্ছে
if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run as root (sudo bash setup.sh)"
  exit 1
fi

echo "[+] Starting PBX & Gateway Full Automation Setup..."

# ১. সিস্টেম আপডেট এবং প্রয়োজনীয় প্যাকেজ (PHP, cURL ইত্যাদি) ইনস্টল
echo "[+] Installing PHP, cURL, and dependencies..."
apt update && apt install -y php-cli php-curl asterisk

# ২. ডিরেক্টরি এবং পারমিশন চেক/তৈরি
echo "[+] Setting up Asterisk AGI directory..."
mkdir -p /var/lib/asterisk/agi-bin
mkdir -p /etc/asterisk

# ৩. মূল মাস্টার প্যানেল AGI স্ক্রিপ্ট তৈরি (/var/lib/asterisk/agi-bin/master_panel.php)
echo "[+] Creating master_panel.php..."
cat << 'EOF' > /var/lib/asterisk/agi-bin/master_panel.php
#!/usr/bin/php -q
<?php
set_time_limit(0);
ob_implicit_flush(true);

$agi_vars = [];
while (!feof(STDIN)) {
    $line = trim(fgets(STDIN));
    if ($line === '') break;
    if (preg_match('/^agi_(\w+):\s*(.*)$/', $line, $matches)) {
        $agi_vars[$matches[1]] = $matches[2];
    }
}

$module = $argv[1] ?? 'routing'; 
$caller = $agi_vars['callerid'] ?? '';
$callee = $agi_vars['extension'] ?? '';
$uniqueid = $agi_vars['uniqueid'] ?? '';
$channel = $agi_vars['channel'] ?? '';

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
    'extra'    => $argv[2] ?? ''
]);

$ch = curl_init($target_url);
curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
curl_setopt($ch, CURLOPT_POST, true);
curl_setopt($ch, CURLOPT_POSTFIELDS, $post_data);
curl_setopt($ch, CURLOPT_TIMEOUT, 10);
$response = trim(curl_exec($ch));
curl_close($ch);

$data = json_decode($response, true);

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


# ৪. cPanel থেকে ট্রাংক সিঙ্ক করার স্ক্রিপ্ট তৈরি (/usr/local/bin/sync_gateway.php)
echo "[+] Creating sync_gateway.php..."
cat << 'EOF' > /usr/local/bin/sync_gateway.php
<?php
$url = "https://pbx.registercamp.com/geteway.php?action=sync_trunks";
$response = @file_get_contents($url);
$data = json_decode($response, true);

if (!$data || $data['status'] !== 'SUCCESS') {
    exit("Failed to fetch trunks from gateway.php\n");
}

$pjsip_config = "; Auto-generated PJSIP Trunks from cPanel Database\n\n";

foreach ($data['trunks'] as $t) {
    $name = $t['trunk_name'];
    $user = $t['username'];
    $pass = $t['password'];
    $host = $t['host_ip'];
    $port = $t['port'] ?? '5060';
    $sip_num = $t['sip_number'];

    $pjsip_config .= <<<EOT
[{$name}]
type=registration
transport=transport-udp
outbound_auth={$name}_auth
server_uri=sip:{$host}:{$port}
client_uri=sip:{$user}@{$host}:{$port}
contact_user={$sip_num}
retry_interval=60

[{$name}_auth]
type=auth
auth_type=userpass
password={$pass}
username={$user}

[{$name}_aor]
type=aor
contact=sip:{$host}:{$port}

[{$name}]
type=endpoint
transport=transport-udp
context=from-panel
disallow=all
allow=ulaw,alaw,g729
outbound_auth={$name}_auth
aors={$name}_aor
from_user={$user}
from_domain={$host}

[{$name}_identify]
type=identify
endpoint={$name}
match={$host}

; -----------------------------------------

EOT;
}

file_put_contents('/etc/asterisk/pjsip_gateway.conf', $pjsip_config);
shell_exec('asterisk -rx "pjsip reload"');
echo "Gateway synchronized and PJSIP reloaded successfully!\n";
?>
EOF

chmod +x /usr/local/bin/sync_gateway.php


# ৫. মূল pjsip.conf ফাইল কনফিগার করা
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
max_contacts=2
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

[1001]
type=endpoint
transport=transport-udp
context=from-panel
disallow=all
allow=ulaw,alaw,g729
auth=1001_auth
aors=1001_aor

[1001_auth]
type=auth
auth_type=userpass
password=YourSecurePassword1001
username=1001

[1001_aor]
type=aor
max_contacts=2

#include "pjsip_gateway.conf"
EOF


# ৬. extensions.conf ডায়ালপ্ল্যান সেটআপ করা
echo "[+] Configuring /etc/asterisk/extensions.conf..."
cat << 'EOF' > /etc/asterisk/extensions.conf
[general]
static=yes
writeprotect=no

[from-panel]
exten => _X.,1,NoOp(=== New Call: ${CALLERID(num)} -> ${EXTEN} ===)
same => n,AGI(master_panel.php,inbound_outbound)

same => n,GotoIf($["${PANEL_ACTION}" = "extension"]?to-extension,1)
same => n,GotoIf($["${PANEL_ACTION}" = "ivr"]?to-ivr,1)
same => n,GotoIf($["${PANEL_ACTION}" = "ring_group"]?to-ringgroup,1)
same => n,GotoIf($["${PANEL_ACTION}" = "outbound"]?to-gateway,1)
same => n,Hangup()

exten => to-extension,1,AGI(master_panel.php,extension)
same => n,Dial(PJSIP/${PANEL_TARGET},30)
same => n,Hangup()

exten => to-gateway,1,AGI(master_panel.php,gateway)
same => n,GotoIf($["${PANEL_STATUS}" != "ALLOW"]?hangup_call)
same => n,Dial(PJSIP/${EXTEN}@${PANEL_TRUNK},60,L(${PANEL_MAX_DURATION}))
same => n(hangup_call),Hangup()

exten => to-ivr,1,Answer()
same => n,AGI(master_panel.php,ivr)
same => n,Background(${PANEL_AUDIO_FILE})
same => n,WaitExten(5)

exten => to-ringgroup,1,AGI(master_panel.php,ring_group)
same => n,Dial(${PANEL_RING_TARGETS},${PANEL_TIMEOUT})
same => n,Hangup()

exten => h,1,NoOp(=== Call Ended, Sending CDR ===)
same => n,AGI(master_panel.php,cdr,${CDR(billsec)}|${CDR(disposition)})
EOF


# ৭. অটোমেটিক সিঙ্কের জন্য ক্রনজব (Cron Job) সেটআপ
echo "[+] Setting up Cron Job for 1-minute automatic sync..."
(crontab -l 2>/dev/null; echo "* * * * * /usr/bin/php /usr/local/bin/sync_gateway.php > /dev/null 2>&1") | crontab -


# ৮. Asterisk রিলোড এবং গেটওয়ে সিঙ্ক রান করা
echo "[+] Reloading Asterisk and syncing gateways..."
php /usr/local/bin/sync_gateway.php
systemctl restart asterisk
asterisk -rx "dialplan reload"
asterisk -rx "pjsip reload"

echo "======================================================"
echo " [✔] SETUP COMPLETED SUCCESSFULLY!"
echo "======================================================"
