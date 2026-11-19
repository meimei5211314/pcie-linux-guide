---
tags: [GPUDirect, RDMA, InfiniBand, RoCE, 跨机通讯, 多卡通讯]
aliases: [GPUDirect与RDMA, 跨机GPU通讯]
created: 2026-11-18
status: 进行中
---

# 11 · GPUDirect 与 RDMA（跨机通讯）

> **前置**：[[07_多卡通讯总览]]　|　**相关**：[[09_并行策略与通讯模式]]（DP/PP 跨机）　|　**进度**：[[学习进度追踪]]

> **核心问题**：跨机时，怎么让 A 机的 GPU 显存**直接**写到 B 机的 GPU 显存，**不经过 CPU 内存中转**？答案是 GPUDirect RDMA。

---

## 一、没有 GPUDirect 的痛点

```
传统跨机 GPU 通讯路径：
  A机GPU显存 → A机CPU内存 → A机网卡 → 网络 → B机网卡 → B机CPU内存 → B机GPU显存
                ↑ CPU 拷贝          ↑ 网络传输    ↑ CPU 拷贝
  问题：
    1. 两次 CPU 内存拷贝（占 CPU、占 PCIe 带宽、增加延迟）
    2. CPU 成为瓶颈
```

## 二、GPUDirect RDMA 的原理

```
GPUDirect 路径：
  A机GPU显存 → A机网卡 → 网络 → B机网卡 → B机GPU显存
              ↑ 绕过 CPU 内存！

  依赖：
    1. 网卡驱动支持 GPU 内存直接 DMA
    2. GPU 内存注册到网卡（memory registration）
    3. RDMA 协议（IB 或 RoCE）
```

### 三层"GPUDirect"
| 名称 | 解决什么 | 跨机？ |
|------|---------|--------|
| **GPUDirect P2P** | 同机两 GPU 直接通讯 | ❌ 单机内 |
| **GPUDirect RDMA** | GPU 显存被网卡直接 DMA | ✅ 跨机 |
| **GPUDirect Storage** | 存储设备直接读写 GPU 显存 | ❌ 本机 I/O |

> 本篇重点是 **GPUDirect RDMA**（跨机 GPU 训练的基石）。

---

## 三、RDMA 基础

### 什么是 RDMA
```
RDMA = Remote Direct Memory Access
  绕过 CPU 和内核，网卡直接读写远端内存
  低延迟（~1μs 级）、低 CPU 占用
```

### IB vs RoCE
| | InfiniBand (IB) | RoCE |
|--|----------------|------|
| 介质 | IB 专用网络 | 以太网 |
| 可靠性 | 无损（内置） | 需 PFC + ECN 配置无损 |
| 成本 | 高（专用交换机） | 低（复用以太网） |
| 配置 | 较简单 | 复杂（PFC/ECN 易踩坑） |

### RDMA 关键概念
- **QP**（Queue Pair）：类似 socket，通讯端点
- **MR**（Memory Region）：注册的内存区域，网卡可直接访问
- **verbs**：RDMA 编程接口（`ibv_post_send` 等）
- **GID**：RDMA 网卡的地址

---

## 四、检查 RDMA 环境

```bash
# 查 IB 网卡状态
ibstat                      # 链路速率、端口状态
ibstatus                    # 每个端口详细信息
ibv_devinfo                 # 设备信息、GID

# 查 RDMA 链路
ibv_devices                 # 列出 RDMA 设备
```

### 测 RDMA 带宽（两台机器）
```bash
# 机器 A（server）
ib_write_bw -d mlx5_0 -x 3
# -d 指定网卡，-x 指定 GID index

# 机器 B（client）
ib_write_bw -d mlx5_0 -x 3 <A机IP>
```

**如何读结果（单位是最容易错的地方）**：perftest 输出的是 **MB/s**，不是 Gb/s，也不是"线速的百分比"。

| IB 速率 | 线速 | 理论单向（÷8） | 实测单向（参考） |
|---------|------|---------------|-----------------|
| EDR（100G） | 100 Gb/s | 12.5 GB/s | ≈11–11.8 GB/s（约 11,000–11,800 MB/s） |
| HDR（200G） | 200 Gb/s | 25 GB/s | ≈22–24 GB/s |
| NDR（400G） | 400 Gb/s | 50 GB/s | ≈45–48 GB/s |

> ⚠️ 常见误算：把 100 Gb/s 直接读成 "100 GB/s"（差 8 倍），再套上编码开销后误报成 "95 GB/s"。正确量级是 **11–12 GB/s 单向**。多端口/多网卡聚合才可能达到数十 GB/s。
> 编码与换算细节见 [[17_带宽与单位换算速查]]。

---

## 五、GPUDirect RDMA 验证

### 前提
1. GPU 驱动 + CUDA 安装好
2. IB 网卡驱动（mlx5 等），且 HCA 支持 ODP（ConnectX-6/7 起）
3. GPU 显存能被网卡 DMA —— **这一条有新旧两条技术路线，不能混为一谈**

### 路线一：peer-memory（旧，OFED 专有）

```bash
lsmod | grep -iE "peermem|peer_mem"     # 旧：nv_peer_mem；新：nvidia_peermem
sudo modprobe nvidia-peermem            # 注意：modprobe 用连字符，模块名是下划线
```

> ⚠️ **关键事实**：`nvidia-peermem` 依赖的 `ib_register_peer_memory_client()` **从来不在 Linux 主线内核里**，只在 **MLNX_OFED** 构建的 `ib_core` 中存在。所以在 Ubuntu/RHEL 自带（inbox）的 rdma-core 上，`modprobe nvidia-peermem` 会报 `Invalid argument (-EINVAL)`——这不是配置错，而是**该符号不存在**。NVIDIA 已把这条路线标记为 legacy。

### 路线二：DMA-BUF（新，主线内核）

机制是：GPU 驱动把显存导出为 dma-buf fd，网卡通过 `ibv_reg_dmabuf_mr()` 直接注册。NCCL 对应开关是 `NCCL_DMABUF_ENABLE=1`。

**要把"内核有能力"和"生态默认走这条"分开看**——这是最容易被二手资料讲混的一点：

| 层次 | 时间 | 判据 |
|------|------|------|
| 内核具备（RDMA 接受 dma-buf） | **v5.12** 起 | `include/rdma/ib_umem.h` 里有 `ib_umem_dmabuf_get()` |
| 用户态具备 | rdma-core 提供 `ibv_reg_dmabuf_mr()` | `grep ibv_reg_dmabuf_mr /usr/include/infiniband/verbs.h` |
| 生态默认走这条路 | 约内核 6.8 时期起，NCCL 逐步默认 | 「6.8 起」说的是这个，**不是接口引入时间** |

> 所以"6.8 之前没有 DMA-BUF"是不准确的：5.12 的内核就能用，只是那时 GPU 侧 exporter 与框架默认路径都不成熟。做兼容性判断请看**头文件里有没有符号**，不要背年份。完整版本矩阵见 [[18_内核版本适配矩阵]]。

```bash
# 1. nvidia-drm 必须开 modeset，否则 dma-buf 导出不生效（最常见的坑）
cat /sys/module/nvidia_drm/parameters/modeset     # 必须是 Y
sudo modprobe nvidia_drm modeset=1

# 2. 内核配置需具备
#    CONFIG_DMA_SHARED_BUFFER=y  CONFIG_HMM_MIRROR=y  CONFIG_INFINIBAND_ON_DEMAND_PAGING=y
zgrep -E "CONFIG_(DMA_SHARED_BUFFER|HMM_MIRROR|INFINIBAND_ON_DEMAND_PAGING)=" /proc/config.gz 2>/dev/null \
  || grep -E "CONFIG_(DMA_SHARED_BUFFER|HMM_MIRROR|INFINIBAND_ON_DEMAND_PAGING)=" /boot/config-$(uname -r)

# 3. 让 NCCL 走 dma-buf 而不是 peer-memory
export NCCL_DMABUF_ENABLE=1
```

**如何判断到底走了哪条路**：`NCCL_DEBUG=INFO` 的初始化段会打印 GPUDirect RDMA 是否启用；若 `ibv_reg_mr` 返回 `Bad address (EFAULT)`，说明显存没被成功注册，通常就是两条路都没走通。

> 两条路线的实现差异与「自研 GPU/NPU 该选哪条」详见 [[dev_case_03_peer_memory]]。

### 验证 GPU-direct 带宽
```bash
# 用 cuda-aware 的带宽测试
# server
ib_write_bw -d mlx5_0 --use_cuda -x 3

# client
ib_write_bw -d mlx5_0 --use_cuda -x 3 <A机IP>
```

### 多机 nccl-tests（端到端）
```bash
# 单机 all_reduce_perf 已跑通后，多机（用 MPI 启动）
mpirun -np 8 --hostfile hosts.txt \
    -x NCCL_DEBUG=INFO \
    ./build/all_reduce_perf -b 8 -e 1G -f 2 -g 1
# -np 8：8 个进程；-g 1：每进程 1 卡
```

---

## 六、常见问题排查

| 问题 | 原因 | 解决 |
|------|------|------|
| NCCL 走不了 IB，fallback 到 TCP | IB 没配好 / GID index 错 | `NCCL_DEBUG=INFO` 看 NET/IB；`NCCL_IB_HCA` 指定网卡 |
| RDMA 带宽远低于线速 | PFC/ECN 没配（RoCE）/ 链路降速 | `ibstat` 查速率；查交换机 PFC |
| GPUDirect 不生效（走 CPU 中转） | 两条路都没走通：旧路线 peer_mem 未加载（且 inbox 栈下无法加载）；新路线 dma-buf 未启用 | 优先走 dma-buf：`nvidia_drm modeset=1` + `NCCL_DMABUF_ENABLE=1`；旧路线仅在 MLNX_OFED 下可用 |
| NUMA 跨节点降速 | 网卡和 GPU 不在同一 NUMA | `numactl` 绑核；查 `nvidia-smi topo -m` |

### 看拓扑（决定走 NVLink 还是 PCIe 还是网络）
```bash
nvidia-smi topo -m
# GPU0  GPU1  GPU2  GPU3  NIC0  CPU Affinity
# GPU0   X    NV1   PIX   PIX   ...
# GPU1  NV1    X    ...         ← NV = NVLink，PIX = 同 PCIe Switch
```

---

## 七、自检

- [ ] 能画出"有/无 GPUDirect"的跨机 GPU 通讯路径
- [ ] 能区分 GPUDirect P2P / RDMA / Storage
- [ ] 能用 `ibstat`、`ib_write_bw` 检查 RDMA 环境
- [ ] 知道 GPUDirect RDMA 有 **peer-memory（OFED 专有）** 与 **DMA-BUF（主线）** 两代路线，不会在 inbox 栈上死磕 `nvidia-peermem`
- [ ] 理解 RoCE 需要配 PFC/ECN 才能无损
- [ ] 能说清 `ib_write_bw` 输出单位是 MB/s，100G IB 单向约 11–12 GB/s

---

## 🔗 关联笔记

- **前置**：[[07_多卡通讯总览]]
- **应用**：[[09_并行策略与通讯模式]]（DP/PP 跨机传输基础）
- **调试**：[[10_NCCL实战与调试]]（NCCL 用 IB）
- **返回**：[[00_首页MOC]]

## 📝 我的学习记录

- **YYYY-MM-DD**：
