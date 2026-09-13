#!/usr/bin/env bash
#
# p30-root.sh -- root and debloat helper for Allwinner A523/T527 tablets
#                (developed against a Teclast P30, Android 14)
# Claude made script - "Works on my machine"
#
# SPDX-License-Identifier: MIT

set -euo pipefail

# --- config --------------------------------------------------------------
WORK="${P30_WORK:-$PWD/p30-work}"
BACKUPS="${P30_BACKUPS:-$HOME/p30-backups}"
XFEL_REPO="https://github.com/xboot/xfel.git"
A523_REPO="https://github.com/chrislennon/A523-root.git"
FEL_USB_ID="1f3a:efe8"
INIT_BOOT_PART="init_boot_a"
SS_SECTOR=12288          # Allwinner Secure Storage
SS_COUNT=256

XFEL="$WORK/xfel/xfel"
TOOLS="$WORK/A523-root/tools"

# --- output --------------------------------------------------------------
if [[ -t 1 ]]; then
	R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[34m'; D=$'\e[2m'; N=$'\e[0m'
else
	R=; G=; Y=; B=; D=; N=
fi
say()  { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s ok %s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s  ! %s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%sfail%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

confirm() {
	# Typed confirmation -- y/N is too easy to fat-finger for destructive steps.
	local want=$1 prompt=$2 reply
	printf '%s\n' "$prompt"
	printf "Type %s'%s'%s to proceed: " "$Y" "$want" "$N"
	read -r reply
	[[ "$reply" == "$want" ]] || die "aborted"
}

need_adb_device() {
	adb get-state >/dev/null 2>&1 || die "no adb device (is USB debugging on and authorised?)"
}

# --- deps ----------------------------------------------------------------
DEB_PKGS=(adb fastboot build-essential gcc-arm-none-eabi libusb-1.0-0-dev
          pkg-config git curl usbutils)

cmd_check() {
	local missing=() t
	for t in adb fastboot git curl make gcc arm-none-eabi-gcc lsusb; do
		command -v "$t" >/dev/null 2>&1 || missing+=("$t")
	done
	pkg-config --exists libusb-1.0 2>/dev/null || missing+=("libusb-1.0 (dev headers)")

	if ((${#missing[@]})); then
		warn "missing: ${missing[*]}"
		echo
		echo "On Debian/Ubuntu:"
		echo "  sudo apt-get install -y ${DEB_PKGS[*]}"
		return 1
	fi
	ok "all host dependencies present"

	if [[ ! -e /etc/udev/rules.d/71-sunxi-fel.rules ]]; then
		warn "udev rule for FEL not installed; xfel will need sudo"
		echo "  echo 'SUBSYSTEM==\"usb\", ATTR{idVendor}==\"1f3a\", ATTR{idProduct}==\"efe8\", MODE=\"0666\"' \\"
		echo "    | sudo tee /etc/udev/rules.d/71-sunxi-fel.rules"
		echo "  sudo udevadm control --reload-rules && sudo udevadm trigger"
	else
		ok "FEL udev rule installed"
	fi
}

cmd_build() {
	mkdir -p "$WORK"
	if [[ ! -d "$WORK/xfel" ]]; then
		say "cloning xfel"
		git clone --depth 1 "$XFEL_REPO" "$WORK/xfel"
	fi
	say "building xfel"
	make -C "$WORK/xfel" >/dev/null
	[[ -x "$XFEL" ]] || die "xfel build failed"
	ok "xfel built: $XFEL"

	if [[ ! -d "$WORK/A523-root" ]]; then
		say "cloning A523-root"
		git clone --depth 1 "$A523_REPO" "$WORK/A523-root"
	fi
	say "building bare-metal eMMC driver"
	make -C "$TOOLS" fel-emmc.bin >/dev/null 2>&1 || die "fel-emmc build failed"
	[[ -f "$TOOLS/fel-emmc.bin" ]] || die "fel-emmc.bin missing"
	ok "fel-emmc.bin built ($(stat -c%s "$TOOLS/fel-emmc.bin") bytes)"
}

# --- device state --------------------------------------------------------
cmd_status() {
	echo "USB:"
	lsusb | grep -i '1f3a' | sed 's/^/  /' || echo "  (no Allwinner device)"
	if adb get-state >/dev/null 2>&1; then
		echo "ADB: $(adb get-state)"
		printf '  model            %s\n' "$(adb shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
		printf '  android          %s\n' "$(adb shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')"
		printf '  board            %s\n' "$(adb shell getprop ro.board.platform 2>/dev/null | tr -d '\r')"
		printf '  flash.locked     %s\n' "$(adb shell getprop ro.boot.flash.locked 2>/dev/null | tr -d '\r')"
		printf '  verifiedboot     %s\n' "$(adb shell getprop ro.boot.verifiedbootstate 2>/dev/null | tr -d '\r')"
		printf '  packages(user 0) %s\n' "$(adb shell pm list packages --user 0 2>/dev/null | wc -l)"
		printf '  root             %s\n' "$(adb shell su -c id 2>/dev/null | tr -d '\r' || echo 'not available')"
	else
		echo "ADB: not connected"
	fi
}

cmd_unlock() {
	need_adb_device
	confirm "WIPE" "$(cat <<-EOF

	${R}This unlocks the bootloader, which ERASES THE ENTIRE TABLET.${N}
	All apps, accounts, photos and settings are destroyed. Not reversible.
	Afterwards you must redo setup and re-enable USB debugging.
	EOF
	)"
	say "rebooting to bootloader"
	adb reboot bootloader
	sleep 6
	fastboot devices -l || die "device not in fastboot"
	say "unlocking (note: 'flashing unlock' is unsupported on this SoC)"
	fastboot oem unlock || die "oem unlock failed"
	fastboot reboot
	echo
	ok "unlock sent; device is wiping and rebooting"
	echo "  Re-run setup on the tablet, re-enable USB debugging, then:"
	echo "  $0 status     # expect flash.locked=0, verifiedbootstate=orange"
}

# --- FEL -----------------------------------------------------------------
fel_instructions() {
	cat <<-EOF

	${Y}Put the tablet into FEL mode:${N}
	  1. Power it OFF completely (hold Power -> Power off). Not sleep.
	  2. Unplug USB.
	  3. Hold VOLUME DOWN and keep holding it throughout.
	  4. Press POWER ~2s, release POWER only.
	  5. Tap POWER 3 more times, still holding VOLUME DOWN.
	  6. Screen must stay COMPLETELY BLACK. Any logo = it booted, start over.
	  7. Plug USB back in.

	  (${D}adb reboot fel only blips for a moment -- use the buttons${N})
	EOF
}

cmd_wait_fel() {
	local timeout=${1:-300} stable=0 deadline
	[[ -x "$XFEL" ]] || die "xfel not built -- run: $0 build"
	fel_instructions
	deadline=$(( $(date +%s) + timeout ))
	say "waiting up to ${timeout}s for a STABLE FEL device..."
	while [[ $(date +%s) -lt $deadline ]]; do
		if lsusb 2>/dev/null | grep -q "$FEL_USB_ID"; then
			stable=$((stable + 1))
			# Require sustained presence: a transient blip is not real FEL.
			if (( stable >= 6 )); then
				if "$XFEL" version 2>&1 | grep -q AWUSBFEX; then
					ok "FEL is live: $("$XFEL" version 2>&1 | head -1)"
					return 0
				fi
			fi
		else
			(( stable > 0 )) && warn "FEL vanished after $stable poll(s) -- transient, still waiting"
			stable=0
		fi
		sleep 0.5
	done
	die "no stable FEL device within ${timeout}s"
}

require_fel() {
	[[ -x "$XFEL" ]] || die "xfel not built -- run: $0 build"
	"$XFEL" version 2>&1 | grep -q AWUSBFEX || die "not in FEL mode -- run: $0 wait-fel"
}

emmc() { ( cd "$TOOLS" && PATH="$WORK/xfel:$PATH" ./emmc-tool.sh "$@" ); }

# First LBA of a partition, read from emmc-tool.sh's own .gpt-cache -- never
# hardcode an offset here. Partition layout is per-device; init_boot_a sits at
# sector 599040 on this P30, but that is not guaranteed on other A523/T527
# units.
partition_first_lba() {
	local name=$1 cache="$TOOLS/.gpt-cache"
	[[ -f "$cache" ]] || die "no GPT cache -- run: $0 backup (or emmc gpt) first"
	local line
	line=$(grep -i "^${name}:" "$cache" | head -1)
	[[ -n "$line" ]] || die "partition '$name' not in GPT cache -- re-run: emmc gpt"
	cut -d: -f2 <<<"$line"
}

# --- backup / flash ------------------------------------------------------
cmd_backup() {
	require_fel
	mkdir -p "$BACKUPS"
	say "reading partition table"
	emmc gpt >/dev/null || die "gpt read failed"

	say "dumping $INIT_BOOT_PART (8 MB -- this takes several minutes)"
	emmc dump "$INIT_BOOT_PART" "$BACKUPS/init_boot_a_original.img"

	say "dumping Secure Storage (contains MACs + serial -- keep private)"
	emmc read "$SS_SECTOR" "$SS_COUNT" "$BACKUPS/secure_storage_original.bin"

	say "dumping env_a"
	emmc dump env_a "$BACKUPS/env_a_backup.bin"

	# A backup full of zeroes is worse than none, because you will trust it.
	local magic
	magic=$(head -c 8 "$BACKUPS/init_boot_a_original.img")
	[[ "$magic" == "ANDROID!" ]] || die "backup is NOT a boot image (magic: '$magic')"
	ok "init_boot magic verified: ANDROID!"

	sha256sum "$BACKUPS"/* > "$BACKUPS/SHA256SUMS"
	ok "backups in $BACKUPS"
	cat "$BACKUPS/SHA256SUMS"
	echo
	warn "do not publish secure_storage_original.bin -- it holds your MACs and serial"
}

cmd_flash() {
	local img=${1:-}
	[[ -n "$img" && -f "$img" ]] || die "usage: $0 flash <magisk_patched.img>"
	[[ "$(head -c 8 "$img")" == "ANDROID!" ]] || die "$img is not an Android boot image"
	[[ -f "$BACKUPS/init_boot_a_original.img" ]] || die "no backup found -- run: $0 backup"
	cmp -s "$img" "$BACKUPS/init_boot_a_original.img" && \
		die "$img is identical to the original -- Magisk did not patch it"

	require_fel
	confirm "FLASH" "$(cat <<-EOF

	About to write ${Y}$img${N}
	to partition ${Y}$INIT_BOOT_PART${N}.

	${D}This takes 8-15 minutes for 8 MB. Do not interrupt it or unplug USB.
	Recovery path: $0 restore${N}
	EOF
	)"
	emmc gpt >/dev/null
	emmc flash "$INIT_BOOT_PART" "$img"
	ok "write complete"

	say "verifying readback"
	local first_lba rb=/tmp/p30-readback.$$ exp=/tmp/p30-expected.$$
	first_lba=$(partition_first_lba "$INIT_BOOT_PART")
	emmc read "$first_lba" 256 "$rb" >/dev/null
	head -c 131072 "$img" > "$exp"
	if cmp -s "$rb" "$exp"; then ok "readback matches -- flash verified"
	else rm -f "$rb" "$exp"; die "READBACK MISMATCH -- do not reboot; run: $0 restore"; fi
	rm -f "$rb" "$exp"
	echo
	echo "  Now: $XFEL reset     # boot it, then: $0 verify"
}

cmd_restore() {
	local img="$BACKUPS/init_boot_a_original.img"
	[[ -f "$img" ]] || die "no backup at $img"
	require_fel
	confirm "RESTORE" "Restore the ORIGINAL (unrooted) $INIT_BOOT_PART from backup?"
	emmc gpt >/dev/null
	emmc flash "$INIT_BOOT_PART" "$img"
	ok "original restored -- run: $XFEL reset"
}

cmd_verify() {
	need_adb_device
	local id
	id=$(adb shell su -c id 2>/dev/null | tr -d '\r' || true)
	if [[ "$id" == *"uid=0"* ]]; then
		ok "root: $id"
		ok "magisk: $(adb shell su -c 'magisk -v' 2>/dev/null | tr -d '\r')"
	else
		warn "no root yet"
		echo "  If magiskd is running, open the Magisk app once to finish setup."
		adb shell ps -A 2>/dev/null | grep -i magiskd | sed 's/^/  /' || true
	fi
	printf '  verifiedbootstate %s\n' "$(adb shell getprop ro.boot.verifiedbootstate 2>/dev/null | tr -d '\r')"
}

# --- debloat -------------------------------------------------------------
# Group 1: Allwinner/Teclast vendor + factory-test software. No launcher
#          icons, no user-facing function. keeptesting is PERSISTENT and
#          holds INTERNET/REBOOT/SHUTDOWN/MANAGE_EXTERNAL_STORAGE.
GROUP1=(
	com.clock.pt1.keeptesting
	com.softwinner.dragonatt
	com.softwinner.timerswitch
	com.teclast.update
	com.softwinner.update
	com.softwinner.awlogsettings
	com.softwinner.awsysteminfo
	com.sktl.sktldeviceinfo
	com.softwinner.qrscanner
)

# Group 2: Google apps and unused services. Safe on a device where you do not
#          use them. Accessibility entries assume no a11y service is enabled.
GROUP2=(
	com.google.android.youtube
	com.google.android.apps.youtube.music
	com.google.android.videos
	com.google.android.play.games
	com.google.android.apps.books
	com.google.android.apps.maps
	com.google.android.gm
	com.google.android.apps.docs
	com.google.android.keep
	com.google.android.calendar
	com.google.android.apps.tachyon
	com.google.android.apps.photos
	com.google.android.apps.nbu.files
	com.google.android.apps.adm
	com.google.android.apps.safetyhub
	com.google.android.apps.googleassistant
	com.android.soundrecorder
	com.android.calculator2
	com.google.android.apps.wellbeing
	com.google.android.apps.restore
	com.google.android.marvin.talkback
	com.google.android.accessibility.switchaccess
	com.google.android.apps.accessibility.voiceaccess
	com.google.android.apps.carrier.carrierwifi
	com.google.android.printservice.recommendation
	com.google.android.tag
	com.google.android.feedback
	com.google.android.onetimeinitializer
	com.google.android.googlequicksearchbox
	com.softwinner.miracastReceiver
	com.google.android.partnersetup
	com.google.android.contacts
)

# Removing any of these produced a broken or unbootable device. Refuse them
# even if the user passes them explicitly.
# HEY USER! Human here, removing a section of these caused the tablet to no longer boot. Unsure which caused it, good luck.
BLOCKLIST=(
	com.google.android.inputmethod.latin com.google.android.gms
	com.google.android.gsf com.android.vending com.google.android.webview
	com.google.android.permissioncontroller com.google.android.packageinstaller
	com.google.android.providers.media.module com.google.android.documentsui
	com.google.android.networkstack com.google.android.networkstack.tethering
	com.google.android.connectivity.resources com.google.android.wifi.resources
	com.google.android.ext.services com.google.android.modulemetadata
	com.google.mainline.adservices com.google.mainline.telemetry
	com.google.android.sdksandbox com.google.android.adservices.api
	com.google.android.ondevicepersonalization.services
	com.google.android.federatedcompute com.google.android.cellbroadcastservice
	com.google.android.captiveportallogin com.google.android.as
	com.softwinner.camera2 com.softwinner.awmanager com.softwinner.screenshot
	com.softwinner.settingssetup com.android.settings
)

is_blocked() {
	local p=$1 b
	for b in "${BLOCKLIST[@]}"; do [[ "$p" == "$b" ]] && return 0; done
	return 1
}

flush_wait() {
	# PackageManager writes packages.xml asynchronously. Rebooting before that
	# lands silently reverts every uninstall -- this is the single most
	# confusing failure mode in the whole procedure.
	local secs=${1:-60}
	say "waiting ${secs}s for PackageManager to flush packages.xml"
	sleep "$secs"
	adb shell su -c sync 2>/dev/null || true
	local xml now
	xml=$(adb shell su -c "stat -c %Y /data/system/packages.xml" 2>/dev/null | tr -d '\r')
	now=$(adb shell "date +%s" 2>/dev/null | tr -d '\r')
	if [[ -n "$xml" && -n "$now" ]]; then
		ok "packages.xml written $(( now - xml ))s ago -- safe to reboot"
	else
		warn "could not confirm flush (need root); wait a little longer before rebooting"
	fi
}

cmd_debloat() {
	need_adb_device
	local group=${1:-} list=() p r okc=0 skip=0
	case "$group" in
		group1) list=("${GROUP1[@]}") ;;
		group2) list=("${GROUP2[@]}") ;;
		*) die "usage: $0 debloat group1|group2   (do them one at a time, rebooting between)" ;;
	esac

	echo "Will remove ${#list[@]} packages (reversible):"
	printf '  %s\n' "${list[@]}"
	confirm "REMOVE" ""

	for p in "${list[@]}"; do
		if is_blocked "$p"; then warn "refusing blocklisted $p"; continue; fi
		r=$(adb shell pm uninstall --user 0 "$p" 2>&1 | tr -d '\r')
		if [[ "$r" == Success* ]]; then okc=$((okc+1)); printf '  %s-%s %s\n' "$D" "$N" "$p"
		else skip=$((skip+1)); warn "$p: $r"; fi
	done
	ok "removed $okc, skipped $skip"
	printf '  packages now: %s\n' "$(adb shell pm list packages --user 0 2>/dev/null | wc -l)"

	# keeptesting is PERSISTENT: uninstalling does not stop the running process.
	local pid
	pid=$(adb shell ps -A 2>/dev/null | awk '/com.clock.pt1.keeptesting/{print $2}' | head -1 | tr -d '\r')
	if [[ -n "${pid:-}" ]]; then
		say "killing persistent keeptesting process (pid $pid)"
		adb shell su -c "kill -9 $pid" 2>/dev/null || warn "could not kill; it dies on reboot anyway"
	fi

	flush_wait 60
	echo
	echo "  Now reboot the tablet and re-run '$0 status' before doing the next group."
}

cmd_restore_apps() {
	need_adb_device
	local group=${1:-} list=() p
	case "$group" in
		group1) list=("${GROUP1[@]}") ;;
		group2) list=("${GROUP2[@]}") ;;
		all)    list=("${GROUP1[@]}" "${GROUP2[@]}") ;;
		*) die "usage: $0 restore-apps group1|group2|all" ;;
	esac
	for p in "${list[@]}"; do
		printf '  %s ... ' "$p"
		adb shell cmd package install-existing "$p" 2>&1 | tr -d '\r' | tail -1
	done
	flush_wait 60
}

# --- usage ---------------------------------------------------------------
usage() {
	cat <<-EOF
	p30-root.sh -- root/debloat helper for Allwinner A523/T527 tablets
	CLAUDE made script - "Works on my machine"

	  check                 verify host dependencies and udev rule
	  build                 clone + build xfel and the FEL eMMC driver
	  status                show device mode, lock state, package count, root

	  unlock                unlock the bootloader   ${R}(ERASES THE TABLET)${N}
	  wait-fel [timeout]    print the button combo and wait for stable FEL
	  backup                dump init_boot_a + Secure Storage + env_a, verified
	  flash <patched.img>   write a Magisk-patched image, then verify readback
	  restore               write the original init_boot back from backup
	  verify                check root and Magisk on a booted device

	  debloat group1        remove vendor/factory-test packages (9)
	  debloat group2        remove Google apps and unused services (32)
	  restore-apps <group>  reinstall a group (group1|group2|all)

	Typical first run:
	  $0 check && $0 build
	  $0 unlock                     # wipes; redo setup + USB debugging
	  $0 wait-fel && $0 backup
	  # patch the backup with Magisk on the tablet, pull it back
	  $0 wait-fel && $0 flash magisk_patched-*.img
	  $XFEL reset && $0 verify

	Paths:  work=$WORK  backups=$BACKUPS
	EOF
}

case "${1:-}" in
	check)        shift; cmd_check "$@" ;;
	build)        shift; cmd_build "$@" ;;
	status)       shift; cmd_status "$@" ;;
	unlock)       shift; cmd_unlock "$@" ;;
	wait-fel)     shift; cmd_wait_fel "$@" ;;
	backup)       shift; cmd_backup "$@" ;;
	flash)        shift; cmd_flash "$@" ;;
	restore)      shift; cmd_restore "$@" ;;
	verify)       shift; cmd_verify "$@" ;;
	debloat)      shift; cmd_debloat "$@" ;;
	restore-apps) shift; cmd_restore_apps "$@" ;;
	-h|--help|help|"") usage ;;
	*) die "unknown command: $1  (try: $0 help)" ;;
esac
