---
tags: [PCIe协议, PCIe, Linux驱动]
aliases: [PCIe协议核心, PCIe协议]
created: 2026-11-18
status: 进行中
---

# 01 · PCIe 协议核心（心智模型）

> **上一篇**：[[00_学习路线图]]　|　**下一篇**：[[02_Linux_PCIe驱动开发]]　|　**进度**：[[学习进度追踪]]

> 目标：读完能画出拓扑、说清数据怎么走、中断怎么发、地址怎么映射。不抠比特细节。

## 1. 一句话本质

PCIe = **基于报文（packet）的、点对点的、交换式（switched）串行总线**。它取代了老 PCI 的"多设备共享一条并行总线 + 仲裁"模型，改成**任意两个设备之间建立专用链路**。

## 2. 拓扑：树形（这是最重要的图）

```
                     CPU / SoC
                        │  ← Root Complex (RC)，树根，也是地址翻译的起点
                  ┌─────┴─────┐
              PCIe Root Port  PCIe Root Port      (RC 内可有多个 port)
                  │             │
           ┌──────┴──────┐      │
        Switch 上行口    │      │
        ┌───┬───┬───┐    │      │
      EP0 EP1 EP2      EP3    EP4
      End Point = 终端设备（网卡/显卡/你的 FPGA 卡）
```

- **Root Complex (RC)**：CPU 到 PCIe 世界的桥梁，负责把 CPU 的内存读写翻译成 PCIe 报文，也负责**枚举**。
- **Switch**：一颗多端口交换芯片，扩展下挂设备。有**上行口（upstream port）**和多个**下行口（downstream port）**。
- **End Point (EP)**：真正的终端设备。
- **Bridge**：连接老 PCI 总线的桥。
- 树中的每一层，靠 **Bus Number / Device Number / Function Number** 唯一标识，组成 **BDF**（如 `0000:01:00.0`）。

## 3. 链路（Link）与带宽

- 一条链路由 **Lane（通道）** 组成，每 Lane 是一对差分线（收/发各一），当前 **GT/s**（每秒千兆传输）决定速率。
- 常见配置：**x1 / x4 / x8 / x16**（Lane 数）。

| 代际 | 速率（每 Lane, GT/s） | 编码 | x16 单向带宽（约） |
|------|------|------|------|
| PCIe 3.0 | 8 GT/s | 128b/130b | ~16 GB/s |
| PCIe 4.0 | 16 GT/s | 128b/130b | ~32 GB/s |
| PCIe 5.0 | 32 GT/s | 128b/130b | ~64 GB/s |
| PCIe 6.0 | 64 GT/s | PAM4 + FLIT | ~128 GB/s |

> 记住：**x16 Gen4 ≈ 32 GB/s 单向**，这个量级帮你判断"数据到底走不走得完"。

## 4. 报文（TLP）——数据怎么走

PCIe 上所有东西都是 **TLP（Transaction Layer Packet）**：

- **Memory Read / Write**：读/写内存空间（含 MMIO 和主存）
- **I/O Read / Write**：读/写 I/O 空间（老式，少用）
- **Configuration Read / Write**：读写配置空间（枚举时用）
- **Completion（完成包）**：读操作的返回数据
- **Message / Interrupt**：中断、电源管理等

**关键流程**（记住这个"内存读写"模型）：
- 设备写主存：EP 发 **Memory Write TLP** → 经 Switch → RC → 写入 DRAM。** Posted，无需回应。
- 设备读主存：EP 发 **Memory Read TLP** → RC 读 DRAM → 回 **Completion TLP** 带数据。** Non-Posted，要等回应。

> Posted / Non-Posted 是排序与流控的基础，也解释了"写快读慢"。

## 5. 三种地址空间（驱动天天打交道）

| 空间 | 是什么 | 驱动里怎么用 |
|------|--------|-------------|
| **Configuration Space** | 每个设备 256B（PCI）/ 4096B（PCIe）寄存器，描述自己是谁、有哪些 BAR | `pci_read_config_*` 读；枚举时 RC 靠它发现设备 |
| **Memory Mapped I/O (MMIO)** | 设备寄存器映射到 CPU 物理地址，CPU 直接 `readl/writel` | 通过 **BAR** 映射，`pci_iomap` / `ioremap` 后访问 |
| **I/O Space** | 老式独立端口空间 | `pci_ioport`，x86 上还有，其他架构基本不用 |

### BAR（Base Address Register）——核心概念

- 在配置空间里有 6 个 BAR（0~5），每个描述**一段设备地址窗口**的大小和类型（内存 / I/O、32 位 / 64 位、可预取否）。
- **枚举时**，RC/Bios 给每个 BAR 分配一个**物理基地址**。
- **驱动里**：`pci_resource_start(pdev, bar)` 拿基地址，`pci_resource_len` 拿长度，`pci_iomap` 映射成内核虚拟地址，之后 `readl/writel` 访问。
- 一个设备常有多个 BAR：BAR0 放寄存器，BAR2 放 DMA 描述符区等。

## 6. 配置空间关键字段（读 `lspci -vv` 会一直遇到）

- **Vendor ID / Device ID**：厂商和设备号，驱动 `pci_device_id` 表靠它匹配。
- **Class Code**：设备类别（0x02 网络、0x01 存储、0x12 加速器…）。
- **Command Register**：开关 Memory Space / Bus Master（**开 DMA 必须置 Bus Master 位**）。
- **Status Register**：记录错误、能力。
- **Capability List**：链到 MSI/MSI-X、Power、AER、PCIe 能力等扩展。

## 7. 枚举（Enumeration）——系统怎么发现你的卡

1. 开机/热插拔，RC 从 Bus 0 开始，扫描所有 Device/Function。
2. 读到有效 Vendor ID（非 0xFFFF）→ 设备存在。
3. 读各 Function 的配置空间，判断类型（EP / Bridge / Switch）。
4. 对 Bridge/Switch：分配下行 Bus 号，递归扫描。
5. 分配 BAR 基地址、中断等资源。
6. 内核把发现结果交给 `pci_driver.probe()`（你的驱动被调用）。

> 驱动的 `pci_device_id` 表匹配到设备 → 内核调你的 `probe`。这是驱动的入口。

## 8. 中断：从老式 INTx 到 MSI/MSI-X

- **INTx**：传统 4 根虚拟中断线，共享、必须轮询哪个设备触发、要读设备寄存器确认。**低效**。
- **MSI（Message Signaled Interrupt）**：设备往一个特定内存地址写一个值来触发中断（本质是 Memory Write TLP）。独占、无需确认、更低延迟。
- **MSI-X**：MSI 的增强，支持**多条中断向量**（如每条队列一个中断），是现代高性能设备（NVMe、网卡）的标配。

> 驱动目标：**能用 MSI-X 就用 MSI-X**，一队列一中断，避免中断风暴和共享开销。

## 9. DMA——高性能的命脉

- 设备直接读写主存，不经过 CPU 搬运。
- 需要驱动准备**一致 DMA 缓冲（coherent）**或**流式 DMA 映射（streaming）**，得到设备能访问的**总线地址（IOVA/DMA address）**告诉设备。
- **IOMMU / SMMU**（Intel VT-d / AMD-Vi / ARM SMMU）：给设备地址做翻译和保护，是**多卡互联和 P2P** 的关键基础设施。

## 10. 你现在应该能回答的

- 拓扑是树还是环？根是谁？
- EP 和 Switch 区别？
- 一次设备写主存，TLP 怎么流？Posted 还是 Non-Posted？
- BAR 是什么，驱动怎么用它访问寄存器？
- 为什么用 MSI-X 而不是 INTx？

> 答不上来就回对应小节，能答就进 [[02_Linux_PCIe驱动开发]]。更多自测见 [[05_面试与原理问答]]。

---

## 🔗 关联笔记

- **上一站**：[[00_学习路线图]]　**下一站**：[[02_Linux_PCIe驱动开发]]
- **相关**：[[06_零拷贝专题]]（DMA 与零拷贝的关系）、[[03_多卡互联设计]]（IOMMU/P2P 基础）
- **自测**：[[05_面试与原理问答]]（PCIe 协议层 Q1–Q5）
- **返回**：[[00_首页MOC]]

## 📝 我的学习记录

- **YYYY-MM-DD**：
