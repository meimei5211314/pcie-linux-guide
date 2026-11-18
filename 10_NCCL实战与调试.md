---
tags: [NCCL, 调试, 性能分析, 多卡通讯]
aliases: [NCCL实战与调试, NCCL Debug]
created: 2026-11-18
status: 进行中
---

# 10 · NCCL 实战与调试

> **前置**：[[08_集合通信原语]]、[[09_并行策略与通讯模式]]　|　**下一站**：[[11_GPUDirect与RDMA]]　|　**进度**：[[学习进度追踪]]

> NCCL（NVIDIA Collective Communications Library）是 GPU 集合通信的事实标准。本篇讲**怎么用、怎么调、怎么排错**。

---

## 一、NCCL 是什么

- **定位**：NVIDIA 专为 GPU 优化的集合通信库，**深度感知 GPU 拓扑**，自动选算法/通道
- **核心操作**：AllReduce、AllGather、ReduceScatter、Broadcast、Send/Recv
- **特点**：
  - 异步（操作挂在 CUDA stream 上）
  - 拓扑感知（识别 NVLink/PCIe/网络层级）
  - 多通道并行（channel）

> **NCCL ≠ MPI 的 GPU 版**：NCCL 自动选路，调优方式和 MPI 不同。

---

## 二、关键环境变量（调试必备）

### 最常用：NCCL_DEBUG
```bash
export NCCL_DEBUG=INFO    # 打印初始化、拓扑、算法选择（最常用）
export NCCL_DEBUG=WARN    # 只打印警告和错误
export NCCL_DEBUG=TRACE   # 最详细（性能分析用）
```

**看什么**：
```
NCCL INFO Bootstrap: ...
NCCL INFO CUDA Driver version ...
NCCL INFO NET/IB : Using 1 OOB connections   ← 用了什么网络
NCCL INFO Channel 00 : ... via NVL#0          ← 走 NVLink 通道
NCCL INFO Algorithm   : Ring                  ← 选了什么算法
NCCL INFO Protocol    : Simple
```

### 算法/协议强制指定（调优用）
```bash
export NCCL_ALGO=Ring          # 强制 Ring（Ring/Tree/CollNet）
export NCCL_PROTO=Simple       # 协议（Simple/LL/LL128）
export NCCL_NCHANNELS=8        # 通道数
```

### 逐项禁用（定位故障）
```bash
export NCCL_P2P_DISABLE=1      # 禁用 P2P（定位 P2P 问题）
export NCCL_SHM_DISABLE=1      # 禁用共享内存
export NCCL_IB_DISABLE=1       # 禁用 InfiniBand
```

---

## 三、编译运行 nccl-tests（带宽基线）

### 为什么先跑 nccl-tests
```
调优前必须建立基线：
  理论带宽 → nccl-tests 实测带宽 → 端到端应用带宽
  哪一环低了，就查哪一环
```

### 编译
```bash
git clone https://github.com/NVIDIA/nccl-tests.git
cd nccl-tests
make MPI=1  # 有 MPI 用 MPI=1，纯单机可不加
```

### 单机 all_reduce_perf
```bash
./build/all_reduce_perf -b 8 -e 128M -f 2 -g 4
#                  -b 8       起始 8 bytes
#                  -e 128M    终止 128 MB
#                  -f 2       步进倍数
#                  -g 4       用 4 张 GPU
```

### 读输出（关键指标）
```
                      out-of-place              in-place
       size    count    type  redop   time  algbw  busbw  ...
       64M  16777216  float    sum  0.95   67.4  235.9  ...  ← 看 busbw
                                ↑       ↑      ↑
                              时间   算法带宽  总线带宽
```

| 指标 | 含义 | 怎么用 |
|------|------|--------|
| **algbw** | 算法带宽 = size / time | 单卡视角的吞吐 |
| **busbw** | 总线带宽 = algbw × 2(N-1)/N | **和硬件理论带宽对比** |

> **判读**：4 卡 NVLink 理论 ~900 GB/s，实测 busbw 接近 600-700 GB/s 为正常；如果只有 100 GB/s，说明走的是 PCIe 而不是 NVLink。

---

## 四、写一个最小 NCCL 程序

```c
#include <nccl.h>
#include <cuda_runtime.h>
#include <stdio.h>

#define NDEV 2
#define SIZE (1024*1024)

int main() {
    ncclComm_t comms[NDEV];
    int devs[NDEV] = {0, 1};

    // 1. 初始化（每个设备一个 communicator）
    ncclCommInitAll(comms, NDEV, devs);

    // 2. 每卡分配数据
    float *sendbuff[NDEV], *recvbuff[NDEV];
    cudaStream_t streams[NDEV];
    for (int i = 0; i < NDEV; i++) {
        cudaSetDevice(devs[i]);
        cudaMalloc(&sendbuff[i], SIZE * sizeof(float));
        cudaMalloc(&recvbuff[i], SIZE * sizeof(float));
        cudaStreamCreate(&streams[i]);
        // 初始化 sendbuff[i] = i+1
        float val = i + 1;
        cudaMemset(sendbuff[i], 0, SIZE * sizeof(float));  // 简化
    }

    // 3. AllReduce（异步，提交到 stream）
    for (int i = 0; i < NDEV; i++) {
        ncclAllReduce(sendbuff[i], recvbuff[i], SIZE,
                      ncclFloat, ncclSum, comms[i], streams[i]);
    }

    // 4. 同步
    for (int i = 0; i < NDEV; i++) {
        cudaStreamSynchronize(streams[i]);
    }

    printf("AllReduce done\n");

    // 5. 清理
    for (int i = 0; i < NDEV; i++) ncclCommDestroy(comms[i]);
    return 0;
}
```

**编译**：
```bash
nvcc -o test test.cu -lnccl -lcudart
```

**运行**：
```bash
NCCL_DEBUG=INFO ./test
```

---

## 五、PyTorch 集成（最常用）

```python
import torch
import torch.distributed as dist

# 初始化（单机多卡）
dist.init_process_group(backend='nccl', init_method='env://')
rank = dist.get_rank()
world = dist.get_world_size()
torch.cuda.set_device(rank)

# AllReduce
t = torch.ones(1024, device='cuda') * (rank + 1)
dist.all_reduce(t, op=dist.ReduceOp.SUM)
# t 现在是所有 rank 求和的结果

# 非阻塞（异步，可和计算重叠）
work = dist.all_reduce(t, op=dist.ReduceOp.SUM, async_op=True)
# ... 做其他计算 ...
work.wait()  # 等通讯完成
```

---

## 六、常见错误与排查

| 错误 | 原因 | 排查 |
|------|------|------|
| `NCCL WARN Invalid handle` | communicator 没共享 / rank 数不匹配 | 检查 init_process_group 参数 |
| `NCCL INFO ... NET/IB ... Failed` | IB 配置错 / 网卡没起来 | `ibstat` 查网卡；`NCCL_IB_DISABLE=1` 验证 |
| 卡死 / timeout | 集合操作顺序不一致 / 某 rank 没参与 | `NCCL_DEBUG=INFO` 看卡在哪个操作 |
| 带宽远低于预期 | 走了 PCIe 没走 NVLink / 拓扑识别错 | `nvidia-smi topo -m`；看 NCCL INFO 走的通道 |
| `out of memory` | 显存不够（NCCL 占显存） | 减小 batch / 减少卡上并发 |

### 卡死（Hang）专项排查
```bash
# 1. 打开详细日志
export NCCL_DEBUG=INFO
export NCCL_DEBUG_SUBSYS=INIT,COLL

# 2. 加超时（默认很长）
export NCCL_TIMEOUT=60  # 秒

# 3. 用 gdb / cuda-gdb attach 看卡在哪
```

---

## 七、自检

- [ ] 知道 `NCCL_DEBUG=INFO` 是排错第一手段
- [ ] 能编译运行 nccl-tests，读懂 algbw 和 busbw
- [ ] 理解 busbw 才是和硬件理论带宽对比的指标
- [ ] 能写一个最小的 NCCL AllReduce 程序
- [ ] 知道 NCCL 是异步的，操作挂在 CUDA stream 上

---

## 🔗 关联笔记

- **前置**：[[08_集合通信原语]]、[[09_并行策略与通讯模式]]
- **下一站**：[[11_GPUDirect与RDMA]]
- **性能**：[[12_通讯性能优化]]
- **返回**：[[00_首页MOC]]

## 📝 我的学习记录

- **YYYY-MM-DD**：
