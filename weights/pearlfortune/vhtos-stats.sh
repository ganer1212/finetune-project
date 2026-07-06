#!/usr/bin/env bash
# pearlfortune — vhTOS stats 适配层（第三平台：HiveOS / mmpOS 之外）
#
# 独立进程、stdout 输出单行 JSON（不依赖 jq，awk/printf 构造）。两种调用形态都支持：
#   ./vhtos-stats.sh                  # 无参：读 $VHTOS_LOG_FILE / 默认日志
#   ./vhtos-stats.sh <设备数> <日志>   # 仿 mmpOS：第 2 参数是日志路径
# schema 由 vhtos-external.conf 的 VHTOS_STATS_SCHEMA 选择：hiveos（默认）| mmpos
# ⚠️ 若实测 vhTOS 是 HiveOS 式「source 读 $khs/$stats」→ 直接用包内 h-stats.sh。
#
# pearl miner stdout 事件：
#   event=large.progress ... proof_per_sec="785.24 T/s" devices="[RTX 4090 D: 98.58T/s, ...]"
#   event=large.progress.device device=N ... proof_per_sec="98.58 T/s"
#   event=device.stats index=N temperature_c=.. fan_pct=.. power_w=..
#   accepted=true/false（份额）   ts=...（uptime）

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MINER_NAME="pearlfortune"; MINER_VERSION="1.2.0"; STATS_SCHEMA="hiveos"; CONF_LOG=""
_env_SCHEMA="${VHTOS_STATS_SCHEMA:-}"
if [[ -f "$SCRIPT_DIR/vhtos-external.conf" ]]; then
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/vhtos-external.conf"
    MINER_NAME="${VHTOS_NAME:-$MINER_NAME}"
    MINER_VERSION="${VHTOS_VERSION:-$MINER_VERSION}"
    STATS_SCHEMA="${VHTOS_STATS_SCHEMA:-hiveos}"
    CONF_LOG="${VHTOS_LOG_FILE:-}"
fi
[[ -n $_env_SCHEMA ]] && STATS_SCHEMA="$_env_SCHEMA"

ARG_LOG="$2"
FALLBACK_LOG="${CONF_LOG:-/tmp/pearlfortune-vhtos.log}"

mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
arr() { awk 'function isnum(x){return (x ~ /^-?[0-9]+([.][0-9]+)?$/)}
             {a[n++]=(isnum($0)?$0:"0")}
             END{s="["; for(i=0;i<n;i++) s=s (i?",":"") a[i]; print s "]"}'; }

emit_empty() {
    if [[ $STATS_SCHEMA == mmpos ]]; then
        printf '{"busid":[],"hash":[],"units":"ths","temp":[],"fan":[],"watt":[],"air":[0,0,0],"uptime":0,"miner_name":"%s","miner_version":"%s"}\n' "$MINER_NAME" "$MINER_VERSION"
    else
        printf '{"hs":[],"hs_units":"khs","temp":[],"fan":[],"power":[],"uptime":0,"ar":[0,0],"algo":"pearl","ver":"%s","bus_numbers":[]}\n' "$MINER_VERSION"
    fi
}

LOG=""
for cand in "$ARG_LOG" "$FALLBACK_LOG"; do
    [[ -n "$cand" && -f "$cand" ]] || continue
    age=$(( $(date +%s) - $(mtime "$cand") ))
    if (( age <= 120 )); then LOG="$cand"; break; fi
done
[[ -z "$LOG" ]] && { emit_empty; exit 0; }

tail_buf="$(tail -n 5000 "$LOG")"
last_prog="$(grep -F 'event=large.progress' "$LOG" 2>/dev/null | grep -vF 'event=large.progress.device' | tail -n 1)"

# --- 每卡 T/s：优先 per-device 行，回退聚合行 devices="[...]" ---
device_hash="$(printf '%s\n' "$tail_buf" | grep -F 'event=large.progress.device' | awk '{
        dev=""
        for(i=1;i<=NF;i++) if($i ~ /^device=/){split($i,a,"=");dev=a[2]}
        if(dev!="" && match($0,/proof_per_sec="[0-9.]+/)){
            s=substr($0,RSTART,RLENGTH); sub(/proof_per_sec="/,"",s)
            rate[dev]=s; seen=1; if(dev+0>maxd) maxd=dev+0 }
    } END{ if(seen) for(k=0;k<=maxd;k++) print (k in rate?rate[k]:"0") }')"
if [[ -z "$device_hash" && -n "$last_prog" ]]; then
    device_hash="$(printf '%s\n' "$last_prog" | awk '{
        if(match($0,/devices="\[[^"]+\]"/)){
            d=substr($0,RSTART+10,RLENGTH-12); n=split(d,item,/, */)
            for(i=1;i<=n;i++) if(match(item[i],/[0-9.]+T\/s/)){
                r=substr(item[i],RSTART,RLENGTH); sub(/T\/s$/,"",r); print r }
        } }')"
fi

# 总 T/s（优先聚合行权威值，否则各卡求和）
proof_total="$(printf '%s\n' "$last_prog" | grep -oE 'proof_per_sec="[0-9.]+' | tail -n 1 | cut -d'"' -f2)"
if [[ -z "$proof_total" || "$proof_total" =~ ^0+([.]0+)?$ ]]; then
    proof_total="$(printf '%s\n' "$device_hash" | awk '{s+=$1} END{printf "%.2f",s+0}')"
fi
[[ -z "$proof_total" ]] && proof_total=0
hash_len="$(printf '%s\n' "$device_hash" | grep -c .)"

# --- per-device 温度/风扇/功耗 ---
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

# --- busid：nvidia-smi pci.bus(hex)->十进制，长度须等于 hash，否则回退 0..n-1 ---
busid_json="[]"
if (( hash_len > 0 )); then
    if command -v nvidia-smi >/dev/null 2>&1; then
        buses="$(nvidia-smi --query-gpu=pci.bus --format=csv,noheader 2>/dev/null | tr -d ' ')"
        bus_count="$(printf '%s\n' "$buses" | grep -c .)"
        if (( bus_count == hash_len )); then
            busid_json="$(printf '%s\n' "$buses" | while read -r b; do [[ -n "$b" ]] && printf '%d\n' "$((16#${b#0x}))"; done | arr)"
        fi
    fi
    [[ "$busid_json" == "[]" ]] && busid_json="$(awk -v n="$hash_len" 'BEGIN{for(i=0;i<n;i++)print i}' | arr)"
fi

# --- uptime / 份额 ---
first_ts="$(grep -m1 -oE 'ts=[0-9T:.-]+' "$LOG" 2>/dev/null | head -n 1 | cut -d= -f2)"
uptime_s=0
if [[ -n "$first_ts" ]]; then
    start_epoch="$(date -d "${first_ts%.*}" +%s 2>/dev/null || echo 0)"
    (( start_epoch > 0 )) && uptime_s=$(( $(date +%s) - start_epoch ))
    (( uptime_s < 0 )) && uptime_s=0
fi
ar="$(awk '/accepted=true/{a++} /accepted=false/{r++} END{print a+0" "r+0}' "$LOG" 2>/dev/null)"
accepted="${ar% *}"; rejected="${ar#* }"
[[ "$accepted" =~ ^[0-9]+$ ]] || accepted=0
[[ "$rejected" =~ ^[0-9]+$ ]] || rejected=0

(( hash_len == 0 )) && { emit_empty; exit 0; }

# ---------------- 按 schema 输出 ----------------
if [[ $STATS_SCHEMA == mmpos ]]; then
    hash_json="$(printf '%s\n' "$device_hash" | awk '{printf "%.4f\n",$1+0}' | arr)"   # ths 原值
    printf '{"busid":%s,"hash":%s,"units":"ths","temp":%s,"fan":%s,"watt":%s,"air":[%d,0,%d],"uptime":%d,"miner_name":"%s","miner_version":"%s"}\n' \
        "$busid_json" "$hash_json" "$temp_json" "$fan_json" "$watt_json" \
        "$accepted" "$rejected" "$uptime_s" "$MINER_NAME" "$MINER_VERSION"
else
    hs_json="$(printf '%s\n' "$device_hash" | awk '{printf "%.3f\n",$1*1000000000}' | arr)"   # T/s -> khs
    printf '{"hs":%s,"hs_units":"khs","temp":%s,"fan":%s,"power":%s,"uptime":%d,"ar":[%d,%d],"algo":"pearl","ver":"%s","bus_numbers":%s}\n' \
        "$hs_json" "$temp_json" "$fan_json" "$watt_json" \
        "$uptime_s" "$accepted" "$rejected" "$MINER_VERSION" "$busid_json"
fi
