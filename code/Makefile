# PCI 驱动骨架的 Kbuild（编译脚本）
#
# 用法 A：作为内核树外模块单独编译（推荐学习用，不需要 Kconfig）
#   需要已装内核头文件：linux-headers-$(uname -r)
#   在本目录执行：
#       make              # 同时编译内核模块 + 用户态测试程序
#       sudo insmod pci_skeleton.ko
#       dmesg | tail      # 看 probe 日志（需要匹配到设备才会有）
#       ls -l /dev/pci_skel*   # 设备节点名 = pci_skel + devfn（见代码 6.9）
#
# 用法 B：放进内核树编译（把本目录放到 drivers/misc/pci_skel/）
#   1) 在 drivers/misc/Kconfig 里加：source "drivers/misc/pci_skel/Kconfig"
#   2) 在 drivers/misc/Makefile 里加：obj-$(CONFIG_PCI_SKEL) += pci_skel/
#   3) 本目录必须再有内部 Makefile.kbuild（内容见下方"树内 Makefile"注释）
#
# 命名说明：模块文件名是 pci_skeleton.ko；驱动名/中断名/动态调试用 pci_skel。

obj-m := pci_skeleton.o

# 内核模块编译告警。注意：ccflags-y 只对 obj-m（内核模块）生效，
# 对下面用户态程序的裸 $(CC) 编译无效。
# 需要更严格检查时用：make KCFLAGS=-Wextra （不要写死，避免和内核 -Werror 冲突）
ccflags-y := -Wall

KDIR ?= /lib/modules/$(shell uname -r)/build
# CURDIR 是 make 内建变量，用 make -C 从别处调用时也始终指向当前目录，比 $(shell pwd) 稳
PWD  := $(CURDIR)

all: module test

module:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

test: userspace_test.c
	$(CC) -Wall -O2 -o userspace_test userspace_test.c

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -f userspace_test

.PHONY: all module test clean

# ── 树内 Makefile（用法 B 用；单独存为 drivers/misc/pci_skel/Makefile）─────────────
#   obj-$(CONFIG_PCI_SKEL) += pci_skeleton.o
# ─────────────────────────────────────────────────────────────────────────────
