---
tags: [开发案例, 多卡集群, GPUDirect, DMA-BUF, peer_memory, 驱动开发]
aliases: [dev_case_03, 显存直连案例, GPUDirect内核基础]
created: 2026-11-19
updated: 2026-11-19
status: 进行中
api_verified: 已核对主线头文件与上游讨论；peer-memory 确认为 OFED 专有，DMA-BUF 为主线方案
---

# Dev Case 03 · 加速器显存与网卡直连：peer-memory 与 DMA-BUF 两条路线

> **目标**：把"网卡的 DMA 引擎如何直接读写 GPU/NPU 显存"这件事在内核层的实现讲清楚，并区分**历史路线（peer-memory）**与**主线路线（DMA-BUF）**。
> **为什么重要**：这是 GPUDirect RDMA 的内核基础。搞错路线，会在 bring-up 阶段浪费数天（典型现象：`modprobe nvidia-peermem` 永远失败，却查不出原因）。
> **前置**：[[dev_case_02_p2pdma]]（P2P 与 DMA 地址映射）、[[11_GPUDirect与RDMA]]（用户态视角）

> ⚠️ **本篇做过一次事实修正**：早期版本把 `ib_register_peer_memory_client()` 写成"主线 `include/rdma/ib_verbs.h` 中已核实的稳定 API"。**这是错的**——该符号从未进入 Linux 主线，详见第三节。现已按事实重写。

---

## 一、要解决什么问题

跨机 GPU 通讯，没有显存直连时：

```
A机 GPU显存 → CPU内存 → A机网卡 → 网络 → B机网卡 → CPU内存 → B机 GPU显存
                ↑ 两次 CPU 内存拷贝（慢、占 CPU、占 PCIe）
```

有显存直连（GPUDirect RDMA）时：

```
A机 GPU显存 → A机网卡 → 网络 → B机网卡 → B机 GPU显存
              ↑ 网卡 DMA 直读写显存，绕过 CPU 内存
```

**核心矛盾**：RDMA 网卡注册内存（`ibv_reg_mr`）的默认路径是 `get_user_pages()`，它只能解析 **CPU 可寻址的页**。GPU 显存的虚拟地址属于 GPU 自己的地址空间，`get_user_pages()` 解析不了。所以要有一个机制，**让 GPU 驱动把"这段显存怎么被 DMA"告诉内核**。

---

## 二、两条技术路线（先看结论）

| | 路线一：peer-memory | 路线二：DMA-BUF |
|---|---|---|
| 年代 | 2015 – 2023（legacy） | 约 6.8 起成为主线推荐 |
| 是否在 Linux 主线 | **否**，仅存在于 MLNX_OFED 构建的 `ib_core` | **是**，主线子系统 |
| 核心 API | `ib_register_peer_memory_client()` | `dma_buf_export()` / `ibv_reg_dmabuf_mr()` |
| 厂商中立性 | 差（绑在 RDMA 子系统） | 好（内核通用缓冲共享框架） |
| 现状 | NVIDIA 标记为 legacy，inbox 栈上无法加载 | Hopper 及更新 GPU 的默认路径 |

> **一句话**：peer-memory 是"在 RDMA 子系统里开个后门"；DMA-BUF 是"在内核里修一条正式的路"。社区最终选择了后者。

---

## 三、路线一：peer-memory（OFED 专有，非主线）

### 3.1 事实澄清（最容易踩的坑）

- `ib_register_peer_memory_client()` / `ib_unregister_peer_memory_client()` **从未被合并进 Linux 主线**。主线既没有 `drivers/infiniband/core/peer_mem.c`，也没有对应头文件。
- 该 API 只存在于 **MLNX_OFED**（Mellanox/NVIDIA 的商业发行版）所构建的 `ib_core` 中。
- 因此：在 Ubuntu / RHEL 使用 **inbox rdma-core** 的机器上，`modprobe nvidia-peermem` 会返回 `Invalid argument (-EINVAL)`，`dmesg` 里能看到类似：

```
failing symbol_get of non-GPLONLY symbol ib_register_peer_memory_client
```

**这不是配置错误，而是符号根本不存在。** 换参数、换内核版本都修不好。

### 3.2 它当初想解决什么

peer-memory 在 `ib_core` 里注册一个"客户端"，当 RDMA 注册内存遇到属于该客户端的地址时，转而调用它的回调：

| 回调（角色） | 作用 |
|-------------|------|
| `is_supported` / `acquire` | 判断这段地址是不是我管的设备内存，并钉住它 |
| `get_pages` | 把设备虚拟地址翻译成可 DMA 的页 / sg_table |
| `dma_map` / `dma_unmap` | 把页映射成网卡可用的总线地址（IOMMU 感知） |
| `put_pages` / `release` | 解钉、释放引用 |
| `get_refcnt` | 引用计数 |

> ⚠️ **回调签名随 OFED 版本变化很大**（旧版 `get_pages/put_pages/dma_map/dma_unmap/is_supported`，新版 `acquire/release/get_refcnt/...`）。**不要照抄任何二手资料的函数原型**——若确实要维护这条路线，请直接对照你所用 MLNX_OFED 版本自带的 `peer_mem.h`。

### 3.3 模块名演进（易混）

| 名字 | 状态 |
|------|------|
| `nv_peer_mem` | 早期开源实现（Mellanox），已淘汰 |
| `nvidia-peermem`（包/仓库名，连字符） | NVIDIA 随驱动发布的模块 |
| `nvidia_peermem`（模块名，下划线） | 现役模块名；`modprobe nvidia-peermem` 时内核会自动匹配 |
| `nvmpe` | **不是标准名称**，勿用 |

### 3.4 为什么主线拒绝了它

上游的核心理由是**层次放错了**：P2P/显存共享不是 RDMA 子系统的私事，DRM、V4L2、存储都需要。把机制绑死在 `ib_core` 里无法复用，也无法让非 RDMA 设备受益。最终社区把能力下沉到通用层——先是 P2PDMA，后是 DMA-BUF/HMM。

---

## 四、路线二：DMA-BUF（主线，推荐）

### 4.1 机制

```
GPU 驱动                                网卡驱动 / RDMA 子系统
   │                                            │
   ├─ dma_buf_export(sg_table 或 HMM 回调)       │
   │        │                                   │
   │        └── 返回 dma-buf fd ────────────────►│
   │                                            ├─ ib_umem_dmabuf_get()
   │                                            │    （内部走 HMM 缺页/迁移）
   │                                            └─ 编程网卡 DMA
```

用户态对应 `ibv_reg_dmabuf_mr(pd, offset, length, iova, fd, access)`。

**关键点**：dma-buf 是"引用 + 回调"，不是一次性拷贝页表。配合 HMM 后，显存可以在注册后被迁移/换出，网卡访问时按需解析——这也是它比 peer-memory 更通用的原因。

### 4.2 前置条件（少一个都不通）

| 条件 | 检查方式 |
|------|---------|
| 内核 `CONFIG_DMA_SHARED_BUFFER=y` | `grep CONFIG_DMA_SHARED_BUFFER /boot/config-$(uname -r)` |
| 内核 `CONFIG_HMM_MIRROR=y` | 同上 |
| 内核 `CONFIG_INFINIBAND_ON_DEMAND_PAGING=y` | 同上（HCA 需支持 ODP） |
| GPU 驱动为 **open kernel driver** | `cat /proc/driver/nvidia/version` |
| `nvidia_drm` 开启 modeset | `cat /sys/module/nvidia_drm/parameters/modeset` 必须为 `Y` |
| GPU 支持 dma-buf 导出 | Hopper 及更新；可用 `cuDeviceGetAttribute(CU_DEVICE_ATTRIBUTE_DMA_BUF_SUPPORTED)` 判定 |

```bash
# 打开 modeset（最常见的缺失项）
echo 'options nvidia-drm modeset=1' | sudo tee /etc/modprobe.d/nvidia-drm-modeset.conf
sudo update-initramfs -u && sudo reboot
```

### 4.3 让 NCCL 走 dma-buf

```bash
export NCCL_DMABUF_ENABLE=1
export NCCL_DEBUG=INFO        # 初始化日志里确认 GPUDirect RDMA 是否启用
```

> 注意：不是所有 GPU 都支持 dma-buf（如部分 L40S 早期固件）。不支持时只能退回 peer-memory 路线，而那又要求 MLNX_OFED——这就是现实中"要么装 OFED、要么换卡/升驱动"的由来。

---

## 五、自研加速器/网卡该怎么选

| 你的场景 | 推荐路线 | 理由 |
|---------|---------|------|
| 自研 NPU/GPU + 商用 IB/RoCE 网卡 | **DMA-BUF exporter** | 主线支持，NCCL/verbs 直接可用，厂商中立 |
| 自研加速器 + 自研网卡，同 Switch | **P2PDMA**（见 case_02） | 走 PCI 总线地址，路径最短 |
| 需要 CPU 也能直接寻址设备内存 | CXL.mem / P2P BAR 映射 | 语义是"内存"而非"一次 DMA" |
| 维护既有 NVIDIA + OFED 集群 | peer-memory（仅存量） | 新部署不应再选 |

### 自研设备做 dma-buf exporter 的最小骨架（示意）

```c
/* 设备侧：把一段设备内存导出为 dma-buf（真实实现需处理 attach/map/unmap 回调） */
static int my_exp_attach(struct dma_buf *dmabuf, struct dma_buf_attachment *a)
{
        return 0;                       /* 通常无需额外动作，映射在 map 回调里做 */
}

static struct sg_table *my_exp_map(struct dma_buf_attachment *a,
                                   enum dma_data_direction dir)
{
        /* 返回描述这段设备内存的 sg_table；网卡会据此编程 DMA */
        return my_dev_build_sg_table(a->dev);
}

static const struct dma_buf_ops my_dmabuf_ops = {
        .attach = my_exp_attach,
        .map_dma_buf = my_exp_map,
        /* .unmap_dma_buf / .release / .mmap 按需实现 */
};

/* 导出：用户态通过 ioctl 拿到 fd */
dmabuf = dma_buf_export(&exp_info);     /* exp_info.ops = &my_dmabuf_ops */
fd = dma_buf_fd(dmabuf, O_RDWR);
```

> 这段是**结构示意**，`dma_buf_export()` 的 `struct dma_buf_export_info` 字段随版本演进（`exp_name`、`size`、`ops`、`flags`、`priv` 等），落地请对照 `include/linux/dma-buf.h`。

---

## 六、验证：到底走通了没有

```bash
# 1. 旧路线是否可用（inbox 栈上大概率报 -EINVAL，属预期）
lsmod | grep -iE "peermem|peer_mem"
sudo modprobe nvidia-peermem && dmesg | tail -5

# 2. 新路线前置条件
cat /sys/module/nvidia_drm/parameters/modeset          # Y
grep -E "CONFIG_(DMA_SHARED_BUFFER|HMM_MIRROR|INFINIBAND_ON_DEMAND_PAGING)=" /boot/config-$(uname -r)

# 3. 端到端：显存直连带宽（两台机器）
ib_write_bw -d mlx5_0 --use_cuda -x 3            # server
ib_write_bw -d mlx5_0 --use_cuda -x 3 <server_ip> # client

# 4. NCCL 视角
NCCL_DEBUG=INFO ./all_reduce_perf -b 8 -e 1G -f 2 -g 8 2>&1 | grep -i "GPU Direct\|NET/IB"
```

| 现象 | 含义 |
|------|------|
| `modprobe` 报 `Invalid argument` + dmesg 有 `symbol_get` 失败 | 旧路线在 inbox 栈上不可用（预期） |
| `ibv_reg_mr` 返回 `Bad address (EFAULT)` | 显存没被成功注册：dma-buf 未启用或 GPU 不支持 |
| `--use_cuda` 带宽与普通 host 内存带宽接近 | 可能没走直连（走了 bounce buffer） |
| `--use_cuda` 带宽显著高于 host 内存路径 | 直连生效 |

---

## 七、自检

- [ ] 能画出"有/无显存直连"的两条跨机路径
- [ ] 能说清为什么 `get_user_pages()` 处理不了显存
- [ ] **知道 `ib_register_peer_memory_client` 不是主线 API**，只存在于 MLNX_OFED
- [ ] 能解释 `modprobe nvidia-peermem` 在 inbox 栈上必然失败的原因
- [ ] 能列出 dma-buf 路线的 4 个前置条件（内核 3 项配置 + modeset）
- [ ] 能给自研加速器选出正确路线（dma-buf / P2PDMA / CXL）
- [ ] 会用 `ib_write_bw --use_cuda` 与 `NCCL_DEBUG` 验证直连是否生效

---

## 🔗 关联笔记

- **前置**：[[dev_case_02_p2pdma]]（P2P 与总线地址）
- **软件栈视角**：[[11_GPUDirect与RDMA]]（用户态怎么用、IB/RoCE 基础）
- **内存与隔离**：[[15_IOMMU_ACS与P2P可行性]]
- **版本判据**：[[18_内核版本适配矩阵]]（"内核有能力"与"生态默认"的时间差，以及如何用 grep 头文件判定）
- **排查**：[[集群高速IO问题排查]]（节点间 RDMA 一节）
- **返回**：[[多卡集群驱动开发技能地图]]

## 📝 我的学习记录

- **YYYY-MM-DD**：
