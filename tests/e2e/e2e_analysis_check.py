#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
DIA-NN GUI 结果分析页端到端回归 (v1.14):
(1) 切到「结果分析」页 (2) 填矩阵路径 → 读取 (3) QC 图渲染 (4) 生成报告
用法:
  python3 tests/e2e/e2e_analysis_check.py --url http://127.0.0.1:4849/ --matrix /path/pg_matrix.tsv
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


def click_tab(drv, data_value):
    els = drv.find_elements(By.CSS_SELECTOR, f'a[data-value="{data_value}"]')
    if not els:
        raise AssertionError(f"未找到页签 {data_value}")
    drv.execute_script(
        "arguments[0].scrollIntoView({block:'center'}); arguments[0].click();", els[0])
    time.sleep(1)


def wait_text_contains(drv, by, ident, needle, timeout=90):
    WebDriverWait(drv, timeout).until(
        lambda d: needle in (d.find_elements(by, ident)[0].text
                             if d.find_elements(by, ident) else ""))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--matrix", required=True, help="合成 pg_matrix tsv 的服务器路径")
    args = ap.parse_args()

    opts = Options()
    opts.add_argument("-headless")
    drv = webdriver.Firefox(options=opts)
    drv.set_window_size(1680, 1200)
    try:
        drv.get(args.url)
        WebDriverWait(drv, 60).until(
            EC.presence_of_element_located((By.CSS_SELECTOR, 'a[data-value="downstream"]')))
        time.sleep(2)

        # ---- 1. 切到结果分析页 ----
        click_tab(drv, "downstream")
        WebDriverWait(drv, 30).until(
            EC.presence_of_element_located((By.ID, "analysis-matrix_path")))

        # ---- 2. 填路径 → 读取矩阵 ----
        box = drv.find_element(By.ID, "analysis-matrix_path")
        box.clear()
        box.send_keys(args.matrix)
        # JS 点击不触发 blur: 显式派发事件把 textInput 值提交给 Shiny
        drv.execute_script(
            "arguments[0].dispatchEvent(new Event('input', {bubbles:true}));"
            "arguments[0].dispatchEvent(new Event('change', {bubbles:true}));", box)
        time.sleep(1)
        drv.execute_script("arguments[0].click();",
                           drv.find_element(By.ID, "analysis-matrix_load"))
        wait_text_contains(drv, By.ID, "analysis-matrix_info", "已读取")
        print("[e2e-analysis] 矩阵读取 OK")

        # 分组自动推断应成功 (A/B 各 3 样本)
        wait_text_contains(drv, By.ID, "analysis-infer_status", "自动推断成功")
        print("[e2e-analysis] 分组自动推断 OK")

        # ---- 3. QC 图渲染 (SVG img 出现) ----
        click_tab(drv, "③ QC 可视化")
        WebDriverWait(drv, 120).until(
            lambda d: d.find_elements(By.CSS_SELECTOR,
                                      "#analysis-qc_figures img") and
            d.find_element(By.ID, "analysis-qc_figures").find_elements(
                By.CSS_SELECTOR, "img"))
        n_img = len(drv.find_element(By.ID, "analysis-qc_figures")
                    .find_elements(By.CSS_SELECTOR, "img"))
        assert n_img >= 8, f"QC 图数量不足: {n_img}"
        print(f"[e2e-analysis] QC 图渲染 OK ({n_img} 张)")

        # ---- 4. 生成报告 ----
        click_tab(drv, "⑥ 生成报告")
        drv.execute_script("arguments[0].scrollIntoView({block:'center'}); arguments[0].click();",
                           drv.find_element(By.ID, "analysis-report_build"))
        wait_text_contains(drv, By.ID, "analysis-report_result", "报告已生成", timeout=180)
        has_zip = drv.find_elements(By.ID, "analysis-report_zip")
        print(f"[e2e-analysis] 报告生成 OK (zip 按钮: {bool(has_zip)})")

        print("[e2e-analysis] 通过")
    finally:
        drv.quit()


if __name__ == "__main__":
    try:
        main()
    except AssertionError as e:
        print(f"::error::e2e-analysis 断言失败: {e}")
        sys.exit(1)
    except Exception as e:  # noqa: BLE001
        import traceback
        try:
            drv.save_screenshot("/tmp/e2e_analysis_fail.png")
            with open("/tmp/e2e_analysis_fail.html", "w") as f:
                f.write(drv.page_source)
        except Exception:
            pass
        print(f"::error::e2e-analysis 异常: {type(e).__name__}: {e}")
        traceback.print_exc()
        sys.exit(1)
