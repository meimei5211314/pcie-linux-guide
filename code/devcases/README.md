# dev_case 配套编译环境

四个开发案例的源码以 **Markdown 代码块**形式存放在上级目录的 `dev_case_0*.md` 里（保持"文档即源码"）。本目录提供统一的编译脚手架与环境自检。

## 目录约定

```
code/devcases/
├── Makefile       # 自动编译本目录下所有 .c 为内核模块
├── extract.sh     # 从 md 里抽出代码块，生成 .c
├── preflight.sh   # 环境自检（只读）：内核 API 区间 / ACS 预判 / IB 速率
└── (生成的) mc_topo.c / mq_msix.c ...
```

## 第 0 步：先跑环境自检（推荐）

在写代码或编译之前先跑一次，它会直接告诉你该抄哪一段代码：

```bash
./preflight.sh                              # 全部检查
./preflight.sh --p2p 0000:3b:00.0 0000:af:00.0   # 定向判定两张卡能否 P2P
./preflight.sh > preflight_$(uname -r).log 2>&1  # 存证，便于事后对比
```

它会输出：

| 结论 | 影响什么 |
|------|---------|
| P2PDMA 形态（provider / map_state / legacy / unknown） | 决定 `dev_case_02` 抄哪一段；`unknown` 说明头文件缺失或没开 `CONFIG_PCI_P2PDMA` |
| peer-memory vs DMA-BUF 可用性 | 决定 `dev_case_03` 走哪条路线 |
| 中断亲和新接口是否存在（v5.17+） | 决定 `dev_case_04` 能不能用 `irq_set_affinity_and_hint` |
| ACS P2P Request Redirect 置位的端口 | 预判 P2P 会被"改道"还是"直达"（**定论仍需 `pci_p2pdma_distance(..., verbose=true)`**） |
| IB 链路速率与 perftest 是否就绪 | 后续跑 `ib_write_bw` 前先校准 MB 口径（见 `17_带宽与单位换算速查.md`） |

脚本**只读**，不修改内核参数、不加载模块。普通用户即可运行，加 `sudo` 能看到更多 `lspci` capability 细节。

## 用法

```bash
cd code/devcases

# 1. 从文档抽源码（文件名为你自定义，需与模块名一致）
./extract.sh ../../dev_case_01_拓扑发现.md mc_topo.c
./extract.sh ../../dev_case_04_多队列msix.md mq_msix.c

# 2. 编译（需要目标内核的头文件）
make

# 3. 加载 / 卸载
sudo insmod mc_topo.ko
dmesg | tail -20
sudo rmmod mc_topo
```

> `dev_case_02`、`dev_case_03` 的代码是**片段级示例**（依赖具体设备的 BAR 与寄存器语义），抽出来并不能独立成模块，只用于对照阅读。可编译的完整案例是 `dev_case_01` 与 `dev_case_04`。

## 注意事项

1. **ID 要改**：案例里用 `0x1234:0x5678` 占位。改成 `lspci -nn` 查到的真实 ID 才会 probe。
2. **内核版本**：`pci_p2pdma_*` 相关接口在 6.16 / 6.19 有变更，`dev_case_01` 只用到签名稳定的 `pci_p2pdma_distance()`，一般无需改动。完整版本矩阵见 `18_内核版本适配矩阵.md`。
3. **编译是最可靠的核验**：任何"文档说能用"的 API，请以 `make` 是否通过为准。
4. **`extract.sh` 只取第一个 ` ```c ` 代码块**。若某篇文档里第一个代码块是片段而非完整模块，抽出结果会不完整——此时手工复制完整模块。
