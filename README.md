# initramfs-ps4
 Custom Initramfs for PS4. (based on better-initramfs)
# Features:
1. internal and external in one
2. fixed automatic script
3. auto eject disc (incase it breaks internal)
4. has ext4 formatting capability
5. uses distro.tar.xz instead of psxitarch.tar.xz
6. edid fix

# How to run:
On a Linux host, run `./scripts/bake.sh`. It produces `dist/initramfs.cpio.gz`. Local builds do not include the private firmware required for Vulkan.

The source tree is split into `rootfs/` (the files packed into the initramfs), `scripts/` (host-side build and QEMU tools), `assets/` (the local kernel), and `dist/` (generated archives).

The PS4 loader must add `/key/eap_hdd_key.bin` to the initramfs. The internal drive can not be opened without it.

...Or download from releases https://github.com/GattoDev-debug/initramfs-ps4/releases/latest

# Bootargs

options for initramfs in bootargs.txt:

`quiet` - disables output (most)

`debug` - enables on-screen kernel logging

`setupnet` - auto set up net on boot

`noboot` - prevents auto booting into system

format:

`initramfs=option1,option2,etc...`

for example

`initramfs=quiet,debug,setupnet,noboot`

this will enable no output, on screen kernel logging, automatic internet setup, and no automatic boot