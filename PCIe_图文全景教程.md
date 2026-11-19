---
tags: [PCIe, Linux驱动, 图文教程, 架构图, 流程图]
aliases: [PCIe图文教程, PCIe全景教程]
created: 2026-11-19
status: 进行中
---

# PCIe 从硬件到多卡：图文全景教程

> 覆盖六大场景：①PCIe 基础 ②Linux 枚举与驱动模型 ③配置空间与 BAR ④DMA 与中断 ⑤多卡拓扑与数据传输 ⑥性能优化与排查。
> 风格：**每节一张图 + 关键步骤**，不铺陈背景。深入细节见 `00_首页MOC.md` 学习库。

---

## 场景 1 · PCIe 基础：一个包交换网络

**心智模型**：PCIe 不是"总线"，而是一个**基于报文的点对点交换网络**。每个设备是网络上的一个节点。

### 架构图：整机 PCIe 拓扑

```
                        ┌─────────────────┐
                        │    CPU / SoC    │
                        │  (cores + LLC)  │
                        └────────┬────────┘
                                 │ 内部总线
                        ┌────────┴────────┐
                        │  Root Complex   │  ← PCIe 网络的"根"
                        │   (RC) 地址翻译 │     枚举起点
                        └───┬─────────┬───┘
                     Root Port 1   Root Port 2
                            │           │
              ┌─────────────┘           └──────────┐
        ┌─────┴─────┐                        ┌──────┴──────┐
        │  Switch   │                        │  EP (单设备) │
        │ upstream  │                        │  (如 NVMe)  │
        └─┬──┬──┬──┘                        └─────────────┘
     downstream ports
      │  │  │
      EP EP EP
     (GPU/GPU/FPGA)
```

### 关键点

- **RC（Root Complex）**：把 CPU 的内存读写翻译成 PCIe 报文；**枚举**从这里开始。
- **Switch**：扩展下挂设备；有 1 个 **upstream port** + 多个 **downstream port**。
- **EP（End Point）**：终端设备。卡与卡能否 P2P 取决于是否挂在**同一个 Switch** 下。
- **树形结构**：任何两个设备之间的报文，都沿着树上的路径走。

### 链路带宽（记住量级）

| 代际 | 每 Lane | x16 单向 |
|------|---------|----------|
| Gen3 | 8 GT/s | ~16 GB/s |
| Gen4 | 16 GT/s | ~32 GB/s |
| Gen5 | 32 GT/s | ~64 GB/s |

> **NVLink 量级**：NVLink4（H100）单卡 **900 GB/s 双向合计**（每向 ≈450），NVLink3（A100）为 600 GB/s 双向——单向仍比 PCIe Gen4 x16 高约 14 倍。注意与 PCIe 口径对齐：PCIe 常说的 32/64 GB/s 是**单向**。

---

## 场景 2 · Linux 设备枚举与驱动模型

### 流程图：从上电到 probe 被调用

```
上电/热插拔
    │
    ▼
┌─────────────────────────────────────────┐
│  固件/内核 PCI 子系统 枚举                │
│  for bus, dev, fn:                       │
│    读 Config Space Vendor ID             │
│    ├─ 0xFFFF → 无设备，跳过              │
│    └─ 有效 → 设备存在，读配置空间        │
│         ├─ Type: EP → 记录               │
│         └─ Type: Bridge/Switch →         │
│              分配下行 Bus 号，递归扫描    │
│  分配资源：BAR 基地址、中断号            │
└────────────────┬────────────────────────┘
                 │ 内核建立 struct pci_dev
                 ▼
┌─────────────────────────────────────────┐
│  驱动匹配                                │
│  遍历已注册的 pci_driver 的 id_table     │
│  Vendor/Device ID 匹配 → 找到驱动        │
└────────────────┬────────────────────────┘
                 │ 调用回调
                 ▼
        ┌─────────────────┐
        │  probe(pdev,id) │  ← 你的代码从这里开始
        └─────────────────┘
```

### 驱动模型：注册 → 匹配 → probe

```c
// 1. 声明"我管哪些设备"
static const struct pci_device_id my_ids[] = {
    { PCI_DEVICE(0x1234, 0x5678) },   // Vendor, Device
    { 0, }
};
MODULE_DEVICE_TABLE(pci, my_ids);

// 2. 定义驱动回调
static struct pci_driver my_drv = {
    .name     = "mydev",
    .id_table = my_ids,
    .probe    = my_probe,     // 设备被枚举且匹配 → 调用
    .remove   = my_remove,    // 移除/卸载 → 反向清理
};

// 3. 一行注册（展开成 init/exit）
module_pci_driver(my_drv);
```

### probe 的标准动作（顺序不能乱）

| 步骤 | API | 作用 |
|------|-----|------|
| 1 | `pci_enable_device` | 上电、使能 |
| 2 | `pci_request_regions` | 申请 BAR 区域（防冲突） |
| 3 | `pci_iomap` | 映射 BAR → 内核虚拟地址 |
| 4 | `pci_set_master` | **开 Bus Master，允许 DMA**（易漏！） |
| 5 | `pci_alloc_irq_vectors` | 申请 MSI-X |
| 6 | `request_irq` | 绑中断处理 |
| 7 | `dma_alloc_coherent` | DMA 缓冲 |
| 8 | 注册字符设备 | 给用户态访问 |

> **remove 必须严格逆序**清理，否则资源泄漏/悬空中断/卸载崩溃。

---

## 场景 3 · 配置空间与 BAR：设备怎么"自我介绍"

### 配置空间布局图（PCIe：4KB）

```
偏移     字段
┌───────────────────────────────────────┐
│ 0x00  Vendor ID │ Device ID          │ ← 驱动匹配靠这俩
├───────────────────────────────────────┤
│ 0x04  Command    │ Status             │ ← Command: 开 Memory/BusMaster
├───────────────────────────────────────┤
│ 0x08  Revision │ Class Code          │ ← Class: 设备类别
├───────────────────────────────────────┤
│ ...    (其他头部字段)                   │
├───────────────────────────────────────┤
│ 0x10  BAR0 (Base Address Register)    │ ← 内存/I/O 窗口
│ 0x14  BAR1                            │
│ 0x18  BAR2                            │
│ 0x1C  BAR3                            │  6 个 BAR (0~5)
│ 0x20  BAR4                            │  64位BAR 占 2 个槽
│ 0x24  BAR5                            │
├───────────────────────────────────────┤
│ 0x2C  Subsystem ID │ ...              │
├───────────────────────────────────────┤
│ 0x30  Expansion ROM BAR               │
├───────────────────────────────────────┤
│ 0x34  Capabilities Pointer ───────────────┐  ← 链表头
│ 0x3C  Interrupt Pin │ Interrupt Line    │  │
└───────────────────────────────────────┘  │
                                            ▼
                       ┌──────────────────────────────┐
                       │ Capability 链表（0x40 起）    │
                       │  MSI / MSI-X / Power / AER   │
                       │  / PCIe Cap / ... 每项:      │
                       │  [Next Ptr][Cap ID][内容]    │
                       └──────────────────────────────┘
```

### BAR 的解析：一个寄存器告诉你窗口类型

```
BAR 寄存器低位编码：
bit0   : 0=Memory Space  1=I/O Space
bit2:1 : Memory 类型 (00=32位  10=64位)
bit3   : 1=可预取 (Prefetchable)
bit31:4: 基地址（映射后由 RC 填入）

例：读 BAR0 = 0x0000000C
    bit0=0 → Memory
    bit2:1=10 → 64位
    → 占 BAR0+BAR1 两个槽，是可映射的内存窗口
```

### 用 BAR 访问设备（驱动三步）

```c
phys = pci_resource_start(pdev, 0);      // BAR0 物理基地址
len  = pci_resource_len(pdev, 0);        // BAR0 大小
regs = pci_iomap(pdev, 0, 0);            // 映射 → 内核虚拟地址

u32 id = readl(regs + 0x00);             // 直接读写寄存器
writel(0x1, regs + 0x08);
```

---

## 场景 4 · DMA 与中断：数据通路与通知

### DMA 数据流（设备 → 主存）

```
        CPU                          设备(EP)
         │                               │
   ①准备缓冲                      ②拿到总线地址
   dma_alloc_coherent             (dma_handle/IOVA)
   得到两个地址：                        │
   ├ CPU虚拟地址 ──┐                    │
   └ 总线地址 ─────┼→ 写进设备寄存器 ───┘
                   │   (DMA_ADDR_LO/HI)
                   │                        │
                   │              ③设备发起 DMA
                   │                 Memory Write TLP
                   │                        │
                   ▼                        ▼
        ┌──────────────────────────────────────┐
        │   主存 (DRAM)   ← 数据落在这里        │
        └──────────────────────────────────────┘
                            │
                   ④设备写完 → 拉中断 → CPU 处理
```

### 两种 DMA（选择依据）

| | Coherent（一致性） | Streaming（流式） |
|--|-------------------|-------------------|
| 映射 | 常驻、双向 | 每次 map/unmap |
| 同步 | 不需要 | 需要 `dma_sync_*_for_cpu` |
| 用途 | 描述符环、命令队列 | 大块一次性数据 |
| API | `dma_alloc_coherent` | `dma_map_single` |

> **64 位地址必写 HI+LO**：`dma_set_mask(64)` 后，寄存器要拆 ADDR_HI/ADDR_LO 两个都写，只写低 32 位会在 >4G 地址截断。

### 中断机制对比

```
INTx（传统）              MSI/MSI-X（现代）
─────────────             ─────────────────
4 根共享虚拟线            设备写内存地址触发
  │                         (本质 Memory Write TLP)
  ▼                         ▼
需轮询哪个设备触发        独占、无需确认
读设备寄存器确认          MSI-X: 多向量
低效、延迟高              一队列一中断，低延迟

                          例(NVMe):
                          队列0 → 向量0
                          队列1 → 向量1   ← 一队列一中断
                          队列2 → 向量2
```

### ISR 铁律：短小精悍

```c
static irqreturn_t my_isr(int irq, void *dev) {
    u32 status = readl(d->regs + STATUS);
    if (!(status & DONE)) return IRQ_NONE;   // 不是我的中断
    writel(status, d->regs + STATUS);        // 清 flag（忘清=中断风暴！）
    complete(&d->dma_done);                  // 唤醒等待者
    return IRQ_HANDLED;                      // 耗时活交给 workqueue
}
```

---

## 场景 5 · 多卡拓扑与数据传输流程

### 拓扑图：两种 GPU 互联

```
【纯 PCIe 拓扑】                    【NVLink 全互联（如 DGX）】

     CPU                                8× GPU
      │                                  全互联
   ┌──┴──┐                            (NVSwitch 交换)
   │     │                            GPU0 ── GPU1
 Switch  EP                          ─┼──────┼─
   │     │                          ││      ││
  GPU  GPU                         GPU2 ── GPU3
  0,1  2,3                          ...
  GPU0→GPU1 走 Switch 内部       任意两卡 NVLink 直连
  不占上行带宽 ✅                 900GB/s 双向合计，带一致性
```

### 数据传输流程：三种路径对比

```
【路径 A：经 CPU 中转（最慢）】
  卡A ─PCIe→ 主存 ─CPU拷贝→ 主存 ─PCIe→ 卡B
  ❌ 两次穿越 PCIe + CPU 搬运

【路径 B：PCIe P2P（绕过 CPU/主存）】
  卡A ──── Memory Write TLP ────→ Switch ────→ 卡B
       (目的地址=卡B 的 DMA 地址)
  ✅ 不经主存；依赖 IOMMU 翻译 + Switch 路由

【路径 C：NVLink 直连（最快，带一致性）】
  卡A ═══════ NVLink 高速链路 ═══════> 卡B
  ✅✅ 带宽高一个数量级 + 缓存一致性（共享显存语义）
```

### AllReduce 传输流程（分布式训练核心）

```
4 卡 Ring AllReduce（求和），每卡数据 S：

  卡0 ──→ 卡1 ──→ 卡2 ──→ 卡3 ──→ 卡0   (环)

  阶段1 Reduce-Scatter（N-1 步）：
    卡0 发 1/4 给卡1 累加 → 卡1 发给卡2 → ...
    每步每卡只发 1/N

  阶段2 AllGather（N-1 步）：
    反向绕一圈，把完整结果广播

  单卡通讯量 = 2×(N-1)/N × S ≈ 2S（N 大时趋近饱和，且严格小于 2S）
```

### 三种并行 → 三种通讯操作

| 并行 | 切分对象 | 通讯操作 | 跨机 |
|------|---------|---------|------|
| 数据并行 DP | 数据 | **AllReduce** | ✅ |
| 张量并行 TP | 单层权重 | **AllReduce**（序列并行下为 AllGather+ReduceScatter） | ❌ 限单机 |
| 流水线 PP | 模型分层 | **Send/Recv**（点对点） | ✅ |

---

## 场景 6 · 性能优化与常见问题排查

### 优化决策树

```
带宽不达标？
  │
  ├─ 硬件链路通吗？──否──→ lspci -vv 看 LnkSta（降速？）
  │                          dmesg 看有无 IOMMU fault
  │
  ├─ 软件数据通吗？──否──→ /proc/interrupts 看中断来了没
  │                          dmesg 看 DMA 是否正常
  │
  └─ 都通 → 是性能问题
        ├─ 通讯量太大？ → 量化/压缩/梯度累积
        ├─ 带宽利用低？ → 选对算法（Ring）/拓扑感知
        └─ 没重叠？    → 通讯-计算并行（分桶异步）
```

### 通讯时间公式（优化三方向）

```
通讯时间 = 通讯量 ÷ 有效带宽 × (1 - 重叠比例)
              │           │              │
         ① 减少通讯量  ② 提高带宽    ③ 提高重叠
         量化/压缩      选对算法       分桶异步
         梯度累积       拓扑感知       通讯计算并行
```

### 常见问题排查表

| 现象 | 最可能原因 | 排查命令 |
|------|-----------|---------|
| `lspci` 看不到卡 | 没插好/供电不足/卡没上电 | 重插、换插槽、查供电 |
| 设备显示 `[ffff:ffff]` | 配置空间没响应，PCIe IP 没起来 | 找硬件/RTL |
| 链路降速 x16→x8 | 金手指/插槽信号/retimer | 清洁金手指、换插槽 |
| `insmod` 报 Operation not permitted | Secure Boot 拒未签名模块 | `mokutil --sb-state`，关 SB |
| probe 没被调用（dmesg 静默） | ID 不匹配 / 设备被占 | `lspci -nn` 核对；`lspci -k` |
| `pci_request_regions` -EBUSY | BAR 被原驱动占用 | `rmmod` 原驱动 |
| DMA 不工作 | 忘 `pci_set_master` | probe 里调用 |
| IOMMU/DMAR fault | 访问未映射地址 | 检查 DMA 映射和地址位宽 |
| 中断数暴涨、系统卡死 | 中断风暴，ISR 忘清 flag | ISR 开头读 status、末尾清 |
| 卸载 Oops | probe/remove 资源没配对 | 对照逆序清理 |
| 带宽只有一半 | LnkSta 降速 | `lspci -vv` 查 LnkSta |

---

## 快速索引：深入哪个场景

| 场景 | 本教程 | 深入细节 |
|------|--------|---------|
| 1 PCIe 基础 | 上文 | `01_PCIE协议核心` |
| 2 枚举与驱动模型 | 上文 | `02_Linux_PCIe驱动开发` · `lab_01` |
| 3 配置空间与 BAR | 上文 | `01` 第 5-7 节 · `lab_04`（用户态读） |
| 4 DMA 与中断 | 上文 | `02` 第 5-7 节 · `06_零拷贝` |
| 5 多卡拓扑与传输 | 上文 | `03_多卡互联` · `07-13 多卡通讯子库` |
| 6 性能优化与排查 | 上文 | `04_优化与调试` · `troubleshooting` · `12_通讯性能优化` |
| 实战 bring-up | — | `硬件bring-up清单` |
| 术语查询 | — | `术语速查表` |

---

*配套学习库：`00_首页MOC.md`*
