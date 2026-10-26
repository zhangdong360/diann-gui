#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
DIANN GUI 作业完成邮件通知助手。

由生成的 sbatch 脚本在 DIA-NN 结束后调用（也可手动运行）：
  python3 mail_notify.py --config /path/mail_config.txt \
      --to "a@x.com, b@y.com" --job-id 17523 --task DIANN_Task \
      --rc 0 --out-dir /path/result --out-file /path/result/report.tsv \
      --script /path/diann_xxx.sh --desc-file /path/diann_xxx_desc.txt \
      --elapsed 3600 --sif /path/diann-2.6.1.sif \
      [--state COMPLETED --status-label 成功 --status-reason "调度完成且产物为新"]

状态参数 (--state/--status-label/--status-reason) 来自 GUI 的四层状态合成
(Slurm 终态 → 程序退出码 → 产物验证 → 展示合成)；给出 --status-label 时邮件按其
渲染 成功/失败/待核实/超时/已取消/未知, 否则退回旧的退出码判定 (--rc == 0)。

自测（真实发一封测试邮件）:
  python3 mail_notify.py --self-test --config mail_config.txt --to me@126.com
连通性检查（只连 SMTP 不登录不发信，用于验证计算节点出网）:
  python3 mail_notify.py --check --config mail_config.txt

约定：作为作业的一部分运行时，任何失败都只打 WARNING、以 0 退出，绝不影响作业状态。
"""
import argparse
import html
import os
import re
import smtplib
import socket
import sys
import time
from email.header import Header
from email.mime.text import MIMEText
from email.utils import formataddr

DEFAULT_CONFIG = os.path.join(os.path.expanduser("~"), ".diann_gui", "mail_config.txt")


def load_config(path):
    cfg = {}
    if not os.path.isfile(path):
        return None
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip()
    if not cfg.get("smtp_host") or not cfg.get("smtp_user") or not cfg.get("smtp_pass"):
        return None
    try:
        cfg["smtp_port"] = int(cfg.get("smtp_port", "465"))
    except ValueError:
        cfg["smtp_port"] = 465
    cfg.setdefault("mail_from", cfg["smtp_user"])
    return cfg


def human_size(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return "%.1f %s" % (n, unit) if unit != "B" else "%d B" % n
        n /= 1024.0


def fmt_elapsed(sec):
    if sec is None:
        return None
    sec = int(sec or 0)
    if sec < 60:
        return "%d 秒" % sec
    h, rem = divmod(sec, 3600)
    if h:
        return "%d 时 %d 分 %d 秒" % (h, rem // 60, rem % 60)
    return "%d 分 %d 秒" % (sec // 60, sec % 60)


def count_lines(path, cap_mb=200):
    """返回 (数据行数, 总行数)；DIA-NN 输出首行为表头。文件过大或不可读返回 (None, None)。"""
    try:
        if os.path.getsize(path) > cap_mb * 1024 * 1024:
            return None, None
        n = 0
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for _ in fh:
                n += 1
        return max(n - 1, 0), n
    except OSError:
        return None, None


def summarize_out_dir(out_dir, report_path=None, max_files=25):
    """返回 (文件行HTML列表, 指标行HTML列表)。

    report_path 是 GUI 的主报告路径 (报告名用户可自定义, 由 --out-file 传入);
    未提供或不存在时才回退到 report.tsv。
    """
    rows, metrics = [], []
    try:
        entries = [e for e in os.scandir(out_dir) if e.is_file()]
    except OSError as e:
        return ["<li>无法读取输出目录: %s</li>" % html.escape(str(e))], metrics
    entries.sort(key=lambda e: -e.stat().st_size)
    total = sum(e.stat().st_size for e in entries)
    metrics.append("输出目录共 %d 个文件, 合计 %s" % (len(entries), human_size(total)))
    for e in entries[:max_files]:
        rows.append("<li><code>%s</code> — %s</li>" % (html.escape(e.name), human_size(e.stat().st_size)))
    if len(entries) > max_files:
        rows.append("<li>… 其余 %d 个文件从略</li>" % (len(entries) - max_files))
    # 关键结果指标: 主报告行数
    candidates = []
    if report_path:
        candidates.append(report_path)
    candidates.append(os.path.join(out_dir, "report.tsv"))
    for p in candidates:
        if not p or not os.path.isfile(p):
            continue
        data_rows, _ = count_lines(p)
        if data_rows is not None:
            metrics.append("<b>%s</b> 数据行数: %d (前体/蛋白组识别)"
                           % (html.escape(os.path.basename(p)), data_rows))
        break
    try:
        for e in entries:
            if "matrix" in e.name.lower() and e.name.lower().endswith((".csv", ".tsv")):
                data_rows, _ = count_lines(e.path)
                if data_rows is not None:
                    metrics.append("<b>%s</b> 行数: %d" % (html.escape(e.name), data_rows))
    except OSError:
        pass
    return rows, metrics


INPUT_RE = {
    "RAW 文件": re.compile(r"--f '([^']+)'"),
    "FASTA": re.compile(r"--fasta '([^']+)'"),
    "光谱库": re.compile(r"--lib '([^']+)'"),
}


def extract_inputs(script_path):
    """从生成的 sbatch 脚本里提取输入文件列表 (--f/--fasta/--lib)。"""
    found = {}
    try:
        with open(script_path, "r", encoding="utf-8", errors="replace") as fh:
            txt = fh.read()
    except OSError:
        return found
    for label, rx in INPUT_RE.items():
        hits = rx.findall(txt)
        if hits:
            found[label] = hits
    return found


HTML_TMPL = """\
<html><body style="font-family:'Microsoft YaHei',Arial,sans-serif;color:#333;">
<h2 style="margin-bottom:4px;">{status_icon} DIA-NN 分析{status_word}</h2>
<p style="color:#888;margin-top:0;">本邮件由实验室 DIA-NN GUI 自动发送, 请勿回复。</p>
<table border="1" cellpadding="6" cellspacing="0" style="border-collapse:collapse;font-size:14px;">
<tr><td style="background:#f5f5f5;"><b>任务名称</b></td><td>{task}</td></tr>
<tr><td style="background:#f5f5f5;"><b>Slurm JobID</b></td><td>{job_id}</td></tr>
<tr><td style="background:#f5f5f5;"><b>作业状态</b></td><td>{status_line}</td></tr>
{elapsed_row}
<tr><td style="background:#f5f5f5;"><b>DIA-NN 版本</b></td><td>{diann_ver}</td></tr>
{inputs_rows}
<tr><td style="background:#f5f5f5;"><b>输出目录</b></td><td><code>{out_dir}</code></td></tr>
</table>

<h3>📋 项目简介</h3>
<div style="background:#f8f9fa;border-left:4px solid #3c763d;padding:8px 12px;white-space:pre-wrap;">{project_desc}</div>

<h3>📊 结果简介</h3>
<ul style="margin-top:0;">{metrics}</ul>
<ul style="color:#555;">{files}</ul>
<p>结果文件请登录集群在输出目录中查看/下载。</p>
</body></html>
"""


def status_view(a):
    """返回 (icon, word, status_line, ok)。

    有 --status-label 时按四层合成结果渲染; 否则退回退出码判定 (兼容手动调用)。
    """
    label = a.status_label
    if label:
        detail = []
        if a.status_reason:
            detail.append(a.status_reason)
        if a.rc is not None:
            detail.append("程序退出码 %d" % a.rc)
        if a.state:
            detail.append("调度状态 %s" % a.state)
        line = label if not detail else "%s: %s" % (label, "; ".join(detail))
        icons = {"成功": "✅", "失败": "❌", "待核实": "⚠️", "超时": "⏱️", "已取消": "🚫", "未知": "❓"}
        words = {"成功": "完成", "失败": "失败", "待核实": "待核实",
                 "超时": "超时", "已取消": "已取消", "未知": "状态未知"}
        return icons.get(label, "❓"), words.get(label, label), line, label == "成功"
    ok = a.rc is not None and a.rc == 0
    if ok:
        return "✅", "完成", "正常结束, 退出码 0", True
    return "❌", "失败", "失败, 退出码 %s" % (a.rc if a.rc is not None else "未知(日志缺失)"), False


def build_html(a, out_files_html, metrics_html, inputs, project_desc):
    inputs_rows = []
    for label in ("RAW 文件", "FASTA", "光谱库"):
        if label in inputs:
            items = inputs[label]
            shown = "".join("<div><code>%s</code></div>" % html.escape(i) for i in items[:12])
            if len(items) > 12:
                shown += "<div>… 共 %d 个</div>" % len(items)
            inputs_rows.append('<tr><td style="background:#f5f5f5;"><b>%s</b></td><td>%s</td></tr>'
                               % (label, shown))
    icon, word, status_line, _ok = status_view(a)
    return HTML_TMPL.format(
        status_icon=icon,
        status_word=word,
        task=html.escape(str(a.task or "-")),
        job_id=html.escape(str(a.job_id or "-")),
        status_line=html.escape(status_line),
        elapsed_row=("" if a.elapsed is None else
                     '<tr><td style="background:#f5f5f5;"><b>耗时</b></td><td>%s</td></tr>'
                     % fmt_elapsed(a.elapsed)),
        diann_ver=html.escape(os.path.basename(a.sif)) if a.sif else "-",
        inputs_rows="".join(inputs_rows),
        out_dir=html.escape(str(a.out_dir or "-")),
        project_desc=html.escape(project_desc or "(未填写)"),
        metrics="".join("<li>%s</li>" % m for m in metrics_html) or "<li>(无)</li>",
        files="".join(out_files_html),
    )


def smtp_send(cfg, to_list, subject, html, timeout=30):
    msg = MIMEText(html, "html", "utf-8")
    msg["Subject"] = Header(subject, "utf-8")
    msg["From"] = formataddr((Header("DIA-NN GUI", "utf-8").encode(), cfg["mail_from"]))
    msg["To"] = ", ".join(to_list)
    if cfg["smtp_port"] == 465:
        smtp = smtplib.SMTP_SSL(cfg["smtp_host"], cfg["smtp_port"], timeout=timeout)
    else:
        smtp = smtplib.SMTP(cfg["smtp_host"], cfg["smtp_port"], timeout=timeout)
        try:
            smtp.starttls()
        except smtplib.SMTPException as e:
            # 不回退明文: 否则用户名/授权码会以明文（或可降级连接）发出
            try:
                smtp.quit()
            except Exception:
                pass
            raise smtplib.SMTPException("STARTTLS 不可用, 拒绝以明文发送凭据: %s" % e)
    try:
        smtp.login(cfg["smtp_user"], cfg["smtp_pass"])
        smtp.sendmail(cfg["mail_from"], to_list, msg.as_string())
    finally:
        try:
            smtp.quit()
        except Exception:
            pass


def main():
    ap = argparse.ArgumentParser(description="DIA-NN GUI 作业邮件通知")
    ap.add_argument("--config", default=DEFAULT_CONFIG)
    ap.add_argument("--to", default="", help="收件人, 逗号分隔")
    ap.add_argument("--job-id", default="")
    ap.add_argument("--task", default="")
    ap.add_argument("--rc", type=int, default=None, help="作业最终退出码")
    ap.add_argument("--state", default=None, help="Slurm 终态 (如 COMPLETED/FAILED/TIMEOUT)")
    ap.add_argument("--status-label", default=None,
                    help="四层状态合成标签 (成功/失败/待核实/未知/超时/已取消)")
    ap.add_argument("--status-reason", default=None, help="状态标签的判定原因")
    ap.add_argument("--out-dir", default="")
    ap.add_argument("--out-file", default="")
    ap.add_argument("--script", default="", help="生成的 sbatch 脚本路径, 用于提取输入文件")
    ap.add_argument("--desc-file", default="", help="项目简介文本文件")
    ap.add_argument("--elapsed", type=int, default=None,
                    help="运行秒数 (未知时邮件省略耗时行)")
    ap.add_argument("--sif", default="")
    ap.add_argument("--self-test", action="store_true", help="发一封简单测试邮件")
    ap.add_argument("--check", action="store_true", help="只测 SMTP 连通性, 不登录不发信")
    ap.add_argument("--strict", action="store_true", help="发送失败时以非零退出码结束 (供轮询方记录)")
    a = ap.parse_args()

    cfg = load_config(a.config)
    if a.check:
        if not cfg:
            print("CHECK FAIL: 配置不可用: %s" % a.config)
            return 1
        try:
            if cfg["smtp_port"] == 465:
                s = smtplib.SMTP_SSL(cfg["smtp_host"], cfg["smtp_port"], timeout=15)
            else:
                s = smtplib.SMTP(cfg["smtp_host"], cfg["smtp_port"], timeout=15)
            banner = s.noop()
            s.quit()
            print("CHECK OK: %s:%s 可达 (%s)" % (cfg["smtp_host"], cfg["smtp_port"], banner))
            return 0
        except (OSError, smtplib.SMTPException) as e:
            print("CHECK FAIL: %s:%s 不可达: %s" % (cfg["smtp_host"], cfg["smtp_port"], e))
            return 1

    to_list = [x.strip() for x in re.split(r"[,;\s]+", a.to or "") if "@" in x]
    if not to_list:
        print("MAIL SKIPPED: 未提供收件人")
        return 1 if a.strict else 0
    if not cfg:
        print("MAIL SKIPPED: 邮件配置不可用 (%s), 请参考 mail_config.example.txt" % a.config)
        return 1 if a.strict else 0

    if a.self_test:
        html = ("<html><body><h3>✅ DIA-NN GUI 邮件通知自测成功</h3>"
                "<p>SMTP 账号 <code>%s</code> 配置正确, 通道可用。</p></body></html>" % cfg["smtp_user"])
        subject = "【DIA-NN GUI】邮件通知自测"
    else:
        project_desc = ""
        if a.desc_file and os.path.isfile(a.desc_file):
            try:
                with open(a.desc_file, "r", encoding="utf-8", errors="replace") as fh:
                    project_desc = fh.read().strip() or "(未填写)"
            except OSError:
                project_desc = "(简介文件不可读)"
        out_files_html, metrics_html = (summarize_out_dir(a.out_dir, a.out_file) if a.out_dir else ([], []))
        html = build_html(a, out_files_html, metrics_html, extract_inputs(a.script), project_desc)
        _icon, word, _line, _ok = status_view(a)
        subject = "【DIA-NN GUI】%s (Job %s) 分析%s" % (
            a.task or "任务", a.job_id or "?", word)

    try:
        smtp_send(cfg, to_list, subject, html)
        print("MAIL SENT: %s -> %s" % (subject, ", ".join(to_list)))
        return 0
    except (OSError, smtplib.SMTPException) as e:
        if a.self_test:
            print("SELF-TEST FAIL: %s" % e)
            return 1
        print("WARNING: 邮件通知发送失败 (不影响作业): %s" % e)
        return 1 if a.strict else 0


if __name__ == "__main__":
    sys.exit(main())
