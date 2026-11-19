---
tags: [开发案例, 多卡集群, MSI-X, 中断亲和, 多队列, 驱动开发]
aliases: [dev_case_04, 多队列MSI-X案例, 中断亲和]
created: 2026-11-19
status: 进行中
---

# Dev Case 04 · 多队列 MSI-X 与中断亲和

> **目标**：给设备申请**多条 MSI-X 向量**，**每条队列绑一条中断**，并用**中断亲和（affinity）**把不同队列的中断绑到不同 CPU 核，避免中断风暴、提升多核并行收发性能。
> **为什么重要**：多卡集群里，单卡往往是多队列（多通道/channel）收发。如果所有队列共享一根中断、挤在一个核，就是瓶颈和中断风暴来源。多队列 + 中断亲和是多通道高吞吐的基础。
> **前置**：[[02_Linux_PCIe驱动开发]]（MSI-X 基础）

---

## 一、要解决什么问题

```
❌ 单中断（所有队列共享一根 MSI-X / INTx）：
   队列0 ─┐
   队列1 ─┼─→ 一根中断 → 一个 CPU 核处理
   队列2 ─┘   → 该核成为瓶颈；中断风暴；其他核空闲

✅ 多队列 + 每队列一向量 + 中断亲和：
   队列0 → 向量0 → CPU0
   队列1 → 向量1 → CPU1     ← 分散到多核，并行处理
   队列2 → 向量2 → CPU2     ← 无单点瓶颈，无风暴
```

这是现代高性能设备（NVMe 多命名空间、100G 网卡多通道、加速器多引擎）的标准设计。

---

## 二、核心 API

| API | 作用 |
|-----|------|
| `pci_alloc_irq_vectors(pdev, min, max, PCI_IRQ_MSIX)` | 申请多条 MSI-X 向量（返回实际申请到的数量） |
| `pci_irq_vector(pdev, i)` | 取第 i 条向量对应的 Linux IRQ 号 |
| `request_irq(irq, isr, 0, name, dev)` | 给某队列绑 ISR。**dev 是第 5 个参数**，作为 ISR 的第 2 形参 `dev_id` 传入 |
| `irq_set_affinity_and_hint(irq, mask)` | **设置中断亲和（强制应用）+ 提示**。⚠️ 旧的 `irq_set_affinity_hint` 已废弃 |
| `irq_update_affinity_hint(irq, mask)` | **只更新提示、不强制改变亲和**（若只想要"提示"语义用这个） |
| `cpumask_set_cpu` / `cpumask_clear` / `cpumask_local_spread` | 构造亲和掩码（分散到多核；`cpumask_local_spread` 还按 NUMA 节点选） |

> ⚠️ **废弃 API 警告**：内核源码标注 `irq_set_affinity_hint` **已废弃**（Deprecated）。它实际等价于"应用亲和 + 提示"，会把 mask 强制应用为真正的亲和性。**若只想要"提示不强制"，用 `irq_update_affinity_hint`；若要"应用+提示"，用 `irq_set_affinity_and_hint`**。二者通过内部 `__irq_apply_affinity_hint(irq, mask, bool setaffinity)` 区分。本案例用"应用+提示"语义，故用 `irq_set_affinity_and_hint`。

---

## 三、实现思路

```
probe:
  nvec = pci_alloc_irq_vectors(pdev, 1, NUM_QUEUES, PCI_IRQ_MSIX);
  for i in 0..nvec-1:
      irq = pci_irq_vector(pdev, i);
      request_irq(irq, my_isr, 0, "mydev", &queues[i]);
      // 中断亲和：按 NUMA 就近 + 轮转选 CPU，再应用
      cpu = cpumask_local_spread(i, dev_to_node(&pdev->dev));
      cpumask_clear(&mask);
      cpumask_set_cpu(cpu, &mask);
      irq_set_affinity_and_hint(irq, &mask);

ISR(dev_id):   // dev_id = 对应队列结构
  queue = dev_id;               // 知道是哪个队列的中断
  处理该队列的完成包，不碰其他队列
```

---

## 四、可编译示例（含注释）

```c
// SPDX-License-Identifier: GPL-2.0
/* multi_queue_msix.c — 多队列 MSI-X + 中断亲和（教学案例） */
#include <linux/module.h>
#include <linux/pci.h>
#include <linux/device.h>
#include <linux/interrupt.h>
#include <linux/cpumask.h>

#define DRV_NAME  "mq_msix"
#define NUM_QUEUE 4
#define MY_VENDOR 0x1234
#define MY_DEVICE 0x5678

/* 每个队列的私有数据 */
struct mq_queue {
    int          index;
    int          irq;
    void __iomem *regs;
    /* 收发计数、NAPI/工作队列等 */
    unsigned long packets;
};

struct mq_dev {
    struct pci_dev   *pdev;
    void __iomem     *regs;
    int               nvec;
    struct mq_queue   queues[NUM_QUEUE];
};

/* ISR：dev_id 指明是哪个队列，只处理该队列 */
static irqreturn_t mq_isr(int irq, void *dev_id)
{
    struct mq_queue *q = dev_id;
    u32 status;

    /* 真实设备必须：读该队列的中断状态 → 判断是不是自己 → 清零 → 处理完成项。
     * 漏掉"清零"就是中断风暴（本案例为了突出亲和性，把寄存器部分省略了）。 */
    status = readl(q->regs + 0x20 + q->index * 0x10);   /* 假设的 per-queue 状态寄存器 */
    if (!(status & 0x1))
        return IRQ_NONE;
    writel(status, q->regs + 0x20 + q->index * 0x10);   /* 写 1 清零 */

    q->packets++;
    return IRQ_HANDLED;
}

static int mq_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
    struct mq_dev *d;
    cpumask_t mask;
    int ret, i;

    d = devm_kzalloc(&pdev->dev, sizeof(*d), GFP_KERNEL);
    if (!d) return -ENOMEM;
    d->pdev = pdev;
    pci_set_drvdata(pdev, d);

    if ((ret = pci_enable_device(pdev))) return ret;
    pci_set_master(pdev);
    if ((ret = pci_request_regions(pdev, DRV_NAME))) goto err_disable;
    d->regs = pci_iomap(pdev, 0, 0);
    if (!d->regs) { ret = -ENOMEM; goto err_regions; }

    /* 申请 NUM_QUEUE 条 MSI-X 向量 */
    d->nvec = pci_alloc_irq_vectors(pdev, 1, NUM_QUEUE, PCI_IRQ_MSIX);
    if (d->nvec < 1) { ret = d->nvec; goto err_iounmap; }

    /* 每条队列：绑一个中断 + 设中断亲和 */
    for (i = 0; i < d->nvec; i++) {
        struct mq_queue *q = &d->queues[i];
        unsigned int cpu;
        q->index = i;
        q->regs  = d->regs;
        q->irq   = pci_irq_vector(pdev, i);

        ret = request_irq(q->irq, mq_isr, 0, DRV_NAME, q);  /* dev_id = 队列 */
        if (ret) goto err_free_irq;

        /* 中断亲和：优先选"离本设备 NUMA 节点最近"的 CPU，再分散。
         * 比 i % nr_cpu_ids 更稳：不会选到 isolated CPU，也贴合 NUMA。 */
        cpu = cpumask_local_spread(i, dev_to_node(&pdev->dev));
        cpumask_clear(&mask);
        cpumask_set_cpu(cpu, &mask);
        irq_set_affinity_and_hint(q->irq, &mask);

        pci_info(pdev, "queue[%d] -> irq=%d -> cpu%u\n", i, q->irq, cpu);
    }

    return 0;

err_free_irq:
    while (--i >= 0) free_irq(d->queues[i].irq, &d->queues[i]);
    pci_free_irq_vectors(pdev);
err_iounmap:
    pci_iounmap(pdev, d->regs);
err_regions:
    pci_release_regions(pdev);
err_disable:
    pci_disable_device(pdev);
    return ret;
}

static void mq_remove(struct pci_dev *pdev)
{
    struct mq_dev *d = pci_get_drvdata(pdev);
    int i;
    for (i = 0; i < d->nvec; i++)
        free_irq(d->queues[i].irq, &d->queues[i]);
    pci_free_irq_vectors(pdev);
    pci_iounmap(pdev, d->regs);
    pci_release_regions(pdev);
    pci_disable_device(pdev);
}

static const struct pci_device_id mq_ids[] = {
    { PCI_DEVICE(MY_VENDOR, MY_DEVICE) }, { 0, }
};
MODULE_DEVICE_TABLE(pci, mq_ids);

static struct pci_driver mq_driver = {
    .name = DRV_NAME, .id_table = mq_ids,
    .probe = mq_probe, .remove = mq_remove,
};
module_pci_driver(mq_driver);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Multi-queue MSI-X + IRQ affinity (teaching case)");
```

---

## 五、预期输出（dmesg）

```
mq_msix 0000:01:00.0: queue[0] -> irq=42 -> cpu0
mq_msix 0000:01:00.0: queue[1] -> irq=43 -> cpu1
mq_msix 0000:01:00.0: queue[2] -> irq=44 -> cpu2
mq_msix 0000:01:00.0: queue[3] -> irq=45 -> cpu3
```

验证中断分散：
```bash
cat /proc/interrupts | grep mq_msix
# 各队列的中断应落在不同 CPU 列上
watch -n1 "cat /proc/interrupts | grep mq_msix"
# 高负载时各核中断计数都在增长（不是集中在一个核）
```

---

## 六、生产级要点

0. **更省事的做法：让内核帮你分散亲和**。`pci_alloc_irq_vectors_affinity()` 会按 NUMA 拓扑自动生成亲和掩码，不必自己 `cpumask_set_cpu(i % nr_cpu_ids)`：

   ```c
   static const struct irq_affinity affd = { .pre_vectors = 0, .post_vectors = 0 };
   nvec = pci_alloc_irq_vectors_affinity(pdev, 1, NUM_QUEUE,
                                         PCI_IRQ_MSIX, &affd);
   ```

   手工绑核适合"队列与业务线程必须严格对应"的场景；否则优先用 affinity 版本。

1. **每队列独立数据结构**：ISR 通过 `dev_id` 直接拿到队列，无需查表/加锁——这是"每队列一向量"的核心收益。
2. **中断亲和 vs RPS/XPS**：网络场景还配合 RPS/XPS 把"包处理"也分散，不只是中断。
3. **NUMA 亲和**：进一步让队列中断绑到"离该队列数据最近的 NUMA 节点"的核（结合 [[dev_case_01_拓扑发现]] 的 NUMA 信息）。
4. **中断合并（coalescing）**：高吞吐场景开中断合并，减少中断次数（权衡延迟）。
5. **别用 `i % nr_cpu_ids` 硬套**：队列数可能大于核数，`nr_cpu_ids` 是"最大可能编号"而非"在线 CPU 数"，且可能选到 isolated CPU。用 `cpumask_local_spread(i, node)` 更稳。

---

## 七、自检

- [ ] 能画出"单中断 vs 多队列多向量"的对比图
- [ ] 知道 `pci_alloc_irq_vectors` 的 min/max 含义
- [ ] 理解 ISR 通过 `dev_id` 拿到队列、无需查表
- [ ] 会用 `irq_set_affinity_and_hint`（应用+提示）或 `irq_update_affinity_hint`（纯提示）做中断亲和，并知道 `irq_set_affinity_hint` 已废弃
- [ ] 知道用 `/proc/interrupts` 验证中断是否分散到多核
- [ ] 理解多队列 + 亲和是"多通道高吞吐、防中断风暴"的基础

---

## 🔗 关联笔记

- **前置**：[[02_Linux_PCIe驱动开发]]（MSI-X 基础）
- **同层案例**：[[dev_case_01_拓扑发现]] · [[dev_case_02_p2pdma]] · [[dev_case_03_peer_memory]]
- **排查**：[[集群高速IO问题排查]]（中断风暴、NUMA）
- **返回**：[[多卡集群驱动开发技能地图]]

## 📝 我的学习记录

- **YYYY-MM-DD**：
