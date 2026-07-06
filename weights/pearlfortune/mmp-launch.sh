#!/usr/bin/env bash
# mmpOS launcher for pearlfortune (Pearl/PRL NVIDIA miner)
#
# mmpOS 默认参数模板(在 profile 的 advanced/arguments 里):
#   ./mmp-launch.sh --coin %coin% %pool_protocol% --pool %pool_server%:%pool_port% --user %user% --password %password% --api-port %api_port%
#
# 本脚本是“参数适配层”,把上面的 mmpOS 标准参数翻译成 pearl 矿工真正的命令:
#   ./miner-cudaXX --proxy <host:port> --address <wallet/template> [--token <TOKEN>] -gpu [透传的其它参数]
#
# 设计与 HiveOS 版 h-run.sh 等价:按 CUDA 版本选二进制、token 可选、-gpu 固定开启。
# pearl 不是 stratum 矿工,因此 --pool 的 host:port 原样作为 --proxy,绝不加 stratum+tcp:// 前缀。

set -o pipefail
cd "$(dirname "$0")" || exit 1

CONF_FILE="mmp-external.conf"
# shellcheck disable=SC1090
[[ -f "$CONF_FILE" ]] && . "$CONF_FILE"

log() { echo "[mmp-launch] $*" >&2; }

# ---------------- 解析 mmpOS 通用参数 ----------------
ARGS=("$@")
EXTRA_ARGS=()
POOL_VAL=""
USER_VAL=""
PASS_VAL=""        # pearl 不用密码,仅解析掉避免透传
COIN_VAL=""        # pearl 单算法,仅解析掉
API_PORT=""        # pearl 无 --api-port,仅解析掉
TOKEN_VAL="${TOKEN:-}"   # 允许从 mmp-external.conf / 环境注入 TOKEN

i=0
while [[ $i -lt ${#ARGS[@]} ]]; do
    case "${ARGS[$i]}" in
        --coin)      COIN_VAL="${ARGS[$((i+1))]}";  ((i+=2)) ;;
        --pool)      POOL_VAL="${ARGS[$((i+1))]}";  ((i+=2)) ;;
        --proxy)     POOL_VAL="${ARGS[$((i+1))]}";  ((i+=2)) ;;   # 也允许直接给 --proxy
        --user)      USER_VAL="${ARGS[$((i+1))]}";  ((i+=2)) ;;
        --address)   USER_VAL="${ARGS[$((i+1))]}";  ((i+=2)) ;;   # 也允许直接给 --address
        --password)  PASS_VAL="${ARGS[$((i+1))]}";  ((i+=2)) ;;
        --api-port)  API_PORT="${ARGS[$((i+1))]}";  ((i+=2)) ;;
        --token)     TOKEN_VAL="${ARGS[$((i+1))]}"; ((i+=2)) ;;
        tcp|tls)     ((i+=1)) ;;          # mmpOS 协议占位符;pearl 非 stratum,忽略
        -gpu)        ((i+=1)) ;;          # 统一在下面补,避免重复
        *)           EXTRA_ARGS+=("${ARGS[$i]}"); ((i+=1)) ;;
    esac
done

# ---------------- 按 CUDA 版本选二进制（逻辑抽到 ./pick-miner.sh，三个启动器共用）----------------
MINER_BIN="$(./pick-miner.sh)"
[[ -n "$MINER_BIN" ]] || MINER_BIN="./miner-cuda12"   # pick-miner.sh 缺失/异常时兜底

# busid 与算力数组对齐(mmp-stats.sh 依赖):让矿工按 PCI 总线顺序枚举 GPU
export CUDA_DEVICE_ORDER=PCI_BUS_ID

# ---------------- 校验必填 ----------------
[[ -z "$POOL_VAL" ]] && { log "ERROR: pool/proxy is empty (need --pool host:port)"; exit 1; }
[[ -z "$USER_VAL" ]] && { log "ERROR: wallet/address is empty (need --user <wallet>)"; exit 1; }

# ---------------- 组装命令 ----------------
CMD=( "$MINER_BIN" --proxy "$POOL_VAL" --address "$USER_VAL" )
[[ -n "$TOKEN_VAL" ]] && CMD+=( --token "$TOKEN_VAL" )
CMD+=( -gpu )
[[ ${#EXTRA_ARGS[@]} -gt 0 ]] && CMD+=( "${EXTRA_ARGS[@]}" )

log "selected: $MINER_BIN"   # CUDA 检测详情见 pick-miner.sh 打到 stderr 的日志
log "exec: ${CMD[*]}"

# 干跑:MMP_DRYRUN=1 时只打印命令,不启动矿工(用于离线验证)
if [[ -n "$MMP_DRYRUN" ]]; then
    echo "${CMD[*]}"
    exit 0
fi

# 本地兜底日志:mmpOS 会捕获本脚本 stdout 作为 LOG_FILE 传给 mmp-stats.sh;
# 同时 tee 一份到固定文件,供 stats 在拿不到 mmpOS 日志时回退解析。
# 每次启动先清空,避免无限增长(submit.ack 计数随之从 0 重新累计,可接受)。
LOCAL_LOG="${MMP_LOG_FILE:-/tmp/pearlfortune-mmp.log}"
: > "$LOCAL_LOG" 2>/dev/null || LOCAL_LOG=/dev/null

exec "${CMD[@]}" 2>&1 | tee -a "$LOCAL_LOG"
