#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
v1.13 本地模式文档截图采集 (提交页 + 任务队列页), 可重复执行, 不进 CI 强制。

自包含夹具 (临时 HOME/配置, 不碰真实 ~/.diann_gui 与 3838 实例):
  假 apptainer: --version -> apptainer version 1.4.5;
                exec <sif> diann-linux --version -> DIA-NN 2.7.0 Academia …;
                exec <sif> diann-linux <作业参数> -> 按 --out 写假报告 (sleep 由 ctl 控制)
  假 SIF: >=1MiB + SIF_MAGIC, 文件名 image.sif (演示 v1.13 "任意文件名可见")
  临时 config: EXEC_BACKEND=local / APPTAINER_PATHS / SIF_DIRS / DATA_HOME /
               BASE_VOLUMES 全部指向 /tmp/diann_docs_demo 下
  假 RAW/光谱库 + 临时 HOME

产出:
  docs/img/local_mode_submit.png   提交页 (模式 banner + SIF 已识别 + 校验/预览)
  docs/img/local_mode_monitor.png  任务队列页 (运行中→已完成 + 本地历史/日志)
  并把两图 base64 嵌入 docs/DIANN_GUI_新手指南.html (图 3-2 / 图 3-3),
  顶部版本说明与侧栏版本号同步 v1.13; 既有 11 张图哈希不变。

页面文本匿名化: 截图前断言 body 不含真实用户名 (检测 $USER/whoami 与 /share/home/)。

用法: python3 tests/e2e/capture_docs_screenshots.py [--repo-root .]
依赖: R + 已安装当前仓库 diann.gui, python3 + selenium + Pillow, Firefox headless。
"""
import argparse
import base64
import hashlib
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.request
from io import BytesIO
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
DEMO = Path("/tmp/diann_docs_demo")

FAKE_APPTAINER = r'''#!/bin/bash
# 文档截图专用假 apptainer (不是真实容器运行时)
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
# 容器内 diann-linux --version (v1.13 SIF 版本识别路径); exec 后 $1 是 sif 路径,
# 需在参数流里找 "diann-linux" 后跟 "--version"
is_ver=0; prev_a=""
for a in "$@"; do
  if [ "$prev_a" = "diann-linux" ] && [ "$a" = "--version" ]; then is_ver=1; fi
  prev_a="$a"
done
if [ "$is_ver" = "1" ]; then
  echo "DIA-NN 2.7.0 Academia, build Oct 12 2025 17:36:10 (git 8f2b1c3)"
  exit 0
fi
out=""; prev=""
for a in "$@"; do
  if [ "$prev" = "--out" ]; then out="$a"; fi
  prev="$a"
done
sleep_s="${DIANN_DOCS_SLEEP:-1}"
sleep "$sleep_s"
if [ -n "$out" ]; then
  mkdir -p "$(dirname "$out")" 2>/dev/null
  printf 'Protein.Names\tGenes\tPG.Quantity\nP12345\tGENE1\t1.0\n' > "$out"
fi
exit 0
'''


def log(msg):
    print("[docs-shot %s] %s" % (time.strftime("%H:%M:%S"), msg), flush=True)


def make_sif(path):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    hdr = b"#!/usr/bin/env run-singularity\n"
    with open(path, "wb") as f:
        f.write(hdr)
        f.write(b"\x00" * (32 - len(hdr)))
        f.write(b"SIF_MAGIC")
        f.write(os.urandom(1024 * 1024))   # >=1MiB, 过 GUI 大小校验
    return path


def build_fixtures():
    if DEMO.exists():
        shutil.rmtree(DEMO)
    fx = {
        "base": DEMO,
        "bin": DEMO / "bin",
        "apptainer": DEMO / "bin" / "apptainer",
        "sif": DEMO / "sif" / "image.sif",
        "data": DEMO / "data",
        "lib": DEMO / "data" / "demo_library.parquet",
        "raw": DEMO / "data" / "demo_sample.raw",
        "out": DEMO / "out",
        "out_report": DEMO / "out" / "demo_report.tsv",
        "ctl": DEMO / "fake_ctl",
        "home": DEMO / "home",
        "config": DEMO / "config.R",
        "app_log": DEMO / "app.log",
    }
    fx["bin"].mkdir(parents=True, exist_ok=True)
    fx["apptainer"].write_text(FAKE_APPTAINER, encoding="utf-8")
    os.chmod(fx["apptainer"], 0o755)
    make_sif(fx["sif"])
    fx["data"].mkdir(parents=True, exist_ok=True)
    fx["out"].mkdir(parents=True, exist_ok=True)
    fx["home"].mkdir(parents=True, exist_ok=True)
    fx["raw"].write_text("demo raw payload\n", encoding="utf-8")
    fx["lib"].write_text("demo spectral library payload\n", encoding="utf-8")
    fx["ctl"].write_text("1\n", encoding="utf-8")
    fx["config"].write_text(
        "# 文档截图用临时配置 (不碰真实 ~/.diann_gui)\n"
        'EXEC_BACKEND <- "local"\n'
        'APPTAINER_PATHS <- c("%s")\n'
        'SIF_DIRS <- c("%s")\n'
        'DEFAULT_SIF <- "%s"\n'
        'DATA_HOME <- "%s"\n'
        'BASE_VOLUMES <- c(Data = "%s", Out = "%s")\n'
        'MAIL_PYTHON <- ""\n'
        % (fx["bin"], fx["base"] / "sif", fx["sif"], fx["data"], fx["data"], fx["out"]),
        encoding="utf-8")
    return fx


def pick_port():
    for _ in range(50):
        s = socket.socket()
        try:
            s.bind(("127.0.0.1", 0))
            p = s.getsockname()[1]
        finally:
            s.close()
        if 41000 <= p <= 48999:
            return p
    raise RuntimeError("no free port")


def r_libs():
    r = subprocess.run(["Rscript", "--vanilla", "-e",
                        "cat(paste(.libPaths(), collapse=':'))"],
                       capture_output=True, text=True, timeout=120)
    return r.stdout.strip()


def start_app(fx, port):
    env = dict(os.environ)
    env["HOME"] = str(fx["home"])
    env["DIANN_GUI_CONFIG"] = str(fx["config"])
    libs = env.get("R_LIBS", "")
    cur = r_libs()
    if cur and cur not in libs:
        env["R_LIBS"] = cur + ((":" + libs) if libs else "")
    code = 'diann.gui::run_app(port=%d, host="127.0.0.1", launch.browser=FALSE)' % port
    logf = open(str(fx["app_log"]), "w", encoding="utf-8")
    proc = subprocess.Popen(["Rscript", "--vanilla", "-e", code],
                            cwd=str(DEMO), env=env,
                            stdout=logf, stderr=subprocess.STDOUT,
                            start_new_session=True)
    url = "http://127.0.0.1:%d/" % port
    t0 = time.time()
    while time.time() - t0 < 120:
        if proc.poll() is not None:
            raise RuntimeError("run_app 提前退出 (rc=%s); 见 %s" % (proc.returncode, fx["app_log"]))
        try:
            with urllib.request.urlopen(url, timeout=3) as resp:
                if str(resp.status) == "200":
                    return proc, url
        except Exception:  # noqa: BLE001
            pass
        time.sleep(1)
    raise RuntimeError("应用 120s 未就绪; 见 %s" % fx["app_log"])


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


def kill_leftovers():
    try:
        out = subprocess.run(["pgrep", "-f", str(DEMO)], capture_output=True, text=True,
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


def save_png(drv, path):
    """截图 → Pillow 缩放宽 1400 → PNG optimize, 目标 <350KB。"""
    from PIL import Image
    raw = drv.get_screenshot_as_png()
    img = Image.open(BytesIO(raw)).convert("RGB")
    w, h = img.size
    if w > 1400:
        img = img.resize((1400, round(h * 1400 / w)), Image.LANCZOS)
    img.save(path, format="PNG", optimize=True)
    if os.path.getsize(path) > 350 * 1024:
        # 量化到 256 色再存 (界面截图降色几乎无损, 体积减半以上)
        img.quantize(colors=256, method=Image.MEDIANCUT).convert("P").save(
            path, format="PNG", optimize=True)
    kb = os.path.getsize(path) / 1024
    log("截图已保存 %s (%.0f KB)" % (path, kb))
    return kb


def capture(fx, url):
    from selenium import webdriver
    from selenium.webdriver.common.by import By
    from selenium.webdriver.firefox.options import Options
    from selenium.webdriver.support import expected_conditions as EC
    from selenium.webdriver.support.ui import WebDriverWait

    opts = Options()
    opts.add_argument("-headless")
    drv = webdriver.Firefox(options=opts)
    drv.set_window_size(1680, 1600)

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

    def wait_until(fn, timeout, interval=0.5):
        t0 = time.time()
        while time.time() - t0 < timeout:
            try:
                if fn():
                    return True
            except Exception:  # noqa: BLE001
                pass
            time.sleep(interval)
        return False

    def click_js(sel):
        el = drv.find_element(By.CSS_SELECTOR, sel)
        drv.execute_script("arguments[0].scrollIntoView({block:'center'});", el)
        drv.execute_script("arguments[0].click();", el)

    def go_tab(name):
        link = drv.find_element(By.CSS_SELECTOR, 'a[href="#shiny-tab-%s"]' % name)
        drv.execute_script("arguments[0].click();", link)
        wait_until(lambda: len(drv.find_elements(
            By.CSS_SELECTOR, 'li.active a[href="#shiny-tab-%s"]' % name)) > 0, 10)

    def freeze_and_anonymize():
        """停掉 Shiny 自动刷新定时器 (防止替换后被重渲染), 并把可见文本里的
        真实用户名替换为 demo —— 运行身份是真实 OS 用户, 无法在进程级伪造。"""
        who = subprocess.run(["whoami"], capture_output=True, text=True).stdout.strip()
        drv.execute_script(
            "window.setTimeout=function(){}; window.setInterval=function(){return 0;};"
            "var walk=document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);"
            "var n; while(n=walk.nextNode()){"
            "  if(n.nodeValue.indexOf(%r)>=0) n.nodeValue=n.nodeValue.split(%r).join('demo');"
            "  if(n.nodeValue.indexOf('/share/home/')>=0) n.nodeValue=n.nodeValue.replace(/\/share\/home\/[^ ]*/g,'/home/demo');"
            "}" % (who, who))
        txt = body_text()
        for bad in (who, "/share/home/"):
            if bad and bad in txt:
                raise RuntimeError("匿名化后页面仍含敏感串 %r, 中止截图" % bad)

    img_dir = REPO / "docs" / "img"
    img_dir.mkdir(parents=True, exist_ok=True)
    out1 = img_dir / "local_mode_submit.png"
    out2 = img_dir / "local_mode_monitor.png"

    try:
        drv.get(url)
        WebDriverWait(drv, 120).until(EC.presence_of_element_located((By.ID, "submit_job")))
        wait_until(lambda: len(elem_text("apptainer_display")) > 3, 30)
        time.sleep(1)

        # ---- SIF 识别: 任意文件名 (image.sif) → 点「识别所有未识别镜像」→ v2.7.0 ----
        assert wait_until(lambda: "image.sif" in elem_text("sif_display"), 30), \
            "SIF 下拉未选中 image.sif"
        click_js("#sif_identify_all")
        got = wait_until(lambda: "2.7.0" in elem_text("sif_display")
                         and "v2.7.0" in (elem_text("sif_version_info")
                                          + elem_text("sif_display")), 60)
        assert got, "识别版本未生效: %s | %s" % (elem_text("sif_version_info"),
                                                elem_text("sif_display"))
        log("SIF 版本已识别 (v2.7.0, 任意文件名)")

        # ---- 填表 (命令导入覆盖层, 与 e2e 同法) ----
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
        click_js("#import_btn")
        assert wait_until(lambda: "已重置旧分析参数并填充" in elem_text("import_result"), 20), \
            "导入失败: %s" % elem_text("import_result")[:160]
        # 收起导入盒, 让截图聚焦提交页主体
        drv.execute_script(
            "var box=document.getElementById('import_cmd').closest('.box');"
            "var b=box?box.querySelector('[data-widget=\"collapse\"]'):null; if(b) b.click();")
        assert wait_until(lambda: len(elem_text("validation_msgs")) > 0
                          and "✗" not in elem_text("validation_msgs"), 40), \
            "校验仍有阻断项: %s" % elem_text("validation_msgs")[:200]

        # ---- 匿名化 + 冻结定时器, 截图 1: 提交页 ----
        freeze_and_anonymize()
        drv.execute_script("window.scrollTo(0, 0);")
        time.sleep(0.8)
        kb1 = save_png(drv, out1)

        # ---- 提交快作业, 监控页截 任务队列 ----
        fx["ctl"].write_text("6\n", encoding="utf-8")
        click_js("#submit_job")
        go_tab("monitor")
        assert wait_until(lambda: "RUNNING" in elem_text("squeue_output"), 40, interval=1), \
            "未观察到 RUNNING: %s" % elem_text("squeue_output")[:160]

        def done():
            click_js("#refresh_q")
            return "已完成" in elem_text("sacct_table")
        assert wait_until(done, 120, interval=2), \
            "作业未完成: %s" % elem_text("sacct_table")[:160]
        # 切 tab/刷新会重建 DOM: 再次匿名化后截图 2
        freeze_and_anonymize()
        drv.execute_script("window.scrollTo(0, 0);")
        time.sleep(0.8)
        kb2 = save_png(drv, out2)
        log("完成: %s (%.0f KB), %s (%.0f KB)" % (out1, kb1, out2, kb2))
    finally:
        try:
            drv.quit()
        except Exception:  # noqa: BLE001
            pass


def embed_guide(png1, png2):
    """两图 base64 嵌入新手指南 §3 (图 3-2/3-3), 版本号 v1.13, 既有 11 图哈希不变。"""
    guide = REPO / "docs" / "DIANN_GUI_新手指南.html"
    src = guide.read_text(encoding="utf-8")

    # 幂等: 已嵌入过则先移除上一版两张 (按图号 3-2/3-3 识别), 再取基线哈希。
    # 用 <figure>.*?</figure> 整块过滤 (figure 不嵌套), 不吞锚点缩进。
    src = re.sub(
        r'[ \t]*<figure>(?:(?!</figure>).)*?<figcaption><b>图 3-[23]</b>(?:(?!</figure>).)*?</figure>[ \t]*\n?',
        lambda m: '' if 'alt="本地模式' in m.group(0) else m.group(0),
        src, flags=re.S)
    old_hashes = [hashlib.sha1(m.encode()).hexdigest()
                  for m in re.findall(r'data:image/png;base64,([A-Za-z0-9+/=]+)', src)]
    assert len(old_hashes) == 11, "期望既有 11 张图, 实际 %d" % len(old_hashes)

    b64_1 = base64.b64encode(Path(png1).read_bytes()).decode()
    b64_2 = base64.b64encode(Path(png2).read_bytes()).decode()

    anchor = '  <h2><span class="sec-no">4</span>第一次搜库 · 手把手</h2>'
    assert anchor in src
    block = (
        '  <h3>两种执行模式的界面差异（v1.13）</h3>\n'
        '  <p>v1.12 起执行后端可选：有 Slurm 时作业提交到集群队列（<code>slurm-&lt;ID&gt;.out</code>）；'
        '无 Slurm 的主机自动切换为<b>本地单机</b>模式（<code>local-&lt;ID&gt;.out</code>，关闭浏览器不影响作业）。'
        '页面顶部与标题栏会明确标注当前模式，提交页/任务队列页各有一条常驻提示条；'
        'sif 镜像下拉按「扫描全部 <code>*.sif</code> + 容器内实测版本」工作，文件名任意，未识别的镜像选中后会自动识别。</p>\n'
        '  <figure>\n'
        '    <img src="data:image/png;base64,%s" alt="本地模式提交页（顶部绿色提示条「当前执行后端：本地单机」、镜像 image.sif 已识别 v2.7.0、校验通过与脚本预览）">\n'
        '    <figcaption><b>图 3-2</b> 本地单机模式「提交分析」页：顶部模式提示条、镜像识别回显（文件名 image.sif 也能识别出 v2.7.0）、校验与脚本预览</figcaption>\n'
        '  </figure>\n'
        '  <figure>\n'
        '    <img src="data:image/png;base64,%s" alt="本地模式任务队列页（运行中→已完成、本地运行任务/近期历史、运行日志查看）">\n'
        '    <figcaption><b>图 3-3</b> 本地单机模式「任务队列」页：作业 运行中→已完成、本地历史与日志；无 Slurm 时没有节点资源表与排队列</figcaption>\n'
        '  </figure>\n' % (b64_1, b64_2)
    )
    src = src.replace(anchor, block + anchor)

    # 顶部版本说明与品牌
    src = src.replace('<b>版本说明（v1.12）</b>', '<b>版本说明（v1.13）</b>')
    src = src.replace('本指南截图仍为 v1.6 界面，请以<b>面板名称</b>为准；操作步骤与按钮文字不变。',
                      'v1.13 起 sif 镜像下拉扫描全部 <code>*.sif</code>（文件名任意）并在容器内实测版本（见 3.x 末尾两张截图）。本指南前 11 张截图仍为 v1.6 界面，请以<b>面板名称</b>为准；操作步骤与按钮文字不变。')
    src = src.replace('<span>新手指南 · v1.12</span>', '<span>新手指南 · v1.13</span>')
    # §8.1 引用新图
    src = src.replace(
        '  <h3>8.1 看进度</h3>\n  <ul>',
        '  <h3>8.1 看进度</h3>\n  <ul>'
        '\n    <li>两种模式的任务队列页样例见<a href="#s3">第 3 节</a>图 3-3（本地单机：运行中→已完成、本地历史与日志）。</li>')

    # 哈希回归: 既有 11 图逐个仍在
    new_hashes = [hashlib.sha1(m.encode()).hexdigest()
                  for m in re.findall(r'data:image/png;base64,([A-Za-z0-9+/=]+)', src)]
    for h in old_hashes:
        assert h in new_hashes, "既有截图哈希发生变化!"

    guide.write_text(src, encoding="utf-8")
    # HTML 可解析性
    from html.parser import HTMLParser
    HTMLParser().feed(guide.read_text(encoding="utf-8"))
    log("新手指南已嵌入图 3-2/3-3 (共 %d 张内嵌图), HTML 可解析" % len(new_hashes))


def main():
    global REPO
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo-root", default=str(REPO))
    args = ap.parse_args()
    REPO = Path(args.repo_root).resolve()

    proc = None
    try:
        kill_leftovers()
        fx = build_fixtures()
        port = pick_port()
        proc, url = start_app(fx, port)
        log("应用已就绪 %s (端口 %d)" % (url, port))
        capture(fx, url)
        embed_guide(REPO / "docs" / "img" / "local_mode_submit.png",
                    REPO / "docs" / "img" / "local_mode_monitor.png")
        print("OK")
        return 0
    except Exception as e:  # noqa: BLE001
        print("FAILED: %s" % e, file=sys.stderr)
        import traceback
        traceback.print_exc()
        return 1
    finally:
        stop_app(proc)
        kill_leftovers()


if __name__ == "__main__":
    sys.exit(main())
