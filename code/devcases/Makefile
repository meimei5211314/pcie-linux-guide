# dev_case 通用 Kbuild
#
# 自动把本目录下所有 .c 编译成内核模块（每个 .c 一个 .ko）。
# 用法：
#   ./extract.sh ../../dev_case_01_拓扑发现.md mc_topo.c
#   make
#
# 需要目标内核的头文件：/lib/modules/$(uname -r)/build

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(CURDIR)

SRCS := $(wildcard *.c)
obj-m := $(patsubst %.c,%.o,$(SRCS))

ccflags-y := -Wall

all:
	@if [ -z "$(SRCS)" ]; then \
		echo "本目录没有 .c 文件。先用 extract.sh 从 dev_case_*.md 抽出源码。"; \
		exit 1; \
	fi
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

help:
	@echo "make        编译本目录所有 .c 为内核模块"
	@echo "make clean  清理产物"
	@echo "当前源文件: $(SRCS)"

.PHONY: all clean help
