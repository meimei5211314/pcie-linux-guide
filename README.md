# PCIe + Linux 驱动 + 多卡互联：最快掌握学习包

> 目标：用最短路径，把「PCIe 协议 → Linux PCIe 驱动开发 → 多卡互联设计 → 优化调试」这条链打通。
> 思路：不背规范，先建**心智模型**，再跑**可编译骨架**，最后用**工具链**验证。

## 这套资料怎么用（最快路径）

```
第 0 步  00_学习路线图.md          —— 5 分钟，知道整条链长什么样、按什么顺序学
第 1 步  01_PCIE协议核心.md         —— 建立 PCIe 心智模型（分层/拓扑/枚举/中断/地址）
第 2 步  02_Linux_PCIe驱动开发.md   —— 主线：probe / BAR 映射 / 中断 / 字符设备 / DMA
第 3 步  code/pci_skeleton.c        —— 边读文档边看可编译骨架，跑起来
第 4 步  03_多卡互联设计.md         —— P2P / NVLink / CXL / 共享内存一致性
第 5 步  04_优化与调试.md           —— 工具链 + 一定位法（lspci/trace/ftrace/crash…）
第 6 步  05_面试与原理问答.md        —— 用问题反向检验掌握程度
```

## 目录结构

```
pcie-linux-guide/
├── README.md                  本文件（入口）
├── 00_学习路线图.md
├── 01_PCIE协议核心.md
├── 02_Linux_PCIe驱动开发.md
├── 03_多卡互联设计.md
├── 04_优化与调试.md
├── 05_面试与原理问答.md
├── lab_01_first_probe.md      ← 动手实验：无自定义设备也能跑到"读到真硬件"
├── lab_02_qemu.md             ← QEMU 模拟实验：完全无硬件跑通 probe/BAR/中断
├── lab_03_qemu_docker.md      ← Docker+QEMU：一键可复现的实验环境（含 docker/）
├── 06_零拷贝专题.md           ← 零拷贝原理/代码/嵌入式/PCIe 实战
├── troubleshooting.md         ← 环境前置 + 报错对照表（零基础必读）
├── docker/                    ← lab_03 配套：Dockerfile + entrypoint.sh
└── code/
    ├── pci_skeleton.c         最小可编译 PCIe 驱动骨架（含注释，已过专家审核）
    ├── Makefile               树外编译（推荐）+ 树内编译说明
    ├── Kconfig                仅树内编译时用
    └── userspace_test.c       用户态测试程序（含 0xA5 闭环校验）
```

> 学习顺序建议：**读 00+01 → 读 02 对照代码 → 做 lab_01（跑通"读到真 BAR"）→ 无硬件时做 lab_02（QEMU）→ 读 03+04+06 → 用 05 自测**。
> 卡住时先看 troubleshooting.md，再上网搜。

## 前置与环境

- 你不需要真硬件就能读完文档。但要跑代码，需要：
  - 一台能编译内核模块的 Linux（虚拟机即可）+ 对应版本内核头文件
  - 一块支持 MSI-X 的 PCIe 设备（练习时可选：现成网卡/NVMe 或 QEMU 模拟设备）
  - `sudo apt install build-essential linux-headers-$(uname -r) pciutils kmod mokutil`
- **先查 Secure Boot**（否则 `insmod` 会莫名失败）：`mokutil --sb-state`
  - 开启了：学习机建议进 BIOS 关掉，或走签名流程（见 `troubleshooting.md`）
- 编译/加载：见 `code/` 内 Makefile 注释。
- **没有自定义 PCIe 设备时**：先做 `lab_01_first_probe.md`（拿现成网卡/NVMe 练手），
  报错时查 `troubleshooting.md`。**probe/中断/DMA 全闭环需要真实设备或 QEMU 教学设备。**

> 提示：Zynq/MicroPhase 一类 FPGA 平台常做 PCIe End Point 或 Root Complex，这套知识和
> Zynq7010 教程（位于本包同级目录，不在本包内）能互相印证。
