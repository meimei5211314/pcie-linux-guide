#!/bin/sh
# extract.sh —— 从 dev_case_*.md 中抽出第一个 ```c 代码块，生成可编译的 .c
#
# 用法：
#   ./extract.sh ../dev_case_01_拓扑发现.md mc_topo.c
#   ./extract.sh ../dev_case_04_多队列msix.md mq_msix.c
#
# 说明：
#   文档里的代码块是"唯一事实源"，脚本只做提取，避免"文档改了、代码没同步"。
set -eu

if [ $# -lt 2 ]; then
        echo "用法: $0 <dev_case_*.md> <输出.c>" >&2
        exit 1
fi

SRC="$1"
OUT="$2"

if [ ! -f "$SRC" ]; then
        echo "找不到输入文件: $SRC" >&2
        exit 1
fi

# 取第一个以 ```c 开头、以 ``` 结尾的块
awk '
        /^```c[[:space:]]*$/ { inblock = 1; next }
        inblock && /^```[[:space:]]*$/ { exit }
        inblock { print }
' "$SRC" > "$OUT"

if [ ! -s "$OUT" ]; then
        echo "未在 $SRC 中找到 c 代码块（以三个反引号 + c 开头的块）" >&2
        rm -f "$OUT"
        exit 1
fi

echo "已生成 $OUT（$(wc -l < "$OUT") 行）"
