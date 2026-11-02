#!/usr/bin/env bash
# shellcheck disable=SC2164

# Constants
WORKDIR="$(pwd)"

# Validate workflow inputs before using them to select repositories and config.
case "$KVER" in
  6.12|5.10) ;;
  *)
    echo "[ERROR] Unsupported KVER '${KVER:-<empty>}'; supported versions are 6.12 and 5.10."
    exit 2
    ;;
esac

case "$VARIANT" in
  VNL|KSU|KSUN) ;;
  *)
    echo "[ERROR] Unsupported VARIANT '${VARIANT:-<empty>}'; choose VNL, KSU, or KSUN."
    exit 2
    ;;
esac

case "$TODO" in
  kernel|defconfig) ;;
  *)
    echo "[ERROR] Unsupported TODO '${TODO:-<empty>}'; choose kernel or defconfig."
    exit 2
    ;;
esac

if [[ "$KVER" == "6.12" ]]; then
  RELEASE="v0.2"
elif [[ "$KVER" == "5.10" ]]; then
  RELEASE="v0.1"
fi

KERNEL_NAME="RendangKernel"
USER="yourapril01"
HOST="indoapril01"
TIMEZONE="Asia/Jakarta"
ANYKERNEL_REPO="https://github.com/linastorvaldz/AnyKernel3"
ANYKERNEL_BRANCH="master"

if [[ "$KVER" == "6.12" ]]; then
  KERNEL_DEFCONFIG="exynos2100-r9sxxx_defconfig"
elif [[ "$KVER" == "5.10" ]]; then
  KERNEL_DEFCONFIG="r9s_defconfig"
fi

if [[ "$KVER" == "6.12" ]]; then
  KERNEL_REPO="https://github.com/yourapril01/rendang_exynos2100_kernel"
  KERNEL_BRANCH="Alpha"
elif [[ "$KVER" == "5.10" ]]; then
  KERNEL_REPO="https://github.com/Flopster101/velpecula-android_kernel_samsung_r9s-5.10"
  KERNEL_BRANCH="android13-5.10-lts"
fi

DEFCONFIG_TO_MERGE=""
GKI_RELEASES_REPO="https://github.com/yourapril01/RendangKernel_release"
#CLANG_URL="https://github.com/linastorvaldz/idk/releases/download/clang-r547379/clang.tgz"
#AOSP_CLANG_VERSION="clang-r596125"
CLANG_URL="$(curl -s https://api.github.com/repos/Neutron-Toolchains/clang-build-catalogue/releases/latest | grep "browser_download_url.*\.tar\.zst" | cut -d '"' -f 4)"
CLANG_BRANCH="" # if it's a github repo
AK3_ZIP_NAME="$KERNEL_NAME-REL-KVER-VARIANT-BUILD_DATE.zip"
OUTDIR="$WORKDIR/out"
KSRC="$WORKDIR/ksrc"
KERNEL_PATCHES="$WORKDIR/kernel-patches"

# Handle error
exec > >(tee "$WORKDIR/build.log") 2>&1
trap 'error "Failed at line $LINENO [$BASH_COMMAND]"' ERR

# Import functions
source "$WORKDIR/functions.sh"

# Set timezone
sudo timedatectl set-timezone "$TIMEZONE" || export TZ="$TIMEZONE"

# Clone kernel source
log "Cloning kernel source from $(simplify_gh_url "$KERNEL_REPO")"
git clone -q --depth=1 --recurse-submodules "$KERNEL_REPO" -b "$KERNEL_BRANCH" "$KSRC"

cd "$KSRC"
LINUX_VERSION=$(make kernelversion)
LINUX_VERSION_CODE=${LINUX_VERSION//./}
DEFCONFIG_FILE=$(find ./arch/arm64/configs -name "$KERNEL_DEFCONFIG")
k_lastcommit=$(git rev-parse --short HEAD)
cd "$WORKDIR"

# Set Kernel variant
log "Setting Kernel variant..."
susfs_included && VARIANT="KSU+SuSFS"

# Replace Placeholder in zip name
AK3_ZIP_NAME=${AK3_ZIP_NAME//KVER/$LINUX_VERSION}
AK3_ZIP_NAME=${AK3_ZIP_NAME//VARIANT/$VARIANT}

# Download Clang
CLANG_DIR="$WORKDIR/clang"
CLANG_BIN="${CLANG_DIR}/bin"
if [[ -z "$CLANG_BRANCH" ]]; then
  log "🔽 Downloading Clang..."
  wget -qO clang-archive "$CLANG_URL"
  mkdir -p "$CLANG_DIR"
  case "$(basename $CLANG_URL)" in
    *.tar.* | *.tgz)
      tar -xf clang-archive -C "$CLANG_DIR"
      ;;
    *.7z)
      7z x clang-archive -o"${CLANG_DIR}/" -bd -y > /dev/null
      ;;
    *)
      error "Unsupported file format"
      ;;
  esac
  rm clang-archive

  if [[ $(find "$CLANG_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l) -eq 1 ]] \
    && [[ $(find "$CLANG_DIR" -mindepth 1 -maxdepth 1 -type f | wc -l) -eq 0 ]]; then
    SINGLE_DIR=$(find "$CLANG_DIR" -mindepth 1 -maxdepth 1 -type d)
    mv "$SINGLE_DIR"/* "$CLANG_DIR"/
    rm -rf "$SINGLE_DIR"
  fi
else
  log "🔽 Cloning Clang..."
  git clone --depth=1 -q "$CLANG_URL" -b "$CLANG_BRANCH" "$CLANG_DIR"
fi

# Clone GNU Assembler
log "Cloning GNU Assembler..."
GAS_DIR="$WORKDIR/gas"
git clone --depth=1 -q \
  https://android.googlesource.com/platform/prebuilts/gas/linux-x86 \
  -b main \
  "$GAS_DIR"

export PATH="${CLANG_BIN}:${GAS_DIR}:$PATH"

# Extract clang version
COMPILER_STRING=$(clang --version | head -n 1 | sed 's/(https..*//' | sed 's/ version//')

cd "$KSRC"

## KernelSU setup
if ksu_included; then
  # Remove existing KernelSU drivers
  for KSU_PATH in drivers/staging/kernelsu drivers/kernelsu KernelSU KernelSU-Next; do
    if [[ -d $KSU_PATH ]]; then
      log "KernelSU driver found in $KSU_PATH, Removing..."
      KSU_DIR=$(dirname "$KSU_PATH")

      [[ -f "$KSU_DIR/Kconfig" ]] && sed -i '/kernelsu/d' "$KSU_DIR/Kconfig"
      [[ -f "$KSU_DIR/Makefile" ]] && sed -i '/kernelsu/d' "$KSU_DIR/Makefile"

      rm -rf $KSU_PATH
    fi
  done

  install_ksu 'pershoot/KernelSU-Next' 'dev-susfs'
  config --enable CONFIG_KSU

  cd KernelSU-Next
  patch -p1 < "$KERNEL_PATCHES/ksu/ksun-add-more-managers-support.patch"
  cd "$OLDPWD"
fi

# SUSFS
if susfs_included; then
  # Kernel-side
  log "Applying kernel-side susfs patches"
  SUSFS_DIR="$WORKDIR/susfs"
  SUSFS_PATCHES="${SUSFS_DIR}/kernel_patches"
  if [[ "$KVER" == "6.12" ]]; then
    SUSFS_BRANCH=gki-android16-6.12
  elif [[ "$KVER" == "5.10" ]]; then
    SUSFS_BRANCH=gki-android13-5.10
  fi
  git clone --depth=1 -q https://gitlab.com/simonpunk/susfs4ksu -b "$SUSFS_BRANCH" "$SUSFS_DIR"
  cp -R "$SUSFS_PATCHES"/fs/* ./fs
  cp -R "$SUSFS_PATCHES"/include/* ./include
  patch -p1 < "$SUSFS_PATCHES/50_add_susfs_in_${SUSFS_BRANCH}.patch" || true
  if [[ $(echo "$LINUX_VERSION_CODE" | head -c4) -eq 6630 ]]; then
    patch -p1 < "$KERNEL_PATCHES/susfs/namespace.c_fix.patch"
    patch -p1 < "$KERNEL_PATCHES/susfs/task_mmu.c_fix.patch"
  elif [[ $(echo "$LINUX_VERSION_CODE" | head -c4) -eq 6658 ]]; then
    patch -p1 < "$KERNEL_PATCHES/susfs/task_mmu.c_fix-k6.6.58.patch"
  elif [[ $(echo "$LINUX_VERSION_CODE" | head -c2) -eq 61 ]]; then
    patch -p1 < "$KERNEL_PATCHES/susfs/fs_proc_base.c-fix-k6.1.patch"
  fi
  if [[ $(echo "$LINUX_VERSION_CODE" | head -c1) -eq 6 ]]; then
    patch -p1 < "$KERNEL_PATCHES/susfs/fix-statfs-crc-mismatch-susfs.patch"
  fi
  pershoot_susfs 'c55d9c4edd9c49b76210ce10c2a8026415bffd93'
  pershoot_susfs '2cdd69d819034ba3e4ba3484af5e34ea4f81c2b8'
  SUSFS_VERSION=$(grep -E '^#define SUSFS_VERSION' ./include/linux/susfs.h | cut -d' ' -f3 | sed 's/"//g')
  config --enable CONFIG_KSU_SUSFS
else
  config --disable CONFIG_KSU_SUSFS
fi

# set localversion
if [[ $TODO == "kernel" ]]; then
  if [[ $STATUS == "BETA" ]]; then
    SUFFIX="$k_lastcommit"
  else
    SUFFIX="$RELEASE"
  fi
  config --set-str CONFIG_LOCALVERSION "-$KERNEL_NAME/$SUFFIX"
  config --disable CONFIG_LOCALVERSION_AUTO
  sed -i 's/echo "+"/# echo "+"/g' scripts/setlocalversion
fi

# Declare needed variables
export KBUILD_BUILD_USER="$USER"
export KBUILD_BUILD_HOST="$HOST"
KBUILD_BUILD_TIMESTAMP=$(date -R)
export KBUILD_BUILD_TIMESTAMP
export KCFLAGS="-w"
MAKE_ARGS=(
  LLVM=1
  LLVM_IAS=1
  ARCH=arm64
  CROSS_COMPILE=aarch64-linux-gnu-
  CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
  "-j$(nproc --all)"
  "O=$OUTDIR"
)

KERNEL_IMAGE="$OUTDIR/arch/arm64/boot/Image"
MODULE_SYMVERS="$OUTDIR/Module.symvers"
if [[ $(echo "$LINUX_VERSION_CODE" | head -c1) -eq 6 ]]; then
  KMI_CHECK="$WORKDIR/py/kmi-check-6.x.py"
else
  KMI_CHECK="$WORKDIR/py/kmi-check-5.x.py"
fi

text=$(
  cat << EOF
Kernel version: \`${LINUX_VERSION}\`
Build Date: \`${KBUILD_BUILD_TIMESTAMP}\`
Variant: \`${VARIANT}\`
SuSFS: \`$(susfs_included && echo "${SUSFS_VERSION}" || echo "None")\`
Compiler: \`${COMPILER_STRING}\`
Last Commit: [$(simplify_gh_url "$KERNEL_REPO")@${k_lastcommit}](${KERNEL_REPO}/commit/${k_lastcommit})
EOF
)

# Merge config
if [[ "$CONFIG_TO_MERGE" ]]; then
  log "Merging configs..."
  for config in $CONFIG_TO_MERGE; do
    if [ -f "$WORKDIR/configs/$config" ]; then
      cat $WORKDIR/configs/$config >> $DEFCONFIG_FILE
    fi
  done
fi

log "Generating .config..."
make "${MAKE_ARGS[@]}" "$KERNEL_DEFCONFIG"

# Upload defconfig if we are doing defconfig
if [[ $TODO == "defconfig" ]]; then
  log "Uploading defconfig..."
  upload_file "$OUTDIR/.config"
  exit 0
fi

# Build the actual kernel
log "Building kernel..."
make "${MAKE_ARGS[@]}"

# Check KMI Function symbol
if [[ $(echo "$LINUX_VERSION_CODE" | head -c1) -eq 6 ]]; then
  $KMI_CHECK "$KSRC/android/abi_gki_aarch64.stg" "$MODULE_SYMVERS" || true
else
  $KMI_CHECK "$KSRC/android/abi_gki_aarch64.xml" "$MODULE_SYMVERS" || true
fi

cd "$WORKDIR"

# Clone AnyKernel
log "Cloning anykernel from $(simplify_gh_url "$ANYKERNEL_REPO")"
git clone -q --depth=1 $ANYKERNEL_REPO -b $ANYKERNEL_BRANCH anykernel

cd anykernel

# Set kernel string in anykernel
if [[ $STATUS == "BETA" ]]; then
  BUILD_DATE=$(date -d "$KBUILD_BUILD_TIMESTAMP" +"%Y%m%d-%H%M")
  AK3_ZIP_NAME=${AK3_ZIP_NAME//BUILD_DATE/$BUILD_DATE}
  AK3_ZIP_NAME=${AK3_ZIP_NAME//-REL/}
  sed -i \
    "s/kernel.string=.*/kernel.string=${KERNEL_NAME} ${LINUX_VERSION} (${BUILD_DATE}) ${VARIANT}/g" \
    anykernel.sh
else
  AK3_ZIP_NAME=${AK3_ZIP_NAME//-BUILD_DATE/}
  AK3_ZIP_NAME=${AK3_ZIP_NAME//REL/$RELEASE}
  sed -i \
    "s/kernel.string=.*/kernel.string=${KERNEL_NAME} ${RELEASE} ${LINUX_VERSION} ${VARIANT}/g" \
    anykernel.sh
fi

# Set supported kernel version in anykernel
sed -i "s/supported_kver=.*/supported_kver='$KVER'/g" anykernel.sh

# Zip the anykernel
log "Zipping anykernel..."
cp "$KERNEL_IMAGE" .
zip -r9 "$WORKDIR/$AK3_ZIP_NAME" ./*
cd "$OLDPWD"

if [[ $STATUS != "BETA" ]]; then
  echo "BASE_NAME=$KERNEL_NAME-$VARIANT" >> "$GITHUB_ENV"
  mkdir -p "$WORKDIR/artifacts"
  mv "$WORKDIR"/*.zip "$WORKDIR/artifacts"
fi

if [[ $LAST_BUILD == "true" ]] && [[ $STATUS != "BETA" ]]; then
  (
    echo "LINUX_VERSION=$LINUX_VERSION"
    echo "SUSFS_VERSION=$(curl -s https://gitlab.com/simonpunk/susfs4ksu/raw/gki-android15-6.6/kernel_patches/include/linux/susfs.h | grep -E '^#define SUSFS_VERSION' | cut -d' ' -f3 | sed 's/"//g')"
    echo "KERNEL_NAME=$KERNEL_NAME"
    echo "RELEASE_REPO=$(simplify_gh_url "$GKI_RELEASES_REPO")"
    echo "RELEASE=$RELEASE"
    echo "KVER=$KVER"
  ) >> "$WORKDIR/artifacts/info.txt"
fi

if [[ $STATUS == "BETA" ]]; then
  upload_file "$WORKDIR/$AK3_ZIP_NAME" "$text"
  upload_file "$WORKDIR/build.log"
else
  send_msg "✅ Build Succeeded for $VARIANT variant."
fi

exit 0
