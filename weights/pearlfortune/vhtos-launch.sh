#!/usr/bin/env bash
# pearlfortune — vhTOS 启动适配层（第三平台：HiveOS / mmpOS 之外）
#
# 把 vhTOS 注入的配置翻译成 pearl 矿工真实命令：
#   ./miner-cudaXX --proxy <host:port> --address <wallet[.worker]> [--token X] -gpu [透传 extra]
#
# 【配置注入三来源（优先级从高到低，取第一个非空）】
#   1) env：VHTOS_POOL / VHTOS_WALLET / VHTOS_WORKER / VHTOS_EXTRA / VHTOS_TOKEN
#   2) CLI：--pool/--proxy、--user/--address、--worker、--token（仿 mmpOS 模板）
#   3) HiveOS 兜底 env：CUSTOM_URL / CUSTOM_TEMPLATE / WORKER_NAME / CUSTOM_USER_CONFIG
#   4) vhtos-external.conf 里的同名变量（最低，测试兜底）
#
# Extra 双语义（沿用 h-run.sh，勿改）：
#   * KEY=VALUE 行 → export（如 TOKEN=xxx / MINER_SUBMIT_VERSION=2），供 miner 子进程读取
#   * 裸 flag（如 --startup-bench）→ 透传给 miner
# pearl 非 stratum：--proxy 用 host:port 原样，不加 scheme。--token 为空时不传。
# CUDA：nvidia-smi "CUDA Version" major 13→cuda13；12/11→cuda12；其它→fallback cuda12。
# 离线验证：VHTOS_DRYRUN=1 只打印命令。

set -o pipefail
cd "$(dirname "$0")" || exit 1

# 快照 vhTOS 真实注入的 env（必须优先于 conf 兜底，避免 sourced conf 反向覆盖；见 minerx-hiveos-manifest-clobber）
_env_POOL="${VHTOS_POOL:-}"; _env_WAL="${VHTOS_WALLET:-}"; _env_WORK="${VHTOS_WORKER:-}"
_env_EXTRA="${VHTOS_EXTRA:-}"; _env_TOKEN="${VHTOS_TOKEN:-}"

CONF_FILE="vhtos-external.conf"
# shellcheck disable=SC1090,SC1091
[[ -f "$CONF_FILE" ]] && . "$CONF_FILE"
_conf_POOL="${VHTOS_POOL:-}"; _conf_WAL="${VHTOS_WALLET:-}"; _conf_WORK="${VHTOS_WORKER:-}"; _conf_EXTRA="${VHTOS_EXTRA:-}"

log()   { echo "[vhtos-launch] $*" >&2; }
first() { local v; for v in "$@"; do [[ -n $v ]] && { printf '%s' "$v"; return; }; done; }

# ---------------- 1) CLI 解析（mmpOS 模板风格） ----------------
ARGS=("$@"); CLI_EXTRA=(); CLI_POOL=""; CLI_USER=""; CLI_WORKER=""; CLI_TOKEN=""
i=0
while [[ $i -lt ${#ARGS[@]} ]]; do
    case "${ARGS[$i]}" in
        --coin|--password|--api-port) ((i+=2)) ;;        # pearl 用不到，吃掉
        --pool|--proxy)   CLI_POOL="${ARGS[$((i+1))]}";   ((i+=2)) ;;
        --user|--address) CLI_USER="${ARGS[$((i+1))]}";   ((i+=2)) ;;
        --worker)         CLI_WORKER="${ARGS[$((i+1))]}"; ((i+=2)) ;;
        --token)          CLI_TOKEN="${ARGS[$((i+1))]}";  ((i+=2)) ;;
        tcp|tls|-gpu)     ((i+=1)) ;;                      # 协议占位/重复 -gpu，忽略
        *)                CLI_EXTRA+=("${ARGS[$i]}"); ((i+=1)) ;;
    esac
done

# ---------------- 2) 择优 ----------------
PROXY="$(first "$_env_POOL" "$CLI_POOL" "$CUSTOM_URL" "$_conf_POOL")"
WALLET="$(first "$_env_WAL" "$CLI_USER" "$CUSTOM_TEMPLATE" "$_conf_WAL")"
WORKER="$(first "$_env_WORK" "$CLI_WORKER" "$WORKER_NAME" "$_conf_WORK")"
# pearl 的 --address 用整段 wallet[.worker]；若单独给了 worker 且 wallet 未含 '.'，拼上
ADDRESS="$WALLET"
[[ -n $WORKER && $ADDRESS != *.* ]] && ADDRESS="$WALLET.$WORKER"

# ---------------- 3) Extra 双语义 + TOKEN 捕获 ----------------
TOKEN="$(first "$_env_TOKEN" "$CLI_TOKEN" "${TOKEN:-}")"   # 初值：env/CLI/conf；下面 extra 里的 TOKEN= 可覆盖
EXTRA_ARGS=()
# 把整段 extra 按空白/换行词切分（eval 尊重引号），再逐 token 分类：
#   KEY=VALUE → export（含 TOKEN 捕获）；裸 flag / flag 的值 → 透传给 miner。
# 这样单行（TOKEN=x --flag）、多行、带引号的值（KEY="a b"）、flag+值（--device 0,1）都正确。
# eval 词切分沿用 pearlfortune 既有 posture（h-run.sh 同样 eval extra；字段来自操作者自己的飞行表）。
process_extra() {
    local blob="$1" toks t
    [[ -z $blob ]] && return
    eval "toks=( $blob )" 2>/dev/null || { log "WARN: 无法解析 extra: $blob"; return; }
    for t in "${toks[@]}"; do
        [[ -z $t || $t == \#* ]] && continue
        if [[ $t != -* && $t =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            export "$t"                 # KEY=VALUE（值已由词切分去引号），写入当前 shell 并标记 export
        else
            EXTRA_ARGS+=("$t")
        fi
    done
}
[[ -n ${MINER_EXTRA_ARGS:-} ]] && process_extra "$MINER_EXTRA_ARGS"
_EXTRA_SRC="$(first "$_env_EXTRA" "$_conf_EXTRA")"; [[ -n $_EXTRA_SRC ]] && process_extra "$_EXTRA_SRC"
[[ -n ${CUSTOM_USER_CONFIG:-} ]] && process_extra "$CUSTOM_USER_CONFIG"
for tok in "${CLI_EXTRA[@]}"; do process_extra "$tok"; done
# process_extra 里的 TOKEN=xxx 会 export 覆盖 $TOKEN
TOKEN="${TOKEN:-}"

# ---------------- 4) 按 CUDA 版本选二进制（逻辑抽到 ./pick-miner.sh，三个启动器共用）----------------
MINER_BIN="$(./pick-miner.sh)"
[[ -n "$MINER_BIN" ]] || MINER_BIN="./miner-cuda12"   # pick-miner.sh 缺失/异常时兜底
export CUDA_DEVICE_ORDER=PCI_BUS_ID   # 让算力数组与 nvidia-smi busid 对齐（vhtos-stats 依赖）

# ---------------- 5) 预检 ----------------
[[ -z $PROXY ]]   && { log "ERROR: proxy/pool 为空，需 host:port。"; exit 1; }
[[ -z $ADDRESS ]] && { log "ERROR: wallet/address 为空，需 prl1...（可带 .worker）。"; exit 1; }

# ---------------- 6) 组装并启动 ----------------
CMD=( "$MINER_BIN" --proxy "$PROXY" --address "$ADDRESS" )
[[ -n $TOKEN ]] && CMD+=( --token "$TOKEN" )
CMD+=( -gpu )
(( ${#EXTRA_ARGS[@]} )) && CMD+=( "${EXTRA_ARGS[@]}" )

log "selected $MINER_BIN"   # CUDA 检测详情见 pick-miner.sh 打到 stderr 的日志
log "exec: ${CMD[*]}"

[[ -n ${VHTOS_DRYRUN:-} ]] && { echo "${CMD[*]}"; exit 0; }

LOG_FILE="${VHTOS_LOG_FILE:-/tmp/pearlfortune-vhtos.log}"
: > "$LOG_FILE" 2>/dev/null || LOG_FILE=/dev/null
exec "${CMD[@]}" 2>&1 | tee -a "$LOG_FILE"
