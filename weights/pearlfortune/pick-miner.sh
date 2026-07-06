#!/usr/bin/env bash
# pick-miner.sh — 单一事实源：按 nvidia-smi 报告的 CUDA 版本输出应使用的 miner 二进制。
# h-run.sh / mmp-launch.sh / vhtos-launch.sh 共用，避免「选 bin」逻辑在多处漂移。
#
# 用法：  MINER_BIN="$(./pick-miner.sh)"      # stdout 输出形如 ./miner-cuda13
#         检测信息打到 stderr，不污染 stdout（调用方 cd 到包目录后再调用）。
# 兼容：  纯 grep/awk/tr/cut/case，busybox 环境(HiveOS/mmpOS/vhTOS)均可用。
#
# 坑：nvidia-smi 头行同时含「驱动版本」和「CUDA 版本」，且驱动版本排在前面：
#       | NVIDIA-SMI 575.57.08   Driver Version: 575.57.08   CUDA Version: 12.9 |
#     直接取整行第一个 X.Y 会抢到驱动版本号(575.57→major 575)，永远走兜底，
#     CUDA13 机器会被误判成 cuda12。用 awk -F 'CUDA' 切掉关键字之前的内容，
#     只保留 "CUDA Version" 之后的版本号再取主版本。
#     nvidia-smi 报的是「驱动最高支持的 CUDA 版本」：major≥13 才能跑 cuda13 二进制。

CUDA_MAJOR=$(nvidia-smi 2>/dev/null | grep -i 'CUDA Version' | head -n1 \
             | awk -F 'CUDA' '{print $NF}' | tr -cd '0-9.' | cut -d. -f1)

case "$CUDA_MAJOR" in
    13) MINER_BIN="./miner-cuda13" ;;
    *)  MINER_BIN="./miner-cuda12" ;;   # 12 / 11 / 检测不到 一律 cuda12（向下兼容兜底）
esac

echo "[pick-miner] CUDA major=${CUDA_MAJOR:-none} -> $MINER_BIN" >&2
printf '%s\n' "$MINER_BIN"
