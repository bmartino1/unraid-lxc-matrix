#!/bin/bash
# =============================================================================
# createLXCarchive.sh  —  Unraid LXC Builder (Debian 12 / bookworm)
#
# Run on the Unraid host (with the LXC plugin installed).
#
# What this does:
#   1) Creates a fresh Debian 12 LXC
#   2) Copies ./build into container and runs build stages (NO domain/secrets)
#   3) Copies setup.sh + setup/ + scripts/ into container (staged in /tmp/setup)
#   4) Stops the container, cleans caches, and packs the rootfs into matrix.tar.xz
#   5) Writes matrix.tar.xz.md5 and a combined build.log
#
# End user flow:
#   - Install template in LXC plugin -> it downloads matrix.tar.xz
#   - User opens console -> runs: /root/setup.sh (or whatever you stage)
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Sanity checks
# ─────────────────────────────────────────────────────────────────────────────
if [[ ! -f /boot/config/plugins/lxc.plg ]]; then
  echo "ERROR: Unraid LXC plugin not found (/boot/config/plugins/lxc.plg)."
  exit 1
fi

CONF="/boot/config/plugins/lxc/lxc.conf"
if [[ ! -f "$CONF" ]]; then
  echo "ERROR: LXC config not found: $CONF"
  exit 1
fi

LXC_PATH="$(grep -E '^\s*lxc\.lxcpath\s*=' "$CONF" | head -n1 | cut -d '=' -f2- | tr -d '[:space:]')"
if [[ -z "${LXC_PATH}" ]]; then
  echo "ERROR: Could not read lxc.lxcpath from $CONF"
  exit 1
fi

# Unraid /mnt/user (FUSE) is not safe for LXC rootfs/packing
if echo "${LXC_PATH}" | grep -q "/mnt/user"; then
  echo "ERROR: LXC path is under /mnt/user (${LXC_PATH}) — not allowed."
  echo "Set LXC plugin path to /mnt/cache/... or /mnt/diskX/..."
  exit 1
fi

LXC_PACKAGE_NAME="matrix"
LXC_PACKAGE_DIR="${LXC_PATH}/cache/build_cache_${LXC_PACKAGE_NAME}"

LXC_DISTRIBUTION="debian"
LXC_RELEASE="bookworm"
LXC_ARCH="amd64"

LXC_BUILD_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Build scripts (sorted)
mapfile -t BUILD_FILES < <(find "${LXC_BUILD_ROOT}/build" -maxdepth 1 -type f -name '[0-9][0-9]-*.sh' -printf '%f\n' | sort)

if [[ ${#BUILD_FILES[@]} -eq 0 ]]; then
  echo "ERROR: No build scripts found in ${LXC_BUILD_ROOT}/build (expected 00-*.sh)."
  exit 1
fi

# Temp container name
LXC_CONT_NAME="$(openssl rand -base64 24 | tr -dc 'a-z0-9' | head -c 12)"

mkdir -p "${LXC_PACKAGE_DIR}"

START_LOG="${LXC_PACKAGE_DIR}/${LXC_PACKAGE_NAME}_startdate.log"
CREATE_LOG="${LXC_PACKAGE_DIR}/${LXC_PACKAGE_NAME}_create.log"
BUILD_LOG="${LXC_PACKAGE_DIR}/build.log"

echo "Build time: $(date +'%Y-%m-%d %H:%M:%S %Z')" > "${START_LOG}"
echo "LXC path: ${LXC_PATH}" >> "${START_LOG}"
echo "Container: ${LXC_CONT_NAME}" >> "${START_LOG}"
echo "Repo root: ${LXC_BUILD_ROOT}" >> "${START_LOG}"

cleanup_on_fail() {
  set +e
  echo ""
  echo "!! Cleanup on failure..."
  lxc-stop -k -n "${LXC_CONT_NAME}" 2>/dev/null || true
  lxc-destroy -n "${LXC_CONT_NAME}" 2>/dev/null || true
}
trap cleanup_on_fail ERR

# ─────────────────────────────────────────────────────────────────────────────
# Create container
# ─────────────────────────────────────────────────────────────────────────────
echo "Creating temporary container: ${LXC_CONT_NAME}"
lxc-create --name "${LXC_CONT_NAME}" \
  --template download -- \
  --dist "${LXC_DISTRIBUTION}" \
  --release "${LXC_RELEASE}" \
  --arch "${LXC_ARCH}" > "${CREATE_LOG}"

ROOTFS="${LXC_PATH}/${LXC_CONT_NAME}/rootfs"
CONT_DIR="${LXC_PATH}/${LXC_CONT_NAME}"

if [[ ! -d "${ROOTFS}" ]]; then
  echo "ERROR: rootfs not found after create: ${ROOTFS}"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Start container
# ─────────────────────────────────────────────────────────────────────────────
echo "Starting temporary container..."
lxc-start -n "${LXC_CONT_NAME}"
sleep 8

# ─────────────────────────────────────────────────────────────────────────────
# Copy scripts into container (host-side copy into rootfs)
# ─────────────────────────────────────────────────────────────────────────────
echo "Copying build scripts into container..."
mkdir -p "${ROOTFS}/tmp/build"
cp -R "${LXC_BUILD_ROOT}/build/." "${ROOTFS}/tmp/build/"

echo "Copying setup payload into container staging area..."
mkdir -p "${ROOTFS}/tmp/setup"
cp -f  "${LXC_BUILD_ROOT}/setup.sh"        "${ROOTFS}/tmp/setup/setup.sh"
cp -R  "${LXC_BUILD_ROOT}/setup"           "${ROOTFS}/tmp/setup/setup"
cp -R  "${LXC_BUILD_ROOT}/scripts"         "${ROOTFS}/tmp/setup/scripts"

# Ensure executable bits inside rootfs
chmod +x "${ROOTFS}/tmp/setup/setup.sh" || true
chmod +x "${ROOTFS}/tmp/setup/setup/"*.sh 2>/dev/null || true
chmod +x "${ROOTFS}/tmp/setup/scripts/"*.sh 2>/dev/null || true
chmod +x "${ROOTFS}/tmp/build/"*.sh 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# Execute build scripts (logs stored in /var/log/lxc-build so /tmp cleanup won't nuke them)
# ─────────────────────────────────────────────────────────────────────────────
echo "Executing build scripts..."
for script in "${BUILD_FILES[@]}"; do
  echo "----> ${script}"
  if ! lxc-attach -n "${LXC_CONT_NAME}" -- bash -lc \
    "mkdir -p /var/log/lxc-build \
     && chmod +x /tmp/build/${script} \
     && /tmp/build/${script} 2>&1 | tee /var/log/lxc-build/${script%.sh}.log"
  then
    echo "ERROR: ${script} failed."
    exit 1
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Stop container (clean shutdown)
# ─────────────────────────────────────────────────────────────────────────────
echo "Stopping container..."
lxc-stop -n "${LXC_CONT_NAME}" -t 15 2>/dev/null || lxc-stop -k -n "${LXC_CONT_NAME}" 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# Collect logs (best-effort)
# ─────────────────────────────────────────────────────────────────────────────
echo "Collecting build logs..."
LOGS_FOUND=0
for script in "${BUILD_FILES[@]}"; do
  src="${ROOTFS}/var/log/lxc-build/${script%.sh}.log"
  dst="${LXC_PACKAGE_DIR}/${LXC_PACKAGE_NAME}_${script%.sh}.log"
  if [[ -f "$src" ]]; then
    cp -f "$src" "$dst"
    LOGS_FOUND=$((LOGS_FOUND+1))
  fi
done
echo "   Collected ${LOGS_FOUND}/${#BUILD_FILES[@]} stage logs."

# ─────────────────────────────────────────────────────────────────────────────
# Cleanup rootfs for distribution (host-side edits)
# ─────────────────────────────────────────────────────────────────────────────
echo "Cleaning up container rootfs..."
find "${ROOTFS}" -name ".bash_history" -exec rm -f {} \; 2>/dev/null || true
rm -rf "${ROOTFS}/tmp/"* 2>/dev/null || true
rm -rf "${ROOTFS}/var/cache/apt/archives/"*.deb 2>/dev/null || true
rm -rf "${ROOTFS}/var/lib/apt/lists/"* 2>/dev/null || true

# Remove container-specific lines in config (safe if not present)
if [[ -f "${CONT_DIR}/config" ]]; then
  sed -i '/# Container specific configuration/,$d' "${CONT_DIR}/config" 2>/dev/null || true
fi

# ─────────────────────────────────────────────────────────────────────────────
# Assemble build.log (NEVER fail if a stage log is missing)
# ─────────────────────────────────────────────────────────────────────────────
echo "Assembling build.log..."
{
  cat "${START_LOG}" 2>/dev/null || true
  echo ""
  cat "${CREATE_LOG}" 2>/dev/null || true
  echo ""
  for script in "${BUILD_FILES[@]}"; do
    f="${LXC_PACKAGE_DIR}/${LXC_PACKAGE_NAME}_${script%.sh}.log"
    echo "==================== ${script} ===================="
    if [[ -f "$f" ]]; then
      cat "$f"
      rm -f "$f" || true
    else
      echo "(missing log: ${script%.sh}.log)"
    fi
    echo ""
  done
  echo "--------------------END--------------------"
} > "${BUILD_LOG}"

rm -f "${START_LOG}" "${CREATE_LOG}" 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# Pack archive
# ─────────────────────────────────────────────────────────────────────────────
echo "Packing container archive..."
cd "${CONT_DIR}"

ARCHIVE="${LXC_PACKAGE_DIR}/${LXC_PACKAGE_NAME}.tar.xz"
ARCHIVE_MD5="${LXC_PACKAGE_DIR}/${LXC_PACKAGE_NAME}.tar.xz.md5"

tar -cf - . | xz -9 --threads="$(nproc --all)" > "${ARCHIVE}"
md5sum "${ARCHIVE}" | awk '{print $1}' > "${ARCHIVE_MD5}"

# ─────────────────────────────────────────────────────────────────────────────
# Destroy temp container
# ─────────────────────────────────────────────────────────────────────────────
echo "Destroying temp container..."
lxc-destroy -n "${LXC_CONT_NAME}" 2>/dev/null || true

trap - ERR

echo ""
echo "=========================================="
echo "  Build complete!"
echo ""
echo "  Archive: ${ARCHIVE}"
echo "  MD5:     ${ARCHIVE_MD5}"
echo "  Log:     ${BUILD_LOG}"
echo ""
echo "  Upload .tar.xz and .tar.xz.md5 to GitHub Release."
echo "  Update lxc_container_template.xml with the release URL."
echo "=========================================="
