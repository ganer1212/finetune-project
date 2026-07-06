#!/usr/bin/env bash
# set -euo pipefail

cd `dirname $0`

# 读取静态路径（CUSTOM_CONFIG_FILENAME / CUSTOM_LOG_BASENAME 等）
. h-manifest.conf

# 读取 h-config.sh 生成的配置（含飞行表里的 CUSTOM_URL / CUSTOM_TEMPLATE / CUSTOM_USER_CONFIG）
[[ -f $CUSTOM_CONFIG_FILENAME ]] && . $CUSTOM_CONFIG_FILENAME

# 解析 CUSTOM_USER_CONFIG（飞行表「其他参数」，可多行）：
#   - 形如 KEY=VALUE 的行 → 当环境变量 export（如 TOKEN / MINER_SUBMIT_VERSION），供 miner 子进程读取
#   - 其它行（如 --startup-bench）→ 收集为额外命令行参数，透传给 miner
# 不再对整段做 eval，避免把 flag 当命令执行而报 "command not found"
EXTRA_ARGS=()
while IFS= read -r _line; do
    _line="${_line#"${_line%%[![:space:]]*}"}"   # 去掉行首空白
    _line="${_line%"${_line##*[![:space:]]}"}"     # 去掉行尾空白
    [[ -z "$_line" || "$_line" == \#* ]] && continue
    if [[ "$_line" != -* && "$_line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
        set -a; eval "$_line"; set +a            # KEY=VALUE → export（eval 处理引号，如 TOKEN="..."）
    else
        eval "EXTRA_ARGS+=( $_line )"            # CLI flag → 透传（eval 拆词并尊重引号）
    fi
done <<< "$CUSTOM_USER_CONFIG"

log() { printf '[%(%F %T)T] [select-miner] %s\n' -1 "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

echo "Debug CUSTOM_URL=$CUSTOM_URL CUSTOM_TEMPLATE=$CUSTOM_TEMPLATE TOKEN=$TOKEN MINER_SUBMIT_VERSION=$MINER_SUBMIT_VERSION"
echo "Debug MINER_SUBMIT_VERSION=$MINER_SUBMIT_VERSION"


# =========================
# 1. 按 CUDA 版本选 miner 二进制（逻辑抽到 ./pick-miner.sh，三个启动器共用）
# =========================
MINER_BIN="$(./pick-miner.sh)"
[[ -n "$MINER_BIN" ]] || MINER_BIN="./miner-cuda12"   # pick-miner.sh 缺失/异常时兜底

log "exec: $MINER_BIN"

## ───────────────────────────────────────────────
## 启动 miner
## 输出同时写入 HiveOS 标准日志（$CUSTOM_LOG_BASENAME.log），供 h-stats.sh 解析
## ───────────────────────────────────────────────
# --token 是可选项；TOKEN 为空时不传，避免传入空值导致 enrollment 失败
args=( --proxy "${CUSTOM_URL}" --address "${CUSTOM_TEMPLATE}" )
[[ -n "$TOKEN" ]] && args+=( --token "${TOKEN}" )
args+=( -gpu )
# 透传飞行表「其他参数」里的额外 flag（如 --startup-bench）
[[ ${#EXTRA_ARGS[@]} -gt 0 ]] && args+=( "${EXTRA_ARGS[@]}" )

echo "Debug exec: $MINER_BIN ${args[*]}"

"$MINER_BIN" "${args[@]}" 2>&1 | tee -a "$CUSTOM_LOG_BASENAME.log"
