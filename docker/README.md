# Docker + QEMU PCIe 实验环境

配套教程见上级目录 [../lab_03_qemu_docker.md](../lab_03_qemu_docker.md)。

## 一键复现

```bash
# 构建镜像（首次较慢）
docker build -t pcie-lab .

# 起容器（挂载学习包，改代码即时生效）
docker run -it --name pcie-lab -v "$(pwd)/..":/work pcie-lab bash

# 容器内：启动带 pci-testdev 的 guest
chmod +x entrypoint.sh && ./entrypoint.sh

# guest 串口 shell 里：
lspci -nn | grep -i test
```

## 文件

- `Dockerfile` —— 固定 QEMU + gcc + 工具链环境
- `entrypoint.sh` —— 获取 guest 内核、做 initramfs、启动 QEMU(TCG)
- `guest/vmlinuz`（可选）—— 你手动放的 guest 内核，放了就跳过下载

## 关键提醒

1. **纯 TCG**：默认不依赖 KVM，任何宿主机都能跑；代价是慢（软件模拟指令）。
2. **内核版本铁律**：驱动 `.ko` 必须用第 3 层 guest 内核的头文件编译，不能用容器的 `uname -r`。最稳是走 lab_03 文档的"路线 A"——在 guest 内编译。
3. **虚拟设备**：本方案跑的是 QEMU 模拟的虚拟 PCIe 设备，练驱动框架流程；真实 PCIe 直通不是 Docker 的强项。
