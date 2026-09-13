# Warning

As always, no warranty / responsibility. If this bricks your tablet, you're on your own. I had Claude do this entire setup from start to finish and then write this README and script. Humans make mistakes. AI make mistakes. Verify before you start.

---

# Rooting the Teclast P30 (Allwinner A523)

Magisk root and debloat for Allwinner **A523 / T527** (`sun55iw3p1`, board `saturn`)
tablets, using **FEL mode** and a bare-metal eMMC driver.

Standard `fastboot flash` does not work on this hardware. This bootloader implements
only a handful of commands, so every partition read and write goes through the
Allwinner boot ROM instead.

---

## Verified on

| | |
|---|---|
| Device | Teclast P30 (`P30_ROW`), Android 14, build `UP1A.231105.001.A1` |
| SoC | Allwinner A523 / T527 — `sun55iw3p1`, board `saturn`, arm64-v8a |
| Storage | 58 GB eMMC, A/B slots, separate `init_boot` partition (GKI) |
| Host | Ubuntu 26.04, USB-A → USB-C |
| Result | Magisk 30.7, `uid=0`, 41 packages removed, boots clean |

Should also apply to other A523/T527 devices with eMMC — Teclast P85T/P26T/P30T,
Pritom B8/M10, and various T527 boxes. `p30-root.sh` reads partition offsets from
each device's own GPT rather than assuming this P30's layout, so `backup`/`flash`
should be layout-agnostic; the debloat package lists (`GROUP1`/`GROUP2`) are this
ROM's bloat specifically and simply no-op on packages that don't exist elsewhere.

---

## ⚠ Read this first

- **Unlocking the bootloader erases the entire tablet.** Not reversible, no prompt.
- **Flashing 8 MB takes 8–15 minutes.** That is expected, not a hang. See [Why writing is slow](#why-writing-is-so-slow).
- **Do not flash a disabled vbmeta.** On most Androids `--flags 0x02` lets you boot
  modified images; on this bootloader it causes an immediate *"your device is corrupt"*
  halt. Leave vbmeta alone.
- **You cannot permanently brick this.** FEL lives in mask ROM and is always reachable
  over USB, even when Android will not boot. That is why the backup step matters more
  than any other.

---

## Requirements

### Debian / Ubuntu packages

```bash
sudo apt-get update
sudo apt-get install -y \
    adb fastboot \
    build-essential \
    gcc-arm-none-eabi \
    libusb-1.0-0-dev \
    pkg-config \
    git curl usbutils
```

| Package | Why |
|---|---|
| `adb`, `fastboot` | Talk to the tablet in Android and bootloader modes |
| `build-essential` | Compile `xfel` on the host |
| `gcc-arm-none-eabi` | Cross-compile the bare-metal ARM eMMC driver |
| `libusb-1.0-0-dev` | `xfel` links against libusb to reach FEL |
| `pkg-config` | Locates libusb during the build |
| `usbutils` | `lsusb`, used constantly to confirm device mode |
| `git`, `curl` | Fetch the two upstream repos and Magisk |

> **Do not use the distro `sunxi-tools` package.** Its `sunxi-fel` binary crashes on
> the A523 with `aw_read_usb_response: Assertion 'strcmp(buf, "AWUS") == 0' failed`.
> This SoC needs [`xfel`](https://github.com/xboot/xfel), built from source — which
> `./p30-root.sh build` does for you.

### udev rule

FEL presents as a raw USB device your user cannot open by default:

```bash
echo 'SUBSYSTEM=="usb", ATTR{idVendor}=="1f3a", ATTR{idProduct}=="efe8", MODE="0666"' \
  | sudo tee /etc/udev/rules.d/71-sunxi-fel.rules
sudo udevadm control --reload-rules && sudo udevadm trigger
```

### Upstream projects

Cloned and built automatically by `./p30-root.sh build`:

- [xboot/xfel](https://github.com/xboot/xfel) — FEL tool with A523 support
- [chrislennon/A523-root](https://github.com/chrislennon/A523-root) — the bare-metal
  SRAM eMMC driver that makes this possible
- [topjohnwu/Magisk](https://github.com/topjohnwu/Magisk) — root

---

## Quick start

```bash
./p30-root.sh check && ./p30-root.sh build
./p30-root.sh status          # confirm the tablet is seen

./p30-root.sh unlock          # ⚠ ERASES THE TABLET
# redo setup on the tablet, re-enable Developer options + USB debugging

./p30-root.sh wait-fel        # prints the button combo, waits for FEL
./p30-root.sh backup          # dumps + verifies init_boot, Secure Storage, env

# patch on the tablet (see below), pull the result back

./p30-root.sh wait-fel
./p30-root.sh flash magisk_patched-30700_xxxxx.img
p30-work/xfel/xfel reset
./p30-root.sh verify          # expect uid=0(root)
```

Then debloat, **one group at a time, rebooting between them**:

```bash
./p30-root.sh debloat group1   # 9 vendor/factory-test packages
# reboot, check it still boots
./p30-root.sh debloat group2   # 32 Google apps and unused services
# reboot
```

### Entering FEL mode

`adb reboot fel` looks like a shortcut and is not one — it drops into FEL for a
fraction of a second and then keeps booting. Use the buttons:

1. Power the tablet **fully off** (hold Power → *Power off*). Not sleep.
2. Unplug USB.
3. Hold **Volume Down** — keep holding for every step below.
4. Press **Power** ~2 s, release **Power** only.
5. Tap **Power** three more times, still holding Volume Down.
6. The screen must stay **completely black**. Any logo means it booted — start over.
7. Plug USB back in.

Properly-entered FEL holds indefinitely. Confirm with:

```bash
lsusb | grep 1f3a        # 1f3a:efe8 ... FEL/flashing mode
p30-work/xfel/xfel version   # AWUSBFEX ID=0x00189000(A523/A527/T527/MR527)
```

### Patching with Magisk

```bash
curl -sLO https://github.com/topjohnwu/Magisk/releases/latest/download/Magisk-v30.7.apk

# verify the signing cert before installing
unzip -p Magisk-v30.7.apk META-INF/*.RSA \
  | openssl pkcs7 -inform DER -print_certs \
  | openssl x509 -noout -fingerprint -sha256

adb install Magisk-v30.7.apk
adb push ~/p30-backups/init_boot_a_original.img /sdcard/Download/
```

On the tablet: **Magisk → Install → Select and Patch a File →
`init_boot_a_original.img` → Let's Go**. Then:

```bash
adb pull /sdcard/Download/magisk_patched-30700_xxxxx.img .
```

The patched ramdisk is often *smaller* than the original — Magisk recompresses it.
The file stays exactly 8,388,608 bytes because it is a full-partition image.

---

## USB ID cheat sheet

| `lsusb` shows | Mode | Tool |
|---|---|---|
| `1f3a:4ee7` / `1f3a:4ee1` | Android, booted | `adb` |
| `1f3a:efe8` | FEL / flashing | `xfel` |
| `Android Bootloader Interface` | Fastboot | `fastboot` (very limited) |

---

## Why writing is so slow

A normal `fastboot flash` finishes in seconds. This takes 8–15 minutes for 8 MB, for
three compounding reasons:

- **1-bit bus.** The driver defaults to 12 MHz on a *1-bit* data bus; normal flashing
  uses the full 8-bit bus at 52 MHz+ — roughly 8× the lane throughput.
- **PIO, not DMA.** The CPU hand-feeds every word through one FIFO register, with
  memory barriers around each access.
- **No DRAM, tiny chunks.** TrustZone blocks DRAM writes from FEL's non-secure
  context, so the whole driver runs in **40 KB of SRAM**. Writes cap at 64 sectors
  (32 KB), and the boot ROM's USB handler times out after ~3 s — so 8 MB becomes
  **256 separate round trips**.

Rebuild for a wider bus if you do a lot of eMMC work (less proven):

```bash
make -C p30-work/A523-root/tools clean
make -C p30-work/A523-root/tools EMMC_DEFS='-DSPEED_8BIT_FAST' fel-emmc.bin
```

---

## Debloating

Uses `pm uninstall --user 0`, not APK deletion. It survives reboots, needs no root,
keeps OTA verification intact, and is instantly reversible because the APK is never
actually removed:

```bash
adb shell pm uninstall --user 0 <package>        # remove
adb shell cmd package install-existing <package> # restore
```

### ⚠ Wait ~60 s before rebooting

PackageManager updates memory immediately but flushes `/data/system/packages.xml`
asynchronously. **Reboot too fast and every removal silently reverts** — the packages
come back and it looks like the ROM restored them. `./p30-root.sh debloat` handles the
wait and verifies the flush landed. Manually:

```bash
adb shell su -c "stat -c %Y /data/system/packages.xml"   # compare to
adb shell "date +%s"
```

### Group 1 — vendor / factory-test (9)

`com.clock.pt1.keeptesting` is the notable one: factory burn-in test software left in
the shipping image, flagged `PERSISTENT` so Android keeps it running permanently,
holding `INTERNET`, `REBOOT`, `SHUTDOWN`, `DISABLE_KEYGUARD` and
`MANAGE_EXTERNAL_STORAGE`.

```
com.clock.pt1.keeptesting     com.softwinner.update
com.softwinner.dragonatt      com.softwinner.awlogsettings
com.softwinner.timerswitch    com.softwinner.awsysteminfo
com.teclast.update            com.sktl.sktldeviceinfo
                              com.softwinner.qrscanner
```

Because `keeptesting` is `PERSISTENT`, uninstalling does not stop the running process
— reboot, or kill the PID (the script does this automatically).

### Group 2 — Google apps and unused services (32)

<details>
<summary>Full list</summary>

```
com.google.android.youtube                    com.google.android.apps.wellbeing
com.google.android.apps.youtube.music         com.google.android.apps.restore
com.google.android.videos                     com.google.android.marvin.talkback
com.google.android.play.games                 com.google.android.accessibility.switchaccess
com.google.android.apps.books                 com.google.android.apps.accessibility.voiceaccess
com.google.android.apps.maps                  com.google.android.apps.carrier.carrierwifi
com.google.android.gm                         com.google.android.printservice.recommendation
com.google.android.apps.docs                  com.google.android.tag
com.google.android.keep                       com.google.android.feedback
com.google.android.calendar                   com.google.android.onetimeinitializer
com.google.android.apps.tachyon               com.google.android.googlequicksearchbox
com.google.android.apps.photos                com.softwinner.miracastReceiver
com.google.android.apps.nbu.files             com.google.android.partnersetup
com.google.android.apps.adm                   com.google.android.contacts
com.google.android.apps.safetyhub
com.google.android.apps.googleassistant
com.android.soundrecorder
com.android.calculator2
```
</details>

Side effects: `googlequicksearchbox` removes the launcher search bar and Assistant
hotword; `partnersetup` is what sets Chrome's homepage to `http://www.teclast.com/`;
`apps.photos` leaves no gallery app.

Accessibility entries are only safe if nothing uses them — check with
`adb shell settings get secure enabled_accessibility_services`.

### Do not remove

All Google-signed, all look like bloat, all load-bearing. The script refuses these
even if passed explicitly.

| Package | What breaks |
|---|---|
| `com.google.android.inputmethod.latin` | **Your only keyboard.** The other listed "IME" is Google TTS voice input, not a typing keyboard |
| `com.google.android.webview` | Any app rendering web content |
| `com.google.android.permissioncontroller` | All permission dialogs |
| `com.google.android.packageinstaller` | Installing APKs, including sideloading |
| `com.google.android.providers.media.module` | Media and file storage |
| `com.google.android.documentsui` | The file picker |
| `com.google.android.networkstack*`, `connectivity.resources`, `wifi.resources` | Networking |
| `com.softwinner.camera2` | The camera app |
| `com.softwinner.awmanager` | Allwinner's background management service ("awbms"); the framework calls into it by name |
| `com.softwinner.dramdfs-service` | Not a package — a native DRAM frequency-scaling daemon |

### ⚠ Removing GMS will probably boot-loop this device

Taking out `com.google.android.gms`, `com.google.android.gsf` and the mainline modules
(`com.google.mainline.*`, `sdksandbox`, `adservices.api`,
`ondevicepersonalization.services`, `federatedcompute`, `cellbroadcastservice`,
`captiveportallogin`) produced an unbootable device that needed a factory reset.

The `com.google.mainline.*` packages in particular are **module metadata the framework
verifies at boot** — they are not bloat. For a genuinely de-Googled tablet, use a
custom ROM or GSI, not `pm uninstall`.

### Result

| | |
|---|---|
| Packages | 199 → 158 (41 removed) |
| Memory available | ~2,165 MB → ~2,446 MB |
| Persistent factory-test process | gone |
| Survives reboot | yes, verified |

---

## Recovery

**Boot loop after removing packages** — factory reset fixes it completely and costs
less than it sounds. Removals live in `/data`, so a reset restores **all** packages;
the APKs were never deleted. Recovery is Volume Up + Power → *Wipe data / factory
reset*.

**Root survives a factory reset.** Magisk lives in the patched `init_boot` partition,
which a data wipe does not touch. Afterwards `magiskd` is already running — you only
reinstall the Magisk *app* and re-grant shell root.

**Boot loop after flashing, or no boot at all** — restore through FEL, which works
even when Android never starts:

```bash
./p30-root.sh wait-fel
./p30-root.sh restore
```

**Removing root entirely** — `./p30-root.sh restore` writes the stock `init_boot`
back. To also re-lock, `fastboot oem lock` — but re-locking with modified partitions
can leave the device unbootable, so restore stock and confirm it boots first.

---

## Gotchas

| Symptom | Cause / fix |
|---|---|
| `sunxi-fel` aborts with an `AWUS` assertion | Wrong tool — build `xfel` from git |
| FEL appears then vanishes instantly | You used `adb reboot fel`; use the buttons |
| `fastboot getvar all` → *"secure mode, fastboot limited used"* | Normal. Tiny command subset; use FEL |
| `fastboot flashing unlock` → *"unknown cmd"* | Use the older `fastboot oem unlock` |
| Flashing 8 MB takes 10 minutes | Expected — see [above](#why-writing-is-so-slow) |
| Uninstalled packages return after reboot | You rebooted before `packages.xml` flushed |
| Boot loop after a big debloat | Almost certainly GMS/GSF or a mainline module |
| *"Connected, no internet"* but internet works | ROM's captive-portal check targets `www.google.cn` |
| `adb` cannot see the device after unlocking | The wipe cleared Developer options and the ADB key |
| Magisk installed but `su: not found` | Open the Magisk app once to finish first-run setup |

### The "no internet" warning

Android validates a network by fetching a `/generate_204` URL. Chinese-market ROMs
point that at `www.google.cn`, which is unreachable on many networks (and on plenty of
DNS blocklists), so the check fails forever on a perfectly working connection:

```bash
adb shell settings put global captive_portal_http_url \
    http://connectivitycheck.gstatic.com/generate_204
adb shell settings put global captive_portal_https_url \
    https://connectivitycheck.gstatic.com/generate_204

adb shell settings put global captive_portal_mode 0          # or silence it
adb shell settings delete global captive_portal_http_url     # or revert
```

Confirm the network actually works first (`adb shell ping -c 2 8.8.8.8`) so you are
fixing a cosmetic bug rather than hiding a real one.

---


## Files

| File | |
|---|---|
| `p30-root.sh` | The helper script — run `./p30-root.sh help` |
| `Teclast-P30-Root-Guide.pdf` | Full 16-page printable procedure, step by step |
| `p30-backups/` | **Your backups. Do not delete.** Not in git — see `.gitignore` |

Override paths with `P30_WORK` and `P30_BACKUPS`.

## Credits

The [linux-sunxi](https://linux-sunxi.org) community for decades of Allwinner reverse
engineering; [xboot/xfel](https://github.com/xboot/xfel);
[chrislennon/A523-root](https://github.com/chrislennon/A523-root) for the SRAM eMMC
driver and the Secure Storage research; [topjohnwu](https://github.com/topjohnwu/Magisk)
for Magisk.

## License

MIT for the scripts in this repository. Upstream projects keep their own licenses.
No vendor firmware is included or distributed.
