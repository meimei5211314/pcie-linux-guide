---
tags: [Linux驱动, PCIe, DMA, 中断]
aliases: [PCIe驱动开发, 驱动开发主线]
created: 2026-11-18
status: 进行中
---

# 02 · Linux PCIe 驱动开发主线

> **上一篇**：[[01_PCIE协议核心]]　|　**下一篇**：[[lab_01_first_probe]]　|　**进度**：[[学习进度追踪]]

> 目标：理解任何 PCIe 驱动都是「配置 + 映射 + 数据通路 + 中断」四件事。读完能看懂 `code/pci_skeleton.c`。

## 0. 驱动骨架总览（背下这个流程）

```
模块加载
  └─ module_pci_driver() 注册 pci_driver
设备插入 / 系统枚举匹配到 pci_device_id
  └─ .probe(pdev, id)              ← 入口
       ├─ pci_enable_device()
       ├─ pci_request_regions()    ← 申请 BAR
       ├─ pci_iomap / ioremap      ← 映射寄存器
       ├─ pci_set_master()         ← 开 DMA
       ├─ pci_alloc_irq_vectors()  ← 申请 MSI-X
       ├─ request_irq()            ← 绑定中断处理
       ├─ dma_alloc_coherent()     ← DMA 缓冲
       ├─ 注册字符设备/misc         ← 给用户态访问
       └─ 启动硬件
移除 / 卸载
  └─ .remove(pdev)                 ← 反向清理
```

## 1. 匹配：`pci_device_id` 表

内核靠这张表决定"这个设备归我"：

```c
static const struct pci_device_id my_ids[] = {
    { PCI_DEVICE(MY_VENDOR_ID, MY_DEVICE_ID) },
    { PCI_DEVICE_CLASS(0x120000, 0xffffff) },  /* 可选：按 class 匹配 */
    { 0, }
};
MODULE_DEVICE_TABLE(pci, my_ids);
```

## 2. probe：拿到设备并做初始化

关键 API（详见 `code/pci_skeleton.c` 注释）：

| API | 作用 |
|-----|------|
| `pci_enable_device(pdev)` | 使能设备（含电源、命令寄存器基本位） |
| `pci_request_regions(pdev, name)` | 申请所有 BAR 区域，防止冲突 |
| `pci_resource_start/len(pdev, bar)` | 拿 BAR 物理基地址/长度 |
| `pci_iomap(pdev, bar, len)` | 把 BAR 映射为内核可访问地址（或 `ioremap`） |
| `pci_set_master(pdev)` | 置 Command 的 Bus Master 位，**允许 DMA** |
| `dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(64))` | 声明能寻址的 DMA 位宽（老教程里的 `pci_set_dma_mask` 已过时） |
| `pci_alloc_irq_vectors(pdev, min, max, PCI_IRQ_MSIX)` | 申请 MSI-X 向量 |
| `pci_irq_vector(pdev, idx)` | 取第 idx 个中断号 |
| `request_irq(irq, handler, 0, name, dev)` | 绑定 ISR |

> 记住：**映射 BAR → 拿到寄存器指针 → readl/writel**，这是访问硬件寄存器的标准方式。

## 3. 访问寄存器：readl/writel

```c
writel(value, base + OFFSET);     /* 写 32 位寄存器 */
u32 v = readl(base + OFFSET);     /* 读 32 位寄存器 */
```

- `__iomem` 标注的指针告诉编译器"这是设备内存，别优化错顺序"。
- 用 `writel_relaxed/readl_relaxed` 可省内存屏障（性能敏感处）。

## 4. 中断处理 ISR

```c
static irqreturn_t my_isr(int irq, void *dev)
{
    struct my_dev *d = dev;
    u32 status = readl(d->reg + STATUS);
    if (!(status & IRQ_PENDING))
        return IRQ_NONE;           /* 不是我的中断（共享时） */
    writel(status, d->reg + STATUS);  /* 清中断标志 */
    /* 处理：完成包、收包、推工作队列… */
    return IRQ_HANDLED;
}
```

原则：**ISR 里做事要短**。耗时的处理丢给工作队列 / tasklet / 线程化中断（`request_threaded_irq`）。

## 5. DMA：把数据通路搭起来

两种模式：

### 一致性 DMA（coherent / consistent）
- `dma_alloc_coherent(dev, size, &dma_handle, GFP_KERNEL)`
- 返回 CPU 虚拟地址 + 设备总线地址（dma_handle），**双向常驻，无需每次同步**。
- 适合：描述符环、命令队列、小而频繁访问的共享数据。

### 流式 DMA（streaming）
- 先 `kmalloc` 普通 buffer，每次传输前 `dma_map_single()` 映射，用完 `dma_unmap_single()`。
- 适合：大块、一次性的收发数据（如网络包、视频帧）。

**必须注意 CPU 与设备的一致性**：映射后 CPU 别碰 buffer；读回前 `dma_sync_single_for_cpu()`。

### DMA 描述符环（Descriptor Ring）
高性能设备的核心模式：

```
驱动准备一张环形描述符表（coherent）：
  [desc0] → 指向 buffer0 的 dma 地址
  [desc1] → 指向 buffer1 的 dma 地址
  ...
设备按描述符直接搬数据，搬完触发 MSI-X。
```
NVMe、网卡、GPU 全是这套。学一个，处处能用。

## 6. 用户态访问：字符设备

让应用能 open/read/write/ioctl/mmap 你的设备：

- 简单：`misc_register()`（自动出现在 /dev/mydev）
- 灵活：`alloc_chrdev_region` + `cdev_init` + `class_create`
- **mmap BAR** 给用户态：性能敏感场景把寄存器直接暴露给用户程序（省 readl 系统调用开销）。

## 7. remove：干净地反着拆一遍

```
释放 IRQ → free_irq
销毁 MSI-X → pci_free_irq_vectors
释放 DMA → dma_free_coherent
解除映射 → pci_iounmap
释放 BAR → pci_release_regions
关闭设备 → pci_disable_device
注销字符设备
```

> **顺序和 probe 相反**。漏掉任一步会导致资源泄漏或卸载崩溃。

## 8. 一个高频坑清单

| 坑 | 症状 | 对策 |
|----|------|------|
| 忘 `pci_set_master` | DMA 不工作 | probe 里调用 |
| DMA mask 没设 | 设备只能用 32 位地址 / 落到 bounce buffer | `dma_set_mask_and_coherent` |
| BAR 映射了错 index | 读写无效果 / 崩溃 | 用 `lspci` 确认 BAR 布局 |
| ISR 忘清中断 | 中断风暴，系统卡死 | ISR 开头读 status、末尾清 flag |
| 32 位设备映射 BAR 高于 4G | 映射失败 | 检查 BAR 类型（64 位 BAR 占两个槽） |
| coherent / streaming 用错 | 数据错乱 | 高频共享用 coherent，大块用 streaming + sync |
| 把未初始化 DMA 缓冲交给用户态 | 内核信息泄漏（安全） | probe 里 `memset(dma_buf, 模式, size)`，只返回已知/硬件写入的数据 |
| 单 completion / 单 buffer 多进程并发 | 一次唤醒丢失、另一进程永久阻塞 / 数据交叉损坏 | 用 mutex 把"触发→等待→拷贝"整段串行化 |
| 64 位 DMA 地址只写低 32 位 | 高地址（>4G）截断 → IOMMU fault / 写错地址 | 拆 ADDR_HI/ADDR_LO，HI/LO 都要写 |
| misc 用固定名做多卡 | 第二张卡 `misc_register` 返回 `-EEXIST` | 用 `pci_skel+devfn` 之类生成唯一名 |
| completion 未 `reinit_completion` 就复用 | 偶发"本次 read 立刻返回上一轮旧数据"（迟到/多余中断留下的完成量） | 每次触发 DMA 前 `reinit_completion()` |

## 9. 学习捷径：读真实驱动

看懂骨架后，去内核源码读这几个，对着四件事（配置/映射/通路/中断）找：

- `drivers/misc/` —— 简单设备，入门友好
- `drivers/net/ethernet/intel/igb/` —— 经典 DMA 描述符环 + MSI-X
- `drivers/nvme/host/pci.c` —— 现代高性能 PCIe 存储，MSI-X + 多队列范本

## 10. 自检

- probe 里最少要调用哪几个 `pci_*`？
- 一致性 DMA 和流式 DMA 的区别和选择依据？
- 为什么 ISR 里别做耗时操作？
- 怎么把一个 BAR 暴露给用户态程序？
- 为什么不能把未初始化的 DMA 缓冲 `copy_to_user` 给用户态？

> 能答就进 `03_多卡互联设计.md`；想先动手就做 `lab_01_first_probe.md`，报错查 `troubleshooting.md`。

## 11. 动手改造任务（选做，加深理解）

1. **加 `.write`**：把用户态传入的数据用 `memcpy_toio` 写到 BAR0 +0x20 的寄存器。
2. **mmap 读 REG_ID**：用骨架的 `.mmap`，写用户态程序 `mmap` BAR0 后直接
   `*(volatile uint32_t*)` 读 ID，用 `perf stat` 对比 `read()` 系统调用路径的开销。
3. **加第二个 BAR**：假设设备还有 BAR2，用 `pci_resource_start(pdev,2)` + `pci_iomap(pdev,2,0)`
   映射并打印长度，用 `lspci -vv` 核对 BAR2 大小是否和你读到的一致。
4. **多 MSI-X 向量**：把 `pci_alloc_irq_vectors` 的 max 改成 4，给每条向量绑单独 ISR，
   打印是哪条向量触发的（用 `pci_irq_vector` 区分）。
5. **中断改轮询**：注释掉 request_irq，在 `skel_read` 里 `while(!(readl(STATUS)&DMA_DONE));`，
   对比两种方式 read 一次的延迟（理解"为什么用中断而不是轮询"）。

---

## 🔗 关联笔记

- **上一站**：[[01_PCIE协议核心]]　**动手**：[[lab_01_first_probe]]
- **相关**：[[06_零拷贝专题]]（DMA 零拷贝）、[[04_优化与调试]]（驱动调优）
- **排错**：[[troubleshooting]]　**自测**：[[05_面试与原理问答]]（驱动层 Q6–Q10）
- **返回**：[[00_首页MOC]]

## 📝 我的学习记录

- **YYYY-MM-DD**：
