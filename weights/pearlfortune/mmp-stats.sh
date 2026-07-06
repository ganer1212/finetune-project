#!/usr/bin/env bash
# mmpOS stats for pearlfortune (Pearl/PRL NVIDIA miner)
#
# mmpOS 调用:  ./mmp-stats.sh <DEVICE_NUM> <LOG_FILE>
#   $1 = mmpOS 期望的设备数(参考)   $2 = mmpOS 捕获的矿工日志路径
#
# 输出**单行 mmpOS 统计 JSON** 到 stdout,除该 JSON 外不要打印任何东西。
# 注意:mmpOS agent 容器(ddobreff/mmp-agent)里**没有 jq**,因此本脚本
# 完全用 awk/printf 自行构造 JSON(仅依赖 awk/mawk、grep、sort、tr、date、stat)。
#
# 日志事件格式(来自 pearl miner stdout):
#   event=large.progress ... proof_per_sec="785.24 T/s" devices="[RTX 4090 D: 98.58T/s, ...]"
#   event=device.stats index=N temperature_c=.. fan_pct=.. power_w=..
#   (份额:任何带 accepted=true/false 的行,本版本可能暂无)
#   ts=...(算 uptime)

DEVICE_NUM="$1"
LOG_FILE="$2"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MINER_NAME="pearlfortune"; MINER_VERSION="1.1.8"
if [[ -f "$SCRIPT_DIR/mmp-external.conf" ]]; then
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/mmp-external.conf"
    MINER_NAME="${EXTERNAL_NAME:-$MINER_NAME}"
    MINER_VERSION="${EXTERNAL_VERSION:-$MINER_VERSION}"
fi

FALLBACK_LOG="${MMP_LOG_FILE:-/tmp/pearlfortune-mmp.log}"

emit_empty() {
    printf '{"busid":[],"hash":[],"units":"ths","temp":[],"fan":[],"watt":[],"air":[0,0,0],"uptime":0,"miner_name":"%s","miner_version":"%s"}\n' \
        "$MINER_NAME" "$MINER_VERSION"
}

# stdin: 每行一个数值 -> 输出 JSON 数组;非数值置 0;空输入 -> []
arr() {
    awk 'function isnum(x){return (x ~ /^-?[0-9]+([.][0-9]+)?$/)}
         {a[n++]=(isnum($0)?$0:"0")}
         END{s="["; for(i=0;i<n;i++) s=s (i?",":"") a[i]; print s "]"}'
}

mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

# 选日志:优先 mmpOS 传入且新鲜(<=120s)的,否则回退本地 tee 日志
LOG=""
for cand in "$LOG_FILE" "$FALLBACK_LOG"; do
    [[ -n "$cand" && -f "$cand" ]] || continue
    age=$(( $(date +%s) - $(mtime "$cand") ))
    if (( age <= 120 )); then LOG="$cand"; break; fi
done
[[ -z "$LOG" ]] && { emit_empty; exit 0; }

tail_buf="$(tail -n 5000 "$LOG")"
# 最近一条聚合进度行(用 grep|tail -n1 取最后一条,避免依赖 GNU tac)
last_prog="$(grep -F 'event=large.progress' "$LOG" 2>/dev/null | grep -vF 'event=large.progress.device' | tail -n 1)"

# --- 每卡 T/s:优先 per-device 行,回退聚合行 devices="[...]"(设备名含空格,如 "RTX 4090 D") ---
device_hash="$(printf '%s\n' "$tail_buf" \
    | grep -F 'event=large.progress.device' \
    | awk '{
        dev=""
        for(i=1;i<=NF;i++) if($i ~ /^device=/){split($i,a,"=");dev=a[2]}
        if(dev!="" && match($0,/proof_per_sec="[0-9.]+/)){
            s=substr($0,RSTART,RLENGTH); sub(/proof_per_sec="/,"",s)
            rate[dev]=s; seen=1; if(dev+0>maxd) maxd=dev+0
        }
      } END{ if(seen) for(k=0;k<=maxd;k++) print (k in rate?rate[k]:"0") }')"

if [[ -z "$device_hash" && -n "$last_prog" ]]; then
    device_hash="$(printf '%s\n' "$last_prog" | awk '{
        if(match($0,/devices="\[[^"]+\]"/)){
            d=substr($0,RSTART+10,RLENGTH-12)
            n=split(d,item,/, */)
            for(i=1;i<=n;i++) if(match(item[i],/[0-9.]+T\/s/)){
                r=substr(item[i],RSTART,RLENGTH); sub(/T\/s$/,"",r); print r
            }
        }
    }')"
fi

# 总 T/s(优先聚合行自报权威总值,否则各卡求和)
proof_total="$(printf '%s\n' "$last_prog" | grep -oE 'proof_per_sec="[0-9.]+' | tail -n 1 | cut -d'"' -f2)"
if [[ -z "$proof_total" || "$proof_total" =~ ^0+([.]0+)?$ ]]; then
    proof_total="$(printf '%s\n' "$device_hash" | awk '{s+=$1} END{printf "%.2f",s+0}')"
fi
[[ -z "$proof_total" ]] && proof_total=0

# hash 数组(units=ths,直接用原始 T/s 数值)+ 设备数
if [[ -n "$device_hash" ]]; then
    hash_json="$(printf '%s\n' "$device_hash" | awk '{printf "%.4f\n",$1+0}' | arr)"
    hash_len="$(printf '%s\n' "$device_hash" | grep -c .)"
elif awk -v p="$proof_total" 'BEGIN{exit !(p+0>0)}'; then
    hash_json="[$(awk -v p="$proof_total" 'BEGIN{printf "%.4f",p+0}')]"
    hash_len=1
else
    hash_json="[]"; hash_len=0
fi

# --- per-device 温度/风扇/功耗(取每个 index 的最新值)---
dev_tsv="$(printf '%s\n' "$tail_buf" | awk '/event=device\.stats/{
        idx="";t="";f="";p=""
        for(i=1;i<=NF;i++){
            if($i ~ /^index=/)         {split($i,a,"=");idx=a[2]}
            if($i ~ /^temperature_c=/) {split($i,a,"=");t=a[2]}
            if($i ~ /^fan_pct=/)       {split($i,a,"=");f=a[2]}
            if($i ~ /^power_w=/)       {split($i,a,"=");p=a[2]}
        }
        if(idx!=""){temp[idx]=t;fan[idx]=f;pow[idx]=p}
    } END{ for(k in temp) printf "%s\t%s\t%s\t%s\n",k,temp[k],fan[k],pow[k] }' | sort -n -k1,1)"

temp_json="[]"; fan_json="[]"; watt_json="[]"
if [[ -n "$dev_tsv" ]]; then
    temp_json="$(printf '%s\n' "$dev_tsv" | awk -F'\t' '{print $2}' | arr)"
    fan_json="$(printf '%s\n' "$dev_tsv"  | awk -F'\t' '{print $3}' | arr)"
    watt_json="$(printf '%s\n' "$dev_tsv" | awk -F'\t' '{print $4}' | arr)"
fi

# --- busid:nvidia-smi pci.bus(hex)->十进制,长度须等于 hash;否则回退 0..n-1 ---
busid_json="[]"
if (( hash_len > 0 )); then
    if command -v nvidia-smi >/dev/null 2>&1; then
        buses="$(nvidia-smi --query-gpu=pci.bus --format=csv,noheader 2>/dev/null | tr -d ' ')"
        bus_count="$(printf '%s\n' "$buses" | grep -c .)"
        if (( bus_count == hash_len )); then
            busid_json="$(printf '%s\n' "$buses" | while read -r b; do
                [[ -n "$b" ]] && printf '%d\n' "$((16#${b#0x}))"
            done | arr)"
        fi
    fi
    # 拿不到/数量不匹配 -> 回退顺序索引,保证 busid 与 hash 等长(mmpOS 要求)
    [[ "$busid_json" == "[]" ]] && busid_json="$(awk -v n="$hash_len" 'BEGIN{for(i=0;i<n;i++)print i}' | arr)"
fi

# --- uptime:日志首条 ts= 到现在 ---
first_ts="$(grep -m1 -oE 'ts=[0-9T:.-]+' "$LOG" 2>/dev/null | head -n 1 | cut -d= -f2)"
uptime_s=0
if [[ -n "$first_ts" ]]; then
    start_epoch="$(date -d "${first_ts%.*}" +%s 2>/dev/null || echo 0)"
    (( start_epoch > 0 )) && uptime_s=$(( $(date +%s) - start_epoch ))
    (( uptime_s < 0 )) && uptime_s=0
fi

# --- accepted/rejected:统计任何含 accepted=true/false 的行(不限事件名,兼容版本差异)---
ar="$(awk '/accepted=true/{a++} /accepted=false/{r++} END{print a+0" "r+0}' "$LOG" 2>/dev/null)"
accepted="${ar% *}"; rejected="${ar#* }"
[[ "$accepted" =~ ^[0-9]+$ ]] || accepted=0
[[ "$rejected" =~ ^[0-9]+$ ]] || rejected=0

printf '{"busid":%s,"hash":%s,"units":"ths","temp":%s,"fan":%s,"watt":%s,"air":[%d,0,%d],"uptime":%d,"miner_name":"%s","miner_version":"%s"}\n' \
    "$busid_json" "$hash_json" "$temp_json" "$fan_json" "$watt_json" \
    "$accepted" "$rejected" "$uptime_s" "$MINER_NAME" "$MINER_VERSION"
