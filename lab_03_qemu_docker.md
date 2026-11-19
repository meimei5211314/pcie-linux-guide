---
tags: [动手实验, QEMU, Docker, 虚拟化]
aliases: [Lab03, DockerQEMU]
created: 2026-11-18
status: 未开始
---

# Lab 03 · Docker + QEMU：一键可复现的 PCIe 实验环境

> **前置**：[[lab_02_qemu]]（先理解 QEMU 本身）　|　**配套文件**：`docker/`　|　**排错**：[[troubleshooting]]　|　**进度**：[[学习进度追踪]]

> **目标**：把整套"QEMU 模拟 PCIe 设备"的实验装进一个 Docker 容器，做到 **`docker build` + `docker run` 一键复现**，任何机器上都不踩环境坑。
>
> **本方案结构（三层，务必先看懂）**：
> ```
> 第1层  宿主机（你的机器，跑 Docker）
>   └─ 第2层  Docker 容器（Ubuntu + QEMU + gcc + 内核头文件）
>        └─ 第3层  QEMU 虚拟机（独立 Linux 内核 + PCIe 总线 + pci-testdev）
>                                ↑ 你的驱动在这层编译、加载、probe
> ```
> **可行性关键**：容器虽无独立内核，但是完整 Linux 用户态，能装能编能跑 QEMU；QEMU(TCG) 自带独立 guest 内核和 PCIe。两者职责分开，互不冲突。

---

## 一、为什么用 Docker（和 lab_02 的关系）

| | lab_02（宿主机直接跑 QEMU） | lab_03（本篇，Docker 里跑 QEMU） |
|---|---|---|
| 环境一致性 | 依赖你机器现状，换机器易踩坑 | Dockerfile 固定，**任何机器一致** |
| 可复现/分享 | 手动配 | 一键 `docker build/run`，方便给别人复现 |
| 隔离 | 直接动宿主机 | 不污染宿主机 |
| 速度 | 可用 KVM 加速 | 纯 TCG（慢，但练 probe/BAR 够用） |

> 本篇是 lab_02 的 **Docker 化 + 可复现版**。如果 lab_02 你已经在宿主机跑通了，本篇主要是把环境"容器化固化"，方便带走和分享。

---

## 二、文件准备

在本目录（`pcie-linux-guide/`）新建一个子目录 `docker/`，放 3 个文件：

### 1. `docker/Dockerfile`

```dockerfile
# 基础镜像：Ubuntu 22.04（含 QEMU、gcc、内核头文件所需工具）
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# 装 QEMU + 编译工具链 + 一些调试/实验工具
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential gcc make \
    qemu-system-x86 qemu-utils \
    pciutils kmod \
    linux-headers-generic \
    wget cpio gzip xz-utils \
    gdb curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# 工作目录：把学习包挂载/拷进这里
WORKDIR /work

# 不在镜像里 COPY 代码：构建上下文是 docker/ 本身，
# 代码通过 docker run -v 挂载进 /work，改完即时生效。
# （若你确实想 COPY 代码进镜像，必须把构建上下文改成仓库根目录：
#    docker build -t pcie-lab -f docker/Dockerfile .  ）

# 默认进入交互 shell
CMD ["/bin/bash"]
```

### 2. `docker/entrypoint.sh`（一键起 QEMU guest 的脚本）

```bash
#!/bin/bash
# entrypoint.sh —— 在容器内构建 guest 内核环境并启动 QEMU(TCG)
# 用法：./entrypoint.sh
set -e

GUEST_DIR=/work/guest
mkdir -p $GUEST_DIR && cd $GUEST_DIR

echo "[1/3] 获取一个小型 guest 内核 + initramfs ..."
# 说明：这里下载一个通用的 Ubuntu 内核 deb 提取 vmlinuz，再做一个最小 initramfs。
#       生产实验建议换成你顺手的发行版内核。以实际可用 URL 为准。
KERNEL_DEB=$(curl -s http://archive.ubuntu.com/ubuntu/pool/main/l/linux/ \
             | grep -oE 'linux-image-[0-9.]+-generic_[0-9.]+-[0-9]+_amd64.deb' | head -n1 || true)
if [ -z "$KERNEL_DEB" ]; then
  echo "!! 未能自动获取内核 deb。请手动放置 vmlinuz 到 $GUEST_DIR 再重试。"
  echo "   提示：也可从你已有的虚拟机/系统 /boot/vmlinuz-* 直接拷一个来用。"
  exit 1
fi
curl -sO http://archive.ubuntu.com/ubuntu/pool/main/l/linux/$KERNEL_DEB
dpkg-deb -x $KERNEL_DEB extract
VMLINUZ=$(find extract -name vmlinuz | head -n1)

echo "[2/3] 做一个最小 initramfs（含 pciutils/kmod）..."
# 极简 initramfs：只为让 guest 能起来、能看到 PCIe。生产请用完整发行版 initramfs。
mkdir -p initramfs/{bin,sbin,lib,proc,sys,dev,etc}
cp /bin/busybox initramfs/bin/ 2>/dev/null || apt-get install -y busybox-static
cp /bin/busybox initramfs/bin/
chroot initramfs /bin/busybox --install -s 2>/dev/null || true
for d in /lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu; do
  cp -a $d initramfs$d 2>/dev/null || true
done
(cd initramfs && find . | cpio -o -H newc | gzip) > initramfs.img

echo "[3/3] 启动 QEMU (TCG 软件模拟，无需 KVM) ..."
exec qemu-system-x86_64 \
    -m 512M -smp 1 \
    -kernel $VMLINUZ \
    -initrd initramfs.img \
    -append "console=ttyS0 rdinit=/bin/sh" \
    -device pci-testdev \
    -nographic
```

### 3. `docker/README.md`（简短用法）

见下方"三、一键运行"。

---

## 三、一键运行

```bash
cd pcie-linux-guide/docker

# 构建镜像（首次较慢，装 QEMU+工具链）
docker build -t pcie-lab .

# 起容器（挂载学习包，方便改代码即时生效）
docker run -it --name pcie-lab \
    -v $(pwd)/..:/work \
    pcie-lab bash
```

进容器后：
```bash
# 确认 QEMU 和工具链就位
qemu-system-x86_64 --version
gcc --version

# 启动带 pci-testdev 的 guest（TCG，无需 KVM）
chmod +x entrypoint.sh && ./entrypoint.sh
```

guest 起来后（你会看到串口 shell），在里面：
```bash
lspci -nn | grep -i test
# 典型：00:04.0 ... PCI Test Device [1b36:0005]
#      ↑ 以你实际输出为准，不要硬抄
```

---

## 四、在 guest 里编译加载驱动（保证内核版本一致）

**关键铁律**：驱动 `.ko` 必须用**第3层 guest 内核**的头文件编译，**不能**用第2层容器的 `uname -r`。

最稳做法——**在 guest 里装它自己版本的 headers 再编译**：

```bash
# guest 内（假设 guest 起来后有完整环境；最小 initramfs 下需在容器侧交叉编译，见下方"两条路线"）
lspci -nn                     # 记下 pci-testdev 的 [厂商:设备]
```

### 两条编译路线（按你 initramfs 完整度选）

**路线 A（推荐，最省心）**：guest 用完整发行版
- 不用极简 initramfs，而是挂一个完整 Ubuntu rootfs。guest 内 `apt install linux-headers-$(uname -r)`，再 `make module` + `insmod`。
- 优点：版本天然一致，工具齐全。缺点：rootfs 大、启动慢。

**路线 B（轻量，要交叉编译）**：guest 用极简 initramfs（本脚本默认）
- 在**第2层容器**里，用**对应 guest 内核版本**的 headers 交叉编译：
  ```bash
  # 容器内：拿到和 guest vmlinuz 同版本的 headers，编译时指定 KDIR
  make module KDIR=/path/to/guest-kernel-build
  ```
- 再把 `.ko` 传进 guest 加载。版本必须严格匹配，否则 `Invalid module format`。

> 想省事就直接走路线 A。本实验主线（probe `pci-testdev` + 映射 BAR）在路线 A 下最顺。

---

## 五、常见卡点

| 现象 | 原因 | 解决 |
|------|------|------|
| `docker build` 里装 headers 失败 | `linux-headers-generic` 和运行内核无关，树外编译需匹配 guest 内核 | 编译放进 guest（路线 A），或按 guest 版本装对应 headers |
| `entrypoint.sh` 抓不到内核 deb | 归档 URL/文件名变了 | 手动放一个 `vmlinuz` 到 `guest/`，或改脚本里的内核来源 |
| guest 起来 `lspci` 没有 testdev | `-device pci-testdev` 没生效 / QEMU 太老 | 核对启动命令；`qemu-system-x86_64 --version` |
| ID 和文档不一样 | QEMU 版本差异 | **以 `lspci -nn` 实际输出为准** |
| 加载 `.ko` 报 `Invalid module format` | 编译用的内核头 ≠ guest 内核版本 | 走路线 A，在 guest 内编译 |
| 容器里想用 KVM | 需 `--device /dev/kvm` + 宿主支持（嵌套虚拟化） | 没有就纯 TCG；Docker 嵌套 VM 时 KVM 常不可用 |
| TCG 太慢 | 软件模拟指令 | 练轻量流程够用；要速度用宿主机 QEMU+KVM（lab_02） |

---

## 六、自检

- [ ] `docker build -t pcie-lab .` 成功
- [ ] 容器内 `qemu-system-x86_64 --version`、`gcc --version` 正常
- [ ] `./entrypoint.sh` 能起一个带 `pci-testdev` 的 guest
- [ ] guest 里 `lspci -nn` 看到测试设备（ID 以实际为准）
- [ ] 理解三层结构，以及"驱动必须在 guest 内核版本下编译"这条铁律
- [ ] 知道本方案是纯 TCG、跑的是虚拟设备，真实 PCIe 直通不是它的强项

## 七、和其它 lab 的衔接

- 本篇是 **lab_02（QEMU）的 Docker 化**。不熟悉 QEMU 部分先看 lab_02。
- guest 里跑通后，按 lab_02 的玩法 B 体验真实中断（换 e1000 网卡）。
- 想跑完整 DMA 闭环（首字节=0xA5），需自写 QEMU 设备模型（见 lab_02 文末），本包列为选做。

> 心法：Docker 负责"环境固化可复现"，QEMU 负责"造带 PCIe 的虚拟机"，guest 负责"跑你的驱动"。三层各司其职，唯一铁律是**内核版本匹配**。

---

## 🔗 关联笔记

- **前置**：[[lab_02_qemu]]（先在宿主机跑通 QEMU，再用本篇 Docker 化）
- **配套文件**：`docker/Dockerfile`、`docker/entrypoint.sh`、`docker/README.md`
- **排错**：[[troubleshooting]]
- **返回**：[[00_首页MOC]]　**进度**：[[学习进度追踪]]

## 📝 我的实验记录

- **YYYY-MM-DD**：（Docker 版本 / 是否走通路线 A / 结果）
