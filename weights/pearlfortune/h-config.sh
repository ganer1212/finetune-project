#!/usr/bin/env bash

# HiveOS 会把本脚本 source 进 /hive/bin/custom，飞行表的 wallet/rig 变量
# （CUSTOM_URL / CUSTOM_TEMPLATE / CUSTOM_PASS / CUSTOM_USER_CONFIG 等）在此处可直接使用。
# 这里负责生成 miner 配置文件，供 h-run.sh 读取（h-run.sh 单独进程拿不到这些变量）。

mkfile_from_symlink $CUSTOM_CONFIG_FILENAME

cat > $CUSTOM_CONFIG_FILENAME <<EOF
CUSTOM_URL='$CUSTOM_URL'
CUSTOM_TEMPLATE='$CUSTOM_TEMPLATE'
CUSTOM_PASS='$CUSTOM_PASS'
CUSTOM_USER_CONFIG='$CUSTOM_USER_CONFIG'
EOF
