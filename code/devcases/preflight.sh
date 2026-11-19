#!/usr/bin/env bash
# ============================================================================
# preflight.sh —— PCIe / 多卡环境自检（只读，不修改任何系统状态）
#
# 用途：把《核查报告》第七节"仍需在目标环境验证"的六项，变成一次可执行的自检。
#       产出五类结论：
#         1) 你的内核属于哪个 P2PDMA API 区间（决定 dev_case_02 该抄哪段代码）
#         2) GPU 显存直访走 peer-memory 还是 DMA-BUF
#         3) 中断亲和新旧接口是否可用
#         4) 卡间 P2P 是否被 ACS / host bridge 卡住（只是预判，定论需实测）
#         5) IB 链路速率与 perftest 的单位口径
#
# 用法：
#   chmod +x preflight.sh && ./preflight.sh              # 全部检查
#   ./preflight.sh --p2p 0000:3b:00.0 0000:af:00.0       # 只判定两张卡能否 P2P
#   ./preflight.sh > preflight_$(uname -r).log 2>&1      # 存证
#
# 依赖：bash、pciutils（lspci）；infiniband 部分需要 infiniband-diags / perftest
# 建议：普通用户可跑，加 sudo 能多看到 lspci 的 capability 细节
# ============================================================================

set -u

HDR()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
OK()   { printf '  [ OK ] %s\n' "$*"; }
INFO() { printf '  [INFO] %s\n' "$*"; }
WARN() { printf '  [WARN] %s\n' "$*"; }
FAIL() { printf '  [FAIL] %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

KVER="$(uname -r)"
KSRC="/usr/src/linux-headers-${KVER}"
[ -d "$KSRC" ] || KSRC="/lib/modules/${KVER}/build"
HDR_FILE=""
[ -f "$KSRC/include/linux/pci-p2pdma.h" ] && HDR_FILE="$KSRC/include/linux/pci-p2pdma.h"
IRQ_FILE="$KSRC/include/linux/interrupt.h"
UMEM_FILE="$KSRC/include/rdma/ib_umem.h"

# ---------------------------------------------------------------- 0. 基本信息
HDR "0. 环境基本信息"
INFO "内核版本        : $KVER"
[ -r /etc/os-release ] && INFO "发行版          : $(. /etc/os-release; echo "${PRETTY_NAME:-unknown}")"
INFO "内核头文件      : $KSRC $( [ -d "$KSRC/include" ] && echo '(可用)' || echo '(缺失 —— 后面的 API 判定会跳过)')"
INFO "架构 / CPU 数   : $(uname -m) / $(nproc)"
if have mokutil; then
    SB="$(mokutil --sb-state 2>/dev/null | tr -d '\n')"
    case "$SB" in
        *enabled*) WARN "Secure Boot 开启（$SB）—— insmod 未签名模块会失败，见 troubleshooting.md" ;;
        *)         OK   "Secure Boot 状态：${SB:-未知}" ;;
    esac
else
    INFO "mokutil 未安装，跳过 Secure Boot 检查"
fi

# ------------------------------------------------------- 1. P2PDMA API 区间
HDR "1. P2PDMA API 形态（决定 dev_case_02 抄哪段）"
P2P_MODE="unknown"
if [ -n "$HDR_FILE" ]; then
    if grep -q "struct p2pdma_provider" "$HDR_FILE" 2>/dev/null; then
        P2P_MODE="provider"
        OK "provider 形态（v6.19+）：用 pcim_p2pdma_init/provider + pci_p2pdma_map_type"
        INFO "bus_addr_map 第一个参数是 struct p2pdma_provider *"
    elif grep -q "pci_p2pdma_map_state" "$HDR_FILE" 2>/dev/null; then
        P2P_MODE="map_state"
        OK "map_state 形态（v6.16–6.18）：用 pci_p2pdma_state() 取 type，再 bus_addr_map()"
        INFO "bus_addr_map 第一个参数是 struct pci_p2pdma_map_state *"
    elif grep -q "pci_p2pdma_add_resource" "$HDR_FILE" 2>/dev/null; then
        P2P_MODE="legacy"
        OK "老形态（v4.20–v6.15）：无公开映射函数，p2pmem 分配后交给 dma_map_sg()"
    else
        P2P_MODE="absent"
        WARN "$HDR_FILE 存在但无 P2PDMA 符号 —— 可能未开 CONFIG_PCI_P2PDMA"
    fi
    INFO "header: $HDR_FILE"
else
    WARN "找不到 pci-p2pdma.h（内核头文件未安装？）—— 请 apt install linux-headers-\$(uname -r)"
fi

# 关键提醒：同名函数跨 6.18→6.19 签名变更
[ "$P2P_MODE" = "provider" ] || [ "$P2P_MODE" = "map_state" ] && \
    INFO "注意：pci_p2pdma_bus_addr_map() 在 6.19 换了参数类型，跨此版本升级需改代码（见 18 篇）"

if [ -r "/boot/config-${KVER}" ]; then
    CFG="/boot/config-${KVER}"
    for opt in CONFIG_PCI_P2PDMA CONFIG_DMABUF CONFIG_PCI_ATS CONFIG_PCI_PRI \
               CONFIG_PCI_IOV CONFIG_VFIO CONFIG_INFINIBAND_USER_MEM; do
        v="$(grep -E "^${opt}=" "$CFG" 2>/dev/null | head -1)"
        [ -n "$v" ] && INFO "$v" || INFO "${opt} 未设置"
    done
fi

# ------------------------------------------------- 2. GPU 直访路线判定
HDR "2. GPU 显存直访：peer-memory（OFED 专有）还是 DMA-BUF（主线）"
if grep -rq "ib_register_peer_memory_client" "$KSRC" 2>/dev/null; then
    OK "内核头文件里有 peer_memory 符号（非典型：多为 OFED 提供的头文件叠加）"
else
    INFO "主线无 peer-memory（预期结果）—— modprobe nvidia-peermem 报 EINVAL 是正常的"
    INFO "应走 DMA-BUF：NCCL_DMABUF_ENABLE=1 + nvidia_drm.modeset=1"
fi
if [ -f "$UMEM_FILE" ] && grep -q "ib_umem_dmabuf_get" "$UMEM_FILE" 2>/dev/null; then
    OK "内核具备 DMA-BUF RDMA 能力（ib_umem_dmabuf_get，v5.12+）"
else
    WARN "未见 ib_umem_dmabuf_get —— DMA-BUF 路径大概率不可用"
fi
if [ -f /usr/include/infiniband/verbs.h ] && grep -q "ibv_reg_dmabuf_mr" /usr/include/infiniband/verbs.h; then
    OK "用户态 rdma-core 支持 ibv_reg_dmabuf_mr"
else
    INFO "用户态未见 ibv_reg_dmabuf_mr（rdma-core 版本偏旧？）"
fi
[ -d /sys/module/nvidia_drm ] && INFO "nvidia_drm 已加载；DMA-BUF 需要 modeset=1（检查 /sys/module/nvidia_drm/parameters/modeset）" || INFO "nvidia_drm 未加载"

# ------------------------------------------------- 3. 中断亲和新接口
HDR "3. 中断亲和 API"
if [ -f "$IRQ_FILE" ]; then
    grep -q "irq_set_affinity_and_hint" "$IRQ_FILE" 2>/dev/null \
        && OK "irq_set_affinity_and_hint / irq_update_affinity_hint 可用（v5.17+）" \
        || WARN "仅有已废弃的 irq_set_affinity_hint（< v5.17）"
else
    INFO "interrupt.h 不可读，跳过"
fi
if have irqbalance; then
    INFO "irqbalance 存在 —— 它会覆盖你设置的亲和，驱动开发机上建议 systemctl stop irqbalance"
fi

# ------------------------------------------------- 4. 拓扑与 P2P 预判
HDR "4. PCIe 拓扑与 P2P 预判"
if ! have lspci; then
    WARN "lspci 未安装（apt install pciutils），跳过拓扑检查"
else
    INFO "PCIe 设备总数：$(lspci -n | wc -l)"
    echo
    printf '  %-14s %-10s %-6s %s\n' "BDF" "类型" "速率" "设备"
    printf '  %-14s %-10s %-6s %s\n' "--------------" "----------" "------" "----"
    lspci -D -nn 2>/dev/null | grep -Ei "vga|3d|display|processing accel" | while read -r line; do
        bdf="${line%% *}"
        lnk="$(lspci -D -s "$bdf" -vv 2>/dev/null | grep -m1 'LnkSta:' | sed 's/.*LnkSta:[[:space:]]*//; s/,.*//')"
        printf '  %-14s %-10s %-6s %s\n' "$bdf" "GPU" "${lnk:-?}" "$(echo "$line" | cut -d' ' -f2-)"
    done

    # ACS 位：P2P Request Redirect 是"改道"，不是"禁用"
    # 一次性解析 lspci -D -vv，避免对上百个设备逐个调用（慢且噪音大）
    echo
    ACS_LIST="$(lspci -D -vv 2>/dev/null | awk '
        /^[0-9a-fA-F]{4}:/ { bdf = $1 }
        /ACSCtl:/ && /ReqRedir\+/ { print bdf }
    ')"
    ACS_HIT=0
    [ -n "$ACS_LIST" ] && ACS_HIT="$(echo "$ACS_LIST" | wc -l)"
    if [ "$ACS_HIT" -eq 0 ]; then
        OK "未见 ACS P2P Request Redirect 置位的端口 —— P2P 大概率可直达"
    else
        WARN "$ACS_HIT 个端口置了 ACS P2P Request Redirect —— P2P 可能被改道到 host bridge"
        echo "$ACS_LIST" | head -5 | while read -r b; do
            INFO "  ReqRedir+ : $b  $(lspci -D -s "$b" 2>/dev/null | cut -d' ' -f2- | cut -c1-40)"
        done
        [ "$ACS_HIT" -gt 5 ] && INFO "  …（其余 $((ACS_HIT-5)) 个略）"
        INFO "改道 ≠ 禁用：还要看 host bridge 是否在 pci_p2pdma_whitelist 里，结果可能是 THRU_HOST_BRIDGE"
        INFO "详见 15_IOMMU_ACS与P2P可行性.md"
    fi

    # IOMMU 状态
    if [ -d /sys/class/iommu ] && [ -n "$(ls -A /sys/class/iommu 2>/dev/null)" ]; then
        INFO "IOMMU 已启用（$(ls /sys/class/iommu | tr '\n' ' ')）"
        INFO "注意：P2P 走的是物理地址直通，不经 IOMMU 翻译；两者是两条路，不要混为一谈"
    else
        INFO "IOMMU 未启用或未暴露到 /sys/class/iommu"
    fi
fi

# 指定两张卡做定向判定
if [ "${1:-}" = "--p2p" ] && [ -n "${2:-}" ] && [ -n "${3:-}" ]; then
    HDR "4b. 定向判定：$2 <-> $3"
    b1="$(echo "$2" | cut -d: -f2 | sed 's/^0*//')"; b1="${b1:-0}"
    b2="$(echo "$3" | cut -d: -f2 | sed 's/^0*//')"; b2="${b2:-0}"
    INFO "bus 号：$2 → $b1 ; $3 → $b2"
    if [ "$b1" = "$b2" ]; then
        OK "两张卡在同一 bus 段内，可能同 Switch（pci_p2pdma_distance 期望 4 或 2）"
    else
        WARN "bus 段不同，通常要经 host bridge（期望 THRU_HOST_BRIDGE 或 -1）"
    fi
    INFO "最终结论只能由 pci_p2pdma_distance(..., verbose=true) 给出，脚本给的是预判"
fi

# ------------------------------------------------- 5. IB 链路
HDR "5. InfiniBand / perftest"
if have ibstat; then
    ibstat 2>/dev/null | grep -E "CA '|Port [0-9]|State:|Rate:|Link_layer" | sed 's/^/  /'
    INFO "Rate 单位是 Gb/s（单向线速），4X 链路要乘 4 才与 IBTA 标称对齐"
elif have ibv_devinfo; then
    ibv_devinfo 2>/dev/null | grep -E "hca_id|state:|active_width|active_speed" | sed 's/^/  /'
else
    INFO "未安装 infiniband-diags / libibverbs-utils，跳过"
fi
if have ib_write_bw; then
    OK "perftest 已安装 —— 用 17 篇'反推 MB 口径'的三步法先校准单位"
else
    INFO "perftest 未安装（apt install perftest）"
fi

# ------------------------------------------------- 6. 结论
HDR "6. 结论摘要（把这段贴进你的 BRING-UP 记录）"
INFO "P2PDMA 形态      : ${P2P_MODE}"
INFO "GPU 直访路线     : $([ -f "$UMEM_FILE" ] && grep -q ib_umem_dmabuf_get "$UMEM_FILE" 2>/dev/null && echo 'DMA-BUF（主线）' || echo '需确认')"
INFO "下一步建议       :"
case "$P2P_MODE" in
    provider)  INFO "  → 读 dev_case_02 的 6.19+ 段落；跑 code/devcases 时用 provider 分支" ;;
    map_state) INFO "  → 读 dev_case_02 的 6.16–6.18 段落" ;;
    legacy)    INFO "  → 读 dev_case_02 的 4.20–6.15 段落；不要写 pci_p2pdma_map_resource（不存在）" ;;
    *)         INFO "  → 先确认 CONFIG_PCI_P2PDMA 与内核头文件" ;;
esac
echo
INFO "本脚本只读，未修改任何内核参数或模块状态。"

# 使用提示
if [ "${1:-}" != "--p2p" ]; then
    echo
    INFO "定向判定两张卡：./preflight.sh --p2p <BDF1> <BDF2>"
fi
