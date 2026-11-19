// SPDX-License-Identifier: GPL-2.0
/*
 * pci_skeleton.c — 最小可编译 Linux PCIe 驱动骨架（教学用）
 *
 * 演示一条 PCIe 驱动主线的四件事：
 *   配置(probe) → 映射(BAR/寄存器) → 数据通路(DMA) → 中断(MSI-X)
 *
 * 目标内核：>= 5.6（.remove 回调为 void 返回；更早内核需按下方注释适配）
 * 编译：见 Makefile。加载后用 /dev/pci_skelN 访问（N 见 probe 内命名说明）。
 *
 * 硬件假设（教学模型，按你的真实设备改 OFFSET / BAR index）：
 *   BAR0 : 4KB 寄存器区
 *     +0x00  ID        (RO)  设备标识
 *     +0x04  STATUS    (RO)  bit0 = DMA done（设备写回数据后置 1）
 *     +0x08  CTRL      (RW)  bit0 = start DMA
 *     +0x0C  DMA_ADDR_LO (RW) DMA 缓冲总线地址低 32 位
 *     +0x10  DMA_ADDR_HI (RW) DMA 缓冲总线地址高 32 位
 *     +0x14  DMA_LEN    (RW)  传输长度（字节）
 *
 * 教学要点（读代码时对照）：
 *   - 一致性 DMA 缓冲用 dma_alloc_coherent；返回给用户的内容必须是
 *     "硬件已写入或已知初始化"的数据，绝不能把未初始化内核内存交给用户（信息泄漏）。
 *   - 64 位 DMA 地址必须同时写 ADDR_HI / ADDR_LO，只写低 32 位会在高地址（>4G）截断。
 *   - 单 completion / 单 buffer 不支持多进程并发，必须用 mutex 串行化。
 */
#include <linux/module.h>
#include <linux/pci.h>
#include <linux/interrupt.h>
#include <linux/dma-mapping.h>
#include <linux/miscdevice.h>
#include <linux/fs.h>
#include <linux/uaccess.h>
#include <linux/completion.h>
#include <linux/mutex.h>
#include <linux/mm.h>
#include <linux/slab.h>

#define DRV_NAME "pci_skel"

/* ===== 1. 你的设备 ID：改成真实值，或用 lspci -nn 查看 ===== */
#define MY_VENDOR_ID  0x1234
#define MY_DEVICE_ID  0x5678

/* ===== 2. 寄存器偏移 ===== */
#define REG_ID         0x00
#define REG_STATUS     0x04
#define REG_CTRL       0x08
#define REG_DMA_ADDR_LO 0x0C
#define REG_DMA_ADDR_HI 0x10
#define REG_DMA_LEN    0x14
#define STATUS_DMA_DONE BIT(0)
#define CTRL_START_DMA  BIT(0)

/* probe 里给 DMA 缓冲填充的可识别模式，供用户态校验闭环 */
#define DMA_PATTERN    0xA5

/* 每个设备的私有数据结构 */
struct skel_dev {
	struct pci_dev  *pdev;          /* 供 mmap 取 BAR 物理地址用 */
	void __iomem    *regs;          /* BAR0 映射后的寄存器指针 */
	int              irq;           /* MSI-X 第 0 条向量 */
	struct completion dma_done;     /* 中断→进程同步 */
	struct mutex     lock;          /* 串行化 read 的 DMA 触发→等待→拷贝 */
	dma_addr_t       dma_handle;    /* DMA 缓冲总线地址 */
	void            *dma_buf;       /* DMA 缓冲 CPU 地址 */
	size_t           dma_size;
	struct miscdevice misc;         /* /dev/pci_skelN */
};

/* ===== 3. 中断处理：短小，只做"标记完成 + 清中断" ===== */
static irqreturn_t skel_isr(int irq, void *dev_id)
{
	struct skel_dev *d = dev_id;
	u32 status = readl(d->regs + REG_STATUS);

	if (!(status & STATUS_DMA_DONE))
		return IRQ_NONE;            /* 不是本设备中断（共享/误触发） */

	writel(status, d->regs + REG_STATUS);  /* 写 1 清除中断标志 */
	complete(&d->dma_done);                 /* 唤醒等待 DMA 的进程 */
	return IRQ_HANDLED;
}

/* ===== 4. 用户态 mmap：把 BAR0 直接映射进用户进程，省去 readl 系统调用开销 =====
 * 用法（用户态）：mmap 后可用 *(volatile uint32_t*) 直接读写寄存器。
 * misc 框架在 misc_open() 里把 file->private_data 指向 struct miscdevice *，
 * 故用 container_of 取回外层 skel_dev；注意：一旦自定义 .open 覆盖 private_data，此法失效。
 */
static int skel_mmap(struct file *f, struct vm_area_struct *vma)
{
	struct skel_dev *d = container_of(f->private_data, struct skel_dev, misc);
	unsigned long pfn  = pci_resource_start(d->pdev, 0) >> PAGE_SHIFT;
	unsigned long size = vma->vm_end - vma->vm_start;

	if (size > pci_resource_len(d->pdev, 0))
		return -EINVAL;

	/* 设备内存属于 I/O 内存，须用 io_remap_pfn_range（x86 上等同 remap_pfn_range） */
	return io_remap_pfn_range(vma, vma->vm_start, pfn, size, vma->vm_page_prot);
}

/* ===== 5. 用户态读：等一次 DMA 完成，把结果拷给应用 ===== */
static ssize_t skel_read(struct file *f, char __user *ubuf,
			 size_t count, loff_t *ppos)
{
	struct skel_dev *d = container_of(f->private_data, struct skel_dev, misc);
	int ret;

	/* 单 completion / 单 buffer：必须串行化，否则多进程并发会丢失唤醒或损坏数据 */
	if (mutex_lock_interruptible(&d->lock))
		return -ERESTARTSYS;

	/* 触发一次 DMA：把设备可访问的总线地址写进寄存器，64 位地址 HI/LO 都要写
	 * 注意：先 reinit_completion，清掉上一次（或迟到中断）遗留的完成量，
	 * 否则本次可能"立刻返回"并读到上一轮的旧数据。 */
	reinit_completion(&d->dma_done);
	writel(lower_32_bits(d->dma_handle), d->regs + REG_DMA_ADDR_LO);
	writel(upper_32_bits(d->dma_handle), d->regs + REG_DMA_ADDR_HI);
	writel(d->dma_size, d->regs + REG_DMA_LEN);
	writel(CTRL_START_DMA, d->regs + REG_CTRL);

	/* 阻塞等待 ISR 里的 complete() */
	ret = wait_for_completion_interruptible(&d->dma_done);
	if (ret)
		goto out_unlock;

	if (count > d->dma_size)
		count = d->dma_size;
	if (copy_to_user(ubuf, d->dma_buf, count)) {
		ret = -EFAULT;
		goto out_unlock;
	}
	ret = count;

out_unlock:
	mutex_unlock(&d->lock);
	return ret;
}

static const struct file_operations skel_fops = {
	.owner   = THIS_MODULE,
	.read    = skel_read,
	.mmap    = skel_mmap,
};

/* ===== 6. probe：设备被发现时调用（核心） ===== */
static int skel_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
	struct skel_dev *d;
	char name[24];
	int ret, nvec;

	/* 6.1 分配私有数据 */
	d = devm_kzalloc(&pdev->dev, sizeof(*d), GFP_KERNEL);
	if (!d)
		return -ENOMEM;
	d->pdev = pdev;
	init_completion(&d->dma_done);
	mutex_init(&d->lock);
	pci_set_drvdata(pdev, d);

	/* 6.2 使能设备 */
	ret = pci_enable_device(pdev);
	if (ret)
		goto err_out;

	/* 6.3 让设备能做总线主控（开 DMA），并声明 DMA 位宽
	 * 注意：现代写法是 dma_set_mask_and_coherent；老教程里的 pci_set_dma_mask 已过时。 */
	pci_set_master(pdev);
	ret = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(64));
	if (ret) {
		pci_warn(pdev, "64-bit DMA not supported\n");
		goto err_disable;
	}

	/* 6.4 申请 BAR 区域 */
	ret = pci_request_regions(pdev, DRV_NAME);
	if (ret)
		goto err_disable;

	/* 6.5 映射 BAR0 为寄存器指针 */
	d->regs = pci_iomap(pdev, 0, 0);  /* 0 = BAR0, 0 = 映射整段 */
	if (!d->regs) {
		ret = -ENOMEM;
		goto err_regions;
	}
	pci_info(pdev, "BAR0 mapped at %px, device id=0x%08x\n",
		 d->regs, readl(d->regs + REG_ID));

	/* 6.6 申请 MSI-X 中断（至少 1 条） */
	nvec = pci_alloc_irq_vectors(pdev, 1, 1, PCI_IRQ_MSIX | PCI_IRQ_MSI);
	if (nvec < 1) {
		ret = nvec;
		goto err_iounmap;
	}
	d->irq = pci_irq_vector(pdev, 0);

	/* 6.7 绑定中断处理函数 */
	ret = request_irq(d->irq, skel_isr, 0, DRV_NAME, d);
	if (ret)
		goto err_irqvec;

	/* 6.8 分配一致性 DMA 缓冲，并填充可识别模式
	 * 关键：绝不能把未初始化内核内存交给用户态（信息泄漏）。这里填 DMA_PATTERN，
	 * 用户态读到 0xA5 即可确认"驱动→硬件→中断→回用户态"闭环打通。 */
	d->dma_size = PAGE_SIZE;
	d->dma_buf = dma_alloc_coherent(&pdev->dev, d->dma_size,
					&d->dma_handle, GFP_KERNEL);
	if (!d->dma_buf) {
		ret = -ENOMEM;
		goto err_irq;
	}
	memset(d->dma_buf, DMA_PATTERN, d->dma_size);

	/* 6.9 暴露成 /dev/pci_skelN 给用户态
	 * misc 的设备节点名 = misc->name。多卡时若都用固定名 "pci_skel"，第二张卡
	 * misc_register 会因同名节点已存在而失败，故用 devfn 生成唯一名。 */
	snprintf(name, sizeof(name), "%s%02x", DRV_NAME, pdev->devfn & 0xff);
	d->misc.name = devm_kstrdup(&pdev->dev, name, GFP_KERNEL);
	if (!d->misc.name) {
		ret = -ENOMEM;
		goto err_dma;
	}
	d->misc.minor  = MISC_DYNAMIC_MINOR;
	d->misc.fops   = &skel_fops;
	d->misc.parent = &pdev->dev;
	ret = misc_register(&d->misc);
	if (ret)
		goto err_dma;

	pci_info(pdev, "probed ok, irq=%d, /dev/%s, dma_addr=0x%pad\n",
		 d->irq, name, &d->dma_handle);
	return 0;

/* ---- 反向清理（顺序与 probe 相反）----
 * 说明：pci_set_master 的镜像清理由 pci_disable_device 完成（它会清 Command 的
 * Master 位），无需显式 clear_master，但要知道这层关系。 */
err_dma:
	dma_free_coherent(&pdev->dev, d->dma_size, d->dma_buf, d->dma_handle);
err_irq:
	free_irq(d->irq, d);
err_irqvec:
	pci_free_irq_vectors(pdev);
err_iounmap:
	pci_iounmap(pdev, d->regs);
err_regions:
	pci_release_regions(pdev);
err_disable:
	pci_disable_device(pdev);
err_out:
	return ret;
}

/* ===== 7. remove：干净地反着拆一遍 =====
 * 注：>=5.6 内核 remove 返回 void；若要支持 <5.6 老内核，需改成返回 int 的版本。 */
static void skel_remove(struct pci_dev *pdev)
{
	struct skel_dev *d = pci_get_drvdata(pdev);

	misc_deregister(&d->misc);
	dma_free_coherent(&pdev->dev, d->dma_size, d->dma_buf, d->dma_handle);
	free_irq(d->irq, d);
	pci_free_irq_vectors(pdev);
	pci_iounmap(pdev, d->regs);
	pci_release_regions(pdev);
	pci_disable_device(pdev);
	pci_info(pdev, "removed\n");
}

/* ===== 8. 设备匹配表 + 电源管理 ===== */
static const struct pci_device_id skel_ids[] = {
	{ PCI_DEVICE(MY_VENDOR_ID, MY_DEVICE_ID) },
	{ 0, }
};
MODULE_DEVICE_TABLE(pci, skel_ids);

/* 现代写法：用 dev_pm_ops（SIMPLE_DEV_PM_OPS），而非已废弃的 .suspend/.resume。
 * 顺序要点：先 pci_save_state 再 pci_disable_device——save 保存的是"设备仍在
 * 正常工作时"的配置空间；若反过来，disable 会清 Bus Master、可能改动 Command
 * 寄存器，保存下来的就不是进入 D3 前的预期状态。
 * 注意本骨架 resume 仅恢复到"能访问"状态，未重做 request_irq / misc_register；
 * 生产驱动如需完整还原应参照 probe 的 6.4-6.9。 */
#ifdef CONFIG_PM
static int skel_suspend(struct device *dev)
{
	struct pci_dev *pdev = to_pci_dev(dev);
	pci_save_state(pdev);
	pci_disable_device(pdev);
	pci_set_power_state(pdev, PCI_D3hot);
	return 0;
}
static int skel_resume(struct device *dev)
{
	struct pci_dev *pdev = to_pci_dev(dev);
	pci_set_power_state(pdev, PCI_D0);
	pci_restore_state(pdev);
	return pci_enable_device(pdev);
}
static SIMPLE_DEV_PM_OPS(skel_pm_ops, skel_suspend, skel_resume);
#define SKEL_PM_OPS (&skel_pm_ops)
#else
#define SKEL_PM_OPS NULL
#endif

static struct pci_driver skel_driver = {
	.name      = DRV_NAME,
	.id_table  = skel_ids,
	.probe     = skel_probe,
	.remove    = skel_remove,
	.driver.pm = SKEL_PM_OPS,
};

/* ===== 9. 模块加载/卸载：一行搞定注册 ===== */
module_pci_driver(skel_driver);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("WorkBuddy");
MODULE_DESCRIPTION("Minimal teaching PCIe driver skeleton");
