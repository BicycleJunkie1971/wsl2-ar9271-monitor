$dev = '0cf3:9271'
$w   = 'wlxc01c3049d538'

Write-Host ""
Write-Host "=== AR9271 MONITOR RIG ===" -ForegroundColor Cyan
Write-Host ""

# --- 1. Dongle present and clean? ---
$list = usbipd list
$good = $list | Select-String -SimpleMatch $dev
$dirty = ($list | Select-String -SimpleMatch 'Descriptor Request Failed') -or ($list | Select-String -SimpleMatch '0000:0002')

if ((-not $good) -or $dirty) {
    Write-Host "Dongle not ready on USB." -ForegroundColor Red
    Write-Host "PULL IT OUT, wait 2 seconds, push it back in FIRMLY, then double-click again." -ForegroundColor Yellow
    Write-Host ""
    $list
    Write-Host ""
    Read-Host "Press Enter to close"
    return
}
Write-Host "[1/4] Dongle detected and clean." -ForegroundColor Green

# --- 2. Wake WSL and confirm it actually answers ---
Write-Host "[2/4] Starting Debian (waiting for it to respond)..." -ForegroundColor Cyan
$ready = $false
for ($i = 0; $i -lt 20; $i++) {
    $r = wsl -d Debian -e echo ready 2>$null
    if ($r -match 'ready') { $ready = $true; break }
    Start-Sleep -Seconds 1
}
if (-not $ready) {
    Write-Host "Debian did not respond after 20 seconds." -ForegroundColor Red
    Write-Host "Open a terminal, run 'wsl -d Debian' once by hand, then try again." -ForegroundColor Yellow
    Read-Host "Press Enter to close"
    return
}
Write-Host "      Debian is up." -ForegroundColor Green

# --- 3. Attach (clear any stale attach first) ---
Write-Host "[3/4] Attaching dongle to Debian..." -ForegroundColor Cyan
usbipd detach --hardware-id $dev 2>$null
Start-Sleep -Seconds 2
usbipd attach --wsl --hardware-id $dev
Start-Sleep -Seconds 6

# --- 4. Wait for the interface to actually appear, then set monitor ---
Write-Host "[4/4] Waiting for interface, then setting monitor mode..." -ForegroundColor Cyan
$seen = $false
for ($i = 0; $i -lt 15; $i++) {
    $chk = wsl -d Debian -u root -e /usr/sbin/ip link show $w 2>&1
    if ($chk -notmatch 'does not exist' -and $chk -notmatch 'Cannot find') { $seen = $true; break }
    Start-Sleep -Seconds 1
}
if (-not $seen) {
    Write-Host "Interface $w never appeared. The attach did not land." -ForegroundColor Red
    Write-Host "Try double-clicking again. If it keeps failing, reseat the dongle." -ForegroundColor Yellow
    Read-Host "Press Enter to close"
    return
}

wsl -d Debian -u root -e /usr/sbin/ip link set $w down
wsl -d Debian -u root -e /usr/sbin/iw dev $w set type monitor
wsl -d Debian -u root -e /usr/sbin/ip link set $w up

$info = wsl -d Debian -u root -e /usr/sbin/iw dev $w info
Write-Host ""
if ($info | Select-String 'type monitor') {
    Write-Host "==================================" -ForegroundColor Green
    Write-Host " MONITOR MODE LIVE. Rig is ready." -ForegroundColor Green
    Write-Host "==================================" -ForegroundColor Green
} else {
    Write-Host "Interface came up but not in monitor mode. Info:" -ForegroundColor Yellow
    $info
    Read-Host "Press Enter to close"
    return
}

Write-Host ""
Write-Host "Opening a Debian window. In it, run one of:" -ForegroundColor Cyan
Write-Host "   sudo wireshark -i $w -k" -ForegroundColor White
Write-Host "   sudo airodump-ng $w" -ForegroundColor White
Write-Host ""
Start-Process wsl -ArgumentList '-d','Debian'
Read-Host "Rig is up. Press Enter to close this launcher window"