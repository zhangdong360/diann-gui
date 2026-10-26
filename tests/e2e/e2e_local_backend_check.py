#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
v1.12 本地执行后端 (EXEC_BACKEND=local) 浏览器端到端回归。

覆盖 v1.11 只能在 Slurm 上跑的验证缺口: 没有 sbatch 的主机改用本地执行后,
UI / 提交 / 监控 / 日志 / 取消 / 会话连接是否与 Slurm 模式同语义。

自包含模式 (不带 --url):
  在临时目录里建 假 apptainer (--version -> 1.4.5; exec 解析 --out 写报告,
  sleep/退出码可经 control 文件控制) + 带 SIF_MAGIC 的假 .sif (>=1MiB) +
  假 RAW/光谱库 + 临时 config (EXEC_BACKEND="local", APPTAINER_PATHS/DATA_HOME/
  BASE_VOLUMES 指向临时目录, MAIL 关闭) + 临时 HOME, 起一个 run_app 实例
  (随机高位端口 41xxx/48xxx, 绝不使用 3838), 结束后按进程组 kill 并清理。

复用模式 (--url + --workdir):
  run_e2e.sh 已按同一布局建好夹具并以 local 后端起好实例, 本脚本只驱动浏览器。

断言:
  (1) 页面加载/提交后 Shiny 会话保持连接 (v1.11 system2 抛错 -> 断连事故回归)
  (2) local 模式 UI: 无 sinfo 集群节点表 / 按钮「提交本地任务」/「取消该作业」/
      监控页标题「本地运行任务」/ 日志盒标题 local-<ID>.out
  (3) 提交后监控页 运行中 -> 已完成(成功), 本会话提交记录「后端」列为 本地
  (4) 运行日志页可读取 local-<ID>.out 尾部 (含 DIANN_GUI_APPTAINER / exit code)
  (5) 慢作业经 UI 取消 -> 已取消, 脚本旁 .cancelled 标记落盘
  (6) 假 apptainer exec 真被调用 (报告写出 + exec 日志含 diann-linux), 本地模式
      不产生 slurm-<ID>.out (证明没走 sbatch)
  (7) 页面全程无 "error in running command" / Shiny 断连

用法:
  python3 tests/e2e/e2e_local_backend_check.py --repo-root .        # 自包含
  python3 tests/e2e/e2e_local_backend_check.py --url http://127.0.0.1:4849/ \
      --workdir /tmp/diann_e2e_apt.XXXX                             # 复用实例
  E2E_SKIP_BROWSER=1 python3 tests/e2e/e2e_local_backend_check.py   # 只自检夹具

依赖: R + 已安装当前仓库的 diann.gui (R CMD INSTALL .), python3 + selenium,
      Firefox (headless; selenium-manager 可自动取 geckodriver)。
"""
import argparse
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

# 假 apptainer: 只实现 GUI 用到的 --version 与 exec <...> diann-linux <args>。
# exec 从参数里找 --out 写一份假报告; sleep 秒数 / 退出码由 control 文件和环境变量
# 控制 (取消测试需要长 sleep)。E2E_FAKE_APPTAINER_LOG 记录每次 exec, 供断言真实执行链。
FAKE_APPTAINER = r'''#!/bin/bash
# e2e 专用假 apptainer (不是真实容器运行时)
set -u
if [ "${1:-}" = "--version" ]; then
  echo "apptainer version 1.4.5"
  exit 0
fi
if [ "${1:-}" != "exec" ]; then
  echo "fake-apptainer: unsupported argv: $*" >&2
  exit 1
fi
shift
out=""; prev=""
for a in "$@"; do
  if [ "$prev" = "--out" ]; then out="$a"; fi
  prev="$a"
done
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
'''


def log(msg):
    print("[e2e-local %s] %s" % (time.strftime("%H:%M:%S"), msg), flush=True)


def check(name, cond, detail="", failures=None):
    ok = bool(cond)
    print("[%s] %s %s" % ("PASS" if ok else "FAIL", name, detail), flush=True)
    if not ok and failures is not None:
        failures.append(name)
    return ok


def wait_until(fn, timeout, interval=0.5):
    t0 = time.time()
    last = None
    while time.time() - t0 < timeout:
        try:
            v = fn()
            if v:
                return v
        except Exception as e:  # noqa: BLE001 - 轮询期间元素未就绪是常态
            last = e
        time.sleep(interval)
    return None


# ---------------------------------------------------------------- 夹具
def make_sif(path):
    """SIF: 偏移 32 处 9 字节魔数 SIF_MAGIC; 大小 >= 1MiB (GUI 有「镜像过小」告警)。"""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    boot = b"#!/usr/bin/env run-singularity\n"
    boot = boot + b"\0" * (32 - len(boot))
    path.write_bytes(boot + b"SIF_MAGIC" + b"\0" * (1024 * 1024 - 32 - 9))
    return path


def build_fixtures(base, backend="local"):
    """在 base 下建 e2e 夹具; 返回路径字典。"""
    base = Path(base)
    fx = {
        "base": base,
        "bin": base / "bin",
        "apptainer": base / "bin" / "apptainer",
        "sif": base / "sif" / "diann-9.9.9.sif",
        "data": base / "data",
        "lib": base / "data" / "fake.parquet",
        "raw": base / "data" / "sample.raw",
        "out": base / "out",
        "out_report": base / "out" / "report.tsv",
        "ctl": base / "fake_ctl",
        "apt_log": base / "fake_apptainer_exec.log",
        "home": base / "home",
        "config": base / "config.R",
        "app_log": base / "app.log",
    }
    fx["bin"].mkdir(parents=True, exist_ok=True)
    fx["apptainer"].write_text(FAKE_APPTAINER, encoding="utf-8")
    os.chmod(fx["apptainer"], 0o755)
    make_sif(fx["sif"])
    fx["data"].mkdir(parents=True, exist_ok=True)
    fx["out"].mkdir(parents=True, exist_ok=True)
    fx["home"].mkdir(parents=True, exist_ok=True)
    fx["raw"].write_text("fake raw for e2e local backend\n", encoding="utf-8")
    fx["lib"].write_text("fake spectral library for e2e local backend\n", encoding="utf-8")
    fx["ctl"].write_text("1\n", encoding="utf-8")
    fx["config"].write_text(
        "# 自动生成: v1.12 本地执行后端 e2e 临时配置 (不碰真实 ~/.diann_gui)\n"
        "EXEC_BACKEND <- \"%s\"\n"
        "APPTAINER_PATHS <- c(\"%s\")\n"
        "SIF_DIRS <- c(\"%s\")\n"
        "DEFAULT_SIF <- \"%s\"\n"
        "DATA_HOME <- \"%s\"\n"
        "BASE_VOLUMES <- c(Data = \"%s\", Out = \"%s\")\n"
        "MAIL_PYTHON <- \"\"\n"
        "RETENTION_DAYS <- 7\n"
        % (backend, fx["bin"], fx["base"] / "sif", fx["sif"], fx["data"], fx["data"], fx["out"]),
        encoding="utf-8")
    return fx


def check_fixtures_static(fx):
    """不启动浏览器也能做的夹具/契约自检 (E2E_SKIP_BROWSER=1)。"""
    failures = []
    v = subprocess.run([str(fx["apptainer"]), "--version"], capture_output=True, text=True)
    check("假 apptainer --version 输出 1.4.5",
          v.returncode == 0 and "1.4.5" in v.stdout, v.stdout.strip(), failures)
    env = dict(os.environ, E2E_FAKE_CTL=str(fx["ctl"]), E2E_FAKE_APPTAINER_LOG=str(fx["apt_log"]))
    fx["ctl"].write_text("0\n", encoding="utf-8")
    r = subprocess.run([str(fx["apptainer"]), "exec", str(fx["sif"]), "diann-linux",
                        "--out", str(fx["out_report"]), "--threads", "2"],
                       capture_output=True, text=True, env=env)
    check("假 apptainer exec 写出报告", r.returncode == 0 and fx["out_report"].is_file(),
          "rc=%s" % r.returncode, failures)
    raw = Path(fx["sif"]).read_bytes()
    check("假 SIF 魔数/尺寸符合 GUI 校验",
          raw[32:41] == b"SIF_MAGIC" and len(raw) >= 1024 * 1024, "%d bytes" % len(raw), failures)
    check("假 SIF 文件名可解析 DIA-NN 版本", fx["sif"].name.startswith("diann-9.9.9"),
          fx["sif"].name, failures)
    txt = fx["config"].read_text(encoding="utf-8")
    check("临时 config 含 EXEC_BACKEND=local 且指向假 apptainer 目录",
          'EXEC_BACKEND <- "local"' in txt and str(fx["bin"]) in txt, "", failures)
    print("E2E-LOCAL SKIP (E2E_SKIP_BROWSER=1, 夹具自检 %d 项失败)" % len(failures))
    return 1 if failures else 0


# ---------------------------------------------------------------- 起应用
def pick_port():
    for _ in range(50):
        s = socket.socket()
        try:
            s.bind(("127.0.0.1", 0))
            p = s.getsockname()[1]
        finally:
            s.close()
        if 41000 <= p <= 48999 and p != 3838:
            return p
    for p in range(41800, 41899):
        if p == 3838:
            continue
        s = socket.socket()
        try:
            s.bind(("127.0.0.1", p))
            return p
        except OSError:
            continue
        finally:
            s.close()
    raise RuntimeError("找不到空闲高位端口")


def r_libs():
    try:
        r = subprocess.run(["Rscript", "--vanilla", "-e",
                            "cat(paste(.libPaths(), collapse=':'))"],
                           capture_output=True, text=True, timeout=120)
        return r.stdout.strip()
    except Exception:  # noqa: BLE001
        return ""


def start_app(fx, port, repo_root):
    env = dict(os.environ)
    env["HOME"] = str(fx["home"])
    env["DIANN_GUI_CONFIG"] = str(fx["config"])
    env["E2E_FAKE_CTL"] = str(fx["ctl"])
    env["E2E_FAKE_APPTAINER_LOG"] = str(fx["apt_log"])
    libs = env.get("R_LIBS", "")
    cur = r_libs()
    if cur and cur not in libs:
        env["R_LIBS"] = cur + ((":" + libs) if libs else "")
    code = ('diann.gui::run_app(port=%d, host="127.0.0.1", launch.browser=FALSE)' % port)
    logf = open(str(fx["app_log"]), "w", encoding="utf-8")
    proc = subprocess.Popen(["Rscript", "--vanilla", "-e", code],
                            cwd=str(fx["base"]), env=env,
                            stdout=logf, stderr=subprocess.STDOUT,
                            start_new_session=True)
    url = "http://127.0.0.1:%d/" % port
    t0 = time.time()
    code_http = ""
    while time.time() - t0 < 120:
        if proc.poll() is not None:
            raise RuntimeError("run_app 提前退出 (rc=%s); 见 %s" % (proc.returncode, fx["app_log"]))
        try:
            with urllib.request.urlopen(url, timeout=3) as resp:
                code_http = str(resp.status)
                if code_http == "200":
                    return proc, url
        except Exception:  # noqa: BLE001
            pass
        time.sleep(1)
    raise RuntimeError("应用 120s 未就绪 (http=%s); 见 %s" % (code_http, fx["app_log"]))


def stop_app(proc):
    if proc is None:
        return
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    except Exception:  # noqa: BLE001
        pass
    try:
        proc.wait(timeout=20)
    except Exception:  # noqa: BLE001
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except Exception:  # noqa: BLE001
            pass


def kill_leftovers(base):
    """兜底: 杀掉命令行里带本次临时目录的残留作业进程 (假 apptainer/本地运行器)。
    注意排除自身与父进程: 本进程/包装脚本的命令行也可能含该目录。"""
    try:
        out = subprocess.run(["pgrep", "-f", str(base)], capture_output=True, text=True,
                             timeout=20).stdout
    except Exception:  # noqa: BLE001
        return
    me, parent = os.getpid(), os.getppid()
    for tok in out.split():
        if not tok.strip().isdigit():
            continue
        pid = int(tok)
        if pid in (me, parent):
            continue
        try:
            os.kill(pid, signal.SIGTERM)
        except Exception:  # noqa: BLE001
            pass


# ---------------------------------------------------------------- 浏览器断言
def run_browser(fx, url):
    from selenium import webdriver
    from selenium.webdriver.common.by import By
    from selenium.webdriver.firefox.options import Options
    from selenium.webdriver.support import expected_conditions as EC
    from selenium.webdriver.support.ui import WebDriverWait

    failures = []
    err_hits = []

    opts = Options()
    opts.add_argument("-headless")
    drv = webdriver.Firefox(options=opts)
    drv.set_window_size(1680, 1500)

    def body_text():
        try:
            return drv.find_element(By.TAG_NAME, "body").text
        except Exception:  # noqa: BLE001
            return ""

    def elem_text(eid):
        try:
            return drv.find_element(By.ID, eid).text
        except Exception:  # noqa: BLE001
            return ""

    def notif_text():
        return elem_text("shiny-notification-panel").replace("\n", " | ")

    def connected():
        return bool(drv.execute_script(
            "try { return Shiny.shinyapp.isConnected() } catch(e) { return false }"))

    def scan_errors(tag=""):
        try:
            page = drv.page_source.lower()
        except Exception:  # noqa: BLE001
            page = ""
        for needle in ["error in running command", "an error has occurred"]:
            if needle in page or needle in body_text().lower():
                err_hits.append("%s:%s" % (tag, needle))
        return not err_hits

    def click_js(by, sel):
        el = drv.find_element(by, sel)
        drv.execute_script("arguments[0].scrollIntoView({block:'center'});", el)
        drv.execute_script("arguments[0].click();", el)
        return el

    def click_retry(by, sel, cond, tries=3, wait_s=10, sleep_s=0.6):
        """点击后等条件满足; Shiny 输入事件与服务端偶有先后竞态, 重试 (动作均幂等)。"""
        for _ in range(tries):
            try:
                click_js(by, sel)
            except Exception:  # noqa: BLE001
                pass
            if wait_until(cond, wait_s):
                return True
            time.sleep(sleep_s)
        return False

    def job_rows():
        rows = []
        for tr in drv.find_elements(By.CSS_SELECTOR, "#jobs_table tbody tr"):
            cells = [td.text.strip() for td in tr.find_elements(By.CSS_SELECTOR, "td")]
            if cells:
                rows.append(cells)
        return rows

    def squeue_text():
        return elem_text("squeue_output")

    def sacct_text():
        return elem_text("sacct_table")

    def go_tab(name):
        link = drv.find_element(By.CSS_SELECTOR, 'a[href="#shiny-tab-%s"]' % name)
        drv.execute_script("arguments[0].scrollIntoView({block:'center'});", link)
        try:
            link.click()
        except Exception:  # noqa: BLE001
            drv.execute_script("arguments[0].click();", link)
        wait_until(lambda: len(drv.find_elements(
            By.CSS_SELECTOR, 'li.active a[href="#shiny-tab-%s"]' % name)) > 0, 10)

    def set_custom_fallback(cb_id, input_id, value, display_id):
        """自动候选缺失时的兜底: 勾选手动路径, 等条件面板显示 + 服务端回显后再继续。"""
        cb = drv.find_element(By.ID, cb_id)
        if cb.get_attribute("checked") is None:
            cb.click()
        wait_until(lambda: drv.find_element(By.ID, input_id).is_displayed(), 15)
        inp = drv.find_element(By.ID, input_id)
        inp.clear()
        inp.send_keys(str(value))
        drv.execute_script("arguments[0].blur();", inp)
        return wait_until(lambda: str(value) in elem_text(display_id), 20)

    try:
        drv.get(url)
        WebDriverWait(drv, 120).until(EC.presence_of_element_located((By.ID, "submit_job")))
        wait_until(connected, 30)
        # 等启动期服务端输入同步完成 (apptainer_display 有回显) 再开始交互, 避免首轮输入竞态
        wait_until(lambda: len(elem_text("apptainer_display")) > 3, 30)
        time.sleep(1)
        scan_errors("load")
        check("页面加载后 Shiny 会话连接正常", connected(), "", failures)

        # ---- local 模式 UI 契约 ----
        check("提交按钮文案为「提交本地任务」",
              "本地" in drv.find_element(By.ID, "submit_job").text,
              drv.find_element(By.ID, "submit_job").text, failures)
        check("头部标注执行后端「本地单机」", "本地单机" in body_text(), "", failures)
        check("local 模式无 sinfo 集群节点表",
              len(drv.find_elements(By.ID, "sinfo_table")) == 0, "", failures)
        go_tab("monitor")
        check("监控页标题为「本地运行任务」", "本地运行任务" in body_text(), "", failures)
        check("取消按钮文案为「取消该作业」", "取消该作业" in body_text(), "", failures)
        check("日志盒标题为 local-<ID>.out 尾部",
              "local-<ID>.out" in body_text(), "", failures)
        check("local 模式监控页无 sinfo 盒", "集群节点资源 (sinfo)" not in body_text(), "", failures)
        go_tab("analysis")

        # ---- 启动自动识别: 假 apptainer / 假 SIF 应被自动发现并默认选中 ----
        apt_ok = wait_until(lambda: str(fx["apptainer"]) in elem_text("apptainer_display"), 30)
        check("自动识别到假 apptainer 并默认选中 (APPTAINER_PATHS)", apt_ok,
              "display=%s" % elem_text("apptainer_display")[:160], failures)
        sif_ok = wait_until(lambda: str(fx["sif"]) in elem_text("sif_display"), 30)
        check("自动扫描到假 SIF 并默认选中 (SIF_DIRS)", sif_ok,
              "display=%s" % elem_text("sif_display")[:160], failures)
        apt_opts = [o.text for o in drv.find_elements(By.CSS_SELECTOR, "#apptainer_version option")]
        scan_panel = elem_text("apt_check_display")
        check("apptainer 自动扫描面板/候选含 1.4.5 版本",
              "1.4.5" in scan_panel or any("1.4.5" in t for t in apt_opts),
              "panel=%s | opts=%s" % (scan_panel.replace("\n", " ")[:140],
                                      " | ".join(apt_opts)[:100]), failures)
        if not apt_ok:  # 兜底路径 (正常配置下不会走到)
            got = set_custom_fallback("use_custom_apptainer", "custom_apptainer",
                                      fx["apptainer"], "apptainer_display")
            check("兜底: 手动 apptainer 路径回显生效", got,
                  elem_text("apptainer_display")[:160], failures)
        if not sif_ok:
            got = set_custom_fallback("use_custom_sif", "custom_sif",
                                      fx["sif"], "sif_display")
            check("兜底: 手动 SIF 路径回显生效", got, elem_text("sif_display")[:160], failures)

        # ---- 命令导入填充 RAW/库/输出目录 (shinyFiles 无法编程填充, 走导入覆盖层) ----
        drv.execute_script(
            "var box=document.getElementById('import_cmd').closest('.box');"
            "var b=box?box.querySelector('[data-widget=\"collapse\"]'):null; if(b) b.click();")
        time.sleep(1)
        cmd = ("diann-linux --f %s --lib %s --out %s --matrices "
               "--threads 2 --verbose 1 --qvalue 0.01"
               % (fx["raw"], fx["lib"], fx["out_report"]))
        ta = drv.find_element(By.ID, "import_cmd")
        ta.clear()
        ta.send_keys(cmd)
        drv.execute_script("arguments[0].blur();", ta)
        time.sleep(0.5)
        got = click_retry(By.ID, "import_btn",
                          lambda: "已重置旧分析参数并填充" in elem_text("import_result"),
                          tries=3, wait_s=8)
        check("命令导入解析完成", got,
              "import_result=%s | notif=%s" % (elem_text("import_result")[:160], notif_text()[:160]),
              failures)
        check("导入后 RAW 路径回显",
              wait_until(lambda: "sample.raw" in elem_text("raw_path_display"), 30),
              elem_text("raw_path_display")[:120], failures)
        check("导入后输出目录回显",
              wait_until(lambda: str(fx["out"]) in elem_text("out_path_display"), 30),
              elem_text("out_path_display")[:120], failures)

        # 等校验块跑完 (有告警是允许的, 不能有阻断项 ✗; 该回显同时证明表单已被服务端接收)
        got = wait_until(lambda: len(elem_text("validation_msgs")) > 0
                         and "✗" not in elem_text("validation_msgs"), 40)
        vtxt = elem_text("validation_msgs")
        check("提交前校验无阻断项", got and "✗" not in vtxt,
              vtxt.replace("\n", " | ")[:220], failures)
        scan_errors("pre-submit")

        # ---- 提交快作业 (control 文件 = 10s, 便于观察 运行中) ----
        fx["ctl"].write_text("10\n", encoding="utf-8")
        click_js(By.ID, "submit_job")
        go_tab("monitor")  # jobs_table 在监控页; Shiny 隐藏 tab 的输出默认挂起, 切换后才渲染
        got = wait_until(lambda: len(job_rows()) >= 1, 20)
        if not got:  # 点击/输入竞态兜底: 再点一次 (若首次实际成功, 记录行会多一条, 仍取首行)
            click_js(By.ID, "submit_job")
            got = wait_until(lambda: len(job_rows()) >= 1, 30)
        check("提交成功并出现在本会话提交记录", got,
              "rows=%s | validation=%s | notif=%s"
              % (job_rows(), elem_text("validation_msgs").replace("\n", " | ")[:200],
                 notif_text()[:200]), failures)
        rows = job_rows()
        jid1 = rows[0][0] if rows else ""
        check("提交记录「后端」列为 本地", bool(rows) and "本地" in " ".join(rows[0]),
              " | ".join(rows[0]) if rows else "", failures)
        check("提交后 Shiny 会话保持连接 (v1.11 断连事故回归)", connected(), "", failures)
        scan_errors("post-submit")

        # ---- 监控页: 运行中 -> 已完成(成功) ----
        go_tab("monitor")

        def running_seen():
            click_js(By.ID, "refresh_q")
            txt = squeue_text()
            return bool(jid1) and jid1 in txt and "RUNNING" in txt

        check("监控页出现 运行中 (RUNNING)", wait_until(running_seen, 40, interval=1),
              squeue_text().replace("\n", " | ")[:200], failures)

        def success_seen():
            click_js(By.ID, "refresh_q")
            txt = sacct_text()
            return bool(jid1) and jid1 in txt and "已完成" in txt

        check("监控页状态 运行中→已完成(成功)", wait_until(success_seen, 120, interval=2),
              sacct_text().replace("\n", " | ")[:200], failures)
        scan_errors("monitor")

        # ---- 运行日志页可读 ----
        logid = drv.find_element(By.ID, "log_id").get_attribute("value")
        check("日志页作业 ID 已自动回填", str(logid).strip() == str(jid1).strip(),
              "log_id=%s jid=%s" % (logid, jid1), failures)
        got = click_retry(By.ID, "view_log",
                          lambda: ("DIANN_GUI_APPTAINER" in elem_text("log_output")
                                   and "exit code: 0" in elem_text("log_output")),
                          tries=3, wait_s=10)
        logtxt = elem_text("log_output")
        check("运行日志页可读取 local-<ID>.out 尾部", got,
              logtxt.replace("\n", " | ")[:220], failures)
        check("日志头部来源为 local-<ID>.out", ("local-%s.out" % jid1) in logtxt, "", failures)

        # ---- 本地执行链真实跑通 (假 apptainer exec + 产物) ----
        check("主报告由假 apptainer exec 写出",
              fx["out_report"].is_file() and fx["out_report"].stat().st_size > 0,
              str(fx["out_report"]), failures)
        apt_log = fx["apt_log"].read_text(encoding="utf-8") if fx["apt_log"].exists() else ""
        check("假 apptainer exec 收到 diann-linux 与所选 SIF",
              "diann-linux" in apt_log and str(fx["sif"]) in apt_log, apt_log[:200], failures)
        slurm_logs = list(Path(fx["out"]).glob("slurm-*.out"))
        check("本地模式不产生 slurm-<ID>.out (未走 sbatch)", not slurm_logs,
              str([p.name for p in slurm_logs]), failures)
        check("本地日志/退出码文件按 local-<ID> 契约落盘",
              (Path(fx["out"]) / ("local-%s.out" % jid1)).is_file()
              and list(Path(fx["out"]).glob("diann_gui_scripts/*.rc")),
              "log=%s rc=%s" % ((Path(fx["out"]) / ("local-%s.out" % jid1)).is_file(),
                                len(list(Path(fx["out"]).glob("diann_gui_scripts/*.rc")))),
              failures)

        # ---- 慢作业提交 -> 取消 -> 已取消 ----
        fx["ctl"].write_text("300\n", encoding="utf-8")
        go_tab("analysis")
        click_js(By.ID, "submit_job")
        go_tab("monitor")
        got = wait_until(lambda: len(job_rows()) >= 2, 20)
        if not got:
            click_js(By.ID, "submit_job")
            got = wait_until(lambda: len(job_rows()) >= 2, 30)
        check("第二个(慢)作业提交成功", got, str(job_rows()), failures)
        rows = job_rows()
        jid2 = rows[-1][0] if len(rows) >= 2 else ""
        check("慢作业获得独立本地作业 ID", bool(jid2) and jid2 != jid1,
              "jid1=%s jid2=%s" % (jid1, jid2), failures)
        check("提交后 Shiny 会话保持连接 (第二次提交)", connected(), "", failures)

        go_tab("monitor")

        def slow_running():
            click_js(By.ID, "refresh_q")
            return bool(jid2) and jid2 in squeue_text() and "RUNNING" in squeue_text()

        check("慢作业在监控页显示 运行中", wait_until(slow_running, 40, interval=1),
              squeue_text().replace("\n", " | ")[:200], failures)

        cid = drv.find_element(By.ID, "cancel_id")
        cid.clear()
        cid.send_keys(str(jid2))
        drv.execute_script("arguments[0].blur();", cid)
        time.sleep(0.5)
        got = click_retry(By.ID, "cancel_btn",
                          lambda: (len(drv.find_elements(By.ID, "shiny-modal")) > 0
                                   and "确认取消" in body_text()),
                          tries=3, wait_s=8)
        modal_txt = elem_text("shiny-modal")
        check("取消作业确认弹窗出现", got, modal_txt.replace("\n", " | ")[:160], failures)
        check("取消弹窗文案标明「本地作业」且带作业 ID",
              "取消本地作业" in modal_txt and bool(jid2) and jid2 in modal_txt,
              modal_txt.replace("\n", " | ")[:160], failures)
        got = click_retry(By.ID, "cancel_confirm",
                          lambda: len(drv.find_elements(By.ID, "shiny-modal")) == 0,
                          tries=3, wait_s=10)
        check("确认取消后弹窗关闭", got, notif_text()[:160], failures)

        def cancelled_seen():
            click_js(By.ID, "refresh_q")
            txt = sacct_text()
            return bool(jid2) and jid2 in txt and "已取消" in txt

        check("取消后监控页显示 已取消", wait_until(cancelled_seen, 60, interval=2),
              sacct_text().replace("\n", " | ")[:200], failures)
        check("取消后 Shiny 会话保持连接", connected(), "", failures)

        markers = list(Path(fx["out"]).glob("diann_gui_scripts/*.cancelled"))
        check("取消标记 <script>.cancelled 落盘", bool(markers),
              str([p.name for p in markers]), failures)

        # ---- 收尾: 全程无 Shiny 错误 ----
        scan_errors("final")
        check("页面全程无 error in running command / Shiny 错误",
              not err_hits, "; ".join(sorted(set(err_hits))), failures)
        check("最终仍保持 Shiny 连接", connected(), "", failures)

        print("E2E-LOCAL %s (%d 项失败)" % ("FAIL" if failures else "PASS", len(failures)))
        return 1 if failures else 0
    finally:
        try:
            drv.quit()
        except Exception:  # noqa: BLE001
            pass


def main():
    ap = argparse.ArgumentParser(description="v1.12 本地执行后端浏览器 E2E")
    ap.add_argument("--url", default=None, help="已按 local 后端运行中的实例 (配合 --workdir)")
    ap.add_argument("--workdir", default=None, help="run_e2e.sh 建好的夹具目录")
    ap.add_argument("--repo-root", default=str(Path(__file__).resolve().parents[2]),
                    help="仓库根 (仅用于日志/错误提示)")
    ap.add_argument("--keep", action="store_true", help="失败/结束后保留临时目录")
    args = ap.parse_args()

    skip_browser = os.environ.get("E2E_SKIP_BROWSER", "") == "1"
    reuse = bool(args.url)
    own_dir = None
    app_proc = None
    rc = 0
    try:
        if reuse:
            if not args.workdir:
                print("[e2e-local] FAIL: --url 需要同时给 --workdir (夹具目录)")
                return 1
            base = Path(args.workdir)
            # run_e2e.sh 已建好夹具; 只在缺失时补齐 (便于手工 --url 调试)
            fx = build_fixtures(base) if not (base / "bin" / "apptainer").exists() else {
                "base": base, "bin": base / "bin", "apptainer": base / "bin" / "apptainer",
                "sif": base / "sif" / "diann-9.9.9.sif", "data": base / "data",
                "lib": base / "data" / "fake.parquet", "raw": base / "data" / "sample.raw",
                "out": base / "out", "out_report": base / "out" / "report.tsv",
                "ctl": base / "fake_ctl", "apt_log": base / "fake_apptainer_exec.log",
                "home": base / "home", "config": base / "config.R",
                "app_log": base / "app.log"}
            if not fx["apt_log"].exists():
                fx["apt_log"].write_text("", encoding="utf-8")
            log("复用实例 %s (夹具 %s)" % (args.url, base))
            url = args.url
        else:
            own_dir = Path(tempfile.mkdtemp(prefix="diann_e2e_local."))
            fx = build_fixtures(own_dir)
            log("自建夹具: %s" % own_dir)
            if skip_browser:
                return check_fixtures_static(fx)
            env_check = subprocess.run(
                ["Rscript", "--vanilla", "-e", 'library(diann.gui); cat("OK")'],
                capture_output=True, text=True)
            if env_check.returncode != 0 or "OK" not in env_check.stdout:
                print("[e2e-local] FAIL: R 包 diann.gui 不可用, 先运行 R CMD INSTALL .")
                print((env_check.stdout + env_check.stderr)[-800:])
                return 1
            port = pick_port()
            log("启动 run_app :%d (config=%s)" % (port, fx["config"]))
            app_proc, url = start_app(fx, port, args.repo_root)
            log("实例就绪 %s" % url)

        if skip_browser:
            return check_fixtures_static(fx)

        try:
            from selenium import webdriver  # noqa: F401
        except ImportError:
            print("[e2e-local] SKIP: 未安装 selenium —— 浏览器断言未执行。", flush=True)
            print("  手动安装后重跑: python3 -m pip install --user selenium; "
                  "sudo apt-get install -y firefox (geckodriver 由 selenium-manager 自动获取)", flush=True)
            return 0 if os.environ.get("E2E_SKIP_BROWSER") == "1" else 1

        rc = run_browser(fx, url)
        return rc
    except Exception as e:  # noqa: BLE001
        print("[e2e-local] FAIL(异常): %s: %s" % (type(e).__name__, e))
        log_path = None
        try:
            log_path = fx["app_log"]
        except Exception:  # noqa: BLE001
            pass
        if log_path and Path(log_path).exists():
            print("----- app.log 尾部 -----")
            for line in Path(log_path).read_text(encoding="utf-8", errors="replace").splitlines()[-25:]:
                print(line)
        return 1
    finally:
        stop_app(app_proc)
        if own_dir is not None:
            kill_leftovers(own_dir)
            if rc == 0 and not args.keep:
                shutil.rmtree(own_dir, ignore_errors=True)
            else:
                log("保留临时目录便于排查: %s" % own_dir)
        elif reuse:
            # 复用模式不动 run_e2e.sh 的目录, 但清理可能残留的本地作业进程
            kill_leftovers(Path(args.workdir))


if __name__ == "__main__":
    sys.exit(main())
