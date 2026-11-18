# 基础镜像：Ubuntu 22.04（含 QEMU、gcc、编译驱动所需工具）
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# 装 QEMU + 编译工具链 + 实验/调试工具
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential gcc make \
    qemu-system-x86 qemu-utils \
    pciutils kmod \
    linux-headers-generic \
    wget curl cpio gzip xz-utils \
    busybox-static \
    gdb \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# 工作目录：把学习包挂载/拷进这里
WORKDIR /work

# 默认进入交互 shell（也可直接跑 entrypoint.sh，见 lab_03 文档）
CMD ["/bin/bash"]
