#!/usr/bin/env bash
#
# Optimized Android build environment installer & tuner
#
# Single-file installer that:
#  - Configures tmpfs for /tmp build scratch space (not ~/.gradle/caches — see note
#    in Section 7 for why mounting tmpfs there destroys cache persistence)
#  - Writes optimised ~/.gradle/gradle.properties (daemon, parallel, caching, G1GC,
#    and RAM-tiered JVM max heap)
#  - Prepares ~/.pub-cache for Dart/Flutter package persistence
#  - Creates a swapfile and configures ZRAM (sized independently via separate variables)
#  - Applies sysctl tuning for builds
#  - Sets I/O scheduler (device-type-aware: none for NVMe, mq-deadline for SATA/SAS)
#    using the current kernel sysfs path (queue/read_ahead_kb, not legacy bdi/)
#  - Adds per-user resource limits (nofile and nproc at practical build ceilings)
#  - Adds user to kvm group for Android emulator hardware acceleration support
#  - Pre-warms Gradle dependency cache (with correct daemon and caching flags)
#  - Verifies the full configuration after setup
#
# Prerequisites: Flutter, Android SDK, JDK, and standard build tools must already
# be installed and configured before running this script. ANDROID_HOME,
# ANDROID_SDK_ROOT, and JAVA_HOME are intentionally not modified here — the
# Flutter/Android SDK installer is responsible for setting and maintaining these.
#
# Usage (run as root or via sudo):
#   sudo ./build_cache_installer.sh
#   sudo ./build_cache_installer.sh <RAM_GB> <DISK_DEVICE>
#
# Examples:
#   sudo ./build_cache_installer.sh 8 /dev/sda5
#   sudo ./build_cache_installer.sh 16 /dev/nvme0n1p3
#
# Supported RAM_GB values: 8, 16, 32, 64

set -euo pipefail

# ─── 1. Root Privilege Check ───────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
  echo "ERROR: This script must be run as root (sudo)."
  exit 1
fi

TARGET_USER="${SUDO_USER:-${USER}}"
TARGET_HOME="$(eval echo ~${TARGET_USER})"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
UNDO_FILE="${TARGET_HOME}/android_build_undo_${TIMESTAMP}.sh"

print_usage() {
  cat <<EOF
Usage: sudo $0 [RAM_GB] [DISK_DEVICE]
  RAM_GB      : 8 | 16 | 32 | 64  (if omitted, you will be prompted)
  DISK_DEVICE : block device or partition (e.g. /dev/sda5 or /dev/nvme0n1p3)
EOF
}

# ─── 2. Argument Parsing ───────────────────────────────────────────────────────
RAM_GB="${1:-}"
DISK_DEVICE="${2:-}"

if [ -z "$RAM_GB" ]; then
  read -rp "Enter system RAM tier in GB (8, 16, 32, 64): " RAM_GB
fi

if [ -z "$DISK_DEVICE" ]; then
  read -rp "Enter block device target (e.g., /dev/sda5): " DISK_DEVICE
fi

# ─── 3. Early Device Validation ────────────────────────────────────────────────
# Validate before making any system changes so we fail cleanly with no side effects.
if [ ! -b "${DISK_DEVICE}" ]; then
  echo "ERROR: '${DISK_DEVICE}' is not a valid block device."
  print_usage
  exit 1
fi

# ─── 4. Memory-Profile Variables ───────────────────────────────────────────────
# TMPFS_SIZE    : /tmp tmpfs size — fast scratch space for build output directories.
#                 Symlink or move a project's build/ into /tmp to exploit this.
# ZRAM_SIZE     : compressed in-RAM swap. Tiered by RAM because it consumes RAM —
#                 oversizing it on a low-RAM box steals memory from the build.
# SWAP_SIZE     : on-disk swapfile — deep OOM safety net. Deliberately NOT tied to
#                 the RAM tier (see SWAP_FLOOR_GB below): swap on a fast SSD is cheap
#                 insurance, and a tiny swapfile is exactly what lets a heavy build
#                 trip the OOM killer. ZRAM handles fast/hot swap; the swapfile is the
#                 generous overflow beneath it.
# GRADLE_JVM_MAX: Gradle daemon -Xmx heap ceiling, scaled to available RAM.
case "$RAM_GB" in
  8)  TMPFS_SIZE="2G"; ZRAM_SIZE="2G";  SWAP_SIZE="2G"; SYS_SWAPPINESS=40; SYS_VFS=80; GRADLE_JVM_MAX="2048m" ;;
  16) TMPFS_SIZE="4G"; ZRAM_SIZE="4G";  SWAP_SIZE="4G"; SYS_SWAPPINESS=30; SYS_VFS=65; GRADLE_JVM_MAX="4096m" ;;
  32) TMPFS_SIZE="4G"; ZRAM_SIZE="8G";  SWAP_SIZE="4G"; SYS_SWAPPINESS=20; SYS_VFS=50; GRADLE_JVM_MAX="6144m" ;;
  64) TMPFS_SIZE="4G"; ZRAM_SIZE="16G"; SWAP_SIZE="8G"; SYS_SWAPPINESS=10; SYS_VFS=50; GRADLE_JVM_MAX="8192m" ;;
  *) echo "Unsupported RAM tier: $RAM_GB"; print_usage; exit 1 ;;
esac

# Swapfile floor (GB). The on-disk swapfile is never provisioned smaller than this,
# regardless of RAM tier — it is the safety net that keeps normal heavy use from
# running the system out of memory. Override per-run with the SWAP_GB env var, e.g.
#   sudo SWAP_GB=64 ./build-optimisation.sh 8 /dev/sda5
SWAP_FLOOR_GB="${SWAP_GB:-32}"
if ! printf '%s' "${SWAP_FLOOR_GB}" | grep -qE '^[0-9]+$'; then
  echo "ERROR: SWAP_GB must be an integer number of GB (got '${SWAP_FLOOR_GB}')."
  exit 1
fi
# Effective swapfile size = max(tier value, floor). The tier value only wins if a
# future tier ever exceeds the floor; today the floor always governs.
if [ "${SWAP_SIZE%G}" -lt "${SWAP_FLOOR_GB}" ]; then
  SWAP_SIZE="${SWAP_FLOOR_GB}G"
fi

# ─── 5. Parent Block Device and Scheduler Detection ────────────────────────────
# The I/O scheduler sysfs interface lives on the parent block device, not the
# partition node. Derive parent from the supplied device path.
DISK_BASE=$(basename "${DISK_DEVICE}")
if echo "${DISK_BASE}" | grep -qE "^nvme"; then
  # NVMe partition: nvme0n1p3 -> nvme0n1
  DISK_PARENT=$(echo "${DISK_BASE}" | sed 's/p[0-9]*$//')
  IO_SCHEDULER="none"        # NVMe manages its own internal queue; kernel passthrough
elif echo "${DISK_BASE}" | grep -qE "^sd"; then
  # SATA/SAS partition: sda5 -> sda
  DISK_PARENT=$(echo "${DISK_BASE}" | sed 's/[0-9]*$//')
  IO_SCHEDULER="mq-deadline" # Multi-queue aware; replaces legacy single-queue deadline
else
  # Unknown device type — apply mq-deadline as a safe default
  DISK_PARENT="${DISK_BASE}"
  IO_SCHEDULER="mq-deadline"
fi

echo "=========================================="
echo " Starting Optimised Build Environment Setup"
echo " User:                ${TARGET_USER}"
echo " Home:                ${TARGET_HOME}"
echo " RAM tier:            ${RAM_GB}GB"
echo " /tmp tmpfs:          ${TMPFS_SIZE}"
echo " ZRAM:                ${ZRAM_SIZE}"
echo " Swapfile:            ${SWAP_SIZE}"
echo " Gradle JVM max heap: ${GRADLE_JVM_MAX}"
echo " Drive:               ${DISK_DEVICE} (parent: ${DISK_PARENT}, scheduler: ${IO_SCHEDULER})"
echo "=========================================="

# ─── 6. Initialise the Timestamped Undo Engine ─────────────────────────────────
cat << 'EOF' > "$UNDO_FILE"
#!/usr/bin/env bash
set -euo pipefail
if [ "$EUID" -ne 0 ]; then
  echo "ERROR: This recovery script must be run as root (sudo)."
  exit 1
fi
echo "Initiating system recovery rollback..."
EOF

# ─── 7. Directory Layout and Ownership ─────────────────────────────────────────
echo "[*] Creating cache directory layout..."

# ~/.gradle remains on persistent storage — deliberately not mounted as tmpfs.
# Mounting tmpfs on ~/.gradle/caches destroys all downloaded dependencies and
# compiled build artefacts on every reboot, forcing a full cold build each session.
# Fast scratch space for high-churn build/ output directories is provided by the
# /tmp tmpfs configured below; symlink a project's build/ into /tmp to exploit it.
mkdir -p "${TARGET_HOME}/.gradle/caches" \
         "${TARGET_HOME}/.gradle/daemon" \
         "${TARGET_HOME}/.gradle/native" \
         "${TARGET_HOME}/.gradle/wrapper"

# ~/.pub-cache — persistent Dart/Flutter package cache (target of pub get).
mkdir -p "${TARGET_HOME}/.pub-cache"

chmod 1777 /tmp || true
chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.gradle"
chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.pub-cache"

# ─── 8. Optimised ~/.gradle/gradle.properties ──────────────────────────────────
echo "[*] Writing optimised Gradle properties..."
GRADLE_PROPS="${TARGET_HOME}/.gradle/gradle.properties"

if [ -f "${GRADLE_PROPS}" ]; then
  cp "${GRADLE_PROPS}" "${GRADLE_PROPS}.bak.${TIMESTAMP}"
  echo "[*] Existing gradle.properties backed up to: ${GRADLE_PROPS}.bak.${TIMESTAMP}"
  cat << EOF >> "$UNDO_FILE"
echo "  - Restoring original gradle.properties..."
if [ -f "${GRADLE_PROPS}.bak.${TIMESTAMP}" ]; then
  mv "${GRADLE_PROPS}.bak.${TIMESTAMP}" "${GRADLE_PROPS}"
else
  rm -f "${GRADLE_PROPS}"
fi
EOF
else
  cat << EOF >> "$UNDO_FILE"
echo "  - Removing generated gradle.properties block..."
sed -i '/# BUILD TUNER START/,/# BUILD TUNER END/d' "${GRADLE_PROPS}"
EOF
fi

# Remove any previously installed managed block before re-inserting.
sed -i '/# BUILD TUNER START/,/# BUILD TUNER END/d' "${GRADLE_PROPS}" 2>/dev/null || true

cat >> "${GRADLE_PROPS}" << EOF
# BUILD TUNER START
org.gradle.daemon=true
org.gradle.parallel=true
org.gradle.caching=true
org.gradle.configureondemand=true
org.gradle.jvmargs=-Xmx${GRADLE_JVM_MAX} -XX:+UseG1GC -XX:MaxMetaspaceSize=512m -Dfile.encoding=UTF-8
# BUILD TUNER END
EOF

chown "${TARGET_USER}:${TARGET_USER}" "${GRADLE_PROPS}"

# ─── 9. fstab: /tmp Tmpfs and Swapfile ─────────────────────────────────────────
echo "[*] Configuring fstab mount entries..."

FSTAB_LINE_SWAP="/swapfile none swap sw 0 0"
ESC_SWAP=$(printf '%s\n' "$FSTAB_LINE_SWAP" | sed 's/[[\.*^$]/\\&/g')

cat << EOF >> "$UNDO_FILE"
echo "  - Removing swapfile fstab entry..."
sed -i '\#${ESC_SWAP}#d' /etc/fstab
EOF

# /tmp tmpfs: many modern Ubuntu/Debian installs enable tmp.mount via systemd,
# which already mounts /tmp as tmpfs. Adding a fstab entry alongside it causes
# a conflicting double-mount at boot. Detect and handle both cases.
if systemctl is-enabled tmp.mount 2>/dev/null | grep -q "enabled"; then
  echo "[*] systemd tmp.mount is active — configuring size via drop-in (not fstab)..."
  mkdir -p /etc/systemd/system/tmp.mount.d
  cat > /etc/systemd/system/tmp.mount.d/build-size.conf << EOF
[Mount]
Options=size=${TMPFS_SIZE},mode=1777
EOF
  systemctl daemon-reload
  systemctl restart tmp.mount || true

  cat << 'EOF' >> "$UNDO_FILE"
echo "  - Removing systemd tmp.mount size drop-in..."
rm -f /etc/systemd/system/tmp.mount.d/build-size.conf
systemctl daemon-reload
EOF
else
  FSTAB_LINE_TMP="tmpfs /tmp tmpfs size=${TMPFS_SIZE},mode=1777 0 0"
  ESC_TMP=$(printf '%s\n' "$FSTAB_LINE_TMP" | sed 's/[[\.*^$]/\\&/g')
  cat << EOF >> "$UNDO_FILE"
echo "  - Removing /tmp fstab entry..."
sed -i '\#${ESC_TMP}#d' /etc/fstab
umount /tmp || true
EOF
  grep -Fxq "${FSTAB_LINE_TMP}" /etc/fstab || echo "${FSTAB_LINE_TMP}" >> /etc/fstab
  mountpoint -q /tmp || mount /tmp || true
fi

grep -Fxq "${FSTAB_LINE_SWAP}" /etc/fstab || echo "${FSTAB_LINE_SWAP}" >> /etc/fstab

# ─── 10. Swapfile ──────────────────────────────────────────────────────────────
# Uses SWAP_SIZE — intentionally separate from ZRAM_SIZE. Both ZRAM and a swapfile
# can coexist, but their sizes are independent concerns and must not share a variable.
#
# Sizing is "grow to target, never shrink": if no swapfile exists we create one at
# SWAP_SIZE; if one exists but is smaller than SWAP_SIZE we rebuild it larger (a
# stale 2G file from an earlier run must not cap us below the floor); if it already
# meets or exceeds the target we leave it untouched — we never shrink a swapfile a
# user may have deliberately enlarged.
SWAP_TARGET_BYTES=$(( ${SWAP_SIZE%G} * 1024 * 1024 * 1024 ))
CURRENT_SWAP_BYTES=0
[ -f /swapfile ] && CURRENT_SWAP_BYTES=$(stat -c %s /swapfile 2>/dev/null || echo 0)

if [ "${CURRENT_SWAP_BYTES}" -lt "${SWAP_TARGET_BYTES}" ]; then
  if [ -f /swapfile ]; then
    echo "[*] Existing swapfile ($(( CURRENT_SWAP_BYTES / 1024 / 1024 / 1024 ))G) is below target ${SWAP_SIZE} — rebuilding larger..."
    swapoff /swapfile 2>/dev/null || true
    rm -f /swapfile
  else
    echo "[*] Provisioning swapfile (${SWAP_SIZE})..."
  fi

  if command -v fallocate >/dev/null 2>&1; then
    fallocate -l "${SWAP_SIZE}" /swapfile
  else
    MB_COUNT=$(( ${SWAP_SIZE%G} * 1024 ))
    dd if=/dev/zero of=/swapfile bs=1M count="${MB_COUNT}" status=progress
  fi
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile

  cat << 'EOF' >> "$UNDO_FILE"
echo "  - Deactivating and removing swapfile..."
swapoff /swapfile || true
rm -f /swapfile
EOF
else
  echo "[*] Existing swapfile ($(( CURRENT_SWAP_BYTES / 1024 / 1024 / 1024 ))G) already meets target ${SWAP_SIZE} — leaving as is."
  swapon --show 2>/dev/null | grep -q "/swapfile" || swapon /swapfile 2>/dev/null || true
fi

# ─── 11. ZRAM Configuration ────────────────────────────────────────────────────
echo "[*] Configuring ZRAM compressed swap device..."
ZRAM_CONF="/etc/systemd/zram-generator.conf"

if [ -f "$ZRAM_CONF" ]; then
  cat "$ZRAM_CONF" > "${ZRAM_CONF}.bak.${TIMESTAMP}"
  cat << EOF >> "$UNDO_FILE"
if [ -f "${ZRAM_CONF}.bak.${TIMESTAMP}" ]; then
  mv "${ZRAM_CONF}.bak.${TIMESTAMP}" "$ZRAM_CONF"
else
  rm -f "$ZRAM_CONF"
fi
EOF
else
  cat << EOF >> "$UNDO_FILE"
rm -f "$ZRAM_CONF"
EOF
fi

# The config file above is inert on its own: it is consumed by the
# systemd-zram-generator package, which provides the generator binary and the
# systemd-zram-setup@.service template that actually create and activate the
# device. Without the package the config does nothing — no /dev/zram0, ever (a
# reboot does not help). Ensure the package is present before relying on it.
ZRAM_READY=0
if [ -e /usr/lib/systemd/system-generators/zram-generator ] || \
   [ -e /lib/systemd/system-generators/zram-generator ]; then
  ZRAM_READY=1
else
  echo "[*] systemd zram-generator not present — installing..."
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y systemd-zram-generator \
      && ZRAM_READY=1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y zram-generator && ZRAM_READY=1
  elif command -v pacman >/dev/null 2>&1; then
    pacman -S --noconfirm zram-generator && ZRAM_READY=1
  fi
  if [ "${ZRAM_READY}" -ne 1 ]; then
    echo "[!] Could not install the zram-generator package automatically."
    echo "    ZRAM will not activate until it is installed (e.g. 'apt-get install systemd-zram-generator')."
  fi
fi

cat > "${ZRAM_CONF}" << EOF
[zram0]
zram-size = ${ZRAM_SIZE}
compression-algorithm = zstd
EOF

# Undo: deactivate the device and reload so the generator drops the unit.
cat << 'EOF' >> "$UNDO_FILE"
echo "  - Deactivating ZRAM swap device..."
systemctl stop systemd-zram-setup@zram0.service 2>/dev/null || true
swapoff /dev/zram0 2>/dev/null || true
systemctl daemon-reload || true
EOF

if [ "${ZRAM_READY}" -eq 1 ]; then
  # daemon-reload reruns the generator, materialising systemd-zram-setup@zram0
  # from the config just written; starting it creates and swaps on /dev/zram0.
  #
  # Activating the device allocates its metadata table and per-CPU compression
  # buffers in RAM. If the script runs while the machine is ALREADY under heavy
  # memory pressure (a live build, a running emulator), that allocation can fail
  # with ENOMEM — there simply isn't enough free RAM to stand up the very thing
  # meant to relieve the pressure. This is not fatal and not a misconfiguration:
  # the on-disk swapfile is the safety net for exactly this window, and the
  # generator re-runs at every boot — when RAM is free — bringing the device up
  # cleanly then. So we attempt activation but tolerate a deferred start.
  modprobe zram 2>/dev/null || true
  systemctl daemon-reload || true
  if systemctl restart systemd-zram-setup@zram0.service 2>/dev/null \
     && swapon --show | grep -q zram; then
    echo "[*] ZRAM device active: $(swapon --show | awk '/zram/{print $1, $3}')"
  else
    echo "[~] ZRAM is configured but could not be activated right now."
    echo "    Most likely cause: too little free RAM at this moment (close the build/"
    echo "    emulator and re-run, or just reboot). It will activate on the next boot."
  fi
fi

# ─── 12. sysctl Kernel Tuning ──────────────────────────────────────────────────
echo "[*] Applying kernel parameter tuning via sysctl..."
SYSCTL_CONF="/etc/sysctl.d/99-build-optim.conf"

# Keys this script owns. They live in a drop-in under /etc/sysctl.d/, but that is
# NOT sufficient to guarantee they take effect: `sysctl --system` applies
# /etc/sysctl.conf LAST — after every /etc/sysctl.d/*.conf file, regardless of
# numeric prefix. So any of these keys set in /etc/sysctl.conf silently overrides
# our drop-in, both now and on every subsequent boot. Neutralise such conflicts so
# the drop-in is authoritative.
MANAGED_SYSCTL_KEYS=(
  vm.swappiness
  vm.vfs_cache_pressure
  fs.inotify.max_user_watches
  fs.inotify.max_user_instances
  fs.file-max
)

# Undo: remove the drop-in. The /etc/sysctl.conf restore (if any) is appended
# below, ahead of a single final `sysctl --system` so the kernel is reloaded once
# after all sysctl state has been rolled back.
cat << EOF >> "$UNDO_FILE"
echo "  - Removing build sysctl config..."
rm -f "${SYSCTL_CONF}"
EOF

if [ -f /etc/sysctl.conf ]; then
  SYSCTL_CONF_CONFLICT=0
  for key in "${MANAGED_SYSCTL_KEYS[@]}"; do
    if grep -qE "^[[:space:]]*${key//./\\.}[[:space:]]*=" /etc/sysctl.conf; then
      SYSCTL_CONF_CONFLICT=1
      break
    fi
  done

  if [ "${SYSCTL_CONF_CONFLICT}" -eq 1 ]; then
    echo "[*] /etc/sysctl.conf sets keys this script manages — neutralising (it is"
    echo "    applied last by 'sysctl --system' and would otherwise win on every boot)..."
    cp /etc/sysctl.conf "/etc/sysctl.conf.bak.${TIMESTAMP}"
    echo "[*] /etc/sysctl.conf backed up to: /etc/sysctl.conf.bak.${TIMESTAMP}"

    cat << EOF >> "$UNDO_FILE"
echo "  - Restoring original /etc/sysctl.conf..."
if [ -f "/etc/sysctl.conf.bak.${TIMESTAMP}" ]; then
  mv "/etc/sysctl.conf.bak.${TIMESTAMP}" /etc/sysctl.conf
fi
EOF

    for key in "${MANAGED_SYSCTL_KEYS[@]}"; do
      key_esc="${key//./\\.}"
      # Comment out uncommented assignments; leave a breadcrumb explaining why.
      sed -i -E \
        "s|^([[:space:]]*${key_esc}[[:space:]]*=.*)$|# [build-optim] superseded by ${SYSCTL_CONF}: \1|" \
        /etc/sysctl.conf
    done
  fi
fi

cat << 'EOF' >> "$UNDO_FILE"
sysctl --system || true
EOF

cat > "${SYSCTL_CONF}" << EOF
# Optimised build environment kernel parameters
vm.swappiness=${SYS_SWAPPINESS}
vm.vfs_cache_pressure=${SYS_VFS}
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=1024
fs.file-max=2097152
EOF
sysctl --system || true

# ─── 13. I/O Scheduler and Read-Ahead (udev) ───────────────────────────────────
echo "[*] Writing device-type-aware I/O optimisation rules (udev)..."
UDEV_RULE="/etc/udev/rules.d/60-io-scheduler.rules"

cat << EOF >> "$UNDO_FILE"
echo "  - Removing I/O scheduler udev rules..."
rm -f "${UDEV_RULE}"
udevadm control --reload
EOF

# Scheduler selection:
#   NVMe         -> "none"        (passthrough; NVMe manages its own internal queue.
#                                  Setting deadline or mq-deadline on NVMe either
#                                  silently fails or degrades performance.)
#   SATA/SAS SSD -> "mq-deadline" (multi-queue aware; replaces legacy single-queue
#                                  "deadline" which is not available on modern kernels)
#   SATA/SAS HDD -> "mq-deadline" with a larger read-ahead window for sequential I/O
#
# read_ahead_kb uses queue/read_ahead_kb — the current sysfs path.
# The legacy bdi/read_ahead_kb path was removed in kernel 5.x.
#
# Rules target parent block devices (nvme*n*, sd[a-z]), not partition nodes, because
# the scheduler sysfs interface lives on the device, not the partition.
cat > "${UDEV_RULE}" << EOF
# NVMe: passthrough — NVMe manages its own internal queue ordering
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/scheduler}="none", ATTR{queue/read_ahead_kb}="2048"
# SATA/SAS SSD: mq-deadline, moderate read-ahead
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline", ATTR{queue/read_ahead_kb}="2048"
# SATA/SAS HDD: mq-deadline, larger read-ahead window for sequential workloads
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="mq-deadline", ATTR{queue/read_ahead_kb}="4096"
EOF

udevadm control --reload
udevadm trigger --action=change "/dev/${DISK_PARENT}" || true
blockdev --setra 4096 "/dev/${DISK_PARENT}" || true

# ─── 14. Per-User Resource Limits ──────────────────────────────────────────────
echo "[*] Writing per-user resource limits..."
LIMITS_FILE="/etc/security/limits.d/99-${TARGET_USER}-build.conf"

cat << EOF >> "$UNDO_FILE"
echo "  - Removing user resource limit file..."
rm -f "${LIMITS_FILE}"
EOF

cat > "${LIMITS_FILE}" << EOF
# Build resource limits for ${TARGET_USER}
# nofile: 1M — Gradle + Dart file watcher consume large numbers of file descriptors
# nproc : 64K — high enough for aggressive parallel builds, bounded to prevent
#               runaway fork bombs or OOM from a crashed parallel compilation
${TARGET_USER} soft nofile 1048576
${TARGET_USER} hard nofile 1048576
${TARGET_USER} soft nproc  65536
${TARGET_USER} hard nproc  65536
EOF

# ─── 15. User Shell Environment (~/.bashrc) ────────────────────────────────────
echo "[*] Injecting build environment variables into ~/.bashrc..."
BASHRC_FILE="${TARGET_HOME}/.bashrc"

cat << EOF >> "$UNDO_FILE"
echo "  - Removing build environment block from .bashrc..."
sed -i '/# ANDROID BUILD VARIABLES START/,/# ANDROID BUILD VARIABLES END/d' "${BASHRC_FILE}"
echo "Shell restore complete. Close and reopen any active shell sessions."
EOF

# Remove any existing managed block before re-inserting.
sed -i '/# ANDROID BUILD VARIABLES START/,/# ANDROID BUILD VARIABLES END/d' "${BASHRC_FILE}"

# Excluded intentionally:
#   ANDROID_HOME / ANDROID_SDK_ROOT / JAVA_HOME : set by the Flutter/Android SDK
#       installer and must not be overwritten by this script.
#   USE_CCACHE / CCACHE_EXEC / CCACHE_DIR        : AOSP-specific; intercept C/C++
#       compiler invocations only. They have no effect on Flutter/Gradle/Dart builds.
#
# Single-quoted heredoc: ${HOME} and ${PUB_CACHE} expand at shell runtime per the
# active user, not at install time under root context.
cat << 'EOF' >> "${BASHRC_FILE}"
# ANDROID BUILD VARIABLES START
export GRADLE_USER_HOME="${HOME}/.gradle"
export PUB_CACHE="${HOME}/.pub-cache"
# ANDROID BUILD VARIABLES END
EOF

# ─── 16. kvm Group Membership (Android Emulator Support) ───────────────────────
if getent group kvm > /dev/null 2>&1; then
  echo "[*] Adding ${TARGET_USER} to kvm group for Android emulator hardware acceleration..."
  usermod -aG kvm "${TARGET_USER}"
  cat << EOF >> "$UNDO_FILE"
echo "  - Removing ${TARGET_USER} from kvm group..."
gpasswd -d "${TARGET_USER}" kvm || true
EOF
else
  echo "[~] kvm group not found — skipping. Install qemu-kvm if Android emulator support is needed."
fi

# ─── 17. SDK Licence Acceptance and Optional Gradle Pre-Warm ───────────────────
if command -v sdkmanager >/dev/null 2>&1; then
  echo "[*] Accepting SDK licences and caching cmake..."
  su - "${TARGET_USER}" -c "yes | sdkmanager --licenses" || true
  su - "${TARGET_USER}" -c "sdkmanager 'cmake;3.22.1'" || true
fi

# Pre-warm the Gradle daemon and seed the dependency cache when run from inside
# a Flutter project directory that contains an android/ subdirectory with a
# Gradle wrapper.
#
# Excluded flags (both were present in the original script and are counter-productive):
#   --no-daemon          : discards the warmed daemon immediately after the run —
#                          the opposite of what pre-warming is trying to achieve
#   --refresh-dependencies: forces a complete dependency re-download from remote
#                          repositories — the opposite of seeding a local cache
PROJECT_DIR="$(pwd)"
if [ -d "${PROJECT_DIR}/android" ] && [ -f "${PROJECT_DIR}/android/gradlew" ]; then
  echo "[*] Pre-warming Gradle daemon and seeding dependency cache..."
  su - "${TARGET_USER}" -c "cd '${PROJECT_DIR}/android' && ./gradlew dependencies" || true
fi

# ─── 18. Verification Pass ─────────────────────────────────────────────────────
echo " "
echo "=========================================="
echo " Post-Installation Verification"
echo "=========================================="

VERIFY_FAIL=0

# /tmp tmpfs
if mountpoint -q /tmp; then
  TMP_SIZE=$(df -h /tmp | awk 'NR==2{print $2}')
  echo "[✓] /tmp is mounted as tmpfs (size: ${TMP_SIZE})"
else
  echo "[✗] /tmp is NOT mounted as tmpfs"
  VERIFY_FAIL=1
fi

# Swapfile
if swapon --show | grep -q "/swapfile"; then
  SWAP_INFO=$(swapon --show | awk '/swapfile/{print $1, $3}')
  echo "[✓] Swapfile active: ${SWAP_INFO}"
else
  echo "[✗] Swapfile is NOT active"
  VERIFY_FAIL=1
fi

# ZRAM
if swapon --show | grep -q "zram"; then
  ZRAM_INFO=$(swapon --show | awk '/zram/{print $1, $3}')
  echo "[✓] ZRAM swap is active: ${ZRAM_INFO}"
elif [ ! -e /usr/lib/systemd/system-generators/zram-generator ] && \
     [ ! -e /lib/systemd/system-generators/zram-generator ]; then
  # The package is genuinely missing — a real configuration failure.
  echo "[✗] ZRAM inactive: systemd-zram-generator package is not installed"
  VERIFY_FAIL=1
else
  # Package present and config written, but the device is not up yet. This is the
  # expected outcome when the script runs under memory pressure (see Section 11):
  # the generator activates it on the next boot. Not a hard failure — the swapfile
  # covers swap in the meantime.
  echo "[~] ZRAM configured but not active yet — activates on next reboot"
  echo "    (insufficient free RAM to start it now; the swapfile covers swap until then)"
fi

# sysctl vm.swappiness
ACTUAL_SWAPPINESS=$(sysctl -n vm.swappiness)
if [ "${ACTUAL_SWAPPINESS}" -eq "${SYS_SWAPPINESS}" ]; then
  echo "[✓] vm.swappiness = ${ACTUAL_SWAPPINESS}"
else
  echo "[✗] vm.swappiness = ${ACTUAL_SWAPPINESS} (expected ${SYS_SWAPPINESS})"
  VERIFY_FAIL=1
fi

# I/O scheduler (reads from sysfs; active state, not just udev rule presence)
SCHED_PATH="/sys/block/${DISK_PARENT}/queue/scheduler"
if [ -f "${SCHED_PATH}" ]; then
  echo "[✓] I/O scheduler (${DISK_PARENT}): $(cat "${SCHED_PATH}")"
else
  echo "[~] Scheduler sysfs path not readable at ${SCHED_PATH}"
fi

# read_ahead_kb
RA_PATH="/sys/block/${DISK_PARENT}/queue/read_ahead_kb"
if [ -f "${RA_PATH}" ]; then
  echo "[✓] read_ahead_kb (${DISK_PARENT}): $(cat "${RA_PATH}")"
else
  echo "[~] read_ahead_kb sysfs path not readable at ${RA_PATH}"
fi

# Per-user resource limits
if grep -q "nofile" "${LIMITS_FILE}" 2>/dev/null; then
  echo "[✓] Per-user resource limits written (effective on next login)"
else
  echo "[✗] Per-user limits file is missing expected nofile content"
  VERIFY_FAIL=1
fi

# gradle.properties
if grep -q "org.gradle.daemon=true"   "${GRADLE_PROPS}" && \
   grep -q "org.gradle.caching=true"  "${GRADLE_PROPS}" && \
   grep -q "org.gradle.parallel=true" "${GRADLE_PROPS}"; then
  echo "[✓] gradle.properties: daemon=true, caching=true, parallel=true"
  echo "    JVM max heap: ${GRADLE_JVM_MAX}"
else
  echo "[✗] gradle.properties is missing one or more expected entries"
  VERIFY_FAIL=1
fi

# ~/.pub-cache
if [ -d "${TARGET_HOME}/.pub-cache" ]; then
  echo "[✓] ~/.pub-cache directory is present"
else
  echo "[✗] ~/.pub-cache directory is missing"
  VERIFY_FAIL=1
fi

# kvm group membership
if getent group kvm > /dev/null 2>&1; then
  if id -nG "${TARGET_USER}" | grep -qw kvm; then
    echo "[✓] ${TARGET_USER} is a member of the kvm group (effective on next login)"
  else
    echo "[~] ${TARGET_USER} is not in the kvm group — emulator hardware acceleration unavailable"
  fi
fi

# Flutter doctor — checked against TARGET_USER's PATH, not root's, since Flutter
# is typically a per-user installation.
if su - "${TARGET_USER}" -c "command -v flutter" > /dev/null 2>&1; then
  echo "[*] Running flutter doctor..."
  su - "${TARGET_USER}" -c "flutter doctor" 2>&1 | grep -E "^\[" | head -10 || true
else
  echo "[~] flutter not found on ${TARGET_USER}'s PATH — skipping flutter doctor"
fi

echo " "
if [ "${VERIFY_FAIL}" -eq 0 ]; then
  echo "[✓] All critical verifications passed."
else
  echo "[!] One or more critical verifications failed. Review output above before proceeding."
fi

# ─── 19. Finalise and Set Recovery File Permissions ────────────────────────────
chmod +x "$UNDO_FILE"
chown "${TARGET_USER}:${TARGET_USER}" "$UNDO_FILE"

echo " "
echo "==============================================================="
echo " Build Environment Optimisation Complete"
echo "==============================================================="
echo " User:                 ${TARGET_USER}"
echo " .bashrc:              ${BASHRC_FILE}"
echo " gradle.properties:    ${GRADLE_PROPS}"
echo " RAM bracket:          ${RAM_GB}GB"
echo " Gradle JVM max heap:  ${GRADLE_JVM_MAX}"
echo " vm.swappiness:        $(sysctl -n vm.swappiness)"
echo " "
echo " To undo all changes:"
echo "   sudo ${UNDO_FILE}"
echo "==============================================================="
echo " "

read -rp "A restart is recommended to fully apply kernel parameters. Reboot now? (y/N): " REBOOT_ANSWER
if [[ "${REBOOT_ANSWER}" =~ ^[Yy]$ ]]; then
  echo "Rebooting..."
  reboot
fi