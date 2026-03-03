#!/bin/bash
# =============================================================================
# createLXCarchive.sh
# Run this on the Unraid host (with LXC plugin) to build the release archive.
#
# This script:
#  1. Creates a fresh Debian 12 LXC container
#  2. Runs build/ scripts (installs packages, stages files — NO domain/secrets)
#  3. Copies the setup/ and scripts/ directories into the container at /root/
#  4. Packs the container as matrix.tar.xz for GitHub release
#
# Users then:
#  1. Download the template XML and add it to Unraid LXC plugin
#  2. The plugin downloads matrix.tar.xz and creates the container
#  3. User opens console, runs: ./setup.sh --domain chat.example.com
# =============================================================================

set -euo pipefail

if [[ ! -f /boot/config/plugins/lxc.plg ]]; then
  echo "ERROR: LXC plugin not found on this Unraid host!"
  exit 1
fi

# ── Config ────────────────────────────────────────────────────────────────────
LXC_PATH=$(grep "lxc.lxcpath" /boot/config/plugins/lxc/lxc.conf \
           | cut -d '=' -f2 | tr -d ' ')
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

# ── Create Debian 12 container ───────────────────────────────────────────────
echo "Creating temporary container: ${LXC_CONT_NAME}"
lxc-create --name "${LXC_CONT_NAME}" \
  --template download -- \
  --dist  "${LXC_DISTRIBUTION}" \
  --release "${LXC_RELEASE}" \
  --arch "${LXC_ARCH}" > "${LXC_PACKAGE_DIR}/${LXC_PACKAGE_NAME}_create.log"

# ── Build script list ─────────────────────────────────────────────────────────
BUILD_FILES=$(ls -1 "${LXC_BUILD_ROOT}/build/" | grep '^[0-9][0-9]-' | sort)

# ── Start container ───────────────────────────────────────────────────────────
echo "Starting temporary container..."
lxc-start -n "${LXC_CONT_NAME}"
echo "Waiting 10 seconds..."
sleep 10

# ── Copy build scripts and setup scripts ────────────────────────────────────
echo "Copying build directory into container..."
cp -R "${LXC_BUILD_ROOT}/build"   "${LXC_PATH}/${LXC_CONT_NAME}/rootfs/tmp/build"

# Copy the user-facing setup scripts into /tmp/setup
# build/09-copy-setup.sh will move them to /root/
echo "Copying setup and scripts directories into container..."
mkdir -p "${LXC_PATH}/${LXC_CONT_NAME}/rootfs/tmp/setup"
cp "${LXC_BUILD_ROOT}/setup.sh"   "${LXC_PATH}/${LXC_CONT_NAME}/rootfs/tmp/setup/"
cp -R "${LXC_BUILD_ROOT}/setup/"  "${LXC_PATH}/${LXC_CONT_NAME}/rootfs/tmp/setup/setup/"
cp -R "${LXC_BUILD_ROOT}/scripts/" "${LXC_PATH}/${LXC_CONT_NAME}/rootfs/tmp/setup/scripts/"
chmod +x "${LXC_PATH}/${LXC_CONT_NAME}/rootfs/tmp/setup/setup.sh"
chmod +x "${LXC_PATH}/${LXC_CONT_NAME}/rootfs/tmp/setup/setup/"*.sh
chmod +x "${LXC_PATH}/${LXC_CONT_NAME}/rootfs/tmp/setup/scripts/"*.sh

# ── Execute build scripts ─────────────────────────────────────────────────────
echo "Executing build scripts (this will take a while)..."
IFS=$'\n'
for script in ${BUILD_FILES}; do
  echo "----> ${script}"
  lxc-attach -n "${LXC_CONT_NAME}" -- \
    bash -c "chmod +x /tmp/build/${script} && /tmp/build/${script} 2>&1 | tee /tmp/${script%.*}.log"
  EXIT_STATUS=$?
  if [[ "${EXIT_STATUS}" != "0" ]]; then
    echo "ERROR: ${script} failed (exit ${EXIT_STATUS}) — aborting."
    lxc-stop -k -n "${LXC_CONT_NAME}" 2>/dev/null
    lxc-destroy -n "${LXC_CONT_NAME}"
    exit 1
  fi
done

# ── Stop container ────────────────────────────────────────────────────────────
echo "Stopping container..."
lxc-stop -n "${LXC_CONT_NAME}" -t 15 2>/dev/null

# ── Collect logs ──────────────────────────────────────────────────────────────
for script in ${BUILD_FILES}; do
  cp "${LXC_PATH}/${LXC_CONT_NAME}/rootfs/tmp/${script%.*}.log" \
     "${LXC_PACKAGE_DIR}/${LXC_PACKAGE_NAME}_${script%.*}.log" 2>/dev/null || true
done

# ── Cleanup container rootfs ──────────────────────────────────────────────────
echo "Cleaning up container..."
cd "${LXC_PATH}/${LXC_CONT_NAME}"
find . -name ".bash_history" -exec rm -f {} \;
rm -rf "${LXC_PATH}/${LXC_CONT_NAME}/rootfs/tmp/"*
rm -rf "${LXC_PATH}/${LXC_CONT_NAME}/rootfs/var/cache/apt/archives/"*.deb
rm -rf "${LXC_PATH}/${LXC_CONT_NAME}/rootfs/var/lib/apt/lists/"*
sed -i '/# Container specific configuration/,$d' config

# ── Assemble build.log ────────────────────────────────────────────────────────
cat "${LXC_PACKAGE_DIR}/${LXC_PACKAGE_NAME}_startdate.log" \
    "${LXC_PACKAGE_DIR}/${LXC_PACKAGE_NAME}_create.log" > "${LXC_PACKAGE_DIR}/build.log"
rm  "${LXC_PACKAGE_DIR}/${LXC_PACKAGE_NAME}_startdate.log" \
    "${LXC_PACKAGE_DIR}/${LXC_PACKAGE_NAME}_create.log"
for script in ${BUILD_FILES}; do
  cat  "${LXC_PACKAGE_DIR}/${LXC_PACKAGE_NAME}_${script%.*}.log" >> "${LXC_PACKAGE_DIR}/build.log"
  rm   "${LXC_PACKAGE_DIR}/${LXC_PACKAGE_NAME}_${script%.*}.log"
done
echo "--------------------END--------------------" >> "${LXC_PACKAGE_DIR}/build.log"

# ── Pack ──────────────────────────────────────────────────────────────────────
echo "Packing container archive..."
tar -cf - . | xz -9 --threads=$(nproc --all) \
  > "${LXC_PACKAGE_DIR}/${LXC_PACKAGE_NAME}.tar.xz"
md5sum "${LXC_PACKAGE_DIR}/${LXC_PACKAGE_NAME}.tar.xz" | awk '{print $1}' \
  > "${LXC_PACKAGE_DIR}/${LXC_PACKAGE_NAME}.tar.xz.md5"

# ── Destroy temp container ────────────────────────────────────────────────────
lxc-stop -k -n "${LXC_CONT_NAME}" 2>/dev/null
lxc-destroy -n "${LXC_CONT_NAME}"

echo ""
echo "=========================================="
echo "  Build complete!"
echo ""
echo "  Archive: ${LXC_PACKAGE_DIR}/${LXC_PACKAGE_NAME}.tar.xz"
echo "  MD5:     ${LXC_PACKAGE_DIR}/${LXC_PACKAGE_NAME}.tar.xz.md5"
echo "  Log:     ${LXC_PACKAGE_DIR}/build.log"
echo ""
echo "  Upload .tar.xz and .tar.xz.md5 to GitHub Release."
echo "  Update lxc_container_template.xml with the release URL."
echo "=========================================="
