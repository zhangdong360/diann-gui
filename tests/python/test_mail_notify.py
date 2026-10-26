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
