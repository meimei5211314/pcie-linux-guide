---
tags: [动手实验, Linux驱动, PCIe]
aliases: [Lab01, 第一次probe]
created: 2026-11-18
status: 未开始
---

# Lab 01 · 让我的驱动第一次摸到真硬件（无自定义设备版）

> **前置**：[[02_Linux_PCIe驱动开发]]　|　**排错**：[[troubleshooting]]　|　**进度**：[[学习进度追踪]]

> **目标**：没有那块 `1234:5678` 自定义卡，也能让你的驱动**真正 probe 到一块真实 PCIe 设备**，打印出它的 BAR0 寄存器值。这是从"读了一堆 API"到"我跑出了第一个结果"的关键一步。
>
> **思路**：不碰 DMA、不碰中断（那些需要设备配合），只做 probe 最前 5 步：`enable → set_master → request_regions → iomap → readl(ID)`。

## 0. 前置检查（3 分钟）

```bash
# 内核头文件版本必须和运行内核一致
uname -r
ls /lib/modules/$(uname -r)/build   # 必须存在，否则装：sudo apt install linux-headers-$(uname -r)

# Secure Boot 会拒绝未签名模块 —— 这是零基础第一个大坑
mokutil --sb-state
# 若显示 SecureBoot enabled：学习机最省事是进 BIOS 关掉它；
# 否则 insmod 会报 "Operation not permitted"，与代码 bug 无法区分。详见 troubleshooting.md。
```

## 1. 挑一个练习对象（安全第一）

选一块**闲置的、系统不依赖它启动**的设备。**不要拿系统盘 NVMe 或你正在用的网卡**（万一驱动接管出错会掉盘/断网）。

```bash
lspci -nn | grep -iE "ethernet|network|nvme"
# 输出形如：
# 01:00.0 Ethernet controller [0200]: Intel Corp ... [8086:1533]
#                                        厂商ID ──┘   └── 设备ID
# 02:00.0 Non-Volatile memory controller [0108]: ... [144d:a808]
```

记下你要练习的那台的 `[厂商ID:设备ID]`（下面用 `8086:1533` 举例，换成你的）。

> **更安全的替代：用虚拟机 + 没用的设备，或直接跳到「无硬件路线」做纯编译加载练习。** 第一次练手优先用虚拟机。

## 2. 改代码：精简 probe 到 5 步

打开 `code/pci_skeleton.c`：

1. 把设备 ID 改成你查到的：
```c
#define MY_VENDOR_ID  0x8086   /* 换成你的 */
#define MY_DEVICE_ID  0x1533   /* 换成你的 */
```

2. **注释掉** probe 里 6.6～6.9 这几段（MSI-X、request_irq、DMA、misc_register），以及对应的 `err_irq`/`err_irqvec`/`err_dma` 清理标签——因为我们只要"读到寄存器"这个里程碑，避免因设备没有 MSI-X 能力/中断冲突而失败。保留 6.1～6.5 和 `err_regions`/`err_disable`/`err_out`。

> 想偷懒的话：直接把 `skel_probe` 里 `/* 6.6 申请 MSI-X */` 到 `return 0;` 之间的内容临时删掉，只留 6.1~6.5 + 一句 `pci_info(pdev, "first probe milestone reached\n");`。

## 3. 编译、加载、看结果

```bash
cd code
make module            # 预期：cc ... pci_skeleton.ko，无 error

sudo insmod pci_skeleton.ko
dmesg | tail
```

**成功的预期输出**（dmesg 末尾应出现）：
```
[ xxx ] pci_skel 0000:01:00.0: BAR0 mapped at 0x..., device id=0x...
[ xxx ] pci_skel 0000:01:00.0: first probe milestone reached
```
🎉 看到 `BAR0 mapped` + 一个非零的 `device id`，就说明**你的代码读到了真硬件的寄存器**。这就是第一个里程碑。

## 4. 干净卸载（验证清理路径不崩）

```bash
sudo rmmod pci_skeleton
dmesg | tail           # 预期：pci_skel ...: removed，且无 Oops / BUG / trace
```

卸载不崩、dmesg 干净，说明 probe/remove 的资源申请-释放配对是对的。**这一步同样重要**——很多人 probe 能过但 remove 崩。

## 5. 自检

- [ ] `make module` 无 error
- [ ] `insmod` 无 "Operation not permitted"（有就是 Secure Boot，见 troubleshooting）
- [ ] `dmesg` 出现 `BAR0 mapped`，device id 非零
- [ ] `rmmod` 干净，无 Oops

## 6. 常见卡点速查

| 现象 | 原因 | 解决 |
|------|------|------|
| `insmod: Operation not permitted` | Secure Boot 拒绝未签名模块 | 关 Secure Boot 或签名模块 |
| insmod 成功但 `dmesg` 静默、没 probe 日志 | ID 不匹配，或设备已被别的驱动占用 | `lspci -k` 看当前绑定；ID 核对 `lspci -nn` |
| `pci_request_regions failed` | BAR 被原驱动占用 | 先卸载占用该设备的原驱动（`rmmod` 那个驱动）或换设备 |
| 加载后系统卡死/断网 | 选到了关键设备 | 换闲置设备 / 用虚拟机 |

## 7. 进阶（下一步）

跑通本篇后，按顺序挑战：
- **加中断**：恢复 probe 的 6.6~6.7（MSI-X + request_irq），用一块支持 MSI-X 的网卡，`cat /proc/interrupts | grep pci_skel` 看中断计数变化。
- **DMA 闭环**：需要设备真的配合写回 DMA 数据（自定义 FPGA 卡，或自写 QEMU 设备模型）才能验证 `userspace_test` 首字节=0xA5，见 [[lab_02_qemu]] 的"玩法 C"。
- **QEMU 模拟**：完全没硬件就去做 [[lab_02_qemu]]；要可复现环境做 [[lab_03_qemu_docker]]。
- **用户态 mmap**：用骨架的 `.mmap`，写个小程序 `mmap` BAR0 后直接 `*(volatile uint32_t*)0x...` 读 REG_ID，对比 `read()` 系统调用路径的开销（`perf stat` 量）。
- **用户态驱动（最安全）**：走 VFIO 路线，不写内核模块、不怕 panic，见 [[lab_04_vfio_userspace]]。

---

## 🔗 关联笔记

- **前置**：[[02_Linux_PCIe驱动开发]]（理解 probe 五步）
- **下一步**：[[lab_02_qemu]]（无真网卡时用 QEMU 练）
- **排错**：[[troubleshooting]]（Secure Boot / headers / 报错表）
- **进阶**：[[06_零拷贝专题]]（mmap 读 REG_ID 属零拷贝层次 1）
- **返回**：[[00_首页MOC]]　**进度**：[[学习进度追踪]]

## 📝 我的实验记录

- **YYYY-MM-DD**：（用什么设备 / 卡在哪 / 怎么解决的）
