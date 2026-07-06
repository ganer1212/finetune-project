#!/usr/bin/env bash
# HiveOS h-stats.sh for pearl GPU miner
# 本脚本由 HiveOS source（非执行）：只需设好 $khs 和 $stats 两个变量，不要 echo。
#   khs   : 总算力 (khs)
#   stats : 统计 JSON

. `dirname $BASH_SOURCE`/h-manifest.conf
LOG_FILE="$CUSTOM_LOG_BASENAME.log"

khs=0
stats=""

if [[ -f $LOG_FILE ]]; then
    log_age=$(( $(date +%s) - $(stat -c %Y "$LOG_FILE") ))
    if (( log_age <= 60 )); then
        # 取较大窗口：最新日志里 rpc.ping 等行可能高频刷屏，而 large.progress 约每 ~15s 才一条，
        # 窗口太小会取不到进度行 -> 间歇算力 0。
        tail_buf=$(tail -n 5000 "$LOG_FILE")

        # 最近一条聚合进度行：最新格式只输出它 ——
        #   event=large.progress ... proof_per_sec="830.93 T/s" devices="[4090: 96.01T/s, ...]"
        # 用 tac 反向全量扫描取最后一条，避免固定窗口被 rpc.ping 等高频行刷掉而漏取进度行
        # （HiveOS 会轮转日志，文件大小有上限，tac 开销可接受）。
        last_prog=$(tac "$LOG_FILE" \
            | grep -F 'event=large.progress' \
            | grep -vF 'event=large.progress.device' \
            | head -n 1)

        # --- 每卡算力数组 device_hash_tsv (index<TAB>T/s) ---
        # 优先老的每卡行 event=large.progress.device（向后兼容）；没有则解析聚合行 devices="[...]"
        # 例: ... event=large.progress.device device=0 ... proof_per_sec="69.53 T/s"
        device_hash_tsv=$(echo "$tail_buf" \
            | grep -F 'event=large.progress.device' \
            | awk '
                {
                    dev=""
                    for (i=1;i<=NF;i++)
                        if ($i ~ /^device=/) { split($i,a,"="); dev=a[2] }
                    # proof_per_sec="69.53 T/s" 含空格，须对整行做正则匹配
                    if (dev!="" && match($0, /proof_per_sec="[0-9.]+/)) {
                        s=substr($0, RSTART, RLENGTH); sub(/proof_per_sec="/, "", s)
                        rate[dev]=s                      # 后出现的覆盖 -> 最新
                        seen=1
                        if (dev+0 > maxd) maxd=dev+0
                    }
                }
                END {
                    # 无任何 device 行时不输出，让下面聚合行分支接管
                    if (seen)
                        for (k=0; k<=maxd; k++)
                            printf "%d\t%s\n", k, (k in rate ? rate[k] : "0")
                }')

        # 聚合行回退：从 devices="[4090: 96.01T/s, ...]" 按位置取每卡速率。
        # 切分用 /, */ 而非 /,[[:space:]]*/，兼容老版 mawk（不支持 POSIX 字符类）；
        # 速率用 /[0-9.]+T\/s/ 提取，兼容 "96.01T/s"(无空格) 与型号前缀 "4090: ..."。
        if [[ -z $device_hash_tsv && -n $last_prog ]]; then
            device_hash_tsv=$(echo "$last_prog" \
                | awk '{
                    if (match($0, /devices="\[[^"]+\]"/)) {
                        devices=substr($0, RSTART+10, RLENGTH-12)
                        n=split(devices, item, /, */)
                        for (i=1;i<=n;i++)
                            if (match(item[i], /[0-9.]+T\/s/)) {
                                rate=substr(item[i], RSTART, RLENGTH); sub(/T\/s$/,"",rate)
                                printf "%d\t%s\n", i-1, rate
                            }
                    }
                }' | sort -n -k1,1)
        fi

        # 总算力 (T/s)：优先聚合行自报的权威总值 proof_per_sec="<X> T/s"（避免各卡四舍五入求和漂移），
        # 取不到再回退为各卡求和，再不行为 0。
        proof_per_sec=$(echo "$last_prog" \
            | grep -oE 'proof_per_sec="[0-9.]+' | tail -n 1 | cut -d'"' -f2)
        if [[ -z $proof_per_sec || $proof_per_sec =~ ^0+([.]0+)?$ ]]; then
            proof_per_sec=$(echo "$device_hash_tsv" | awk -F'\t' '{s+=$2} END{printf "%.2f", s+0}')
        fi
        [[ -z $proof_per_sec ]] && proof_per_sec=0

        # T/s -> khs:  1 T/s = 10^12 /s = 10^9 khs
        khs=$(awk -v p="$proof_per_sec" 'BEGIN{printf "%.3f", p * 1000000000}')

        # --- per-device telemetry: keep latest device.stats per index ---
        dev_tsv=$(echo "$tail_buf" \
            | awk '/event=device\.stats/{
                idx=""; t=""; f=""; p=""
                for (i=1;i<=NF;i++) {
                    if ($i ~ /^index=/)         { split($i,a,"="); idx=a[2] }
                    if ($i ~ /^temperature_c=/) { split($i,a,"="); t=a[2] }
                    if ($i ~ /^fan_pct=/)       { split($i,a,"="); f=a[2] }
                    if ($i ~ /^power_w=/)       { split($i,a,"="); p=a[2] }
                }
                if (idx!="") { temp[idx]=t; fan[idx]=f; pow[idx]=p }
              }
              END {
                # mawk 兼容：不用 gawk 专有的 asorti，改为外部 sort -n 按 index 排序
                for (k in temp) printf "%s\t%s\t%s\t%s\n", k, temp[k], fan[k], pow[k]
              }' | sort -n -k1,1)

        temp_json="[]"; fan_json="[]"; power_json="[]"
        if [[ -n $dev_tsv ]]; then
            temp_json=$(echo "$dev_tsv"  | awk -F'\t' '{print $2}' | jq -Rn '[inputs|tonumber? // 0]')
            fan_json=$(echo "$dev_tsv"   | awk -F'\t' '{print $3}' | jq -Rn '[inputs|tonumber? // 0]')
            power_json=$(echo "$dev_tsv" | awk -F'\t' '{print $4}' | jq -Rn '[inputs|tonumber? // 0]')
        fi

        # JSON hs 数组按每卡 khs 输出（×1e9）；旧日志无 devices 时退回总算力单元素数组
        if [[ -n $device_hash_tsv ]]; then
            hs_json=$(echo "$device_hash_tsv" \
                | awk -F'\t' '{printf "%.3f\n", $2 * 1000000000}' \
                | jq -Rn '[inputs|tonumber? // 0]')
        else
            hs_json=$(awk -v p="$proof_per_sec" 'BEGIN{printf "[%.3f]", p * 1000000000}')
        fi

        # --- bus_numbers: 把每个 hs 元素映射到对应 GPU 行（HiveOS 据此把算力放到正确的卡）---
        # 这台机器有 Intel 核显 + N 卡，HiveOS 把核显也算一行；没有 bus_numbers 时它无法把
        # 2 个 hs 值对到 3 行 GPU 上 -> 每卡算力列留空。bus 取自 nvidia-smi（按 index/bus 升序），
        # 配合 h-run.sh 的 CUDA_DEVICE_ORDER=PCI_BUS_ID，hs[i] 与 bus_numbers[i] 严格对齐。
        # 仅当 N 卡数 == hs 长度时输出，否则置 null 不输出：宁可不映射也不要错映射。
        hs_count=$(echo "$hs_json" | jq 'length')
        bus_json=null
        if (( hs_count > 0 )) && command -v nvidia-smi >/dev/null 2>&1; then
            mapfile -t bus_hex < <(nvidia-smi --query-gpu=pci.bus --format=csv,noheader 2>/dev/null | tr -d ' ')
            if (( ${#bus_hex[@]} == hs_count )); then
                bus_dec=(); for b in "${bus_hex[@]}"; do bus_dec+=( $((16#${b#0x})) ); done
                bus_json=$(printf '%s\n' "${bus_dec[@]}" | jq -Rn '[inputs|tonumber? // 0]')
            fi
        fi

        # uptime from first timestamp in log
        first_ts=$(grep -m1 -oE 'ts=[0-9T:.-]+' "$LOG_FILE" 2>/dev/null | head -n1 | cut -d= -f2)
        uptime_s=0
        if [[ -n $first_ts ]]; then
            start_epoch=$(date -d "${first_ts%.*}" +%s 2>/dev/null || echo 0)
            now_epoch=$(date +%s)
            (( start_epoch > 0 )) && uptime_s=$(( now_epoch - start_epoch ))
            (( uptime_s < 0 )) && uptime_s=0
        fi

        # --- accepted/rejected 份额：来自服务器回执 event=submit.ack 的 accepted=true/false ---
        # 必须扫整份 LOG_FILE（submit.ack 很稀疏，窗口 tail 里通常一条都取不到）。单遍 awk，128MB 实测 ~0.3s。
        # 注意：HiveOS 轮转/截断该日志后计数会从 0 重新累计（与 ar 累计语义一致，可接受）。
        read accepted rejected < <(awk '
            /event=submit.ack/{
                if ($0 ~ /accepted=true/)       a++
                else if ($0 ~ /accepted=false/) r++
            }
            END { print a+0, r+0 }' "$LOG_FILE")
        : "${accepted:=0}" "${rejected:=0}"

        ver="pearl"

        stats=$(jq -nc \
            --argjson hs    "$hs_json" \
            --arg     hs_units "khs" \
            --argjson temp  "$temp_json" \
            --argjson fan   "$fan_json" \
            --argjson power "$power_json" \
            --argjson uptime "$uptime_s" \
            --arg     algo  "pearl" \
            --arg     ver   "$ver" \
            --argjson accepted "$accepted" \
            --argjson rejected "$rejected" \
            --argjson bus   "$bus_json" \
            '{hs:$hs, hs_units:$hs_units, temp:$temp, fan:$fan, power:$power,
              uptime:$uptime, ar:[$accepted,$rejected],
              algo:$algo, ver:$ver}
             + (if $bus != null then {bus_numbers:$bus} else {} end)')

        # 可选自诊断：PEARL_STATS_DEBUG=1 时把关键中间值写到独立文件，便于在矿机上定位空列根因
        [[ -n $PEARL_STATS_DEBUG ]] && \
            printf '[h-stats] khs=%s hs=%s bus=%s\n' "$khs" "$hs_json" "$bus_json" \
            >> "${CUSTOM_LOG_BASENAME}-stats-debug.log" 2>/dev/null
    fi
fi

[[ -z $khs ]] && khs=0
[[ -z $stats ]] && stats='{"hs":[],"hs_units":"khs","temp":[],"fan":[],"power":[],"uptime":0,"ar":[0,0],"algo":"pearl","ver":"pearl"}'
