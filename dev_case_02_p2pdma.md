---
tags: [开发案例, 多卡集群, P2PDMA, DMA, 驱动开发]
aliases: [dev_case_02, P2PDMA案例, 卡间直传]
created: 2026-11-19
status: 进行中
---

# Dev Case 02 · P2PDMA 卡间直传

> **目标**：用内核 P2PDMA 框架，让**同一 Switch 下两张卡之间的 DMA 直传**，绕过 CPU/主存。
> **为什么重要**：这是"多卡协同"最实在的性能收益——卡 A 直接把数据写进卡 B，不占用 CPU、不占用主存带宽。
> **前置**：[[dev_case_01_拓扑发现]]（先发现哪些卡可 P2P）

> ⚠️ **本案例 API 高度版本相关**。P2PDMA 框架约在 Linux 4.20 引入；**6.16 增加了显式的映射状态结构，6.19 又改为 `struct p2pdma_provider` 模型**。下面按三个版本区间给出真实接口。落地前**必须对照你目标内核的 `include/linux/pci-p2pdma.h` 与 `Documentation/driver-api/pci/p2pdma.rst`**。

---

## 一、要解决什么问题

```
传统路径（经 CPU/主存）：
  卡A ─PCIe→ 主存 ─CPU拷贝→ 主存 ─PCIe→ 卡B
  ❌ 两次穿越 PCIe + CPU 搬运 + 占主存带宽

P2P 直传路径：
  卡A ──── Memory Write TLP ────→ Switch ────→ 卡B
       (目的地址 = 卡B 暴露的 P2P 资源地址)
  ✅ 不经主存、不占 CPU；只在 Switch 内部走
```

P2PDMA 框架解决的核心问题：**让一个设备的 DMA 缓冲区，"变成"另一个设备可直接访问的总线地址**。

---

## 二、核心概念：Provider 与 Client

```
┌──────────────────────────────────────────────┐
│                P2PDMA 域                      │
│                                              │
│  Provider（资源提供方）= 卡B                  │
│    暴露一段"可被别的设备 DMA 访问的资源"      │
│    通常是它的一段 BAR / 内存                  │
│                                              │
│  Client（发起方）= 卡A                        │
│    想直接把数据 DMA 写进卡B 的那段资源        │
│                                              │
│  映射：把"卡B 资源的物理地址"                  │
│        转成"卡A 能用的 dma_addr"              │
└──────────────────────────────────────────────┘
```

**限制条件**（决定能否 P2P）：
1. 两卡在**同一个 IOMMU 域**（同 Switch 通常满足）
2. **ACS 未禁用** P2P（ACS 开启常禁用——经典坑）
3. 资源地址可被 client 的 DMA 引擎寻址（对齐、位宽）

---

## 三、关键 API（分三个版本区间，务必对照目标内核）

### 3.1 通用（4.20 至今，签名稳定）

| API | 作用 |
|-----|------|
| `int pci_p2pdma_distance(struct pci_dev *provider, struct device *client, bool verbose)` | 判断能否 P2P。`<0` 不可；`0/2/4/...` 为距离（同功能 0、同设备不同功能 2、同 Switch 4） |
| `int pci_p2pdma_add_resource(struct pci_dev *pdev, int bar, size_t size, u64 offset)` | 把某 BAR 的一段注册为 P2P 资源 |
| `void pci_p2pmem_publish(struct pci_dev *pdev, bool publish)` | 发布为可供他人分配的 P2P 内存（sysfs 出现 `p2pmem/`） |
| `void *pci_alloc_p2pmem(struct pci_dev *pdev, size_t size)` / `pci_free_p2pmem()` | 从 provider 分配/释放 P2P 内存 |
| `pci_bus_addr_t pci_p2pmem_virt_to_bus(struct pci_dev *pdev, void *addr)` | 虚拟地址 → 总线地址 |
| `struct scatterlist *pci_p2pmem_alloc_sgl(struct pci_dev *pdev, unsigned int *nents, u32 length)` | 分配 P2P scatterlist |

### 3.2 映射判定：三个版本区间

| 内核版本 | provider 侧 | 映射判定 |
|---------|------------|---------|
| **4.20 – 6.15** | `pci_p2pdma_add_resource()` + `pci_p2pmem_*` | **无公开映射函数**。P2P 页直接交给标准 `dma_map_sg()`，由 dma-direct / IOMMU 层内部判定 |
| **6.16 – 6.18** | 同上 | `pci_p2pdma_state(&st, dev, page)` + `pci_p2pdma_bus_addr_map(&st, paddr)`，`st` 是 `struct pci_p2pdma_map_state` |
| **6.19+** | `pcim_p2pdma_init(pdev)` + `pcim_p2pdma_provider(pdev, bar)` | `pci_p2pdma_map_type(prov, dev)` + `pci_p2pdma_bus_addr_map(prov, paddr)` |

> **版本边界是逐版本核对 `include/linux/pci-p2pdma.h` 得出的**：`pci_p2pdma_map_state` 首次出现在 **v6.16**；`struct p2pdma_provider` 与 `pcim_p2pdma_init()` 首次出现在 **v6.19**。二手资料里常见的"6.17+"标注是错的。

### 3.3 不存在 / 易混淆的接口（务必避开）

| 流传的名字 | 事实 |
|-----------|------|
| `pci_p2pdma_setup` | **不存在** |
| `pci_p2pdma_add_client` | **不存在** |
| `pci_p2pdma_enable` | **不存在**（只有 `pci_p2pdma_enable_show/store`，是 sysfs 辅助函数） |
| **`pci_p2pdma_map_resource`** | **从未存在于任何主线版本**（已核对 4.20 / 6.12 / 6.15 / 6.16 / 6.18 / 6.19） |
| `pci_p2pdma_map_sg` | **不存在**；P2P 页走标准 `dma_map_sg()` |

> **关键认知**：不存在"把 BAR 映射成 dma_addr 的专用函数"。P2P 的本质是 **页带有 P2P 属性 + 走标准 DMA 映射管线**；`pci_p2pdma_map_type()` 判定路径，`pci_p2pdma_bus_addr_map()` 只是在 `MAP_BUS_ADDR` 情况下做 `paddr + bus_offset` 的换算。

---

## 四、实现流程（按版本三套）

### 4.20 – 6.15

```
1. provider 侧注册资源
   pci_p2pdma_add_resource(provider_pdev, bar_index, size, offset);

2. （可选）发布，便于他人经 pci_alloc_p2pmem() 分配
   pci_p2pmem_publish(provider_pdev, true);

3. client 侧：把 p2p 页组成 sgl，直接走标准 DMA 管线
   dma_map_sg(&client_pdev->dev, sgl, nents, dir);

4. 预判：pci_p2pdma_distance() < 0 就别走这条路
   ⚠️ 此区间没有公开 API 能读到"是 BUS_ADDR 还是 THRU_HOST_BRIDGE"
```

### 6.16 – 6.18（map_state）

```
1. 同上注册资源
2. struct pci_p2pdma_map_state st;
   type = pci_p2pdma_state(&st, &client_pdev->dev, page);
3. type == PCI_P2PDMA_MAP_BUS_ADDR
       → dma_addr = pci_p2pdma_bus_addr_map(&st, page_to_phys(page));
   type == PCI_P2PDMA_MAP_THRU_HOST_BRIDGE
       → 用常规 dma_map_page()（走 IOVA / CPU 物理地址），仍可 P2P 但经 RC
   type == PCI_P2PDMA_MAP_NOT_SUPPORTED
       → 回退经 CPU
```

### 6.19+（provider）

```
1. ret = pcim_p2pdma_init(provider_pdev);        if (ret)      → 回退
2. prov = pcim_p2pdma_provider(provider_pdev, bar); if (!prov)  → 回退
3. type = pci_p2pdma_map_type(prov, &client_pdev->dev);
4. BUS_ADDR          → pci_p2pdma_bus_addr_map(prov, paddr)
   THRU_HOST_BRIDGE  → 常规 dma_map_page()
   NOT_SUPPORTED     → 回退经 CPU
```

---

## 五、生产级代码结构（示意）

```c
#include <linux/pci-p2pdma.h>

struct my_p2p_dev {
    struct pci_dev *pdev;
    /* 6.19+ 才有 */
    struct p2pdma_provider *provider;
    /* ... */
};

/* 初始化（仅 6.19+；6.16~6.18 无此步骤，6.15 及以前用 add_resource） */
static int setup_p2p_provider(struct my_p2p_dev *prov, int bar)
{
    int ret = pcim_p2pdma_init(prov->pdev);      /* devm 托管，返回 int */
    if (ret) {
        dev_warn(&prov->pdev->dev, "P2P not supported, will fallback\n");
        return ret;                              /* 不致命：上层走回退路径 */
    }
    prov->provider = pcim_p2pdma_provider(prov->pdev, bar);
    if (!prov->provider) {
        dev_warn(&prov->pdev->dev, "no P2P provider, fallback\n");
        return -ENODEV;
    }
    return 0;
}

/* 传输时判定映射类型：把"决策"和"映射"分开，调用方才好分三种情况处理 */
static enum pci_p2pdma_map_type
map_for_transfer(struct my_p2p_dev *prov, struct device *client_dev,
                 phys_addr_t paddr, dma_addr_t *bus_addr)
{
    enum pci_p2pdma_map_type type;

    if (!prov->provider)
        return PCI_P2PDMA_MAP_NOT_SUPPORTED;

    type = pci_p2pdma_map_type(prov->provider, client_dev);
    if (type == PCI_P2PDMA_MAP_BUS_ADDR)
        *bus_addr = pci_p2pdma_bus_addr_map(prov->provider, paddr);
    /* THRU_HOST_BRIDGE：仍是 P2P，但经 RC，调用方应改用常规 dma_map_page() */
    return type;
}
```

调用方按类型分三路：

```c
dma_addr_t addr = 0;
enum pci_p2pdma_map_type t = map_for_transfer(prov, &client->dev, paddr, &addr);

switch (t) {
case PCI_P2PDMA_MAP_BUS_ADDR:          /* Switch 内直通，最快 */
        use_bus_addr(addr);
        break;
case PCI_P2PDMA_MAP_THRU_HOST_BRIDGE:  /* 经 host bridge 白名单放行 */
        use_dma_map_page();            /* 仍比 CPU 拷贝快，但不如直通 */
        break;
default:                               /* NOT_SUPPORTED / 无 provider */
        fallback_via_cpu();
        break;
}
```

---

## 六、回退策略（生产必备）

P2P 不是总能用（跨 IOMMU、ACS、对齐、内核版本）。健壮的驱动必须有**回退**：

```
if (可 P2P) {
    dma_addr = p2p_map(...);
    if (成功) 走 P2P 直传;
}
if (P2P 不可用) {
    走传统路径：经 CPU/主存（慢但保证正确）
}
```

> **核心心法**：P2P 是**优化**，不是**依赖**。上层逻辑必须"P2P 可用走快路、不可用走慢路"都能跑，驱动才能在不同拓扑/BIOS/内核版本下健壮。

---

## 七、验证：怎么确认真走 P2P 了

1. **看距离**：`pci_p2pdma_distance` 返回 ≥0 说明拓扑允许（调试时开 `verbose=true` 会打印 ACS/白名单告警）
2. **看带宽**：P2P 前后测卡间传输带宽（应显著提升）
3. **看 CPU 占用**：P2P 时 CPU 占用应下降
4. **看主存流量**：P2P 时主存不该有对应流量（perf/带宽计数器）
5. **驱动日志**：加 `used_p2p` 日志，打印"P2P 走通"还是"回退经 CPU"

---

## 八、自检

- [ ] 能画出 P2P 直传 vs 经 CPU 中转的两条路径
- [ ] 理解 Provider / Client 角色和"资源地址映射成 dma_addr"的本质
- [ ] **知道 P2PDMA 映射接口有三个区间**（≤6.15 无公开函数 / 6.16–6.18 map_state / 6.19+ provider），会按目标内核选接口
- [ ] 知道 `pci_p2pdma_map_resource` 从未存在于主线，不会去"找这个函数"
- [ ] 知道 `pci_p2pdma_distance` 第二参是 `struct device *`、返回 -1 表示不可 P2P
- [ ] 知道 P2P 的限制条件（同 IOMMU 域、ACS 未禁用、地址可寻址）
- [ ] 理解为什么必须有"回退经 CPU"路径
- [ ] 知道怎么验证"真的走了 P2P"

---

## 🔗 关联笔记

- **前置**：[[dev_case_01_拓扑发现]]
- **下一步**：[[dev_case_03_peer_memory]]（跨机 GPUDirect 的内核基础）
- **背景**：[[03_多卡互联设计]] · [[06_零拷贝专题]]（P2P 是多卡零拷贝层次3）
- **版本区间**：[[18_内核版本适配矩阵]]（本篇三段代码对应哪个内核，以及 6.19 的签名变更）
- **能不能 P2P**：[[15_IOMMU_ACS与P2P可行性]]（ACS 与 host bridge 白名单）
- **权威文档**：内核 `Documentation/driver-api/pci/p2pdma.rst` · `include/linux/pci-p2pdma.h`
- **返回**：[[多卡集群驱动开发技能地图]]

## 📝 我的学习记录

- **YYYY-MM-DD**：
