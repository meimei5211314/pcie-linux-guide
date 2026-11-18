/* SPDX-License-Identifier: GPL-2.0 */
/*
 * userspace_test.c — 驱动骨架的用户态测试程序
 *
 * 编译：make test   (或 gcc -Wall -O2 -o userspace_test userspace_test.c)
 * 运行：sudo ./userspace_test /dev/pci_skelNN
 *
 * 说明：触发一次驱动里的 DMA（read 会阻塞直到中断完成），把结果打印出来。
 *       这是最简单的"用户态 → 驱动 → 硬件 → 中断 → 回用户态"闭环验证。
 *
 * 成功标志：驱动在 probe 里把 DMA 缓冲填成了 0xA5，因此首字节应为 0xa5。
 *           看到 0xa5 = 闭环打通；看到别的值说明驱动没跑到那条路径（见 troubleshooting.md）。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

#define DEFAULT_DEV "/dev/pci_skel00"  /* 节点名 = pci_skel + devfn，见代码 probe 6.9 */
#define BUF_SIZE    4096
#define EXPECT_BYTE 0xA5               /* 驱动 probe 填充的模式 */

int main(int argc, char **argv)
{
	const char *dev = (argc > 1) ? argv[1] : DEFAULT_DEV;
	unsigned char buf[BUF_SIZE];
	int fd, n;

	fd = open(dev, O_RDONLY);
	if (fd < 0) {
		fprintf(stderr, "open(%s): %s\n", dev, strerror(errno));
		fprintf(stderr, "提示：1) 模块已加载? lsmod | grep pci_skeleton\n"
				"      2) 设备节点存在? ls -l /dev/pci_skel*\n"
				"      3) probe 跑了? dmesg | tail\n"
				"      详见 troubleshooting.md\n");
		return 1;
	}

	printf("[*] open %s ok, 触发一次 DMA 并等待中断完成...\n", dev);

	n = read(fd, buf, sizeof(buf));
	if (n < 0) {
		fprintf(stderr, "read: %s\n", strerror(errno));
		close(fd);
		return 1;
	}

	printf("[+] 收到 %d 字节 (经 DMA + 中断闭环)\n", n);
	if (n > 0) {
		printf("[i] 首字节 = 0x%02x", buf[0]);
		if (buf[0] == EXPECT_BYTE)
			printf("  ✓ == 0x%02x，闭环成功！\n", EXPECT_BYTE);
		else
			printf("  ✗ != 0x%02x，驱动未走通 DMA/中断路径（无硬件时属预期，"
			       "见 troubleshooting.md）\n", EXPECT_BYTE);
	}

	close(fd);
	return 0;
}
