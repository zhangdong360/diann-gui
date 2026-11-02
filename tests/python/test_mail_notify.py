#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mail_notify.py 单元测试 (标准库 unittest, 不联网)。

覆盖 2026-10 审查修复:
  * --out-file 自定义主报告名被结果简介使用 (此前硬编码 report.tsv)
  * STARTTLS 失败必须拒绝明文发送凭据 (此前静默降级)
  * 文件名/项目简介 HTML 转义
"""
import argparse
import importlib.util
import os
import pathlib
import smtplib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
# 既有用例断言中文输出: 在加载被测模块前钉默认语言 (外部已显式设置时尊重之)
os.environ.setdefault("DIANN_GUI_LANG", "zh")
_spec = importlib.util.spec_from_file_location("mail_notify", ROOT / "inst" / "python" / "mail_notify.py")
mail = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mail)


def ns(**kw):
    base = dict(status_label=None, status_reason=None, rc=None, state=None,
                task="T", job_id="1", out_dir="", sif="", elapsed=None)
    base.update(kw)
    return argparse.Namespace(**base)


class ConfigTest(unittest.TestCase):
    def test_load_config_reads_required_keys(self):
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".txt", delete=False) as fh:
            fh.write("# comment\nsmtp_host=smtp.example.com\nsmtp_user=u@example.com\n"
                     "smtp_pass=secret\nsmtp_port=587\n")
            path = fh.name
        try:
            cfg = mail.load_config(path)
            self.assertEqual(cfg["smtp_host"], "smtp.example.com")
            self.assertEqual(cfg["smtp_port"], 587)
            self.assertEqual(cfg["mail_from"], "u@example.com")
        finally:
            os.unlink(path)

    def test_load_config_missing_returns_none(self):
        self.assertIsNone(mail.load_config("/nonexistent/mail_config.txt"))


class SummaryTest(unittest.TestCase):
    def test_custom_report_name_is_used(self):
        with tempfile.TemporaryDirectory() as d:
            report = os.path.join(d, "my_report.tsv")
            with open(report, "w", encoding="utf-8") as fh:
                fh.write("header\nrow1\nrow2\n")
            _, metrics = mail.summarize_out_dir(d, report)
            joined = " ".join(metrics)
            self.assertIn("my_report.tsv", joined)
            self.assertIn("2", joined)

    def test_fallback_to_report_tsv_when_out_file_missing(self):
        with tempfile.TemporaryDirectory() as d:
            report = os.path.join(d, "report.tsv")
            with open(report, "w", encoding="utf-8") as fh:
                fh.write("header\nrow1\n")
            _, metrics = mail.summarize_out_dir(d, "/nonexistent/custom.tsv")
            self.assertIn("report.tsv", " ".join(metrics))

    def test_file_names_are_html_escaped(self):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "<script>.tsv"), "w", encoding="utf-8") as fh:
                fh.write("h\n")
            rows, _ = mail.summarize_out_dir(d, "")
            joined = " ".join(rows)
            self.assertIn("&lt;script&gt;", joined)
            self.assertNotIn("<script>", joined)


class BuildHtmlTest(unittest.TestCase):
    def _html(self, **kw):
        a = ns(**kw)
        return mail.build_html(a, [], [], {}, "")

    def test_diann_ver_flag_rendered(self):
        # v1.14.1: 容器实测版本经 --diann-ver 显示 (不再用文件名)
        html = self._html(diann_ver="2.10.0", sif="/x/diann_latest.sif")
        self.assertIn("2.10.0", html)
        self.assertNotIn("diann_latest.sif", html)

    def test_diann_ver_missing_falls_back_to_sif_basename(self):
        html = self._html(diann_ver="", sif="/x/diann-2.7.0.sif")
        self.assertIn("diann-2.7.0.sif", html)

    def test_diann_ver_and_sif_both_missing(self):
        html = self._html(diann_ver="", sif="")
        self.assertIn("<td>-</td>", html)


class StatusViewTest(unittest.TestCase):
    def test_labels(self):
        self.assertEqual(mail.status_view(ns(status_label="成功"))[1], "完成")
        self.assertEqual(mail.status_view(ns(status_label="失败"))[1], "失败")
        self.assertTrue(mail.status_view(ns(status_label="成功"))[3])
        self.assertFalse(mail.status_view(ns(status_label="待核实"))[3])

    def test_fallback_to_rc(self):
        self.assertTrue(mail.status_view(ns(rc=0))[3])
        self.assertFalse(mail.status_view(ns(rc=2))[3])
        self.assertFalse(mail.status_view(ns(rc=None))[3])


class LangEnTest(unittest.TestCase):
    """en 模式: 状态词映射 (label/key 保持中文协议常量) 与主题行/正文模板渲染。"""

    def setUp(self):
        self._old_lang = mail._LANG
        self._old_tab = (mail._I18N_TABLE, mail._I18N_TABLE_LOADED)
        mail.set_lang("en")
        # 注入最小翻译表: 真实表仅在安装布局 <pkg>/i18n/ 下存在; 源码树缺失/缺
        # key 时 _() 回退中文原文 (与 R 侧 tr_ 语义一致), 故注入以保证断言确定
        mail._I18N_TABLE = {
            "【DIA-NN GUI】%s (Job %s) 分析%s": "[DIA-NN GUI] %s (Job %s) analysis %s",
            "DIA-NN 分析%s": "DIA-NN analysis %s",
        }
        mail._I18N_TABLE_LOADED = True

    def tearDown(self):
        mail.set_lang(self._old_lang)
        mail._I18N_TABLE, mail._I18N_TABLE_LOADED = self._old_tab

    def test_status_words_en_map(self):
        # label (协议常量) 不译; word 值经内置 STATUS_WORDS_EN; "完成"→"completed"
        self.assertEqual(mail.status_view(ns(status_label="成功")), ("✅", "Success", "成功", True))
        self.assertEqual(mail.status_view(ns(status_label="失败"))[1], "Failed")
        self.assertEqual(mail.status_view(ns(status_label="未知"))[1], "Unknown")
        self.assertEqual(mail.status_view(ns(status_label="超时"))[1], "Timed out")
        self.assertEqual(mail.status_view(ns(rc=0))[1], "completed")
        self.assertEqual(mail.status_view(ns(rc=2))[1], "Failed")
        # 判定比较不受语言影响
        self.assertTrue(mail.status_view(ns(status_label="成功"))[3])
        self.assertFalse(mail.status_view(ns(status_label="已取消"))[3])

    def test_subject_and_h2_en_rendering(self):
        self.assertEqual(mail.build_subject("T1", "7", "completed"),
                         "[DIA-NN GUI] T1 (Job 7) analysis completed")
        html = mail.build_html(ns(status_label="成功", task="T1", job_id="7",
                                  elapsed=60, diann_ver="2.10.0"),
                               [], [], {}, "")
        self.assertIn("DIA-NN analysis Success", html)  # label 成功 → STATUS_WORDS_EN
        # 注入表未收录的 key 回退中文原文 (与 R 侧 tr_ 语义一致)
        self.assertIn("任务名称", html)
        # rc 回退路径: word 完成经 STATUS_WORDS_EN 映射为 "completed"
        html_rc = mail.build_html(ns(rc=0, diann_ver=""), [], [], {}, "")
        self.assertIn("DIA-NN analysis completed", html_rc)

    def test_fallback_to_zh_without_table(self):
        mail._I18N_TABLE, mail._I18N_TABLE_LOADED = None, True
        self.assertEqual(mail._("任务名称"), "任务名称")
        self.assertEqual(mail.build_subject("T", "1", "completed"),
                         "【DIA-NN GUI】T (Job 1) 分析completed")


class StartTlsTest(unittest.TestCase):
    def test_starttls_failure_refuses_plaintext(self):
        class FakeSMTP:
            instance = None

            def __init__(self, *a, **k):
                FakeSMTP.instance = self
                self.logged = False
                self.sent = False

            def starttls(self):
                raise smtplib.SMTPException("no starttls")

            def login(self, *a):
                self.logged = True

            def sendmail(self, *a):
                self.sent = True

            def quit(self):
                pass

        cfg = {"smtp_host": "h", "smtp_port": 587, "smtp_user": "u", "smtp_pass": "p",
               "mail_from": "u"}
        old = mail.smtplib.SMTP
        mail.smtplib.SMTP = FakeSMTP
        try:
            with self.assertRaises(smtplib.SMTPException):
                mail.smtp_send(cfg, ["a@b.c"], "subject", "<b>x</b>")
            self.assertFalse(FakeSMTP.instance.logged)
            self.assertFalse(FakeSMTP.instance.sent)
        finally:
            mail.smtplib.SMTP = old


if __name__ == "__main__":
    unittest.main()
