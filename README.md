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
├── 05_面试与原理问答.md          ← 37 道反向检验题（覆盖全部主题）
├── lab_01_first_probe.md      ← 动手实验：无自定义设备也能跑到"读到真硬件"
├── lab_02_qemu.md             ← QEMU 模拟实验：完全无硬件跑通 probe/BAR/中断
├── lab_03_qemu_docker.md      ← Docker+QEMU：一键可复现的实验环境（含 docker/）
├── lab_04_vfio_userspace.md   ← VFIO 用户态驱动：不写内核模块、不怕 panic ⭐推荐
├── 06_零拷贝专题.md           ← 零拷贝原理/代码/嵌入式/PCIe 实战
├── 07_多卡通讯总览.md         ← 多卡通讯技术栈子库入口（07-13 完整链路）
├── 08_集合通信原语.md         ← AllReduce/AllGather/ReduceScatter 五大原语
├── 09_并行策略与通讯模式.md   ← DP/TP/PP 对应的通讯操作
├── 10_NCCL实战与调试.md       ← NCCL 用法 + nccl-tests + 排错
├── 11_GPUDirect与RDMA.md      ← 跨机 GPU 通讯基础（IB/RoCE）
├── 12_通讯性能优化.md         ← 减量/提带宽/通讯-计算重叠
├── 13_多卡通讯实战演练.md     ← 从零到实战路径 + L1-L5 分层自测
├── 14_配置空间与能力链表详解.md ← 4KB 配置空间/BAR 尺寸/MSI-X 表/能力链表
├── 15_IOMMU_ACS与P2P可行性.md  ← 为什么同一对卡换机器就不能 P2P
├── 16_AER错误处理与链路稳定性.md ← AER 位定义/日志解读/DPC/复位
├── 17_带宽与单位换算速查.md    ← 双向 vs 单向、GT/s、busbw，防算错
├── 18_内核版本适配矩阵.md      ← 同一 API 在不同内核版本的签名差异（写代码前查）
├── 多卡集群驱动开发技能地图.md ← 多卡集群驱动开发子库入口（五层技能模型）
├── dev_case_01_拓扑发现.md    ← 开发案例：枚举多卡、判断卡间拓扑
├── dev_case_02_p2pdma.md      ← 开发案例：同 Switch 卡 DMA 直传（P2PDMA）
├── dev_case_03_peer_memory.md ← 开发案例：GPU peer memory 模块（跨机 GPUDirect 基础）
├── dev_case_04_多队列msix.md  ← 开发案例：多队列 MSI-X + 中断亲和
├── PCIe_图文全景教程.md       ← 图文全景教程：六大场景一图看懂（含架构图/流程图）
├── 集群高速IO问题排查.md      ← 训练/推理多卡集群高速 IO 典型问题手册
├── 硬件bring-up清单.md        ← 拿到新卡从插上到跑通的工程化清单
├── 术语速查表.md              ← 按主题分组的术语速查（查概念"是什么"）
├── 学习进度追踪.md            ← 勾选式进度表 + 里程碑 + 卡点记录
├── troubleshooting.md         ← 环境前置 + 报错对照表（零基础必读）
├── 核查报告_2026-11-19.md      ← 全库核查记录（P0/P1/P2 清单 + 验证方法，可复现）
├── docker/                    ← lab_03 配套：Dockerfile + entrypoint.sh
├── Templates/                 ← Obsidian 笔记模板
├── 学习日志/                  ← 每日学习日志（用 Obsidian 每日笔记）
└── code/
    ├── pci_skeleton.c         最小可编译 PCIe 驱动骨架（含注释，已过专家审核）
    ├── Makefile               树外编译（推荐）+ 树内编译说明
    ├── Kconfig                仅树内编译时用
    ├── userspace_test.c       用户态测试程序（含 0xA5 闭环校验）
    └── devcases/              dev_case 编译脚手架（Makefile + extract.sh + preflight.sh）
```

> **完整学习顺序**：**读 00+01 → 读 02 对照代码 → 做 lab_01（跑通"读到真 BAR"）→ 无硬件时做 lab_02（QEMU）或 lab_04（VFIO，最安全）→ 读 03+04+06 → 学 07-13 多卡通讯技术栈 → 要做集群驱动开发则学「多卡集群驱动开发技能地图」+ dev_case_01~04 → 用 05 自测（37 题）**。
> **遇到具体故障时**：先查 16（AER 日志）、再查 15（P2P 不可用）、算带宽前查 17、读配置空间查 14。
> **动手写内核代码前**：先跑 `code/devcases/preflight.sh`（只读自检，打印你的内核该用哪套 API + P2P 预判），再查 18 确认 API 签名与版本区间。
> 卡住时先看 troubleshooting.md，再上网搜；查概念用术语速查表；集群 IO 问题查集群高速IO问题排查；拿到新卡查硬件bring-up清单。

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
