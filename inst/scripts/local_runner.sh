#!/bin/bash
# ============================================================
# local_runner.sh — diann.gui 本地执行运行器 (v1.12)
#
# 由 R/backend-local.R 以 `setsid nohup bash local_runner.sh ... &` 派生,
# 脱离 Shiny 会话生命周期独立运行。职责:
#   1) 先写 pidfile (GUI 侧拿 pid 做 /proc starttime 防复用校验);
#   2) 用 nice + timeout 启动共享作业体脚本 (make_local_script 生成);
#   3) stdout/stderr 重定向到 local-<ID>.out/.err;
#   4) 保证 .rc 退出码落盘 (作业体已写则以作业体为准; timeout 命中补 124);
#   5) 补 DIANN_GUI_END_EPOCH (作业体被信号打断时缺失), 清理 pidfile。
#
# 用法: local_runner.sh SCRIPT OUT ERR RC PIDFILE TIMEOUT_SEC GRACE NICE
#   TIMEOUT_SEC = 0 表示不限时
# 标记: <SCRIPT>.cancelled 由取消操作写入; <SCRIPT>.timeout 由本运行器写入
# ============================================================
set -u

SCRIPT="${1:?SCRIPT required}"
OUT="${2:?OUT required}"
ERR="${3:?ERR required}"
RC="${4:?RC required}"
PIDFILE="${5:?PIDFILE required}"
TIMEOUT_SEC="${6:-0}"
GRACE="${7:-30}"
NICE="${8:-10}"

MARK_CANCEL="${SCRIPT}.cancelled"
MARK_TIMEOUT="${SCRIPT}.timeout"

# pidfile 先写: GUI 侧最多等 3s; 写失败不影响作业本身, 只影响取消/状态显示
printf '%s\n' "$$" > "$PIDFILE" 2>/dev/null || true

# 启动前已被取消 (用户在 launcher 抢到 pid 前点了取消): 写好 rc/END 后直接退出
if [ -f "$MARK_CANCEL" ]; then
  [ -s "$RC" ] || printf '%s' 143 > "$RC"
  printf 'DIANN_GUI_END_EPOCH %s\n' "$(date +%s)" >> "$OUT" 2>/dev/null || true
  rm -f "$PIDFILE" 2>/dev/null || true
  exit 143
fi

# 作业体 (make_local_script) 自带 DIANN_GUI_START/END_EPOCH 与 .rc 落盘
if [ "$TIMEOUT_SEC" -gt 0 ] 2>/dev/null && command -v timeout >/dev/null 2>&1; then
  nice -n "$NICE" timeout -k "$GRACE" "$TIMEOUT_SEC" bash "$SCRIPT" >> "$OUT" 2>> "$ERR"
  rc=$?
else
  nice -n "$NICE" bash "$SCRIPT" >> "$OUT" 2>> "$ERR"
  rc=$?
fi

# timeout 命中 (124, 或 KILL 后的 137): 记标记; .rc 已有内容时以作业体为准
if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
  touch "$MARK_TIMEOUT" 2>/dev/null || true
  [ -s "$RC" ] || printf '%s' "$rc" > "$RC"
fi
# 作业体被外部 signal 杀死等场景未写 .rc 时由运行器补写, 保证状态层 2 有输入
[ -s "$RC" ] || printf '%s' "$rc" > "$RC"

# END epoch: 正常完成时作业体已写; 被打断时补一行 (耗时/产物层使用)
if ! grep -q '^DIANN_GUI_END_EPOCH ' "$OUT" 2>/dev/null; then
  printf 'DIANN_GUI_END_EPOCH %s\n' "$(date +%s)" >> "$OUT" 2>/dev/null || true
fi

rm -f "$PIDFILE" 2>/dev/null || true
exit "$rc"
