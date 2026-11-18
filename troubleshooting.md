---
tags: [排错, 环境, FAQ]
aliases: [排错手册, 故障排查, FAQ]
created: 2026-11-18
status: 常用参考
---

# 环境准备与故障排查（零基础必读）

> **全程配合**：做任何 [[lab_01_first_probe]] [[lab_02_qemu]] [[lab_03_qemu_docker]] 遇到报错都先查这里　|　**进度**：[[学习进度追踪]]

> 这份是"报错→原因→解决"对照表。**先看这里，再上网搜**。分三段：环境前置、编译期、加载/运行期。

## 一、环境前置检查

装依赖：
```bash
sudo apt install build-essential linux-headers-$(uname -r) pciutils kmod mokutil
```

三个必查项：

| 检查 | 命令 | 不通过怎么办 |
|------|------|------------|
| 内核头文件版本一致 | `uname -r` vs `ls /lib/modules/` | 重装 `linux-headers-$(uname -r)` |
| 头文件 build 目录存在 | `ls /lib/modules/$(uname -r)/build` | 装 headers；某些发行版还要 `linux-headers-generic` |
| **Secure Boot** | `mokutil --sb-state` | 见下 |

### Secure Boot（最大的隐形坑）

开 Secure Boot 时，内核**拒绝加载未签名模块**，`insmod` 报 `Operation not permitted` 或 `Key was rejected by service`——这和"代码有 bug"的报错完全无法区分，新手极易卡死。

按从易到难三选一：
1. **进 BIOS 关掉 Secure Boot**（学习机最省事，推荐）
2. 自己生成密钥 → `mokutil` 导入 MOK → 用密钥给 `.ko` 签名（步骤较多，按发行版文档）
3. 换用不开 Secure Boot 的虚拟机

## 二、编译期报错

| 报错 | 最可能原因 | 解决 |
|------|-----------|------|
| `make: *** /lib/modules/.../build: No such file or directory` | 没装 headers 或版本不对 | `sudo apt install linux-headers-$(uname -r)` |
| `ERROR: Kernel configuration is invalid` | 缺内核构建产物 | `cd /lib/modules/$(uname -r)/build && make oldconfig && make prepare` |
| 大量 `error: 'struct pci_driver' has no member named 'remove'` 之类签名不匹配 | 内核版本与代码假设不符 | 本骨架面向 ≥5.6；老内核（如 5.4）需把 `void skel_remove` 改回 `int skel_remove(...) { ... return 0; }` |
| `-Werror` 让告警变失败 | 叠加了 `CONFIG_WERROR`/`KCFLAGS` | 用 `make` 不加 `-Wextra`，或 `make KCFLAGS=` 覆盖 |
| `No rule to make target`（树内编译用法 B） | 子目录缺内部 Makefile | 在 `drivers/misc/pci_skel/` 里补 `Makefile`：`obj-$(CONFIG_PCI_SKEL) += pci_skeleton.o` |

## 三、加载 / 运行期报错

| 报错/现象 | 最可能原因 | 解决 |
|------|-----------|------|
| `insmod: Operation not permitted` / `Key was rejected by service` | Secure Boot 拒绝未签名模块 | 见第一节 Secure Boot |
| `insmod: ERROR: could not insert module ... Invalid module format` | 内核头文件版本和运行内核不一致 | `uname -r` 对比 `/lib/modules/`，重装匹配的 headers 重编 |
| **insmod 成功但 `dmesg` 没有任何 probe 日志** | ID 不匹配（`lspci -nn` 里没 1234:5678），或设备已被别的驱动占用 | 这是**无自定义硬件时的预期行为**。做 Lab 01：把 ID 改成真设备；`lspci -k` 看当前占用 |
| `pci_request_regions failed` / `-EBUSY` | BAR 区域被其他驱动占用 | 先 `rmmod` 占用该设备的原驱动，或换设备 |
| `open /dev/pci_skelNN: No such file or directory` | probe 没跑（见上两行） | 同上；节点名 = `pci_skel`+devfn，用 `ls -l /dev/pci_skel*` 找真实名 |
| `open /dev/pci_skelNN: Permission denied` | misc 设备默认 root-only | `sudo` 运行，或加 udev 规则 / `sudo chmod 666` |
| `read` 一直卡住不返回 | 设备没真的拉 `DMA_DONE`（无硬件/教学设备没实现写回时**必然如此**） | 无硬件时不要走 read 路径；闭环需设备配合（Lab 03 / QEMU 设备） |
| `read` 返回了但首字节 ≠ 0xA5 | DMA 数据通路没打通（设备没把数据写进 dma_buf） | 需要 Lab 01 已跑通且设备实现 DMA 写回；无硬件属预期 |
| 多张卡第二张 probe 失败 `-EEXIST/-EBUSY` | misc 设备同名 | 本骨架已用 `pci_skel+devfn` 命名规避；若自己改回固定名会复现 |
| 卸载时 Oops / BUG | probe/remove 资源没严格配对，或漏了某步 | 对照 `pci_skeleton.c` 的 goto 逆序清理检查 |

## 四、调试命令速查（详细见 04_优化与调试.md）

```bash
lspci -nn                 # 设备 + 厂商/设备 ID
lspci -k                  # 每个设备当前绑定的内核驱动
lspci -vv -s 01:00.0      # 单设备详情（BAR/中断/链路状态 LnkSta）
lspci -t                  # 树形拓扑
sudo dmesg -c             # 清空内核日志，方便只看本次 insmod 的输出
cat /proc/interrupts | grep pci_skel   # 看中断计数是否增长
```

## 五、无硬件学习路线（重要）

没有自定义 `1234:5678` 设备时，**probe/中断/DMA 的完整闭环跑不到**，这是正常的。按此推进：

1. **纯编译加载**（最基础）：`make` 通过 + `insmod`/`rmmod` 不报错 + dmesg 干净。这已经验证了你的构建环境和模块框架没问题。
2. **Lab 01（推荐）**：拿现成 NVMe/网卡，精简 probe 到 5 步，跑到"读到真硬件 BAR0"。
3. **用户态摸 BAR（最安全）**：用 `vfio-pci` 把一块现成网卡绑给用户态，写用户态程序 `mmap` BAR、`readl/writel`，不写内核模块、不怕 panic。整包不强制此路线，想深入 IOMMU/用户态驱动再学。
4. **完整闭环（Lab 03）**：需要自定义 FPGA 卡或自建 QEMU 教学设备（实现 BAR0 寄存器 + 拉高 STATUS bit0 触发 MSI-X）。

> 心法：**别指望一口气跑通全闭环**。先把"编译→加载→读到真 BAR"这条最短链跑通，建立信心，再逐段加中断、DMA。

---

## 🔗 关联笔记

- **配合使用**：做任何 lab 遇到报错都先查这里 → [[lab_01_first_probe]] · [[lab_02_qemu]] · [[lab_03_qemu_docker]]
- **运行期定位**：[[04_优化与调试]]（本篇管环境/编译/加载期，它管运行期）
- **返回**：[[00_首页MOC]]

## 📝 我踩过的坑（持续记录）

- **YYYY-MM-DD**：（报错 → 原因 → 解决，避免重复踩）
