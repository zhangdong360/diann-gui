#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
DIA-NN GUI 命令导入端到端回归 (2026-10-09 断连事故固化):
把真实用户粘贴 (tests/fixtures/) 经真实浏览器填入导入框、点击解析,
断言 (1) 会话保持连接 (2) 解析结果正确填充 (3) RAW 路径全部进入覆盖层
(4) var_mods_max 显式值不被修饰行数覆盖 (2026-10-12 事故)。

用法:
  python3 tests/e2e/e2e_import_check.py --url http://127.0.0.1:4849/
  # 通常通过 tests/e2e/run_e2e.sh 调用 (自动起/停本地实例); --url 也可指向生产

依赖: python3 + selenium, geckodriver 在 PATH, Firefox (headless)。
"""
import argparse
import sys
import time
from pathlib import Path

from selenium import webdriver
from selenium.webdriver.common.by import By
from selenium.webdriver.firefox.options import Options
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.support.ui import WebDriverWait

FIXTURES = [
    ("tests/fixtures/import_small_userpaste.txt", 39, None),
    ("tests/fixtures/import_large_userpaste.txt", 796, None),
    # 2026-10-12 事故回归: 显式 --var-mods 5 曾被 2 行修饰覆盖成 2 (集群重建库前体数少 12 万)
    ("tests/fixtures/import_windows_predlib_userpaste.txt", None, "5"),
]


def run_case(drv, base_url, fixture_path, expected_raws, expected_var_mods=None):
    drv.get(base_url)
    WebDriverWait(drv, 60).until(EC.presence_of_element_located((By.ID, "import_cmd")))
    time.sleep(3)
    # 展开折叠的导入框
    drv.execute_script("""
      var box = document.getElementById('import_cmd').closest('.box');
      var btn = box.querySelector('[data-widget="collapse"]');
      if (btn) btn.click();
      var p = document.getElementById('shiny-notification-panel');
      if (p) p.innerHTML = '';
    """)
    time.sleep(1.5)
    drv.find_element(By.ID, "import_cmd").send_keys(
        Path(fixture_path).read_text(encoding="utf-8"))
    time.sleep(2)
    drv.find_element(By.ID, "import_btn").click()
    result = None
    for _ in range(60):
        time.sleep(1)
        res = drv.find_element(By.ID, "import_result").get_attribute("textContent")
        if res and "尚未导入" not in res:
            result = res
            break
    alive = drv.execute_script(
        "try { return Shiny.shinyapp.isConnected() } catch(e) { return false }")
    raw_lines = drv.execute_script(
        "var el = document.getElementById('raw_path_display');"
        " return el ? el.textContent.split('\\n').filter(function(x){return x.trim()}).length : -1")
    vm_val = drv.execute_script(
        "var el = document.getElementById('var_mods_max');"
        " return el ? el.value : null")
    ok = bool(result) and alive and (
        expected_raws is None or raw_lines == expected_raws)
    if expected_var_mods is not None:
        ok = ok and vm_val is not None and str(vm_val).strip() == expected_var_mods
    print("[%s] connected=%s raw_lines=%s (期望 %s) var_mods_max=%s (期望 %s) -> %s"
          % (Path(fixture_path).name, alive, raw_lines,
             "不查" if expected_raws is None else expected_raws,
             vm_val, expected_var_mods if expected_var_mods is not None else "不查",
             "PASS" if ok else "FAIL"))
    if not ok:
        print("    result:", (result or "(未更新)")[:300].replace("\n", " | "))
    return ok


def main():
    ap = argparse.ArgumentParser(description="命令导入 E2E 回归")
    ap.add_argument("--url", required=True, help="待测 GUI 地址, 如 http://127.0.0.1:4849/")
    ap.add_argument("--repo-root", default=str(Path(__file__).resolve().parents[2]),
                    help="仓库根目录 (定位 fixtures)")
    a = ap.parse_args()

    opts = Options()
    opts.add_argument("-headless")
    drv = webdriver.Firefox(options=opts)
    failures = 0
    try:
        for fx, n, vm_exp in FIXTURES:
            path = str(Path(a.repo_root) / fx)
            if not run_case(drv, a.url, path, n, vm_exp):
                failures += 1
    finally:
        drv.quit()
    print("E2E %s (%d/%d 通过)" % ("FAIL" if failures else "PASS",
                                   len(FIXTURES) - failures, len(FIXTURES)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
