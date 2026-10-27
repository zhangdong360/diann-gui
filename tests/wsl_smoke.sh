#!/usr/bin/env bash
# ============================================================
# wsl_smoke.sh — diann.gui 在 WSL / 裸机 Ubuntu 上的一键安装+验证
#
# 面向全新 Ubuntu (WSL2 或物理机/VM) 的自托管调试: 装系统依赖 → 装 R 包
# → 装本包 → doctor 自检 → 启动冒烟 (curl 200) → 离线 e2e 夹具 → (可选)
# 完整单元测试。可重复执行 (已装的步骤自动跳过)。
#
# 用法:
#   bash tests/wsl_smoke.sh                  # 默认: 含分析模块依赖
#   bash tests/wsl_smoke.sh --no-analysis    # 只验 GUI 本体 (跳过分析依赖/limma)
#   bash tests/wsl_smoke.sh --with-tests     # 追加完整 testthat (多花几分钟)
#   bash tests/wsl_smoke.sh --with-apptainer # 追加 apt 安装 apptainer (跑真实作业用)
#   bash tests/wsl_smoke.sh --skip-apt       # 已手动装好系统包时跳过 sudo apt
#
# 结束打印 "===== 验证报告 =====", 整段贴回给开发者即可。
# ============================================================
set -uo pipefail

START=$(date +%s)
REPORT=/tmp/diann_wsmoke_report.txt
: > "$REPORT"
NO_ANALYSIS=0; WITH_TESTS=0; WITH_APPTAINER=0; SKIP_APT=0
for arg in "$@"; do
  case "$arg" in
    --no-analysis)   NO_ANALYSIS=1 ;;
    --with-tests)    WITH_TESTS=1 ;;
    --with-apptainer) WITH_APPTAINER=1 ;;
    --skip-apt)      SKIP_APT=1 ;;
    *) echo "未知参数: $arg (忽略)" ;;
  esac
done

step() { echo ""; echo "########## [$1] $2 ##########"; }
pass() { echo "[PASS] $*" | tee -a "$REPORT"; }
fail() { echo "[FAIL] $*" | tee -a "$REPORT"; FAIL_N=$((FAIL_N+1)); }
FAIL_N=0

step 1 "系统信息"
. /etc/os-release 2>/dev/null
echo "发行版: ${NAME:-?} ${VERSION_ID:-?} ($(uname -m))"
IS_WSL=$(grep -qi microsoft /proc/version 2>/dev/null && echo yes || echo no)
echo "WSL: $IS_WSL (内核 $(uname -r))"
pass "系统信息采集: ${NAME:-?} ${VERSION_ID:-?}, WSL=$IS_WSL"

# WSL1 上容器/setsid 语义残缺, 直接给出结论
if [ "$IS_WSL" = "no" ]; then
  echo "提示: 非 WSL 环境 (物理机/VM/服务器) 同样适用本脚本。"
fi

step 2 "系统依赖 (apt)"
if [ "$SKIP_APT" = "1" ]; then
  echo "跳过 (--skip-apt)"
else
  PKGS="git curl python3 r-base-core r-base-dev build-essential \
libcurl4-openssl-dev libssl-dev libxml2-dev libfontconfig1-dev libpng-dev libfreetype6-dev"
  [ "$WITH_APPTAINER" = "1" ] && PKGS="$PKGS apptainer"
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $PKGS \
    && pass "apt 依赖安装完成" \
    || fail "apt 依赖安装失败 (查看上方 apt 报错)"
fi
command -v R >/dev/null || { fail "R 未安装且无法继续"; cat "$REPORT"; exit 1; }
R_VER=$(R --version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
echo "R 版本: $R_VER"

step 3 "R 用户库准备"
R_LIB_USER=$(Rscript --vanilla -e 'cat(Sys.getenv("R_LIBS_USER"))' 2>/dev/null)
[ -z "$R_LIB_USER" ] && R_LIB_USER="$HOME/R/library"
mkdir -p "$R_LIB_USER"
export R_LIBS_USER="$R_LIB_USER"
echo "R_LIBS_USER=$R_LIB_USER"
pass "R 用户库: $R_LIB_USER"

step 4 "CRAN 镜像选择 (P3M 二进制优先, 不支持当前代号则回退源码)"
CODENAME=$(. /etc/os-release; echo "${VERSION_CODENAME:-jammy}")
P3M="https://packagemanager.posit.co/cran/__linux__/${CODENAME}/latest"
if curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$P3M/src/contrib/PACKAGES" | grep -q 200; then
  CRAN="$P3M"; echo "使用 P3M 二进制: $CRAN"
else
  CRAN="https://cloud.r-project.org"; echo "P3M 不支持 ${CODENAME}, 回退源码编译: $CRAN"
fi
pass "CRAN 仓库: $CRAN"

r_install() {  # r_install (经 CRAN_URL/PKGS 环境变量) — 已装则跳过, 失败返回非零
  CRAN_URL="$CRAN_URL" PKGS="$PKGS" Rscript --vanilla -e '
    options(repos = c(CRAN = Sys.getenv("CRAN_URL")), Ncpus = 2)
    need <- strsplit(Sys.getenv("PKGS"), ",", fixed = TRUE)[[1]]
    got <- vapply(need, requireNamespace, logical(1), quietly = TRUE)
    if (any(!got)) install.packages(need[!got])
    got2 <- vapply(need, requireNamespace, logical(1), quietly = TRUE)
    if (any(!got2)) { cat("缺失:", paste(need[!got2], collapse = ", "), "\n"); quit(status = 1) }' 2>&1 | tail -5
  return ${PIPESTATUS[0]}
}

step 5 "R 硬依赖 (shiny/shinydashboard/shinyFiles/htmltools)"
CRAN_URL="$CRAN" PKGS="shiny,shinydashboard,shinyFiles,htmltools" r_install \
  && pass "R 硬依赖就绪" || fail "R 硬依赖安装失败"

if [ "$NO_ANALYSIS" = "0" ]; then
  step 6 "R 分析模块依赖 (Suggests: DT/ggplot2/ggrepel/gridExtra/pheatmap/scales/svglite/jsonlite/zip/openxlsx)"
  CRAN_URL="$CRAN" PKGS="DT,ggplot2,ggrepel,gridExtra,pheatmap,scales,svglite,jsonlite,zip,openxlsx" r_install \
    && pass "分析模块 CRAN 依赖就绪" || fail "分析模块 CRAN 依赖安装失败"
  echo "-- limma (Bioconductor) --"
  Rscript --vanilla -e '
    options(repos = c(CRAN = Sys.getenv("CRAN_URL")), Ncpus = 2)
    if (!requireNamespace("limma", quietly = TRUE)) {
      if (!requireNamespace("BiocManager", quietly = TRUE)) install.packages("BiocManager")
      BiocManager::install("limma", ask = FALSE, update = FALSE)
    }
    quit(status = if (requireNamespace("limma", quietly = TRUE)) 0 else 1)' 2>&1 | tail -3 \
    && pass "limma (Bioconductor) 就绪" || fail "limma 安装失败 (分析模块差异分析不可用, 其余不受影响)"
fi

step 7 "定位/克隆 diann.gui 源码"
REPO_DIR=""
for d in "$PWD" "$HOME/diann-gui" "$HOME/diann_gui_user"; do
  [ -f "$d/DESCRIPTION" ] && grep -q "Package: diann.gui" "$d/DESCRIPTION" && REPO_DIR="$d" && break
done
if [ -z "$REPO_DIR" ]; then
  git clone --depth 1 https://github.com/zhangdong360/diann-gui.git "$HOME/diann-gui" \
    && REPO_DIR="$HOME/diann-gui" \
    || fail "GitHub 克隆失败 (无外网? 手动拷贝源码后重跑)"
fi
echo "源码: $REPO_DIR"
[ -n "$REPO_DIR" ] && pass "源码就绪: $REPO_DIR"

step 8 "安装 diann.gui 包"
if [ -n "${REPO_DIR:-}" ]; then
  R CMD INSTALL --no-multiarch "$REPO_DIR" > /tmp/diann_install.log 2>&1 \
    && pass "diann.gui 安装完成 (版本 $(Rscript --vanilla -e 'cat(as.character(packageVersion("diann.gui")))' 2>/dev/null))" \
    || { fail "diann.gui 安装失败"; tail -15 /tmp/diann_install.log; }
else
  fail "无源码, 跳过安装"
fi

step 9 "加载与 doctor 自检"
Rscript --vanilla -e '
  suppressMessages(library(diann.gui))
  cat("加载 OK, 版本", as.character(packageVersion("diann.gui")), "\n")
  df <- doctor()
  cat(sprintf("DOCTOR_SUMMARY ok=%d warn=%d fail=%d na=%d\n",
      sum(df$status == "ok"), sum(df$status == "warn"),
      sum(df$status == "fail"), sum(df$status == "na")))
  quit(status = if (any(df$status == "fail")) 1 else 0)' 2>&1 | tail -40
RC=${PIPESTATUS[0]}
[ "$RC" = "0" ] && pass "doctor 自检无 fail 项" || fail "doctor 自检存在 fail 项 (RC=$RC, 见上方 doctor 表格)"

step 10 "启动冒烟 (run_app + curl 200)"
PORT=48673
Rscript --vanilla -e "diann.gui::run_app(port = $PORT, host = '127.0.0.1', launch.browser = FALSE)" \
  > /tmp/diann_smoke_app.log 2>&1 &
APP_PID=$!
CODE=""
for i in $(seq 1 60); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:$PORT/" || true)
  [ "$CODE" = "200" ] && break
  sleep 1
done
kill "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null
[ "$CODE" = "200" ] && pass "启动冒烟: HTTP 200 (端口 $PORT)" \
  || { fail "启动冒烟失败 (http=$CODE)"; tail -10 /tmp/diann_smoke_app.log; }

step 11 "离线 e2e 夹具自检 (假 apptainer + 假 SIF, 无需浏览器/容器)"
if [ -n "${REPO_DIR:-}" ] && [ -f "$REPO_DIR/tests/e2e/e2e_local_backend_check.py" ]; then
  (cd "$REPO_DIR" && E2E_SKIP_BROWSER=1 python3 tests/e2e/e2e_local_backend_check.py 2>&1 | tail -3)
  [ "${PIPESTATUS[0]}" = "0" ] && pass "离线 e2e 夹具自检通过" || fail "离线 e2e 夹具自检失败"
else
  fail "未找到 e2e 脚本 (源码缺失?)"
fi

if [ "$WITH_TESTS" = "1" ]; then
  step 12 "完整单元测试 (testthat, 约 1-3 分钟)"
  if [ -n "${REPO_DIR:-}" ]; then
    Rscript -e 'res <- testthat::test_dir("tests/testthat", stop_on_failure = FALSE)
      df <- as.data.frame(res)
      cat(sprintf("TESTS pass=%d fail=%d error=%d skip=%d\n",
          sum(df$passed), sum(df$failed), sum(df$error), sum(df$skipped)))
      quit(status = if (any(df$error) || sum(df$failed) > 0) 1 else 0)' 2>&1 | tail -6
    [ "${PIPESTATUS[0]}" = "0" ] && pass "单元测试全绿" || fail "单元测试存在失败"
  fi
fi

MIN=$(( ($(date +%s) - START) / 60 ))
{
  echo "===== 验证报告 (耗时 ${MIN} 分钟) ====="
  cat "$REPORT"
  echo "======================================"
  [ "$FAIL_N" = "0" ] && echo "结论: 全部通过" || echo "结论: $FAIL_N 项失败 — 整段报告贴回给开发者"
} | tee -a "$REPORT"
exit $(( FAIL_N > 0 ? 1 : 0 ))
