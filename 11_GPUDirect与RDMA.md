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
# 输出带宽，接近线速（如 100Gb IB ≈ 95 GB/s 实测）
```

---

## 五、GPUDirect RDMA 验证

### 前提
1. GPU 驱动 + CUDA 安装好
2. IB 网卡驱动（mlx5 等）
3. **GPUDirect RDMA 内核模块**（`nvidia-peermem` 或 `nv_peer_mem`）

```bash
# 检查 peer memory 模块
lsmod | grep -i "peer"
# 应看到 nvidia_peermem 或 nv_peer_mem

# 如果没有，加载
sudo modprobe nvidia_peermem
```

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
| GPUDirect 不生效（走 CPU 中转） | peer_mem 模块没加载 / 内存没对齐 | 加载 `nvidia_peermem`；用 `cudaMalloc` 对齐内存 |
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
- [ ] 知道 GPUDirect RDMA 需要加载 `nvidia_peermem` 模块
- [ ] 理解 RoCE 需要配 PFC/ECN 才能无损

---

## 🔗 关联笔记

- **前置**：[[07_多卡通讯总览]]
- **应用**：[[09_并行策略与通讯模式]]（DP/PP 跨机传输基础）
- **调试**：[[10_NCCL实战与调试]]（NCCL 用 IB）
- **返回**：[[00_首页MOC]]

## 📝 我的学习记录

- **YYYY-MM-DD**：
