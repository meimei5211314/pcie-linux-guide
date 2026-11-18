#!/bin/bash
# entrypoint.sh —— 在容器内构建 guest 内核环境并启动 QEMU(TCG 软件模拟)
# 用法：./entrypoint.sh
# 注意：本脚本默认下载一个 Ubuntu 通用内核做 guest。归档 URL/文件名可能随时间变化，
#       若抓取失败，请手动放置一个 vmlinuz 到 ./guest/ 再重试（脚本会检测到并跳过下载）。
set -e

GUEST_DIR=/work/guest
mkdir -p "$GUEST_DIR" && cd "$GUEST_DIR"

# ---------- 1. 获取 guest 内核 vmlinuz ----------
VMLINUZ=""
if [ -f "$GUEST_DIR/vmlinuz" ]; then
    VMLINUZ="$GUEST_DIR/vmlinuz"
    echo "[1/3] 使用已存在的 $VMLINUZ"
else
    echo "[1/3] 尝试下载 Ubuntu 通用内核 ..."
    KERNEL_REL="$(uname -r 2>/dev/null || echo 5.15.0-70-generic)"
    BASE=http://archive.ubuntu.com/ubuntu/pool/main/l/linux
    # 在归档目录里找一个 linux-image-*-generic 的 deb
    DEB=$(curl -s "$BASE/" | grep -oE 'linux-image-[0-9.]+-generic_[0-9.]+-[0-9]+_amd64\.deb' | head -n1 || true)
    if [ -n "$DEB" ]; then
        curl -sO "$BASE/$DEB"
        dpkg-deb -x "$DEB" extract
        VMLINUZ=$(find extract -name vmlinuz | head -n1)
    fi
    if [ -z "${VMLINUZ:-}" ]; then
        echo "!! 未能自动获取内核。请手动放置 vmlinuz 到 $GUEST_DIR/vmlinuz 后重试。"
        echo "   提示：可从任意已有 Linux 的 /boot/vmlinuz-* 拷一个（版本不限，guest 内一致即可）。"
        exit 1
    fi
fi

# ---------- 2. 做一个最小 initramfs ----------
echo "[2/3] 构建最小 initramfs（busybox + 必要库）..."
mkdir -p initramfs/bin initramfs/proc initramfs/sys initramfs/dev initramfs/etc
cp /bin/busybox initramfs/bin/
chroot initramfs /bin/busybox --install -s 2>/dev/null || true
for d in /lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu /lib64; do
    cp -a "$d" "initramfs$d" 2>/dev/null || true
done
( cd initramfs && find . | cpio -o -H newc | gzip ) > initramfs.img

# ---------- 3. 启动 QEMU（TCG，纯软件模拟，无需 KVM）----------
echo "[3/3] 启动 QEMU (TCG, -device pci-testdev) ..."
echo "    guest 起来后在串口 shell 里执行: lspci -nn | grep -i test"
exec qemu-system-x86_64 \
    -m 512M -smp 1 \
    -kernel "$VMLINUZ" \
    -initrd initramfs.img \
    -append "console=ttyS0 rdinit=/bin/sh" \
    -device pci-testdev \
    -nographic
