#!/usr/bin/env bash
#
# Build mainline U-Boot for the Xiaomi Mi 10 (umi, SM8250) and pack it
# into an Android boot image that Qualcomm ABL accepts via `fastboot boot`.
#
# Targeted at GitHub Actions (Ubuntu 24.04) with gcc-aarch64-linux-gnu.
#
# Environment:
#   UBOOT_TAG       U-Boot tag/branch to build (default: v2027.01-rc1)
#   UBOOT_URL       git URL (default: https://github.com/u-boot/u-boot.git)
#   BUILD_DIR       work directory (default: <repo>/build)
#   CROSS_COMPILE   default: aarch64-linux-gnu-
#   JOBS            default: nproc
#   PAYLOAD         optional PE/COFF EFI file to pack as the Android ramdisk
#                   (ABL exposes it as prevbl_initrd_start_addr)
#   MKBOOTIMG       optional path to mkbootimg / mkbootimg.py

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UBOOT_TAG="${UBOOT_TAG:-v2027.01-rc1}"
UBOOT_URL="${UBOOT_URL:-https://github.com/u-boot/u-boot.git}"
BUILD_DIR="${BUILD_DIR:-$REPO_DIR/build}"
SRC_DIR="$BUILD_DIR/u-boot"
OUT_DIR="$BUILD_DIR/out"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
JOBS="${JOBS:-$(nproc)}"
PAYLOAD="${PAYLOAD:-}"
MKBOOTIMG="${MKBOOTIMG:-}"

say() { printf '\n==> %s\n' "$*"; }

mkdir -p "$BUILD_DIR" "$OUT_DIR"

if [ ! -d "$SRC_DIR/.git" ]; then
	say "Cloning U-Boot $UBOOT_TAG"
	git clone --depth 1 --branch "$UBOOT_TAG" "$UBOOT_URL" "$SRC_DIR"
else
	say "Using existing U-Boot tree: $SRC_DIR"
fi

say "Installing the umi port files"
install -m 0644 \
	"$REPO_DIR/dts/upstream/src/arm64/qcom/sm8250-xiaomi-umi.dts" \
	"$SRC_DIR/dts/upstream/src/arm64/qcom/sm8250-xiaomi-umi.dts"
install -m 0644 "$REPO_DIR/board/qualcomm/umi.config" "$SRC_DIR/board/qualcomm/umi.config"
install -m 0644 "$REPO_DIR/board/qualcomm/umi.env" "$SRC_DIR/board/qualcomm/umi.env"

PATCH="$REPO_DIR/patches/0001-save-prevbl-initrd-size.patch"
if git -C "$SRC_DIR" apply --check "$PATCH" 2>/dev/null; then
	say "Applying $PATCH"
	git -C "$SRC_DIR" apply "$PATCH"
elif grep -q prevbl_initrd_size "$SRC_DIR/arch/arm/lib/save_prev_bl_data.c"; then
	say "Patch already applied"
else
	echo "Cannot apply $PATCH to this U-Boot tree" >&2
	exit 1
fi

say "Configuring (qcom_defconfig + qcom-phone.config + umi.config)"
make -C "$SRC_DIR" O="$OUT_DIR" CROSS_COMPILE="$CROSS_COMPILE" \
	qcom_defconfig qcom-phone.config umi.config

say "Building with $JOBS jobs"
make -C "$SRC_DIR" O="$OUT_DIR" CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS"

for f in u-boot.bin u-boot.dtb; do
	[ -f "$OUT_DIR/$f" ] || { echo "missing $OUT_DIR/$f" >&2; exit 1; }
done

say "Locating mkbootimg"
if [ -z "$MKBOOTIMG" ]; then
	if command -v mkbootimg >/dev/null 2>&1; then
		MKBOOTIMG="$(command -v mkbootimg)"
	else
		if [ ! -f "$BUILD_DIR/mkbootimg/mkbootimg.py" ]; then
			git clone --depth 1 \
				https://android.googlesource.com/platform/system/tools/mkbootimg \
				"$BUILD_DIR/mkbootimg"
		fi
		MKBOOTIMG="$BUILD_DIR/mkbootimg/mkbootimg.py"
	fi
fi

say "Packing the Android boot image (header v1, appended DTB)"
gzip -9 -c "$OUT_DIR/u-boot.bin" > "$OUT_DIR/u-boot.bin.gz"
cat "$OUT_DIR/u-boot.bin.gz" "$OUT_DIR/u-boot.dtb" > "$OUT_DIR/u-boot-umi.bin.gz-dtb"

if [ -n "$PAYLOAD" ]; then
	[ -f "$PAYLOAD" ] || { echo "PAYLOAD not found: $PAYLOAD" >&2; exit 1; }
	RAMDISK="$PAYLOAD"
	say "Using EFI payload as ramdisk: $PAYLOAD ($(stat -c%s "$PAYLOAD") bytes)"
else
	RAMDISK="$BUILD_DIR/ramdisk"
	# The same five bytes Mu-Silicium uses: ABL only needs a non-empty
	# ramdisk to publish /chosen/linux,initrd-start.
	printf 'dummy' > "$RAMDISK"
fi

mkdir -p "$BUILD_DIR"
if [[ "$MKBOOTIMG" == *.py ]]; then
	python3 "$MKBOOTIMG" \
		--kernel "$OUT_DIR/u-boot-umi.bin.gz-dtb" \
		--ramdisk "$RAMDISK" \
		--header_version 1 \
		-o "$OUT_DIR/u-boot-umi.img"
else
	"$MKBOOTIMG" \
		--kernel "$OUT_DIR/u-boot-umi.bin.gz-dtb" \
		--ramdisk "$RAMDISK" \
		--header_version 1 \
		-o "$OUT_DIR/u-boot-umi.img"
fi

{
	echo "U-Boot tag:      $UBOOT_TAG"
	echo "Built:           $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "u-boot.bin:      $(stat -c%s "$OUT_DIR/u-boot.bin") bytes"
	echo "u-boot.dtb:      $(stat -c%s "$OUT_DIR/u-boot.dtb") bytes"
	echo "boot image:      $(stat -c%s "$OUT_DIR/u-boot-umi.img") bytes"
	echo "payload/ramdisk: $(stat -c%s "$RAMDISK") bytes"
	echo
	if command -v dtc >/dev/null 2>&1; then
		echo "DT compatible:"
		dtc -I dtb -O dts "$OUT_DIR/u-boot.dtb" 2>/dev/null \
			| grep -m1 -A2 '^/ {' || true
	fi
} > "$OUT_DIR/build-info.txt"

cat "$OUT_DIR/build-info.txt"
say "Done: $OUT_DIR/u-boot-umi.img"