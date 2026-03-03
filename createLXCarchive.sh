#!/bin/bash
# =============================================================================
# createLXCarchive.sh
# Builds the matrix-stack LXC container archive for Unraid release.
# Run this on the Unraid host (requires LXC plugin installed).
#
# Output: <lxc_path>/cache/build_cache_matrix/matrix.tar.xz
#         <lxc_path>/cache/build_cache_matrix/matrix.tar.xz.md5
#         <lxc_path>/cache/build_cache_matrix/build.log
# =============================================================================
# Based on pattern by bmartino1 (unraid-lxc-unifi)

set -euo pipefail

if [ ! -f /boot/config/plugins/lxc.plg ]; then
  echo "ERROR: LXC plugin not found on this Unraid host!"
  exit 1
fi

# ── Config ────────────────────────────────────────────────────────────────────
LXC_PATH=$(grep "lxc.lxcpath" /boot/config/plugins/lxc/lxc.conf | cut -d '=' -f2 | tr -d ' ')
LXC_PACKAGE_NAME=matrix
LXC_PACKAGE_DIR="${LXC_PATH}/cache/build_cache_matrix"
LXC_DISTRIBUTION=debian
LXC_RELEASE=bookworm
LXC_ARCH=amd64
LXC_BUILD_ROOT="$(cd "$(dirname "$0")" && pwd)"

if echo "${LXC_PATH}" | grep -q "/mnt/user"; then
  echo "ERROR: LXC path /mnt/user is not allowed!"
  exit 1
fi

# ── Temp container name ───────────────────────────────────────────────────────
LXC_CONT_NAME=$(openssl rand -base64 24 | tr -dc 'a-z0-9' | cut -c -12)

mkdir -p "${LXC_PACKAGE_DIR}"
echo "Build time: $(date +'%Y-%m-%d %H:%M')" > "${LXC_PACKAGE_DIR}/${LXC_PACKAGE_NAME}_startdate.log"

# ── Create container ──────────────────────────────────────────────────────────
echo "Creating temporary container: ${LXC_CONT_NAME}"
lxc-create --name "${LXC_CONT_NAME}" \
  --template download -- \
  --dist  "${LXC_DISTRIBUTION}" \
  --release "${LXC_RELEASE}" \
  --arch "${LXC_ARCH}" > "${LXC_PACKAGE_DIR}/${LXC_PACKAGE_NAME}_create.log"

# ── Build scripts list ────────────────────────────────────────────────────────
BUILD_FILES=$(ls -1 "${LXC_BUILD_ROOT}/build/" | grep '^[0-9][0-9]-' | sort)

# ── Start container ───────────────────────────────────────────────────────────
echo "Starting temporary container..."
lxc-start -n "${LXC_CONT_NAME}"
echo "Waiting 10 seconds for container to come online..."
sleep 10

# ── Copy build scripts into container ─────────────────────────────────────────
echo "Copying build directory into container..."
cp -R "${LXC_BUILD_ROOT}/build" "${LXC_PATH}/${LXC_CONT_NAME}/rootfs/tmp/build"
cp -R "${LXC_BUILD_ROOT}/config" "${LXC_PATH}/${LXC_CONT_NAME}/rootfs/tmp/config" 2>/dev/null || true

# ── Execute build scripts ─────────────────────────────────────────────────────
echo "Executing build scripts..."
IFS=$'\n'
for script in ${BUILD_FILES}; do
  echo "----> Running: ${script}"
  lxc-attach -n "${LXC_CONT_NAME}" -- \
    bash -c "chmod +x /tmp/build/${script} && /tmp/build/${script} 2>&1 | tee /tmp/${script%.*}.log"
  EXIT_STATUS=$?
  if [[ "${EXIT_STATUS}" != "0" ]]; then
    echo "ERROR: ${script} failed (exit ${EXIT_STATUS}) — aborting build."
    lxc-stop -k -n "${LXC_CONT_NAME}" 2>/dev/null
    lxc-destroy -n "${LXC_CONT_NAME}"
    exit 1
  fi
done

# ── Stop container ────────────────────────────────────────────────────────────
echo "Stopping container..."
lxc-stop -n "${LXC_CONT_NAME}" -t 15 2>/dev/null

# ── Collect logs ──────────────────────────────────────────────────────────────
echo "Collecting build logs..."
for script in ${BUILD_FILES}; do
  cp "${LXC_PATH}/${LXC_CONT_NAME}/rootfs/tmp/${script%.*}.log" \
     "${LXC_PACKAGE_DIR}/${LXC_PACKAGE_NAME}_${script%.*}.log" 2>/dev/null || true
done

# ── Cleanup container FS ──────────────────────────────────────────────────────
echo "Cleaning up container..."
cd "${LXC_PATH}/${LXC_CONT_NAME}"
find . -name ".bash_history" -exec rm -f {} \;
rm -rf "${LXC_PATH}/${LXC_CONT_NAME}/rootfs/tmp/"*
sed -i '/# Container specific configuration/,$d' config

# ── Build log ─────────────────────────────────────────────────────────────────
echo "Assembling build.log..."
cat "${LXC_PACKAGE_DIR}/${LXC_PACKAGE_NAME}_startdate.log" \
    "${LXC_PACKAGE_DIR}/${LXC_PACKAGE_NAME}_create.log" > "${LXC_PACKAGE_DIR}/build.log"
rm  "${LXC_PACKAGE_DIR}/${LXC_PACKAGE_NAME}_startdate.log" \
    "${LXC_PACKAGE_DIR}/${LXC_PACKAGE_NAME}_create.log"
for script in ${BUILD_FILES}; do
  cat  "${LXC_PACKAGE_DIR}/${LXC_PACKAGE_NAME}_${script%.*}.log" >> "${LXC_PACKAGE_DIR}/build.log"
  rm   "${LXC_PACKAGE_DIR}/${LXC_PACKAGE_NAME}_${script%.*}.log"
done

# ── Pack container archive ────────────────────────────────────────────────────
echo "Packing container archive (this may take a while)..."
tar -cf - . | xz -9 --threads=$(nproc --all) > "${LXC_PACKAGE_DIR}/${LXC_PACKAGE_NAME}.tar.xz"
echo "Creating MD5 checksum..."
md5sum "${LXC_PACKAGE_DIR}/${LXC_PACKAGE_NAME}.tar.xz" | awk '{print $1}' \
  > "${LXC_PACKAGE_DIR}/${LXC_PACKAGE_NAME}.tar.xz.md5"
echo "--------------------END--------------------" >> "${LXC_PACKAGE_DIR}/build.log"

# ── Destroy temp container ────────────────────────────────────────────────────
echo "Destroying temporary container..."
lxc-stop -k -n "${LXC_CONT_NAME}" 2>/dev/null
lxc-destroy -n "${LXC_CONT_NAME}"

echo ""
echo "=========================================="
echo "  Build complete!"
echo "  Archive:  ${LXC_PACKAGE_DIR}/${LXC_PACKAGE_NAME}.tar.xz"
echo "  MD5:      ${LXC_PACKAGE_DIR}/${LXC_PACKAGE_NAME}.tar.xz.md5"
echo "  Log:      ${LXC_PACKAGE_DIR}/build.log"
echo "=========================================="
