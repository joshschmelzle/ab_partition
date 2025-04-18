#!/bin/bash -e
# ab_partition.sh - A/B partition script for WLAN Pi OS images
#
# Convert a standard WLAN Pi OS image to an A/B partition structure.
# Intended for system updates on WLAN Pi compute module eMMC devices.
# Created for bookworm based images.
#
# Usage: sudo ./ab_partition.sh <input> <output>
# Troubleshooting: sudo bash -x ./ab_partition.sh <input> <output>
#
# Requires: parted mount util-linux dosfstools rsync
#
# Version: v0.2
# Author: Josh Schmelzle
# License: BSD-3

function show_usage {
    echo "Usage: $0 <input> <output>"
    echo ""
    echo "Convert a standard WLAN Pi OS image to an A/B partition structure"
    echo ""
    echo "Arguments:"
    echo "  input    Path to original WLAN Pi OS image"
    echo "  output   Path where new A/B partitioned image will be saved"
    echo ""
    echo "Example:"
    echo "  $0 wlanpi-os-20250416-154720-lite.img wlanpi-os-20250416-154720-lite-AB-partitioned.img"
    exit 1
}

for cmd in parted losetup mkfs.ext4 mkfs.vfat rsync; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: required tool/cmd '$cmd' not found. Install and try again."
        exit 1
    fi
done

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: need root (sudo)."
    exit 1
fi

if [ "$#" -ne 2 ]; then
    show_usage
fi

echo "=== WLAN Pi A/B partition script ==="
echo ""

INPUT_IMAGE="$1"
OUTPUT_IMAGE="$2"

if [ ! -f "$INPUT_IMAGE" ]; then
    echo "Error: '$INPUT_IMAGE' not found."
    exit 1
fi

TEMP_DIR=$(mktemp -d)
ORIGINAL_BOOT="$TEMP_DIR/original_boot"
ORIGINAL_ROOT="$TEMP_DIR/original_root"
NEW_ROOTFS="$TEMP_DIR/new_rootfs"

cleanup() {  
  echo "Starting cleanup ..."
  (
    set +e
    if mountpoint -q "$NEW_ROOTFS/boot" 2>/dev/null; then umount "$NEW_ROOTFS/boot"; fi
    if mountpoint -q "$NEW_ROOTFS/home" 2>/dev/null; then umount "$NEW_ROOTFS/home"; fi
    if mountpoint -q "$NEW_ROOTFS" 2>/dev/null; then umount "$NEW_ROOTFS"; fi
    if mountpoint -q "$ORIGINAL_BOOT" 2>/dev/null; then umount "$ORIGINAL_BOOT"; fi
    if mountpoint -q "$ORIGINAL_ROOT" 2>/dev/null; then umount "$ORIGINAL_ROOT"; fi
    losetup -D
    rm -rf "$TEMP_DIR" 2>/dev/null || true
  )
  echo "Cleanup complete ..."
}
trap cleanup EXIT INT TERM

echo "Debug: creating temporary directories for mounting ..."
mkdir -p "$ORIGINAL_BOOT" "$ORIGINAL_ROOT" "$NEW_ROOTFS"

echo "Input image: $INPUT_IMAGE"
echo "Output image: $OUTPUT_IMAGE"
echo "Temp directory: $TEMP_DIR"

ORIGINAL_SIZE=$(stat -c%s "$INPUT_IMAGE")
echo "Original image size: $(( ORIGINAL_SIZE / 1024 / 1024 )) MB"

BOOT1_SIZE=$((256 * 1024 * 1024))          # 256 MB
ROOT1_SIZE=$((2500 * 1024 * 1024))         # 2.5 GB
BOOT2_SIZE="${BOOT1_SIZE}"
ROOT2_SIZE="${ROOT1_SIZE}"
HOME_MIN_SIZE=$((8 * 1024 * 1024))         # 8 MB
BUFFER_SIZE=$((32 * 1024 * 1024))          # 32 MB
ALIGN=$((1024 * 1024))

required_size=$ALIGN
required_size=$((required_size + BOOT1_SIZE))
required_size=$((required_size + ROOT1_SIZE))
required_size=$((required_size + BOOT2_SIZE))
required_size=$((required_size + ROOT2_SIZE))
required_size=$((required_size + HOME_MIN_SIZE))
required_size=$((required_size + BUFFER_SIZE))
required_size=$(((required_size + ALIGN - 1) / ALIGN * ALIGN )) # Align to boundary

echo "Required size: $((required_size / 1024 / 1024)) MB"
NEW_SIZE=$((required_size))

echo "Creating a copy of the original image ..."
if [ -f "$OUTPUT_IMAGE" ]; then
    echo "Warning: removing already existing output file ..."
    rm -f "$OUTPUT_IMAGE"
fi

echo "Copying image (${ORIGINAL_SIZE} bytes) ..."
cp "$INPUT_IMAGE" "$OUTPUT_IMAGE"

echo "Resizing image file ..."
truncate -s "$NEW_SIZE" "$OUTPUT_IMAGE"

echo "Mounting original image ..."
ORIG_LOOP_DEV=$(losetup --show -P -f "$INPUT_IMAGE")
trap 'losetup -d $ORIG_LOOP_DEV 2>/dev/null || true' EXIT

mount "${ORIG_LOOP_DEV}"p1 "$ORIGINAL_BOOT"
mount "${ORIG_LOOP_DEV}"p2 "$ORIGINAL_ROOT"
trap 'umount $ORIGINAL_BOOT 2>/dev/null || true; umount $ORIGINAL_ROOT 2>/dev/null || true; losetup -d $ORIG_LOOP_DEV 2>/dev/null || true' EXIT

ORIGINAL_BOOT_SIZE=$(du -s -B1 "$ORIGINAL_BOOT" | cut -f1)
ORIGINAL_ROOT_SIZE=$(du -s -B1 "$ORIGINAL_ROOT" | cut -f1)

echo "Original boot size: $(( ORIGINAL_BOOT_SIZE / 1024 / 1024 )) MB"
echo "Original root size: $(( ORIGINAL_ROOT_SIZE / 1024 / 1024 )) MB"

BOOT1_SIZE=$((ORIGINAL_BOOT_SIZE + 64 * 1024 * 1024)) # Original + 64MB margin
BOOT1_SIZE=$(((BOOT1_SIZE + ALIGN - 1) / ALIGN * ALIGN)) # Align to boundary
BOOT1_SIZE=$((BOOT1_SIZE < 256 * 1024 * 1024 ? 256 * 1024 * 1024 : BOOT1_SIZE)) # Min 256MB

ROOT1_SIZE=$((2500 * 1024 * 1024)) # ~2.5 size for root parts
ROOT1_SIZE=$(((ROOT1_SIZE + ALIGN - 1) / ALIGN * ALIGN)) # Align to boundary

BOOT2_SIZE=$BOOT1_SIZE
ROOT2_SIZE=$ROOT1_SIZE

total_needed=$((BOOT1_SIZE + ROOT1_SIZE + BOOT2_SIZE + ROOT2_SIZE + HOME_MIN_SIZE + BUFFER_SIZE))
total_needed=$(( (total_needed + ALIGN - 1) / ALIGN * ALIGN ))  # Align to boundary

echo "Total space needed for all partitions: $((total_needed / 1024 / 1024)) MB"

echo "Calculated partition sizes:"
echo "- Boot (A/B): $(( BOOT1_SIZE / 1024 / 1024 )) MB"
echo "- Root (A/B): $(( ROOT1_SIZE / 1024 / 1024 )) MB"
echo "- Min Home: $(( HOME_MIN_SIZE / 1024 / 1024 )) MB"
echo "- Buffer: $(( BUFFER_SIZE / 1024 / 1024 )) MB"

umount "$ORIGINAL_BOOT"
umount "$ORIGINAL_ROOT"
losetup -d "$ORIG_LOOP_DEV"
trap - EXIT

echo "Setting up loop device for the new image ..."
NEW_LOOP_DEV=$(losetup --show -P -f "$OUTPUT_IMAGE")
trap 'losetup -d $NEW_LOOP_DEV 2>/dev/null || true' EXIT

echo "Calculating partition positions ..."
SECTOR_SIZE=512 # Define in sectors (512 bytes each)
SECTORS_PER_MB=$((1024*1024 / SECTOR_SIZE))  # 2048 sectors per MB

p1_start=$((SECTORS_PER_MB * 1))  # Start at 1MB
p1_size=$((BOOT1_SIZE / SECTOR_SIZE))
p1_end=$((p1_start + p1_size - 1))

p2_start=$((p1_end + 1))
p2_start=$(((p2_start + SECTORS_PER_MB - 1) / SECTORS_PER_MB * SECTORS_PER_MB))  # Align to MB
p2_size=$((ROOT1_SIZE / SECTOR_SIZE))
p2_end=$((p2_start + p2_size - 1))

p3_start=$((p2_end + 1))
p3_start=$(((p3_start + SECTORS_PER_MB - 1) / SECTORS_PER_MB * SECTORS_PER_MB))  # Align to MB

echo "Verifying image size ..."
ACTUAL_SIZE=$(stat -c%s "$OUTPUT_IMAGE")
LAST_SECTOR=$((ACTUAL_SIZE / SECTOR_SIZE - 1))
echo "Actual image size: $((ACTUAL_SIZE / 1024 / 1024)) MB (sectors: $((ACTUAL_SIZE / SECTOR_SIZE)))"
echo "Last available sector: $LAST_SECTOR"

echo "Calculating logical partitions within extended partition ..."
lp1_start=$((p3_start + SECTORS_PER_MB)) # First lp starts 1 MB into extended partition
lp1_size=$((BOOT2_SIZE / SECTOR_SIZE))
lp1_end=$((lp1_start + lp1_size - 1))

lp2_start=$((lp1_end + SECTORS_PER_MB + 1)) # 1MB gap
lp2_size=$((ROOT2_SIZE / SECTOR_SIZE))
lp2_end=$((lp2_start + lp2_size - 1))

lp3_start=$((lp2_end + SECTORS_PER_MB + 1)) # 1MB gap
home_sectors=$((HOME_MIN_SIZE / SECTOR_SIZE))
lp3_end=$((lp3_start + home_sectors - 1))

if [ $lp3_end -ge $((LAST_SECTOR - SECTORS_PER_MB)) ]; then
    echo "Adjusting home partition size to fit within available space"
    lp3_end=$((LAST_SECTOR - SECTORS_PER_MB))
    if [ $lp3_end -le $lp3_start ]; then
        echo "Error: Not enough space for even minimal home partition"
        exit 1
    fi
fi

echo "Verifying partition calculations ..."
echo "p1: $p1_start -> $p1_end (size: $p1_size sectors)"
echo "p2: $p2_start -> $p2_end (size: $p2_size sectors)"
echo "p3: $p3_start -> $LAST_SECTOR"
echo "lp1: $lp1_start -> $lp1_end (size: $lp1_size sectors)"
echo "lp2: $lp2_start -> $lp2_end (size: $lp2_size sectors)"
echo "lp3: $lp3_start -> $lp3_end"

echo "Final image size verification ... Maybe (: ..."
if [ $lp3_end -ge $LAST_SECTOR ]; then
    echo "Error: partition layout exceeds image size!"
    echo "Last partition ends at sector $lp3_end, but image ends at $LAST_SECTOR"
    exit 1
fi

echo "Running parted ..."
parted --script "$OUTPUT_IMAGE" mklabel msdos
parted --script "$OUTPUT_IMAGE" unit s mkpart primary fat32 ${p1_start} ${p1_end} # Primary boot (A)
parted --script "$OUTPUT_IMAGE" unit s mkpart primary ext4 ${p2_start} ${p2_end} # Primary root (A)
parted --script "$OUTPUT_IMAGE" unit s mkpart extended ${p3_start} ${LAST_SECTOR}
parted --script "$OUTPUT_IMAGE" set 1 boot on

parted --script "$OUTPUT_IMAGE" unit s mkpart logical fat32 ${lp1_start} ${lp1_end} # Second boot (B)
parted --script "$OUTPUT_IMAGE" unit s mkpart logical ext4 ${lp2_start} ${lp2_end} # Second root (B)
parted --script "$OUTPUT_IMAGE" unit s mkpart logical ext4 ${lp3_start} ${lp3_end} # Home

partprobe "$NEW_LOOP_DEV"

echo "Waiting for logical partitions to appear..."
success=false
for i in {1..10}; do
    if [ -e "${NEW_LOOP_DEV}p5" ] && [ -e "${NEW_LOOP_DEV}p6" ] && [ -e "${NEW_LOOP_DEV}p7" ]; then
        echo "All logical partitions detected after $i attempts"
        success=true
        break
    fi
    echo "Waiting for partitions (attempt $i)..."
    sleep 1
    partprobe "$NEW_LOOP_DEV"
done

if [ "$success" = false ]; then
    echo "ERROR: Failed to detect logical partitions after 10 attempts"
    ls -la "${NEW_LOOP_DEV}"*
    exit 1
fi

echo "Giving the system three seconds to stabilize ..."
sleep 3

BOOT1_DEV="${NEW_LOOP_DEV}p1"
ROOT1_DEV="${NEW_LOOP_DEV}p2"
# p3 is the home/extended container; skipping.
BOOT2_DEV="${NEW_LOOP_DEV}p5"
ROOT2_DEV="${NEW_LOOP_DEV}p6"
HOME_DEV="${NEW_LOOP_DEV}p7" # /home is last partition so we can resize it to fill fs

echo "Formatting partitions ..."
if [ "$BOOT1_SIZE" -lt 134742016 ]; then
    FAT_SIZE=16
    echo "Fat size set to 16 ..."
else
    FAT_SIZE=32
    echo "Fat size set to 32 ..."
fi

mkfs.vfat -F "$FAT_SIZE" -n BOOTFS "${BOOT1_DEV}"
mkfs.ext4 -F -L ROOTFS "${ROOT1_DEV}" -O ^huge_file

mkfs.vfat -F "$FAT_SIZE" -n BOOT2FS "${BOOT2_DEV}"
mkfs.ext4 -F -L ROOTFS2 "${ROOT2_DEV}" -O ^huge_file
mkfs.ext4 -F -L HOME "${HOME_DEV}" -O ^huge_file

echo "Getting partition UUIDs ..."
BOOT1_PARTUUID=$(blkid -s PARTUUID -o value "${BOOT1_DEV}")
ROOT1_PARTUUID=$(blkid -s PARTUUID -o value "${ROOT1_DEV}")
BOOT2_PARTUUID=$(blkid -s PARTUUID -o value "${BOOT2_DEV}")
ROOT2_PARTUUID=$(blkid -s PARTUUID -o value "${ROOT2_DEV}")
HOME_PARTUUID=$(blkid -s PARTUUID -o value "${HOME_DEV}")
echo " - BOOT1: $BOOT1_PARTUUID"
echo " - ROOT1: $ROOT1_PARTUUID"
echo " - BOOT2: $BOOT2_PARTUUID"
echo " - ROOT2: $ROOT2_PARTUUID"
echo " - HOME: $HOME_PARTUUID"

echo "Re-mounting original image to copy content ..."
ORIG_LOOP_DEV=$(losetup --show -P -f "$INPUT_IMAGE")
mount "${ORIG_LOOP_DEV}"p1 "$ORIGINAL_BOOT"
mount "${ORIG_LOOP_DEV}"p2 "$ORIGINAL_ROOT"

echo "Mounting new partitions ..."
mount -v "${ROOT1_DEV}" "${NEW_ROOTFS}" -t ext4
mkdir -p "${NEW_ROOTFS}/boot"
mount -v "${BOOT1_DEV}" "${NEW_ROOTFS}/boot" -t vfat
mkdir -p "${NEW_ROOTFS}/home"
mount -v "${HOME_DEV}" "${NEW_ROOTFS}/home" -t ext4

echo "Copying root filesystem content ..."
rsync -aHAXx --exclude /boot "$ORIGINAL_ROOT/" "$NEW_ROOTFS/"
echo "Copying boot files ..."
cp -a "$ORIGINAL_BOOT"/* "$NEW_ROOTFS/boot/"

echo "Verifying critical boot files ..."
for file in start.elf fixup.dat wlanpi-kernel8.img bootcode.bin; do
    if ! cmp -s "$ORIGINAL_BOOT/$file" "$NEW_ROOTFS/boot/$file"; then
        echo "WARNING: $file may not have copied correctly. Trying direct copy ..."
        cp -a "$ORIGINAL_BOOT/$file" "$NEW_ROOTFS/boot/$file"
    fi
done

echo "Making sure kernel modules are owned by root ..."
chown -R root:root "$NEW_ROOTFS/lib/modules/"

echo "Updating bootloader configuration ..."
echo "Updating root parameter in cmdline.txt ..."
if [ -f "$NEW_ROOTFS/boot/cmdline.txt" ]; then
    cp "$NEW_ROOTFS/boot/cmdline.txt" "$NEW_ROOTFS/boot/cmdline.txt.bak"
    sed -i "s|root=[^ ]*|root=PARTUUID=${ROOT1_PARTUUID}|" "$NEW_ROOTFS/boot/cmdline.txt"

    cp "$NEW_ROOTFS/boot/cmdline.txt" "$NEW_ROOTFS/boot/cmdline-b.txt"
    sed -i "s|PARTUUID=${ROOT1_PARTUUID}|PARTUUID=${ROOT2_PARTUUID}|" "$NEW_ROOTFS/boot/cmdline-b.txt"

    echo ""
    echo "New cmdline.txt content:"
    cat "$NEW_ROOTFS/boot/cmdline.txt"
    echo ""
    echo "New cmdline-b.txt content:"
    cat "$NEW_ROOTFS/boot/cmdline-b.txt"
    echo ""
else
    echo "ERROR: cmdline.txt not found in boot directory!"
fi

echo "Checking for boot directory symlinks ..."
find "$ORIGINAL_ROOT/boot" -type l | while read -r symlink; do
    if [ -z "$symlink" ]; then
        continue
    fi
    
    target=$(readlink "$symlink")
    if [ -z "$target" ]; then
        continue
    fi
    
    filename=$(basename "$symlink")
    
    if [[ "$filename" == "overlays" && "$target" == "firmware/overlays" ]]; then
        if [ ! -d "$NEW_ROOTFS/boot/overlays" ]; then
            mkdir -p "$NEW_ROOTFS/boot/overlays"
            
            if [ -d "$ORIGINAL_BOOT/overlays" ]; then
                cp -a "$ORIGINAL_BOOT/overlays/"* "$NEW_ROOTFS/boot/overlays/"
                echo "Created overlays directory with content from original boot"
            fi
        fi
        continue
    fi
    
    if [[ "$target" == *"firmware"* ]]; then
        echo "WARNING: Skipping firmware-related symlink: $filename -> $target"
        continue
    fi
    
    source_file="$NEW_ROOTFS/boot/$target"
    dest_file="$NEW_ROOTFS/boot/$filename"
    
    if [ -f "$source_file" ]; then
        cp -a "$source_file" "$dest_file"
        echo "Copied file instead of symlink: $filename <- $target"
    else
        echo "Not copying: $filename -> $target (target not found)"
    fi
done

echo "Ensuring the overlay directory exists ..."
if [ ! -d "$NEW_ROOTFS/boot/overlays" ] && [ -d "$ORIGINAL_BOOT/overlays" ]; then
    mkdir -p "$NEW_ROOTFS/boot/overlays"
    cp -a "$ORIGINAL_BOOT/overlays/"* "$NEW_ROOTFS/boot/overlays/"
    echo "Ensured overlays directory exists with proper content"
fi

echo "Setting up A/B boot configuration ..."
cat > "$NEW_ROOTFS/boot/autoboot.txt" << EOF
boot_partition=0
tryboot_a_b=1
EOF

cat > "$NEW_ROOTFS/boot/tryboot.txt" << EOF
# This configuration will be used when booting in tryboot mode
# Point to the B partitions
kernel=wlanpi-kernel8.img
os_prefix=5:/
cmdline=cmdline-b.txt
EOF

echo "Updating fstab for new partition layout ..."
cat > "$NEW_ROOTFS/etc/fstab" << EOF
PARTUUID=${ROOT1_PARTUUID}  /        ext4    defaults,noatime  0  1
PARTUUID=${BOOT1_PARTUUID}  /boot    vfat    defaults          0  2
PARTUUID=${HOME_PARTUUID}   /home    ext4    defaults,noatime  0  2
EOF

echo "Creating home partition expansion script ..."
mkdir -p "$NEW_ROOTFS/usr/local/sbin"
cat > "$NEW_ROOTFS/usr/local/sbin/expand-home-partition" << 'EOF'
#!/bin/bash

# First boot script to expand the home partition 

if [ -f /etc/home-partition-expanded ]; then
    echo "Home partition already expanded ... exiting..."
    exit 0
fi

echo "Starting home partition expansion ..."

DEVICE=$(findmnt -n -o SOURCE /home | sed 's/p[0-9]\+$//')
HOME_PART=$(findmnt -n -o SOURCE /home)
EXTENDED_PART="${DEVICE}p3"
TOTAL_SECTORS=$(fdisk -l $DEVICE | grep "sectors$" | awk '{print $7}')

echo "Unmounting home partition ..."
umount /home

echo "Resizing extended partition to fill disk ..."
parted -s $DEVICE unit s resizepart 3 $((TOTAL_SECTORS - 2048))

echo "Updating partition table ..."
partprobe $DEVICE
sleep 2

echo "Expanding home partition to fill extended partition..."
EXTENDED_END=$(fdisk -l $DEVICE | grep "$(basename $EXTENDED_PART)" | awk '{print $3}')
echo "Extended partition now ends at: $EXTENDED_END"

parted -s $DEVICE unit s resizepart 7 $((EXTENDED_END - 2048))

echo "Updating partition table (again) ..."
partprobe $DEVICE
sleep 2

echo "Checking and resizing filesystem ..."
e2fsck -fy $HOME_PART
resize2fs $HOME_PART

echo "Remounting home partition ..."
mount $HOME_PART /home

echo "Expansion complete (hopefully!) ..."
df -h /home
fdisk -l $DEVICE
EOF

chmod +x "$NEW_ROOTFS/usr/local/sbin/expand-home-partition"

mkdir -p "$NEW_ROOTFS/etc/systemd/system"
cat > "$NEW_ROOTFS/etc/systemd/system/expand-home-partition.service" << EOF
[Unit]
Description=Expand home partition to fill remaining disk
After=local-fs.target
ConditionPathExists=!/etc/home-partition-expanded

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/expand-home-partition
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

mkdir -p "$NEW_ROOTFS/etc/systemd/system/multi-user.target.wants"
ln -sf "/etc/systemd/system/expand-home-partition.service" "$NEW_ROOTFS/etc/systemd/system/multi-user.target.wants/expand-home-partition.service"

echo "Verifying final image integrity ..."
if [ ! -f "$NEW_ROOTFS/boot/config.txt" ] || [ ! -f "$NEW_ROOTFS/boot/cmdline.txt" ] || [ ! -f "$NEW_ROOTFS/boot/wlanpi-kernel8.img" ]; then
  echo "ERROR: critical boot files missing ..."
  exit 1
fi

if ! grep -q "PARTUUID=${ROOT1_PARTUUID}" "$NEW_ROOTFS/boot/cmdline.txt"; then
  echo "ERROR: root partition label not set in cmdline.txt ..."
  exit 1
fi

echo "Unmounting and cleaning up..."
sync
if mountpoint -q "$NEW_ROOTFS/boot"; then
  umount "$NEW_ROOTFS/boot"
fi
if mountpoint -q "$NEW_ROOTFS/home"; then
  umount "$NEW_ROOTFS/home"
fi
if mountpoint -q "$NEW_ROOTFS"; then
  umount "$NEW_ROOTFS"
fi
if mountpoint -q "$ORIGINAL_BOOT"; then
  umount "$ORIGINAL_BOOT"
fi
if mountpoint -q "$ORIGINAL_ROOT"; then
  umount "$ORIGINAL_ROOT"
fi
if [ -n "$ORIG_LOOP_DEV" ] && losetup -a | grep -q "$ORIG_LOOP_DEV"; then
  losetup -d "$ORIG_LOOP_DEV"
fi
if [ -n "$NEW_LOOP_DEV" ] && losetup -a | grep -q "$NEW_LOOP_DEV"; then
  losetup -d "$NEW_LOOP_DEV"
fi
sleep 1
rm -rf "$TEMP_DIR" || {
  echo "Warning: some resources still busy, trying lazy unmount ..."
  for mnt in "$NEW_ROOTFS/boot" "$NEW_ROOTFS/home" "$NEW_ROOTFS"; do
    mountpoint -q "$mnt" && umount -l "$mnt"
  done
  sleep 1
  rm -rf "$TEMP_DIR" || echo "Warning: could not fully clean up temp directory"
}

echo "Calculating SHA-256 hash for $OUTPUT_IMAGE ..."
HASH=$(sha256sum "$OUTPUT_IMAGE")
echo "$HASH" > "$OUTPUT_IMAGE".sha256
HASH_ONLY=$(echo "$HASH" | awk '{print $1}')

echo ""
echo "====================================="
echo "A/B partitioned image created successfully!"
echo "Output image: $OUTPUT_IMAGE"
echo "SHA-256 hash: $HASH_ONLY"
echo ""
echo "Verify integrity with: sha256sum --check ""$OUTPUT_IMAGE"".sha256"
echo ""
echo "The image has the following partition structure:"
echo "1: BOOTFS   - Primary boot partition (A)"
echo "2: ROOTFS   - Primary root partition (A)"
echo "3: Extended partition container for additional logical partitions"
echo "  - 5: BOOT2FS  - Secondary boot partition (B)"
echo "  - 6: ROOT2FS  - Secondary root partition (B)"
echo "  - 7: HOME     - Home partition (automatically expanded on first boot)"
echo ""
echo "Partition structure is optimized for CM4s with 8GB of disk"
echo "====================================="
