#!/bin/bash
# 端到端回归: 起本地 runApp 实例 → 浏览器执行 导入 / apptainer 运行环境 / 本地执行后端
# 三组断言。每次更新 R/ 下的命令构建、导入、UI、配置或执行后端逻辑后必须执行
# (staging 部署=改文件即上线, 本脚本验证的是"改动之后的应用"本身; 部署后可再以
# --url 对生产复核一次)。
#
# v1.12 起 Slurm 只是可选后端: 主实例默认按 E2E_BACKEND=local 启动 (CI 离线可跑),
# 有 Slurm 的机器可用 E2E_BACKEND=slurm 覆盖, 验证 Slurm 模式 UI 未被破坏。
# 第 3 组 e2e 自带假 apptainer/假 SIF/临时 config, 始终验证 local 后端。
#
# 用法:
#   tests/e2e/run_e2e.sh                       # 自动起本地实例 (端口 4849, 后端 local)
#   E2E_BACKEND=slurm tests/e2e/run_e2e.sh     # 主实例按 slurm 后端启动
#   tests/e2e/run_e2e.sh --url URL             # 验证一个已在运行的实例 (如生产)
#
# 依赖: R (shiny/shinydashboard/shinyFiles/testthat), python3 + selenium, geckodriver, Firefox。
set -u
cd "$(dirname "$0")/../.."   # 仓库根
REPO="$(pwd)"
PORT="${E2E_PORT:-4849}"
# 执行后端: CI 默认 local (无 Slurm, 离线); 有 Slurm 的机器可 E2E_BACKEND=slurm 复核旧 UI。
E2E_BACKEND="${E2E_BACKEND:-local}"
# 夹具使用合成路径 /share/home/demo/..., 本地/CI 无此目录:
# 经 DIANN_GUI_EXTRA_VOLUMES 把它加入路径守卫白名单 (测试钩子, 生产不受影响)
export DIANN_GUI_EXTRA_VOLUMES="${DIANN_GUI_EXTRA_VOLUMES:-/share/home/demo}"
URL=""
if [ "${1:-}" = "--url" ]; then URL="$2"; fi
RC=0
FAKE_APT=""
CLEANUP_DIR=""
APP_PID=""

cleanup() {
  [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null
  # 本地后端作业由 local_runner (setsid) 派生, 不在应用进程组里: 按唯一临时目录路径兜底清理
  [ -n "$CLEANUP_DIR" ] && pkill -f "$CLEANUP_DIR" 2>/dev/null
  [ -n "$CLEANUP_DIR" ] && rm -rf "$CLEANUP_DIR"
  return 0
}
trap cleanup EXIT

if [ -z "$URL" ]; then
  LOG="$(mktemp /tmp/diann_e2e.XXXX.log)"
  CLEANUP_DIR="$(mktemp -d /tmp/diann_e2e_env.XXXX)"
  mkdir -p "$CLEANUP_DIR/bin" "$CLEANUP_DIR/sif" "$CLEANUP_DIR/data" \
           "$CLEANUP_DIR/out" "$CLEANUP_DIR/home"
  FAKE_APT="$CLEANUP_DIR/bin/apptainer"
  # 假 apptainer: --version 供自动识别/手动验证; exec 供 local 后端作业真正执行
  # (解析 --out 写报告, sleep/退出码可经 control 文件/环境变量控制, 见 v1.12 本地 e2e)。
  cat > "$FAKE_APT" <<'FAKEAPT'
#!/bin/bash
# e2e 专用假 apptainer (不是真实容器运行时)
set -u
if [ "${1:-}" = "--version" ]; then echo "apptainer version 1.4.5"; exit 0; fi
if [ "${1:-}" != "exec" ]; then echo "fake-apptainer: unsupported argv: $*" >&2; exit 1; fi
shift
# v1.13: 容器内 diann-linux --version (SIF 版本识别路径); exec 后 $1 是 sif 路径
is_ver=0; pv=""
for a in "$@"; do
  if [ "$pv" = "diann-linux" ] && [ "$a" = "--version" ]; then is_ver=1; fi
  pv="$a"
done
if [ "$is_ver" = "1" ]; then
  echo "DIA-NN 2.7.0 Academia, build Oct 12 2025 17:36:10 (git 8f2b1c3)"
  exit 0
fi
out=""; prev=""
for a in "$@"; do if [ "$prev" = "--out" ]; then out="$a"; fi; prev="$a"; done
sleep_s=1
ctl="${E2E_FAKE_CTL:-}"
if [ -n "$ctl" ] && [ -f "$ctl" ]; then
  v="$(tr -dc '0-9.' < "$ctl" 2>/dev/null || true)"
  if [ -n "$v" ]; then sleep_s="$v"; fi
fi
if [ -n "${E2E_FAKE_APPTAINER_LOG:-}" ]; then
  printf '%s exec %s\n' "$(date +%s)" "$*" >> "$E2E_FAKE_APPTAINER_LOG" 2>/dev/null || true
fi
sleep "$sleep_s"
if [ -n "$out" ]; then
  mkdir -p "$(dirname "$out")" 2>/dev/null
  printf 'Protein.Names\tGenes\tPG.Quantity\nP12345\tGENE1\t1.0\n' > "$out"
fi
exit "${E2E_FAKE_RC:-0}"
FAKEAPT
  chmod 755 "$FAKE_APT"
  printf '1\n' > "$CLEANUP_DIR/fake_ctl"
  : > "$CLEANUP_DIR/fake_apptainer_exec.log"
  # 假 SIF: 32 字节引导头 + 偏移 32 处 SIF_MAGIC + 1MiB 填充 (GUI 校验魔数与尺寸)
  python3 - "$CLEANUP_DIR/sif/image.sif" <<'PYSIF'
import sys
data = b"#!/usr/bin/env run-singularity\n"
data += b"\0" * (32 - len(data))
data += b"SIF_MAGIC" + b"\0" * (1024 * 1024 - 32 - 9)
open(sys.argv[1], "wb").write(data)
PYSIF
  # 假 RAW / 光谱库: local 后端 e2e 的输入 (内容不参与真实分析)
  printf 'fake raw for e2e\n' > "$CLEANUP_DIR/data/sample.raw"
  printf 'fake spectral library for e2e\n' > "$CLEANUP_DIR/data/fake.parquet"
  # v1.14: 合成 pg_matrix (结果分析页 e2e 输入; 前 12 个蛋白 B 组上调 4 倍, MNAR 缺失)
  python3 - "$CLEANUP_DIR/data/pg_matrix.tsv" <<'PYMAT'
import random, sys
random.seed(42)
cols = ["A1", "A2", "A3", "B1", "B2", "B3"]
head = ["Protein.Group", "Protein.Names", "PG.Genes", "First.Protein.Description",
        "N.Sequences", "N.Proteotypic.Sequences"] + cols
lines = ["\t".join(head)]
for i in range(1, 41):
    base = random.uniform(18.0, 22.0)
    pg = f"P{i:03d}_HUMAN"
    if i == 40:
        pg = "cRAP_ALBU_HUMAN"
    elif i == 39:
        pg = "REV_P039_HUMAN"
    desc = "Albumin (Contaminant)" if i == 40 else f"Protein_{i:03d} (Homo sapiens)"
    vals = []
    for c in cols:
        mult = 4.0 if (i <= 12 and c.startswith("B")) else 1.0
        if random.random() < (0.12 if base < 19.3 else 0.02):
            vals.append("NA")
        else:
            vals.append("%.3f" % (2 ** (base + random.gauss(0, 0.15)) * mult))
    lines.append("\t".join([pg, f"Protein_{i:03d}_HUMAN", f"GENE{i}", desc, "10", "5"] + vals))
open(sys.argv[1], "w").write("\n".join(lines) + "\n")
print("synthetic pg_matrix written:", sys.argv[1])
PYMAT
  # 独立配置: 后端 + 运行时/镜像/数据/输出根全指临时目录; 不碰用户 ~/.diann_gui
  cat > "$CLEANUP_DIR/config.R" <<EOF
EXEC_BACKEND <- "$E2E_BACKEND"
APPTAINER_PATHS <- c("$CLEANUP_DIR/bin")
SIF_DIRS <- c("$CLEANUP_DIR/sif")
DEFAULT_SIF <- "$CLEANUP_DIR/sif/image.sif"
DATA_HOME <- "$CLEANUP_DIR/data"
BASE_VOLUMES <- c(Data = "$CLEANUP_DIR/data", Out = "$CLEANUP_DIR/out")
MAIL_PYTHON <- ""
RETENTION_DAYS <- 7
EOF
  export DIANN_GUI_CONFIG="$CLEANUP_DIR/config.R"
  export E2E_FAKE_CTL="$CLEANUP_DIR/fake_ctl"
  export E2E_FAKE_APPTAINER_LOG="$CLEANUP_DIR/fake_apptainer_exec.log"
  echo "[e2e] 启动本地实例 :$PORT (后端 $E2E_BACKEND, 日志 $LOG)"
  R CMD INSTALL --no-multiarch . > /dev/null 2>&1 || { echo "[e2e] FAIL: R CMD INSTALL"; exit 1; }
  # 临时 HOME 只给应用进程: GUI 注册表/本地作业状态/通知状态全部隔离, 不污染真实 HOME。
  # 注意不能 export HOME —— python/selenium 装在用户 site (~/.local), 改了 HOME 会 import 失败。
  # 包装在用户库, HOME 变了 .libPaths 会找不到 -> 显式把当前库路径传给应用。
  R_LIBS_APP="$(Rscript --vanilla -e 'cat(paste(.libPaths(), collapse=":"))' 2>/dev/null || true)"
  if [ -n "$R_LIBS_APP" ] && [ -n "${R_LIBS:-}" ]; then R_LIBS_APP="$R_LIBS_APP:$R_LIBS"; fi
  [ -n "$R_LIBS_APP" ] || R_LIBS_APP="${R_LIBS:-}"
  env HOME="$CLEANUP_DIR/home" R_LIBS="$R_LIBS_APP" \
    Rscript --vanilla -e "diann.gui::run_app(port = $PORT, host = '127.0.0.1', launch.browser = FALSE)" > "$LOG" 2>&1 &
  APP_PID=$!
  URL="http://127.0.0.1:$PORT/"
  code=""
  for i in $(seq 1 90); do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$URL" || true)
    [ "$code" = "200" ] && break
    kill -0 "$APP_PID" 2>/dev/null || break
    sleep 1
  done
  if [ "$code" != "200" ]; then echo "[e2e] FAIL: 本地实例未就绪 (http=$code)"; tail -30 "$LOG"; exit 1; fi
  echo "[e2e] 实例就绪"
fi

echo "[e2e] 1/4 命令导入回归"
python3 tests/e2e/e2e_import_check.py --url "$URL" --repo-root "$REPO" || RC=1

echo "[e2e] 2/4 apptainer 运行环境回归"
if [ -n "$FAKE_APT" ]; then
  python3 tests/e2e/e2e_apptainer_check.py --url "$URL" --apptainer "$FAKE_APT" || RC=1
else
  python3 tests/e2e/e2e_apptainer_check.py --url "$URL" || RC=1
fi

# 第 3 组: 本地执行后端 (假 apptainer exec 走完整 提交→监控→日志→取消 链路)。
# 主实例本身就是 local 后端时直接复用 (省一次应用启动); 否则自起一个 local 实例。
echo "[e2e] 3/4 本地执行后端回归 (EXEC_BACKEND=local)"
if [ "$E2E_BACKEND" = "local" ] && [ -n "$CLEANUP_DIR" ]; then
  python3 tests/e2e/e2e_local_backend_check.py --repo-root "$REPO" \
    --url "$URL" --workdir "$CLEANUP_DIR" || RC=1
else
  python3 tests/e2e/e2e_local_backend_check.py --repo-root "$REPO" || RC=1
fi

# 第 4 组: 结果分析页 (合成矩阵 → 读取 → QC 渲染 → 报告生成)。依赖分析层
# Suggests 包 (ggplot2/limma/zip 等, CI 由 setup-r-dependencies 安装)。
echo "[e2e] 4/4 结果分析页回归 (矩阵 → QC → 报告)"
python3 tests/e2e/e2e_analysis_check.py --url "$URL" \
  --matrix "$CLEANUP_DIR/data/pg_matrix.tsv" || RC=1

[ "$RC" = 0 ] && echo "[e2e] 通过" || echo "[e2e] 失败"
exit $RC
