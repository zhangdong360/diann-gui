#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
apptainer 运行环境选择 端到端回归 (v1.11):
(1) 新 box 出现在「DIA-NN 版本」之前 (DOM/布局顺序)
(2) 自动识别候选 (服务端配置 APPTAINER_PATHS 指向假二进制) 且带版本
(3) 手动路径「识别并验证」成功路径 ✓
(4) 不存在路径失败路径 ✗
(5) 预览脚本包含所选 apptainer 路径

用法:
  python3 tests/e2e/e2e_apptainer_check.py --url http://127.0.0.1:4849/ \
      --apptainer /tmp/xxx/bin/apptainer
依赖: python3 + selenium, geckodriver, Firefox (headless)。
"""
import argparse
import sys
import time

from selenium import webdriver
from selenium.webdriver.common.by import By
from selenium.webdriver.firefox.options import Options
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.support.ui import WebDriverWait


def main():
    ap = argparse.ArgumentParser(description="apptainer 运行环境选择 E2E")
    ap.add_argument("--url", required=True)
    ap.add_argument("--apptainer", default=None,
                    help="假 apptainer 可执行文件 (自动识别/手动验证用); 省略则只查 UI 结构")
    args = ap.parse_args()

    opts = Options()
    opts.add_argument("-headless")
    drv = webdriver.Firefox(options=opts)
    drv.set_window_size(1600, 1200)
    failures = []

    def check(name, cond, detail=""):
        print("[%s] %s %s" % ("PASS" if cond else "FAIL", name, detail))
        if not cond:
            failures.append(name)

    try:
        drv.get(args.url)
        WebDriverWait(drv, 60).until(EC.presence_of_element_located((By.ID, "apptainer_version")))
        time.sleep(2)

        # (1) 顺序: apptainer box 在 DIA-NN 版本 box 之前
        before = drv.execute_script(
            "var a=document.getElementById('apptainer_version');"
            "var b=document.getElementById('sif_version');"
            "return (a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING) ? true : false;")
        check("apptainer 区域在 DIA-NN 版本之前", before)

        # (2) 候选下拉: 自动识别到假二进制并解析出版本
        if args.apptainer:
            opts_txt = [o.text for o in drv.find_elements(By.CSS_SELECTOR,
                                                          "#apptainer_version option")]
            joined = " | ".join(opts_txt)
            check("自动识别候选含版本", any("apptainer" in t and "1.4.5" in t for t in opts_txt),
                  joined[:160])

        # (3) 手动路径验证成功
        cb = drv.find_element(By.ID, "use_custom_apptainer")
        if cb.get_attribute("checked") is None:
            cb.click()
        time.sleep(1)
        inp = drv.find_element(By.ID, "custom_apptainer")
        inp.clear()
        inp.send_keys(args.apptainer or "/nonexistent/apptainer")
        drv.find_element(By.ID, "verify_apptainer").click()
        WebDriverWait(drv, 30).until(
            lambda d: "✓" in d.find_element(By.ID, "apptainer_verify_result").text)
        txt = drv.find_element(By.ID, "apptainer_verify_result").text
        check("手动路径识别并验证", "✓" in txt and "1.4.5" in txt, txt.replace("\n", " ")[:120])

        # (4) 不存在路径失败
        inp.clear()
        inp.send_keys("/nonexistent/apptainer")
        drv.find_element(By.ID, "verify_apptainer").click()
        WebDriverWait(drv, 30).until(
            lambda d: "✗" in d.find_element(By.ID, "apptainer_verify_result").text)
        check("不存在路径正确报错", True)

        # (5) 预览脚本包含选定的 apptainer 路径
        if args.apptainer:
            inp.clear()
            inp.send_keys(args.apptainer)
            drv.find_element(By.ID, "verify_apptainer").click()
            time.sleep(1)
            prev = drv.find_element(By.ID, "preview").get_attribute("textContent")
            check("预览脚本含所选 apptainer", args.apptainer in prev)

        alive = drv.execute_script(
            "try { return Shiny.shinyapp.isConnected() } catch(e) { return false }")
        check("会话保持连接", bool(alive))

        print("E2E-APPTAINER %s (%d 项失败)" % ("FAIL" if failures else "PASS", len(failures)))
        return 1 if failures else 0
    finally:
        drv.quit()


if __name__ == "__main__":
    sys.exit(main())
