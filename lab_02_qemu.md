---
tags: [动手实验, QEMU, 虚拟化, PCIe]
aliases: [Lab02, QEMU实验]
created: 2026-11-18
status: 未开始
---

# Lab 02 · 用 QEMU 模拟 PCIe 设备做实验（完全无硬件）

> **前置**：[[02_Linux_PCIe驱动开发]]　|　**Docker版**：[[lab_03_qemu_docker]]　|　**排错**：[[troubleshooting]]　|　**进度**：[[学习进度追踪]]

> **目标**：不用任何真实 PCIe 卡，在一台 x86 Linux 上用 QEMU 起一个带 PCIe 设备的虚拟机，让你的驱动在虚拟机里真正 `probe` 到设备、映射 BAR、（可选）走中断。这是"完全无硬件"也能跑通 probe 链路的最可靠路径。
>
> **两种玩法**：
> - **玩法 A（推荐入门）**：用 QEMU 现成的测试设备 `pci-testdev`，跑通"看到自定义设备被 probe"。
> - **玩法 B（进阶）**：改驱动去 probe 一个 QEMU 里现成的**真实语义**设备（如 `e1000` 网卡），体验完整的"映射 BAR → 读寄存器 → 收 MSI-X 中断"。

---

## 一、为什么 QEMU 是零基础最好的练习场

- **安全**：设备是虚拟的，驱动写错了最多虚拟机崩，不会烧卡、不会断你真实网络、不会 panic 宿主机。
- **可重复**：一条命令随时重置，随便折腾。
- **可观测**：能配合 GDB 单步跟驱动、看寄存器、看中断。
- **覆盖 probe→BAR→中断全链路**：比"只读文档"和"只敢在真机上精简版"都更能练手。

**局限**：QEMU 模拟不出真实硬件的时序、带宽、DMA 描述符环的真实行为。所以 QEMU 适合**练驱动框架和流程**，真实性能/DMA 调优仍需真硬件。

---

## 二、玩法 A：用 `pci-testdev`（最省事）

`pci-testdev` 是 QEMU 自带的 PCIe 测试设备，就是为"内核/驱动测试"造的，天生适合练手。

### 1. 准备一个能跑的虚拟机磁盘

最简单是直接用云上/本地的 Ubuntu 云镜像做无盘启动（cloud image），或复用你已有的虚拟机磁盘。下面以"现成 Ubuntu 云镜像 + cloud-init"为例，命令在**宿主机**执行：

```bash
# 安装 QEMU（宿主机）
sudo apt install qemu-system-x86 ovmf

# 下载一个 Ubuntu cloud image（示例；换成你顺手的镜像也行）
wget https://cloud-images.ubuntu.com/release/22.04/release/ubuntu-22.04-server-cloudimg-amd64.img -O disk.qcow2

# 做个可写的副本
qemu-img create -f qcow2 -F qcow2 -b disk.qcow2 disk-work.qcow2
```

> 第一次跑 cloud image 需要配套 cloud-init 注入用户名/密码/SSH key，否则进不去。为降低门槛，**建议直接用你已经能登录的桌面版 Ubuntu ISO 装一个虚拟机**，跳过 cloud-init 折腾。下面步骤在任何能跑的 Ubuntu 虚拟机里都一样。

### 2. 启动 QEMU，挂上 `pci-testdev`

```bash
qemu-system-x86_64 \
  -enable-kvm -m 2G -smp 2 \
  -drive file=disk-work.qcow2,if=virtio,format=qcow2 \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -device pci-testdev \
  -nographic
```

关键就是这一行：`-device pci-testdev`。启动后进虚拟机。

### 3. 在虚拟机里确认设备存在

```bash
lspci -nn | grep -i test
# 典型输出：
# 00:04.0 Class 00ff: Red Hat, Inc. PCI Test Device [1b36:0005]
#                              厂商ID ──────┘       └── 设备ID
```

> ⚠️ `1b36:0005` 是 `pci-testdev` 的 ID，请以你虚拟机里 `lspci -nn` 的**实际输出**为准——不同 QEMU 版本/配置下 ID 可能不同。**不要硬抄本文的 ID，以 `lspci -nn` 为准**。

### 4. 把驱动的 ID 改成它的 ID 并 probe

在虚拟机里，把 `code/pci_skeleton.c` 改成（用你上一步查到的真实 ID）：

```c
#define MY_VENDOR_ID  0x1b36   /* pci-testdev，按实际改 */
#define MY_DEVICE_ID  0x0005
```

编译加载（虚拟机里）：

```bash
sudo apt install build-essential linux-headers-$(uname -r)
make module
sudo insmod pci_skeleton.ko
dmesg | tail
```

**成功的预期输出**：
```
pci_skel 0000:00:04.0: BAR0 mapped at 0x..., device id=0x...
pci_skel 0000:00:04.0: probed ok, irq=..., /dev/pci_skelXX, dma_addr=0x...
```

🎉 这一步跑通，说明你的驱动在**一个有真实 PCI 枚举的虚拟机**里完成了 probe→BAR 映射。这是"零硬件"能拿到的最扎实成果。

### 5. 关于 `pci-testdev` 的寄存器/中断（重要提醒）

`pci-testdev` 的 BAR 布局、寄存器含义、是否支持 MSI-X，**随 QEMU 版本而变**。所以：

- **不要假设它的寄存器偏移和 `pci_skeleton.c` 里的教学模型（ID/STATUS/CTRL/DMA_ADDR）对得上**。它的 BAR0 有它自己的寄存器定义，`readl(REG_ID)` 读到的值未必是你预期的那种"设备 ID"。
- 想知道它的真实布局，去查你所用 QEMU 版本的源码 `hw/misc/pci-testdev.c`，或 QEMU 文档。这是很好的"读设备模型源码"练习。
- **本实验的目标只是"驱动 probe 到一个虚拟 PCIe 设备 + 映射到它的 BAR"**，不追求 DMA 数据闭环。

---

## 三、玩法 B：改驱动去 probe 一个真实语义设备（如 e1000 网卡）

`pci-testdev` 语义简单，想体验"完整寄存器 + 真实 MSI-X"，可以用 QEMU 模拟的**真实网卡**（它有完整的寄存器布局和中断）。步骤：

### 1. 启动时挂一块 e1000 网卡

```bash
qemu-system-x86_64 \
  -enable-kvm -m 2G -smp 2 \
  -drive file=disk-work.qcow2,if=virtio,format=qcow2 \
  -device e1000,netdev=n0 -netdev user,id=n0 \
  -nographic
```

### 2. 查它的 ID（`lspci -nn`）

```bash
lspci -nn | grep -i ethernet
# e1000 的 ID 通常是 [8086:100e]，请以实际输出为准
```

### 3. 让你的驱动抢先绑定这块卡（关键技巧）

真实设备开机就被内核自带的 `e1000` 驱动占用了，你的驱动 `pci_request_regions` 会 `-EBUSY` 失败。两种解法：

**解法 1（推荐，临时）**：先卸载系统驱动再加载你的

```bash
sudo rmmod e1000          # 释放设备
sudo insmod pci_skeleton.ko
dmesg | tail              # 你的驱动 probe 上去了，能读到 e1000 真实寄存器
```

**解法 2（更优雅）**：用 sysfs 把设备从原驱动解绑，绑到你的驱动

```bash
echo 0000:00:03.0 | sudo tee /sys/bus/pci/drivers/e1000/unbind
echo "8086 100e"  | sudo tee /sys/bus/pci/drivers/pci_skel/new_id
```

跑通后 `dmesg` 里能看到你读到 e1000 的真实 BAR0 值，并且 `cat /proc/interrupts | grep pci_skel` 能看到**真实 MSI-X 中断计数在涨**（如果你恢复了 request_irq）。这是**零硬件能体验到的最完整的 probe→BAR→中断链路**。

---

## 四、进阶：自己写 QEMU 设备模型，跑通完整 DMA 闭环

想真正跑通"`userspace_test` 首字节 = 0xA5"的 **DMA→中断→用户态**闭环，需要一个**寄存器布局和 `pci_skeleton.c` 教学模型对得上**的设备。QEMU 现成设备对不上，需要**自己写一个 QEMU 设备模型**（约 150–250 行 C）：

- 实现 BAR0：`+0x00 ID / +0x04 STATUS / +0x08 CTRL / +0x0C DMA_ADDR_LO / +0x10 DMA_ADDR_HI / +0x14 DMA_LEN`
- 实现一个"假 DMA"：收到 `CTRL bit0=1` 时，往 `DMA_ADDR` 指向的内存写数据，然后拉高 `STATUS bit0` 并触发 MSI-X。

这属于"QEMU 设备模型开发"，本身是个不错的进阶练习（能加深理解设备如何发起 DMA 和中断）。但它**不是驱动学习的主线**——主线是驱动侧。所以本包把它列为**选做**，不在主线教程展开完整代码。

> 如果你想走这条，我可以单独帮你写一份"QEMU 自定义设备模型"教程 + 配套代码，和 `pci_skeleton.c` 的寄存器布局严格对齐，真正跑通 DMA 闭环。见文末"想要更多"。

---

## 五、常用命令速查

| 目的 | 宿主机命令 |
|------|-----------|
| 起 QEMU 带 pci-testdev | `-device pci-testdev` |
| 起 QEMU 带 e1000 网卡 | `-device e1000,netdev=n0 -netdev user,id=n0` |
| 打开 KVM 加速 | `-enable-kvm` |
| 无图形（串口） | `-nographic` |
| 给虚拟机加更多 PCIe 设备 | 多写几个 `-device ...` |

虚拟机里：
```bash
lspci -nn            # 查设备 ID
lspci -k             # 查每个设备当前绑定的驱动
lspci -t             # 树形拓扑
```

---

## 六、自检

- [ ] 能起一个带 `pci-testdev` 的 QEMU 虚拟机
- [ ] 虚拟机里 `lspci -nn` 能看到测试设备并读出真实 ID
- [ ] 改驱动 ID 后 `insmod`，`dmesg` 出现 `BAR0 mapped` + `probed ok`
- [ ] （进阶）能用 e1000 + 解绑/绑驱动，看到 `/proc/interrupts` 里中断计数增长
- [ ] 理解"QEMU 练驱动框架流程，真实 DMA/性能仍需真硬件"这个边界

## 七、常见卡点

| 现象 | 原因 | 解决 |
|------|------|------|
| 虚拟机 `lspci` 里没有 testdev | `-device pci-testdev` 没加 / QEMU 太老 | 核对启动命令；`qemu-system-x86_64 --version` |
| ID 和教程不一样 | QEMU 版本差异 | **以你 `lspci -nn` 实际输出为准**，别硬抄 |
| `insmod` 报 `Operation not permitted` | 虚拟机里也开了 Secure Boot | 关掉虚拟机的 Secure Boot（见 troubleshooting.md） |
| `pci_request_regions` `-EBUSY` | 设备被系统驱动占用 | `rmmod` 系统驱动或 sysfs unbind |
| 加载后虚拟机网络断 | 你接管了正在用的网卡 | 用一块"你不靠它联网"的卡，或玩完 `rmmod` 你的驱动 + 重载 e1000 |

---

## 想要更多

- 想跑通**完整 DMA 闭环**（`userspace_test` 首字节=0xA5）：需要自写 QEMU 设备模型，可让我单独出一份配套教程+代码。
- 想练**用户态驱动**（不写内核模块、更安全）：可走 VFIO 路线，让我出 VFIO 上手 lab。

---

## 🔗 关联笔记

- **前置**：[[02_Linux_PCIe驱动开发]]
- **Docker 化版**：[[lab_03_qemu_docker]]（一键可复现，建议先跑通本篇再固化）
- **无真硬件的替代**：[[lab_01_first_probe]]（用真网卡/NVMe）
- **排错**：[[troubleshooting]]
- **返回**：[[00_首页MOC]]　**进度**：[[学习进度追踪]]

## 📝 我的实验记录

- **YYYY-MM-DD**：（QEMU 版本 / 用哪种玩法 / 结果）
