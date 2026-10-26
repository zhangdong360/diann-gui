#!/bin/bash
# 端到端回归: 起本地 runApp 实例 → 浏览器执行 导入 / apptainer 运行环境 两组断言。
# 每次更新 R/ 下的命令构建、导入、UI 或配置逻辑后必须执行 (staging 部署=改文件即上线,
# 本脚本验证的是"改动之后的应用"本身; 部署后可再以 --url 对生产复核一次)。
#
# 用法:
#   tests/e2e/run_e2e.sh                 # 自动起本地实例 (端口 4849) 并验证
#   tests/e2e/run_e2e.sh --url URL       # 验证一个已在运行的实例 (如生产 http://localhost:3838/diann_gui/)
#
# 依赖: R (shiny/shinydashboard/shinyFiles/testthat), python3 + selenium, geckodriver, Firefox。
set -u
cd "$(dirname "$0")/../.."   # 仓库根
REPO="$(pwd)"
PORT="${E2E_PORT:-4849}"
# 夹具使用合成路径 /share/home/demo/..., 本地/CI 无此目录:
# 经 DIANN_GUI_EXTRA_VOLUMES 把它加入路径守卫白名单 (测试钩子, 生产不受影响)
export DIANN_GUI_EXTRA_VOLUMES="${DIANN_GUI_EXTRA_VOLUMES:-/share/home/demo}"
URL=""
if [ "${1:-}" = "--url" ]; then URL="$2"; fi
RC=0
FAKE_APT=""
CLEANUP_DIR=""

cleanup() {
  [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null
  [ -n "$CLEANUP_DIR" ] && rm -rf "$CLEANUP_DIR"
}
trap cleanup EXIT

if [ -z "$URL" ]; then
  LOG="$(mktemp /tmp/diann_e2e.XXXX.log)"
  # 假 apptainer: 登录节点通常没有 apptainer, 用它验证 自动识别 + 版本解析 + 手动验证。
  CLEANUP_DIR="$(mktemp -d /tmp/diann_e2e_apt.XXXX)"
  mkdir -p "$CLEANUP_DIR/bin"
  FAKE_APT="$CLEANUP_DIR/bin/apptainer"
  printf '#!/bin/sh\necho "apptainer version 1.4.5"\nexit 0\n' > "$FAKE_APT"
  chmod 755 "$FAKE_APT"
  # 用独立配置把 APPTAINER_PATHS 指到假二进制 (不碰用户 ~/.diann_gui)
  cat > "$CLEANUP_DIR/config.R" <<EOF
APPTAINER_PATHS <- c("$CLEANUP_DIR/bin")
EOF
  export DIANN_GUI_CONFIG="$CLEANUP_DIR/config.R"

  echo "[e2e] 启动本地实例 :$PORT (日志 $LOG)"
  R CMD INSTALL --no-multiarch . > /dev/null 2>&1 || { echo "[e2e] FAIL: R CMD INSTALL"; exit 1; }
  Rscript -e "diann.gui::run_app(port = $PORT, host = '127.0.0.1', launch.browser = FALSE)" > "$LOG" 2>&1 &
  APP_PID=$!
  URL="http://127.0.0.1:$PORT/"
  for i in $(seq 1 60); do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$URL" || true)
    [ "$code" = "200" ] && break
    sleep 1
  done
  if [ "$code" != "200" ]; then echo "[e2e] FAIL: 本地实例未就绪"; tail -20 "$LOG"; exit 1; fi
  echo "[e2e] 实例就绪"
fi

echo "[e2e] 1/2 命令导入回归"
python3 tests/e2e/e2e_import_check.py --url "$URL" --repo-root "$REPO" || RC=1

echo "[e2e] 2/2 apptainer 运行环境回归"
if [ -n "$FAKE_APT" ]; then
  python3 tests/e2e/e2e_apptainer_check.py --url "$URL" --apptainer "$FAKE_APT" || RC=1
else
  python3 tests/e2e/e2e_apptainer_check.py --url "$URL" || RC=1
fi

[ "$RC" = 0 ] && echo "[e2e] 通过" || echo "[e2e] 失败"
exit $RC
