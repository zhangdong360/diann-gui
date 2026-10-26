#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
DIA-NN GUI 镜像验证功能端到端回归 (v1.10):
(1) 环境自检面板渲染 (2) 验证链全绿路径 (3) 不存在路径失败路径
(4) shinyFiles 浏览选择回填 custom_sif + 回显 + 验证链。
注意: headless 下原生双击不触发 shinyFiles 0.9.3 的目录 dblclick 委托,
进入目录用 jQuery trigger('dblclick'), 选中文件用原生单击 + Select 按钮
(真实用户交互等效; 生产其余 4 个选择器同机制)。
用法:
  python3 tests/e2e/e2e_sif_verify_check.py --url http://127.0.0.1:4841/ --sif /path/diann-x.y.z.sif
依赖: python3 + selenium, geckodriver, Firefox (headless)。
"""
import argparse
import sys
import time

from selenium import webdriver
from selenium.webdriver.common.action_chains import ActionChains
from selenium.webdriver.common.by import By
from selenium.webdriver.firefox.options import Options
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.support.ui import WebDriverWait, Select


def open_at_file_modal(drv):
    cb = drv.find_element(By.ID, "use_custom_sif")
    if cb.get_attribute("checked") is None:
        cb.click()
    time.sleep(1)
    btn = drv.find_element(By.ID, "sif_pick")
    drv.execute_script("arguments[0].scrollIntoView({block:'center'}); arguments[0].click();", btn)
    WebDriverWait(drv, 20).until(EC.presence_of_element_located((By.ID, "sif_pick-modal")))
    time.sleep(2)
    return drv.find_element(By.ID, "sif_pick-modal")


def browse_to(drv, modal, volume, dirname, filename):
    """切换卷 → 进入子目录 → 原生单击选中文件 → Select 确认"""
    Select(modal.find_element(By.CSS_SELECTOR, "select.sF-breadcrumps")).select_by_value(volume)
    time.sleep(2)
    for e in modal.find_elements(By.CSS_SELECTOR, ".sF-directory"):
        if dirname in e.text:
            drv.execute_script("jQuery(arguments[0]).trigger('dblclick');", e)
            break
    else:
        raise AssertionError(f"未找到目录 {dirname}")
    time.sleep(3)
    for e in modal.find_elements(By.CSS_SELECTOR, ".sF-file"):
        if filename in e.text:
            drv.execute_script("arguments[0].scrollIntoView({block:'center'});", e)
            time.sleep(0.3)
            ActionChains(drv).move_to_element(e).click().perform()
            break
    else:
        raise AssertionError(f"未找到文件 {filename}")
    time.sleep(1)
    drv.execute_script("arguments[0].click();", modal.find_element(By.ID, "sF-selectButton"))
    time.sleep(3)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--sif", required=True, help="可读的真实 sif 镜像 (全绿路径用)")
    ap.add_argument("--volume", default=None, help="浏览用卷名 (默认跳过浏览测试)")
    ap.add_argument("--dirname", default=None)
    args = ap.parse_args()

    opts = Options()
    opts.add_argument("-headless")
    drv = webdriver.Firefox(options=opts)
    drv.set_window_size(1600, 1200)
    try:
        drv.get(args.url)
        WebDriverWait(drv, 60).until(EC.presence_of_element_located((By.ID, "verify_sif")))
        time.sleep(3)

        # ---- 1. 环境自检面板渲染 ----
        apt = drv.find_element(By.ID, "apt_check_display").text
        assert apt.strip(), f"环境自检面板为空: {apt!r}"
        print("[1] 环境自检面板渲染 OK:", " / ".join(apt.splitlines()[:2]))

        # ---- 2. 失败路径: 自定义 + 不存在的路径 ----
        drv.find_element(By.ID, "use_custom_sif").click()
        time.sleep(1)
        inp = drv.find_element(By.ID, "custom_sif")
        inp.clear()
        inp.send_keys("/nonexistent/diann-9.9.9.sif")
        drv.find_element(By.ID, "verify_sif").click()
        WebDriverWait(drv, 20).until(lambda d: "镜像不存在" in d.find_element(By.ID, "sif_verify_result").text)
        print("[2] 不存在路径正确报错 OK")

        # ---- 3. 全绿路径: 快速验证 → 深度验证 ----
        inp.clear()
        inp.send_keys(args.sif)
        WebDriverWait(drv, 10).until(
            lambda d: args.sif in d.find_element(By.ID, "sif_display").text)
        drv.find_element(By.ID, "verify_sif").click()
        WebDriverWait(drv, 30).until(
            lambda d: "快速验证通过" in d.find_element(By.ID, "sif_verify_result").text)
        quick_txt = drv.find_element(By.ID, "sif_verify_result").text
        for needle in ["文件存在", "可读取", "SIF 镜像格式有效", "apptainer 可用"]:
            assert needle in quick_txt, f"快速验证缺步骤 {needle!r}: {quick_txt!r}"
        drv.find_element(By.ID, "verify_sif_deep").click()
        WebDriverWait(drv, 90).until(
            lambda d: "容器内 DIA-NN 可执行" in d.find_element(By.ID, "sif_verify_result").text)
        txt = drv.find_element(By.ID, "sif_verify_result").text
        for needle in ["文件存在", "可读取", "SIF 镜像格式有效", "apptainer inspect 通过"]:
            assert needle in txt, f"深度验证缺步骤 {needle!r}: {txt!r}"
        assert "✗" not in txt, f"全绿路径出现失败项: {txt!r}"
        print("[3] 快速 + 深度验证全绿 OK:", txt.replace("\n", " | ")[:200])

        # ---- 4. 浏览选择回填 + 验证 ----
        if args.volume and args.dirname:
            modal = open_at_file_modal(drv)
            browse_to(drv, modal, args.volume, args.dirname, args.sif.rsplit("/", 1)[-1])
            val = drv.find_element(By.ID, "custom_sif").get_attribute("value")
            assert val == args.sif, f"回填路径不符: {val!r}"
            disp = drv.find_element(By.ID, "sif_display").text
            assert "v" in disp and args.sif in disp, f"回显异常: {disp!r}"
            drv.find_element(By.ID, "verify_sif").click()
            WebDriverWait(drv, 30).until(
                lambda d: "快速验证通过" in d.find_element(By.ID, "sif_verify_result").text)
            drv.find_element(By.ID, "verify_sif_deep").click()
            WebDriverWait(drv, 90).until(
                lambda d: "容器内 DIA-NN 可执行" in d.find_element(By.ID, "sif_verify_result").text)
            print("[4] 浏览选择回填 + 验证 OK")

        print("E2E-SIF PASS")
        return 0
    finally:
        drv.quit()


if __name__ == "__main__":
    sys.exit(main())
