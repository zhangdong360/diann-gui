#!/usr/bin/env python3
"""合成标识白名单扫描 (CI 闸门): 防止真实集群路径/命名再次入库。

只编码"允许出现的合成值", 不编码任何真实标识——本文件本身会进入公开仓库。
规则:
  1. 全部跟踪文件中, /share/home/<name> 只允许 /share/home/demo;
  2. Windows 盘符路径只允许 C:\\ I:\\ M:\\ (测试用的合成示例);
  3. tests/fixtures/ 内的 .raw/.fasta/.speclib 基名必须在合成白名单内。
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

HOME_ROOT_RE = re.compile(r"/share/home/[A-Za-z0-9_.-]+")
WIN_RE = re.compile(r"\b([A-Z]):\\[A-Za-z0-9_.\\-]+")
ALLOWED_HOME = {"/share/home/demo"}
ALLOWED_DRIVES = {"C", "I", "M"}
RAW_OK = re.compile(r"^demo_sample_\d{3}\.raw$")
FASTA_OK = {
    "human_proteome.fasta", "human_proteome_reviewed.fasta",
    "mouse_proteome_reviewed.fasta", "cRAP_contaminants.fasta",
}
SPECLIB_OK = {"demo_library.predicted.speclib", "library.speclib"}

violations = []


def check(fname, text):
    for m in set(HOME_ROOT_RE.findall(text)):
        if m not in ALLOWED_HOME:
            violations.append(f"{fname}: 非白名单根路径 {m}")
    for m in WIN_RE.finditer(text):
        if m.group(1) not in ALLOWED_DRIVES:
            violations.append(f"{fname}: 非白名单盘符 {m.group(0)[:40]}")
    if Path(fname).parts[:2] == ("tests", "fixtures"):
        for m in re.finditer(r"\b[A-Za-z0-9_]+\.[Rr]aw\b", text):
            if not RAW_OK.match(m.group(0)):
                violations.append(f"{fname}: 非白名单样本名 {m.group(0)}")
        for m in re.finditer(r"\b[A-Za-z0-9_.]+\.fasta\b", text):
            if m.group(0) not in FASTA_OK:
                violations.append(f"{fname}: 非白名单 FASTA 名 {m.group(0)}")
        for m in re.finditer(r"\b[A-Za-z0-9_.]+\.speclib\b", text):
            if m.group(0) not in SPECLIB_OK:
                violations.append(f"{fname}: 非白名单谱库名 {m.group(0)}")


def main():
    files = subprocess.run(
        ["git", "ls-files", "-z"], cwd=ROOT, capture_output=True, check=True
    ).stdout.decode().split("\0")
    files = [f for f in files if f]
    for f in files:
        p = ROOT / f
        if not p.is_file():
            continue
        try:
            text = p.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        check(f, text)
    if violations:
        print("发现非合成标识 (真实路径/命名疑似入库):")
        for v in violations:
            print(" ", v)
        sys.exit(1)
    print(f"合成标识白名单扫描通过 ({len(files)} 个跟踪文件)")


if __name__ == "__main__":
    main()
