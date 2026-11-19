---
tags: [开发案例, 多卡集群, 拓扑发现, 驱动开发]
aliases: [dev_case_01, 拓扑发现案例]
created: 2026-11-19
status: 进行中
---

# Dev Case 01 · 多卡拓扑发现

> **目标**：写一个驱动，加载后**枚举系统中所有同类卡**，判断它们两两之间的拓扑关系（是否同 Switch / 同 NUMA / 是否可 P2P），并打印一张拓扑矩阵。
> **为什么这是第一步**：集群驱动的核心是"让多卡协同"，而协同的前提是**知道哪些卡靠近、能直传**。拓扑发现是一切调度的依据。
> **前置**：[[02_Linux_PCIe驱动开发]]（probe/BAR/DMA 基础）

---

## 一、要解决什么问题

多卡集群里，N 张卡不一定"平权"：

```
同一 Switch 下的两卡 → 可 P2P 直传（快）
跨 Switch / 跨 NUMA → 要经 CPU/RC（慢）
有 NVLink 的两卡    → 高带宽 + 一致性（最快）
```

上层（NCCL / 推理调度）需要一张**"谁挨着谁"的拓扑表**来决定"把哪两张卡分到一组"。本案例就是**在内核驱动里构建这张表**。

---

## 二、核心 API

| API | 作用 |
|-----|------|
| `pci_bus_type` / `bus_for_each_dev` | 遍历总线上所有设备 |
| `to_pci_dev(dev)` | 从 `struct device*` 转成 `struct pci_dev*` |
| `pci_domain_nr(pdev->bus)` / `pdev->bus->number` / `PCI_SLOT/FUNC` | 取 BDF（域/总线/槽/功能） |
| `pci_p2pdma_distance(provider, client_dev, verbose)` | **判断能否 P2P 及距离**：返回 `-1` 不可 P2P、`0` 同卡、`>0` 距离。**第二参是 `struct device *`**（传 `&pdev->dev`） |
| `dev_to_node(&pdev->dev)` | 取设备所在 NUMA 节点（无 NUMA 返回 `-1`/`NUMA_NO_NODE`） |
| `bus_for_each_dev(&pci_bus_type, ...)` 或维护自己的设备链表 | 枚举同类卡（**不要用已从主线移除的 `pci_dev_present()`**） |

---

## 三、实现思路

```
probe(每张卡被枚举时调用)
  ├─ 把本卡加入驱动维护的设备链表（card_list）
  └─ 触发一次"拓扑刷新"（最后一卡加载后）

build_topology()
  for 每对卡 (a, b) in card_list:
      dist = pci_p2pdma_distance(a->pdev, &b->pdev->dev, false)
      if dist == -1:      关系 = "不可 P2P（跨 IOMMU/ACS 禁用）"
      else if dist == 0:  关系 = "同一张卡"
      else:               关系 = "可 P2P，距离=dist（同 Switch 通常=4，越小越近）"
  打印 N×N 拓扑矩阵
```

---

## 四、可编译示例（含注释）

```c
// SPDX-License-Identifier: GPL-2.0
/* multi_card_topo.c — 多卡拓扑发现（教学案例）
 * 编译见 dev_case 配套 Makefile。加载后 dmesg 打印拓扑矩阵。
 */
#include <linux/module.h>
#include <linux/pci.h>
#include <linux/pci-p2pdma.h>
#include <linux/device.h>
#include <linux/list.h>
#include <linux/mutex.h>

#define DRV_NAME "mc_topo"
#define MY_VENDOR 0x1234      /* 换成你的卡厂商 ID */
#define MY_DEVICE 0x5678      /* 换成你的卡设备 ID */

/* 驱动维护的"同类卡"链表节点 */
struct mc_card {
    struct list_head list;
    struct pci_dev  *pdev;
    int              idx;      /* 卡序号（加载顺序） */
    int              node;     /* NUMA 节点；-1 表示无 NUMA 信息 */
};

static LIST_HEAD(card_list);        /* 卡链表 */
static DEFINE_MUTEX(card_lock);     /* 保护链表 */
static int nr_cards;                /* 卡数量 */
static int card_seq;                /* 单调递增序号 */

/* 判断两卡的拓扑关系，返回可读字符串 */
static const char *topo_rel(struct mc_card *a, struct mc_card *b, int *dist_out)
{
    int dist;
    if (a == b) {
        *dist_out = 0;
        return "self";
    }
    /* 第二参是 struct device *：传 &pdev->dev，不是 pdev 本身
     * 返回值：<0 不可 P2P；0 同一功能；2 同设备不同功能；4 同 Switch；
     *         更大 = 更远（中间多一级 Switch/RC） */
    dist = pci_p2pdma_distance(b->pdev, &a->pdev->dev, false);
    *dist_out = dist;
    if (dist < 0)
        return "no-p2p";            /* ACS redirect 且 host bridge 不在白名单，或非 PCI 设备 */
    return "p2p";                   /* 可 P2P；dist 越小越近 */
}

/* 构建并打印 N×N 拓扑矩阵 */
static void build_topology(void)
{
    struct mc_card *a, *b;
    int dist;

    pr_info(DRV_NAME ": ===== 拓扑矩阵 (%d 卡) =====\n", nr_cards);

    mutex_lock(&card_lock);
    list_for_each_entry(a, &card_list, list) {
        list_for_each_entry(b, &card_list, list) {
            const char *rel = topo_rel(a, b, &dist);
            pr_info(DRV_NAME ": card[%d]=%04x:%02x:%02x.%x(node %d)  <->  card[%d](node %d) : %s (dist=%d)\n",
                a->idx,
                pci_domain_nr(a->pdev->bus), a->pdev->bus->number,
                PCI_SLOT(a->pdev->devfn), PCI_FUNC(a->pdev->devfn),
                a->node,
                b->idx, b->node, rel, dist);
        }
    }
    mutex_unlock(&card_lock);

    pr_info(DRV_NAME ": ================================\n");
}

/* probe：每张卡被发现时调用 */
static int mc_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
    struct mc_card *card;
    bool do_refresh = false;

    card = devm_kzalloc(&pdev->dev, sizeof(*card), GFP_KERNEL);
    if (!card)
        return -ENOMEM;
    card->pdev = pdev;
    card->node = dev_to_node(&pdev->dev);   /* 无 NUMA 时返回 -1 */

    mutex_lock(&card_lock);
    card->idx = card_seq++;
    list_add_tail(&card->list, &card_list);
    nr_cards++;
    /* 约定：加载到第 2 张卡起，刷新拓扑（生产中可由工作队列延迟刷新） */
    if (nr_cards >= 2)
        do_refresh = true;
    mutex_unlock(&card_lock);

    pci_set_drvdata(pdev, card);
    pci_info(pdev, "registered as card[%d], total=%d\n", card->idx, nr_cards);

    if (do_refresh)
        build_topology();

    return 0;
}

static void mc_remove(struct pci_dev *pdev)
{
    struct mc_card *card = pci_get_drvdata(pdev);

    mutex_lock(&card_lock);
    list_del(&card->list);
    nr_cards--;
    mutex_unlock(&card_lock);
    pci_info(pdev, "removed card[%d], total=%d\n", card->idx, nr_cards);
}

static const struct pci_device_id mc_ids[] = {
    { PCI_DEVICE(MY_VENDOR, MY_DEVICE) },
    { 0, }
};
MODULE_DEVICE_TABLE(pci, mc_ids);

static struct pci_driver mc_driver = {
    .name     = DRV_NAME,
    .id_table = mc_ids,
    .probe    = mc_probe,
    .remove   = mc_remove,
};
module_pci_driver(mc_driver);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Multi-card topology discovery (teaching case)");
```

---

## 五、预期输出（dmesg）

```
mc_topo 0000:01:00.0: registered as card[0], total=1
mc_topo 0000:02:00.0: registered as card[1], total=2
mc_topo: ===== 拓扑矩阵 (2 卡) =====
mc_topo: card[0]=0000:01:00.0(node 0)  <->  card[0](node 0) : self (dist=0)
mc_topo: card[0]=0000:01:00.0(node 0)  <->  card[1](node 0) : p2p (dist=4)
mc_topo: card[1]=0000:02:00.0(node 0)  <->  card[0](node 0) : p2p (dist=4)
mc_topo: card[1]=0000:02:00.0(node 0)  <->  card[1](node 0) : self (dist=0)
mc_topo: ================================
```

**距离值的含义（源码 `calc_map_type_and_dist()` 定义）**：

| dist | 含义 |
|------|------|
| 0 | 同一个 PCI 功能（自己和自己） |
| 2 | 同一设备的不同功能（如 01:00.0 与 01:00.1） |
| 4 | 同一个 PCIe Switch 下的两个下行口，最典型的"可直传"关系 |
| 更大 | 中间还夹了多级 Switch / RC，越远越差 |
| -1 | 不可 P2P：ACS redirect 且 host bridge 不在白名单 / 非 PCI 设备 / 跨域 |

> ⚠️ `dist >= 0` 只说明"**允许** P2P"，不区分是"Switch 内直通"还是"经 host bridge 白名单放行"。要区分必须看映射类型：6.16~6.18 用 `pci_p2pdma_state()`，6.19+ 用 `pci_p2pdma_map_type()`（`MAP_BUS_ADDR` 才是真正的 Switch 内直通）。

---

## 六、可扩展点（贴近生产）

1. **按 NUMA 分组**：代码已记录 `node`；可进一步把"同 node + 同 Switch"的卡归为一个亲和域，供调度器优先选择。
2. **区分直通与经桥**：用 6.16+ 的 `pci_p2pdma_state()` / 6.19+ 的 `pci_p2pdma_map_type()` 判定 `MAP_BUS_ADDR` 还是 `THRU_HOST_BRIDGE`，后者带宽与延迟明显更差。
2. **结合 NVLink**：若有 NVLink，读 NVLink 拓扑（如通过厂商接口/`nvidia-smi topo` 的内核等价）标记"NV# 关系"，优先级高于 PCIe P2P。
3. **暴露给上层**：把拓扑表通过 sysfs/debugfs 暴露，供 NCCL/调度器读取。
4. **动态刷新**：用工作队列在卡增删后延迟刷新，而不是在 probe 里同步刷（避免热插拔抖动）。

---

## 七、自检

- [ ] 能说出"为什么集群驱动要先做拓扑发现"
- [ ] 理解 `pci_p2pdma_distance` 返回值的含义（-1 不可 P2P / 0 同卡 / >0 距离），且知道**第二参是 `struct device *`**
- [ ] 知道可用 `dev_to_node(&pdev->dev)` 取 NUMA 节点
- [ ] 能用 `bus_for_each_dev` 或 probe 链表枚举同类卡
- [ ] 知道 `no-p2p` 的常见原因（跨 IOMMU 域 / ACS）
- [ ] 能扩展成"拓扑表 + NUMA + NVLink"的生产版

---

## 🔗 关联笔记

- **前置**：[[02_Linux_PCIe驱动开发]]
- **下一步**：[[dev_case_02_p2pdma]]（让可 P2P 的卡真正直传）
- **背景**：[[03_多卡互联设计]] · [[集群高速IO问题排查]]
- **返回**：[[多卡集群驱动开发技能地图]]

## 📝 我的学习记录

- **YYYY-MM-DD**：
