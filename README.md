# WSL2 AR9271 Monitor Mode

**Injection-capable 802.11 monitor mode inside Windows Subsystem for Linux, on a
99-cent Atheros AR9271 dongle and a 2013 ThinkPad. The thing the internet says
can't be done.**

Monitor mode works. `aireplay-ng --test` returns 30/30. The whole rig comes up on
a double-click.
![Monitor mode running on WSL2: terminal, live Wireshark capture, and the repo](screenshot-monitor-mode.png)
---

## Quick start (if you already have the custom kernel built)

1. Boot Windows with the adapter **unplugged**.
2. Plug in the AR9271.
3. Double-click `START-WIFI-RIG.cmd`.
4. In the Debian window that opens:
   ```bash
   sudo airodump-ng wlxXXXXXXXXXXXX          # live survey
   sudo wireshark -i wlxXXXXXXXXXXXX -k       # full GUI capture
   ```
   (Replace `wlxXXXXXXXXXXXX` with your interface name from `iw dev`.)

## Files in this repo

| File | What it is |
|------|-----------|
| `START-WIFI-RIG.cmd` | Double-click launcher. Runs the worker script with the window held open. |
| `wifi-rig.ps1` | Worker: checks the adapter, wakes WSL, attaches over USB/IP, sets monitor mode, opens Debian. |
| `README.md` | The full build write-up below, including how to compile the kernel from scratch. |

## Before the quick start works: the one-time build

If you have **not** yet built the custom kernel, the quick-start launcher will not
work, there is no wireless stack in the stock WSL2 kernel. The full build (custom
kernel, embedded firmware, usbipd setup) is documented in detail below. Budget an
afternoon; most of it is unattended compile time.

## You will need to edit the scripts for your machine

Both scripts hardcode two values from the build machine. Change them to match yours:

- **`$dev = '0cf3:9271'`** is the AR9271 USB ID. Same for any AR9271, but check
  with `usbipd list`.
- **`$w = 'wlxc01c3049d538'`** is the interface name, which is derived from *your*
  adapter's MAC and will be different. Find yours with `iw dev` inside Debian.
- The kernel path in `.wslconfig` (`C:\Users\Owner\...`) and the distro name
  (`Debian`) also assume the build-machine layout.

---


**Or: how to do the thing the internet keeps telling you is impossible.**

The consensus online is blunt: you cannot get real 802.11 monitor mode, let alone
frame injection, working inside the Windows Subsystem for Linux. The stock WSL2
kernel has no wireless stack, USB/IP is said to be too lossy for timing-sensitive
injection, and the usual advice is "just dual-boot Linux."

This is a record of doing it anyway, on a Haswell-era ThinkPad X240 running Windows
11, with a 99-cent Atheros AR9271 dongle off AliExpress. Monitor mode works. Injection tests at 30/30.
The whole rig comes up on a double-click.

What follows is the real path, including the dead ends, because the dead ends are
where the actual knowledge is.

---

## The hardware and the starting point

- **Laptop:** Lenovo ThinkPad X240, Intel Core i5-4300U (2 cores / 4 threads,
  Haswell, 2013), 8 GB RAM.
- **OS:** Windows 11 Pro 23H2, build 22631.
- **Adapter:** Atheros AR9271, USB ID `0cf3:9271`. The classic ath9k_htc chip. 99 cents on AliExpress.
  Single-band 2.4 GHz only. Cheap, ubiquitous, and one of the few USB adapters
  with mainline monitor + injection support.
- **Target environment:** Debian on WSL2.

The AR9271 is the right chip for this because its driver, `ath9k_htc`, is in the
mainline Linux tree and supports both monitor mode and injection. The problem was
never the adapter. The problem is everything between the adapter and the driver.

---

## The four walls you hit, in order

Getting here means clearing four separate obstacles, each of which looks like the
final one until you clear it and find the next:

1. **Virtualization is off.** WSL2 needs the hypervisor. If it is not running,
   nothing else matters.
2. **The stock WSL2 kernel has no 802.11 stack.** No `cfg80211`, no `mac80211`,
   no `ath9k`. The adapter enumerates and the kernel does nothing with it.
3. **A custom kernel cannot find firmware.** Even with the driver compiled in,
   WSL's firmware loader cannot see the distro's `/lib/firmware`.
4. **The adapter is dirty on cold boot.** A hardware quirk that has nothing to do
   with software but will convince you the software is broken.

---

## Wall 1: The hypervisor

Symptom: `wsl --status` reports that virtualization is not enabled, and
`(Get-CimInstance Win32_ComputerSystem).HypervisorPresent` returns `False`.

There are three independent layers that can each zero out the hypervisor, and a
generic "enable virtualization" guide will not tell you which one is your problem:

1. **Firmware VT-x.** Check with `systeminfo`, read the line
   `Virtualization Enabled In Firmware`. On this machine it was already `Yes`, so
   no BIOS trip was needed. If it says `No`, that is a reboot-into-BIOS fix
   (ThinkPad: F1 at splash, Security > Virtualization > Intel Virtualization
   Technology > Enabled) and nothing in Windows can substitute for it.

2. **The `VirtualMachinePlatform` optional feature.** This was the actual culprit
   here. It was `Disabled`. Note: you do **not** need the
   `Microsoft-Windows-Subsystem-Linux` feature, that is WSL1. Store-based WSL2
   needs only `VirtualMachinePlatform`.

   ```powershell
   Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart
   ```

3. **The BCD `hypervisorlaunchtype`.** The silent killer. Even with VMP enabled,
   if this is set to `Off` the hypervisor never launches. Check it:

   ```powershell
   bcdedit /enum '{current}' | findstr /i hypervisorlaunchtype
   ```

   If the line is absent, it defaults to `Auto` and you are fine. If it reads
   `Off`, fix with `bcdedit /set '{current}' hypervisorlaunchtype Auto`.

**Critical detail:** after enabling VMP, do a **full shutdown**, not a restart.
Windows Fast Startup hibernates the kernel and the feature will not take on a warm
restart.

```powershell
shutdown /s /f /t 0
```

After the cold boot, `HypervisorPresent` returned `True`.

### A note on `bcdedit not recognized`

At one point `bcdedit` threw "not recognized as a cmdlet." The instinct is to
blame a broken PATH or WOW64 redirection, but the real fix was simpler: call it
by full path, `C:\Windows\System32\bcdedit.exe`. A stale PATH in one window, not
a missing binary.

---

## Wall 2: Building a kernel with a wireless stack

The stock WSL2 kernel ships without any 802.11 support. You confirm this by the
fact that `lsusb` shows the adapter but `iw` reports nothing exists. There is no
subsystem for the driver to bind to.

The fix is to compile your own WSL2 kernel with the stack built in.

### Get the matching source

WSL2's kernel version is reported by `uname -r`. On this system that was
`6.18.33.2-2`, so the matching branch is `linux-msft-wsl-6.18.y`. Microsoft moved
WSL2 to the 6.18 LTS line in spring 2026.

```bash
cd ~
git clone https://github.com/microsoft/WSL2-Linux-Kernel.git --depth=1 -b linux-msft-wsl-6.18.y
cd WSL2-Linux-Kernel
make kernelversion   # confirmed 6.18.35.2
```

**Build on ext4, not on `/mnt/c`.** Cloning into a Windows-mounted path
(DrvFs / 9p) makes the build 5 to 10 times slower and can break on
case-sensitivity. Keep it in the Linux home directory.

### Dependencies

```bash
sudo apt install -y build-essential flex bison dwarves libssl-dev libelf-dev \
                    cpio bc python3 git rsync
```

Two traps here:

- **`pahole` is not a package.** It ships inside `dwarves`. Do not
  `apt install pahole`.
- **apt is all-or-nothing.** If any single package name in an install line is
  bad, apt installs *nothing* from that line, not "everything except the bad
  one." This bites you repeatedly if you are not watching. Split installs when
  in doubt.

### Configuration: the step that decides everything

Start from Microsoft's lean config, not a distro config. This is why the build
takes an hour instead of five.

```bash
cp Microsoft/config-wsl .config
```

Then enable the wireless stack. Everything as `=y` (built in), not `=m`
(module). Module loading in WSL2 is a swamp; building in sidesteps it entirely.

```bash
./scripts/config --file .config \
  -e CFG80211 -e CFG80211_WEXT -e MAC80211 -e WLAN -e WLAN_VENDOR_ATH \
  -e ATH_COMMON -e ATH9K_HW -e ATH9K_COMMON -e ATH9K_HTC -e ATH9K_BTCOEX_SUPPORT
make olddefconfig
```

**Now verify, before building.** This grep is not optional. It is the difference
between a working kernel and 90 wasted minutes:

```bash
grep -E '^CONFIG_(CFG80211|MAC80211|ATH9K|WLAN)' .config
```

### The dependency cap that will get you

On the first pass, this is what came back:

```
CONFIG_CFG80211=y
CONFIG_MAC80211=y
CONFIG_WLAN=y
CONFIG_ATH9K_HW=m      <-- module, not built in
CONFIG_ATH9K_COMMON=m  <-- module
CONFIG_ATH9K_HTC=m     <-- module
```

The ath9k family silently downgraded to modules. The reason: a tristate symbol
**cannot** be `=y` if something it depends on is `=m`. `ATH9K_HTC` depends on USB,
and `config-wsl` ships `CONFIG_USB=m`. So `olddefconfig` capped the whole family
at module level and said nothing.

The USB/IP transport that delivers the dongle was capped the same way:
`CONFIG_USBIP_CORE=m`, `CONFIG_USBIP_VHCI_HCD=m`.

Fix: force the whole chain, USB included, to built-in.

```bash
./scripts/config --file .config \
  -e USB_COMMON -e USB -e USBIP_CORE -e USBIP_VHCI_HCD \
  -e ATH9K_HW -e ATH9K_COMMON -e ATH9K_HTC
make olddefconfig
```

Re-verify. All nine must read `=y`:

```
CONFIG_USB=y
CONFIG_USB_COMMON=y
CONFIG_USBIP_CORE=y
CONFIG_USBIP_VHCI_HCD=y
CONFIG_CFG80211=y
CONFIG_MAC80211=y
CONFIG_WLAN=y
CONFIG_WLAN_VENDOR_ATH=y
CONFIG_ATH9K_HTC=y
```

### Build

```bash
make -j$(nproc) 2>&1 | tee ~/build.log
```

On the dual-core i5-4300U this ran about 2.5 hours with thermal throttling. The
artifact is `arch/x86/boot/bzImage`, roughly 18 MB with the wireless stack built
in. Confirm no `ath9k*.ko` modules were produced, that would mean the `=y` did
not take:

```bash
find . -name 'ath9k*' -name '*.ko'   # must return nothing
```

---

## Wall 3: Firmware the kernel cannot find

Point WSL at the new kernel via `%USERPROFILE%\.wslconfig`. **Double backslashes.**
Single ones are parsed as escapes and the line is silently discarded, which will
convince you the build failed.

```
[wsl2]
kernel=C:\\Users\\Owner\\wsl-kernel\\bzImage
```

After `wsl --shutdown` and relaunch, `uname -r` reported `6.18.35.2` with a
trailing `+`. The `+` is git's mark for a tree with uncommitted changes, that is,
your config edits. Proof you are running your own kernel.

Then the driver loaded, claimed the adapter, requested firmware, and failed:

```
usb 1-1: ath9k_htc: Firmware ath9k_htc/htc_9271-1.4.0.fw requested
usb 1-1: Direct firmware load for ath9k_htc/htc_9271-1.4.0.fw failed with error -2
usb 1-1: ath9k_htc: no suitable firmware found!
```

The firmware file was present at `/lib/firmware/ath9k_htc/htc_9271-1.4.0.fw`,
verified, 51008 bytes. The kernel insisted it did not exist.

### Why

WSL2 runs multiple distros inside one shared VM, so the kernel's initial mount
namespace is Microsoft's own minimal init rootfs, not Debian's. The direct
firmware loader resolves paths against that init namespace and never sees Debian's
`/lib/firmware`. The signed regulatory database (`regulatory.db`) failed the same
way for the same reason.

### The fix: embed the firmware in the kernel

Stop asking the filesystem. Compile the firmware blobs directly into the kernel
image with `CONFIG_EXTRA_FIRMWARE`. Then there is no path lookup to fail.

```bash
./scripts/config --file .config \
  --set-str EXTRA_FIRMWARE "ath9k_htc/htc_9271-1.4.0.fw regulatory.db regulatory.db.p7s"
./scripts/config --file .config --set-str EXTRA_FIRMWARE_DIR "/lib/firmware"
make olddefconfig
grep EXTRA_FIRMWARE .config
```

The firmware comes from the `firmware-ath9k-htc` package (the old
`firmware-atheros` was split up; on current Debian the ath9k_htc blob lives in
`main`, not non-free, since it was open-sourced). The regdb comes from
`wireless-regdb`.

Rebuild. This is incremental, object files are cached, so it is 10 to 30 minutes,
not another 2.5 hours. You can confirm the embedding in the build log:

```
AS  drivers/base/firmware_loader/builtin/ath9k_htc/htc_9271-1.4.0.fw.gen.o
AS  drivers/base/firmware_loader/builtin/regulatory.db.gen.o
AS  drivers/base/firmware_loader/builtin/regulatory.db.p7s.gen.o
```

Swap the new `bzImage` in (copy to a temp name, `wsl --shutdown`, move over the
top, because you cannot overwrite the running kernel image), and this time:

```
usb 1-1: ath9k_htc: Transferred FW: ath9k_htc/htc_9271-1.4.0.fw, size: 51008
ath9k_htc 1-1:1.0: ath9k_htc: HTC initialized with 33 credits
ath9k_htc 1-1:1.0: ath9k_htc: FW Version: 1.4
ieee80211 phy0: Atheros AR9271 Rev:1
```

The radio is live.

---

## Passing the adapter into WSL

The transport is `usbipd-win`. Install on Windows:

```powershell
winget install --interactive --exact dorssel.usbipd-win
```

Bind once (persists across reboots). Because Windows has an active driver on the
adapter, you must force the bind:

```powershell
usbipd bind --force --hardware-id 0cf3:9271
```

Attach into a running WSL2 VM (this drops on every `wsl --shutdown` and must be
redone):

```powershell
usbipd attach --wsl --hardware-id 0cf3:9271
```

Note: `usbipd` takes `--hardware-id` (VID:PID) directly, so you never need to
chase the transient busid. `bind` needs an elevated shell; `attach` does not.

---

## Monitor mode and the injection test

The interface does **not** come up as `wlan0`. udev's predictable naming renames
it based on the MAC, here `wlxc01c3049d538`. Every guide that says `wlan0` is
wrong for your box unless you set `net.ifnames=0`. Find the real name with
`iw dev`.

```bash
sudo ip link set wlxc01c3049d538 down
sudo iw dev wlxc01c3049d538 set type monitor
sudo ip link set wlxc01c3049d538 up
iw dev wlxc01c3049d538 info   # confirm: type monitor
```

Then the moment of truth, the thing that supposedly cannot survive a USB/IP
tunnel:

```bash
sudo aireplay-ng --test wlxc01c3049d538
```

Result:

```
Injection is working!
Found 15 APs
...
30/30: 100%
```

Injection over USB/IP into a virtualized host controller, at full success rate.
The frames survive the tunnel.

---

## Wall 4: The cold-boot enumeration quirk

With everything working, one problem remained: after a full Windows shutdown and
cold boot, the adapter often failed to enumerate. `usbipd list` would show it as:

```
3-1  0000:0002  Unknown USB Device (Device Descriptor Request Failed)
```

This is not a software failure. The AR9271 is known to fail USB descriptor
handshake when it is powered up during the boot sequence, before the USB power
rail is stable. The tell is the `0000:0002` placeholder ID instead of `0cf3:9271`.

Two fixes, in increasing order of elegance:

1. **Reseat.** Pull the dongle, wait two seconds, firmly reinsert. It enumerates
   clean into a settled USB stack.

2. **Boot without it, then hot-plug.** Shut down, unplug the dongle, boot Windows
   fully, *then* plug the dongle into the running system. It enumerates cleanly
   every time because it is joining a stable bus rather than racing the boot.

Option 2 is the winning workflow. It removes the reseat friction entirely.

---

## The one-double-click launcher

The final workflow is two files in one folder. `START-WIFI-RIG.cmd` is a
two-line batch launcher (Windows runs `.cmd` on double-click natively, sidestepping
the PowerShell execution-policy fight):

```
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0wifi-rig.ps1"
```

`-NoExit` guarantees the window stays open so you can read what happened. `%~dp0`
locates the `.ps1` next to the launcher regardless of where the folder lives.

The worker script, `wifi-rig.ps1`, does the whole sequence with proper guards
instead of blind sleeps:

- Checks the adapter is present and cleanly enumerated (not `0000:0002` or
  "Descriptor Request Failed"). If dirty, it prints a reseat instruction and
  waits, rather than failing silently.
- **Polls** for WSL to respond rather than sleeping a fixed time. Fast on warm
  start, patient on cold.
- Clears any stale attach, then attaches.
- **Waits for the interface to actually appear** before touching it, which was
  the cause of an early "Cannot find device" cascade.
- Sets monitor mode using **full binary paths** (`/usr/sbin/iw`, `/usr/sbin/ip`).
  This matters: `wsl -e <cmd>` runs without a login shell and gets a minimal PATH
  that excludes `/usr/sbin`, so bare `iw` fails with "No such file or directory"
  even though it is installed. Full paths fix it.
- Verifies `type monitor`, then opens a Debian window ready to work in.

Daily use, start to finish:

1. Boot Windows (adapter unplugged).
2. Plug in the adapter.
3. Double-click `START-WIFI-RIG.cmd`.
4. In the Debian window: `sudo airodump-ng wlxc01c3049d538` or
   `sudo wireshark -i wlxc01c3049d538 -k`.

---

## What you can do with it

Once live, the adapter is a full passive 2.4 GHz sensor. `airodump-ng` gives a
live survey of every AP and client in range: BSSID, signal, channel, encryption,
and per-device data rates. Wireshark with the filter
`wlan.fc.type_subtype == 0x04` isolates probe requests, the frames devices emit
while hunting for known networks.

Probe requests are where the privacy lessons live. Devices split into two camps:

- **Leakers** broadcast the *names* of networks they remember, in the clear.
  Observed here: laptops with real Intel MACs, an HP printer, an assortment of
  IoT gear. Anyone listening learns which networks a device belongs to.
- **Well-behaved** devices send only wildcard (broadcast) probes and use MAC
  randomization (identifiable by the locally-administered bit in the first octet).
  Most modern phones now do this.

A subtle point visible frame-by-frame: some devices interleave wildcard and
directed probes, so even a device that "sometimes randomizes" still gives itself
away on the directed frames. And sequence numbers provide a known
de-anonymization hook: a device that rotates its MAC but keeps a continuous
sequence counter can be re-linked across the rotation.

This is exactly the raw material a wireless intrusion detection baseline is built
from: capture the normal RF environment, then flag what deviates.

**One boundary worth stating plainly:** passive capture of broadcast frames is one
thing. Active injection against any network you do not own or have explicit
authorization to test is a federal crime under the CFAA. Injection testing belongs
on your own AP, or one you are cleared in writing to assess. The capability does
not change the law.

---

## Summary of the whole path

| Wall | Symptom | Fix |
|------|---------|-----|
| Hypervisor off | `HypervisorPresent = False` | Enable `VirtualMachinePlatform`, check BCD `hypervisorlaunchtype`, full cold boot |
| No wireless stack | `lsusb` sees adapter, `iw` sees nothing | Build custom WSL2 kernel with cfg80211/mac80211/ath9k_htc as `=y` |
| USB dependency cap | ath9k silently drops to `=m` | Force `CONFIG_USB=y` and the whole chain built-in |
| Firmware not found | `Direct firmware load ... failed error -2` | Embed firmware via `CONFIG_EXTRA_FIRMWARE` |
| Cold-boot enumeration | `0000:0002 Descriptor Request Failed` | Boot without adapter, hot-plug after |

Total cost: one 99-cent adapter, a free afternoon of compile time, and a laptop most
people would have thrown out. The result is a genuinely useful wireless analysis
rig running on hardware from 2013, doing something the documentation says is not
possible.

---

*Environment: ThinkPad X240, Windows 11 Pro 23H2, WSL2 2.7.10, custom kernel
6.18.35.2, Debian, usbipd-win, Atheros AR9271. Built July 2026.*
