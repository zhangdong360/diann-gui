#!/bin/bash
# 命令导入端到端回归: 起本地 runApp 实例 -> 浏览器粘贴两份真实命令 -> 断言会话存活与填充。
# 每次更新 app.R / diann_core.R / notify_common.R 后必须执行 (staging 部署=改文件即上线,
# 本脚本验证的是"改动之后的应用"本身; 部署后可再以 --url 对生产复核一次)。
#
# 用法:
#   tests/e2e/run_e2e.sh                 # 自动起本地实例 (端口 4849) 并验证
#   tests/e2e/run_e2e.sh --url URL       # 验证一个已在运行的实例 (如生产 http://localhost:3838/diann_gui/)
#
# 依赖: R (shiny/shinydashboard/shinyFiles 可用), python3 + selenium, geckodriver, Firefox。
set -u
cd "$(dirname "$0")/../.."   # 仓库根
REPO="$(pwd)"
PORT="${E2E_PORT:-4849}"
# 夹具使用合成路径 /share/home/demo/..., 本地/CI 无此目录:
# 经 DIANN_GUI_EXTRA_VOLUMES 把它加入路径守卫白名单 (app.R 测试钩子, 生产不受影响)
export DIANN_GUI_EXTRA_VOLUMES="${DIANN_GUI_EXTRA_VOLUMES:-/share/home/demo}"
URL=""
if [ "${1:-}" = "--url" ]; then URL="$2"; fi
PASS=0

if [ -z "$URL" ]; then
  LOG="$(mktemp /tmp/diann_e2e.XXXX.log)"
  echo "[e2e] 启动本地实例 :$PORT (日志 $LOG)"
  R CMD INSTALL --no-multiarch . > /dev/null 2>&1 || { echo "[e2e] FAIL: R CMD INSTALL"; exit 1; }
  Rscript -e "diann.gui::run_app(port = $PORT, host = '127.0.0.1', launch.browser = FALSE)" > "$LOG" 2>&1 &
  APP_PID=$!
  URL="http://127.0.0.1:$PORT/"
  trap 'kill $APP_PID 2>/dev/null' EXIT
  for i in $(seq 1 60); do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$URL" || true)
    [ "$code" = "200" ] && break
    sleep 1
  done
  if [ "$code" != "200" ]; then echo "[e2e] FAIL: 本地实例未就绪"; tail -20 "$LOG"; exit 1; fi
  echo "[e2e] 实例就绪"
fi

python3 tests/e2e/e2e_import_check.py --url "$URL" --repo-root "$REPO" && PASS=1
RC=$?
[ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null
trap - EXIT
[ "$RC" = 0 ] && echo "[e2e] 通过" || echo "[e2e] 失败"
exit $RC
