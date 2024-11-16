#!/bin/bash

# Define default variables
ROOT=/mnt

# Ask for keymap
keymapsetup() {
    read -p "What keymap do you want? -> " keymap
    if ! localectl list-keymaps | grep -q "^$keymap$"; then
        echo "Error: '$keymap' is not a valid keymap"
        keymapsetup
    else
        loadkeys $keymap
    fi
}
keymapsetup

choicePart() {
    # Ask how to partition disk
    echo "How would you like to partition the disk?"
    echo "1) Use entire disk with EFI"
    echo "2) Supply custom partition values"
    read -p "Enter your choice (1-2) -> " choice

    case $choice in
        1)
            # Get device name
            lsblk
            read -p "Enter device name (e.g., sda, nvme0n1) -> " devname
            
            if [[ $devname == nvme* ]]; then
                devpath="/dev/${devname}"
                EFI="/dev/${devname}p1"
                ROOTDEV="/dev/${devname}p2"
            else
                devpath="/dev/${devname}"
                EFI="/dev/${devname}1"
                ROOTDEV="/dev/${devname}2"
            fi

            # Confirm device selection
            echo "Selected device: $devpath"
            echo "EFI partition will be: $EFI"
            echo "Root partition will be: $ROOTDEV"
            read -p "Is this correct? (y/n) -> " confirm
            
            if [[ $confirm != "y" ]]; then
                echo "Aborting. Please try again."
                choicePart
                return
            fi

            # Create EFI partition and root partition
            parted $devpath -- mklabel gpt
            parted $devpath -- mkpart ESP fat32 1MiB 513MiB
            parted $devpath -- set 1 esp on
            parted $devpath -- mkpart primary ext4 513MiB 100%
            mkfs.fat -F32 $EFI
            mkfs.ext4 $ROOTDEV
            mount $ROOTDEV $ROOT
            mkdir -p $ROOT/boot/efi
            mount $EFI $ROOT/boot/efi
            ;;
        2)
            lsblk
            read -p "Enter EFI partition (e.g., /dev/sda1) or press Enter to skip -> " EFI
            read -p "Enter root partition (e.g., /dev/sda2) -> " ROOTDEV
            
            if [ ! -z "$EFI" ]; then
                read -p "Format EFI partition? (y/n) -> " format_efi
                read -p "Format root partition? (y/n) -> " format_root
                
                if [[ $format_efi == "y" ]]; then
                    mkfs.fat -F32 $EFI
                fi
                if [[ $format_root == "y" ]]; then
                    mkfs.ext4 $ROOTDEV
                fi
                
                mount $ROOTDEV $ROOT
                mkdir -p $ROOT/boot/efi
                mount $EFI $ROOT/boot/efi
            else
                read -p "Format root partition? (y/n) -> " format_root
                if [[ $format_root == "y" ]]; then
                    mkfs.ext4 $ROOTDEV
                fi
                mount $ROOTDEV $ROOT
            fi
            ;;
        *)
            echo "Invalid choice."
            choicePart
            ;;
    esac
}

choicePart

# Create and enable swap file
dd if=/dev/zero of=$ROOT/swap.img bs=1M count=4096
chmod 600 $ROOT/swap.img
mkswap $ROOT/swap.img
swapon $ROOT/swap.img

# Use pacstrap to setup base packages 
pacstrap $ROOT base linux linux-firmware grub efibootmgr amd-ucode intel-ucode \
    networkmanager modemmanager nano plasma kde-applications man-db man-pages \
    texinfo sudo ntp sddm git base-devel

# Generate fstab
genfstab -U $ROOT >> $ROOT/etc/fstab

# Setup chroot environment
chroot="arch-chroot $ROOT"

# Configure system in chroot
$chroot ln -sf /usr/share/zoneinfo/Europe/London /etc/localtime
$chroot hwclock --systohc

# Configure locale
echo "en_GB.UTF-8 UTF-8" >> $ROOT/etc/locale.gen
$chroot locale-gen
echo "Modify /etc/locale.gen if you need additional locales."
sleep 2
nano $ROOT/etc/locale.gen

# Set hostname
read -p "Type hostname for current system here -> " hostname
echo "$hostname" > $ROOT/etc/hostname

# Set locale and keymap
echo "LANG=en_GB.UTF-8" > $ROOT/etc/locale.conf
echo "KEYMAP=$keymap" > $ROOT/etc/vconsole.conf

# Set root password
echo "Set password for root below."
$chroot passwd

# Create user and set password
$chroot useradd -m -G wheel,video,audio,storage -s /bin/bash ks
echo "Set password for ks below."
$chroot passwd ks

# Configure sudo
echo "%wheel ALL=(ALL:ALL) ALL" >> $ROOT/etc/sudoers.d/wheel

# Configure NTP
cat > $ROOT/etc/ntp.conf << EOF
# Please consider joining the pool:
#     http://www.pool.ntp.org/join.html
#
# For additional information see:
# - https://wiki.archlinux.org/index.php/Network_Time_Protocol_daemon
# - http://support.ntp.org/bin/view/Support/GettingStarted
# - the ntp.conf man page

server 0.pool.ntp.org
server 1.pool.ntp.org
server 2.pool.ntp.org
server 3.pool.ntp.org

restrict default kod limited nomodify nopeer noquery notrap
restrict -6 default kod limited nomodify nopeer noquery notrap
restrict 127.0.0.1
restrict -6 ::1

driftfile /var/lib/ntp/ntp.drift
leapfile /usr/share/zoneinfo/leap-seconds.list
tos orphan 15
EOF

# Install and configure bootloader
$chroot grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
$chroot grub-mkconfig -o /boot/grub/grub.cfg

# Enable services
$chroot systemctl enable NetworkManager
$chroot systemctl enable sddm
$chroot systemctl enable ntpd

# Mount tmpfs for building AUR packages
mount -t tmpfs tmpfs $ROOT/tmp

# Create temporary install script for paru
cat > $ROOT/tmp/install-paru.sh << EOF
#!/bin/bash
cd /tmp
git clone https://aur.archlinux.org/paru.git
cd paru
makepkg -si --noconfirm
EOF

# Make script executable and run as user
chmod 755 $ROOT/tmp/install-paru.sh 
$chroot sudo -u ks /tmp/install-paru.sh

# Clean up
rm -f $ROOT/tmp/install-paru.sh

# Optional chroot
read -p "Additional chroot needed? Press any key+enter for yes, or just enter for no -> " chrootneeded
if [ -n "$chrootneeded" ]; then
    echo "Chrooting in!"
    arch-chroot $ROOT
fi
