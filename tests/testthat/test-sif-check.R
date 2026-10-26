# v1.13 SIF: 扫描全部 *.sif (文件名无关) + 容器识别 + probe 缓存 + 数值版本排序。
# 硬约束: 2.10.0 必须排在 2.9.1 之前、默认选中 2.10.0 (v1.11 B9 事故回归);
# 严禁字符串排序 / as.numeric(numeric_version) (2.10.0 会塌缩成 2.1)。

mk_fake_sif <- function(path, magic = TRUE) {
  hdr <- charToRaw("#!/usr/bin/env run-singularity\n")
  pad <- as.raw(rep(0, 32 - length(hdr)))
  writeBin(c(hdr, pad,
             if (magic) charToRaw("SIF_MAGIC") else charToRaw("NOT_SIF_!"),
             as.raw(rep(0xAA, 1024))), path)
  path
}

test_that("sif_check_local: 静态校验 (v1.13 起无 ver_from_name)", {
  r <- sif_check_local("")
  expect_false(r$exists); expect_false(r$readable); expect_false(r$sif_magic)
  expect_null(r$ver_from_name)
  expect_equal(sif_check_local(NULL)$exists, FALSE)
  r2 <- sif_check_local("/nonexistent/diann-9.9.9.sif")
  expect_false(r2$exists); expect_true(is.na(r2$readable))
  f <- mk_fake_sif(file.path(tempdir(), "image.sif"))       # 任意文件名
  r3 <- sif_check_local(f)
  expect_true(r3$exists); expect_true(r3$readable); expect_true(r3$sif_magic)
  f2 <- mk_fake_sif(file.path(tempdir(), "bad.sif"), magic = FALSE)
  expect_false(sif_check_local(f2)$sif_magic)
})

test_that("扫描: 任意文件名的 .sif 全部可见, 不按版本去重", {
  d <- file.path(tempdir(), sprintf("sifscan_%d_%d", Sys.getpid(), as.integer(runif(1, 1, 1e9))))
  dir.create(d, showWarnings = FALSE)
  for (nm in c("image.sif", "diann_latest.sif", "diann-2.7.0.sif", "UPPER.SIF", "notes.txt"))
    file.create(file.path(d, nm))
  df <- scan_sif_images(d)
  expect_equal(sort(df$name), sort(c("image.sif", "diann_latest.sif", "diann-2.7.0.sif", "UPPER.SIF")))
  expect_true(all(c("size", "mtime") %in% names(df)))
  expect_false(any(grepl("notes", df$name, fixed = TRUE)))
})

test_that("parse_diann_version", {
  expect_equal(parse_diann_version("DIA-NN 2.7.0 Academia, build Jan 12 2025"), "2.7.0")
  expect_equal(parse_diann_version(c("", "DIA-NN 2.10.0 Academia")), "2.10.0")
  expect_equal(parse_diann_version("diann-linux: no such file"), "")
  expect_equal(parse_diann_version(""), "")
  expect_equal(parse_diann_version(NULL), "")
})

# 假 apptainer: exec <sif> diann-linux --version 输出版本横幅
mk_runner <- function(out = "DIA-NN 2.7.0 Academia, build x", err = FALSE) {
  function(bin, args, timeout = 30) {
    if (length(args) >= 1 && identical(args[1], "inspect")) {
      if (err) stop("boom") else
        c("org.label-schema.usage.singularity.deffile.from: docker://ubuntu:22.04", "")
    } else {
      if (err) stop("exec failed") else c(out, "")
    }
  }
}

fake_ap <- local({
  p <- file.path(tempdir(), sprintf("fake_apptainer_%d", Sys.getpid()))
  writeLines("#!/bin/sh", p); Sys.chmod(p, "0755"); p
})

test_that("sif_identify: 成功/静态失败/无运行时/超时/无 diann-linux", {
  f <- mk_fake_sif(file.path(tempdir(), "any_name.sif"))
  ok <- sif_identify(f, fake_ap, runner = mk_runner())
  expect_true(ok$ok); expect_equal(ok$version, "2.7.0"); expect_equal(ok$reason, "")
  expect_match(ok$message, "2.7.0")

  expect_false(sif_identify("/no/such.sif", fake_ap, runner = mk_runner())$ok)
  bad <- mk_fake_sif(file.path(tempdir(), "notsif.sif"), magic = FALSE)
  r <- sif_identify(bad, fake_ap, runner = mk_runner())
  expect_false(r$ok); expect_equal(r$reason, "not_sif")

  r2 <- sif_identify(f, "", runner = mk_runner())
  expect_false(r2$ok); expect_equal(r2$reason, "no_apptainer")

  r3 <- sif_identify(f, fake_ap, runner = mk_runner(out = "command timed out"))
  expect_false(r3$ok); expect_equal(r3$reason, "timeout")

  r4 <- sif_identify(f, fake_ap,
                     runner = mk_runner(out = "exec: diann-linux: not found"))
  expect_false(r4$ok); expect_equal(r4$reason, "no_diann_linux")

  r5 <- sif_identify(f, fake_ap, runner = mk_runner(out = "Segmentation fault"))
  expect_false(r5$ok); expect_equal(r5$reason, "no_version")
})

test_that("probe 缓存: size+mtime 命中、变化失效、no_apptainer 不落缓存、损坏不崩", {
  f <- mk_fake_sif(file.path(tempdir(), "cache_me.sif"))
  fi <- file.info(f)
  probe <- sif_probe_record(list(entries = list(), version = 1L), f,
                            unname(fi$size), as.numeric(fi$mtime),
                            ver = "2.7.0", ok = TRUE, message = "ok", reason = "")
  expect_equal(sif_probe_lookup(probe, f, unname(fi$size), as.numeric(fi$mtime))$ver, "2.7.0")
  # 文件变化 (mtime/size 不同) → 缓存失效
  expect_null(sif_probe_lookup(probe, f, unname(fi$size) + 1, as.numeric(fi$mtime)))
  expect_null(sif_probe_lookup(probe, f, unname(fi$size), as.numeric(fi$mtime) + 5))
  # 失败也缓存 (可显示"上次失败"), 但 no_apptainer 不落缓存
  f2 <- "/other/img.sif"
  p2 <- sif_probe_record(probe, f2, 1, 1, ok = FALSE, message = "bad image", reason = "not_sif")
  expect_false(is.null(p2$entries[[f2]]))
  expect_equal(p2$entries[[f]]$ver, "2.7.0")     # 原成功条目不受影响
  p3 <- sif_probe_record(probe, f2, 1, 1, ok = FALSE, message = "no apt", reason = "no_apptainer")
  expect_identical(p3, probe)                    # no_apptainer 完全不落缓存
  # 保存/加载往返 + 损坏回退
  tf <- file.path(tempdir(), sprintf("probe_%d.rds", Sys.getpid()))
  expect_true(sif_probe_save(p2, tf))
  expect_equal(sif_probe_load(tf)$entries[[f]]$ver, "2.7.0")
  writeLines("not an rds", tf)
  expect_identical(sif_probe_load(tf)$entries, list())
})

test_that("合并排序: 已识别按数值版本降序, 未识别最后; 2.10.0 在 2.9.1 之前", {
  # 直接构造 (不经文件系统, 聚焦排序)
  scan <- data.frame(
    path = c("/x/diann-2.9.1.sif", "/x/diann-2.10.0.sif", "/x/aaa.sif", "/x/zzz.sif"),
    name = c("diann-2.9.1.sif", "diann-2.10.0.sif", "aaa.sif", "zzz.sif"),
    size = c(1, 1, 1, 1), mtime = c(1, 1, 1, 1), stringsAsFactors = FALSE)
  probe <- list(entries = list(), version = 1L)
  probe <- sif_probe_record(probe, "/x/diann-2.9.1.sif", 1, 1, ver = "2.9.1", ok = TRUE, message = "ok")
  probe <- sif_probe_record(probe, "/x/diann-2.10.0.sif", 1, 1, ver = "2.10.0", ok = TRUE, message = "ok")
  merged <- sif_merge_probe(scan, probe)
  expect_equal(merged$verified, c(TRUE, TRUE, FALSE, FALSE))
  expect_equal(merged$ver[1], "2.10.0")          # 数值最高在前 (字符串排序会给出 2.9.1)
  expect_equal(merged$ver[2], "2.9.1")
  expect_equal(merged$path[3:4], c("/x/aaa.sif", "/x/zzz.sif"))  # 未识别按路径
  labels <- sif_choice_labels(merged)
  expect_match(names(labels)[1], "^v2\\.10\\.0 ·")
  expect_match(names(labels)[3], "^未识别 ·")
  expect_equal(unname(labels)[1], "/x/diann-2.10.0.sif")
  # 默认选中: 无 DEFAULT_SIF → 已识别最高数值版本
  expect_equal(merged$path[sif_default_index(merged, NULL)], "/x/diann-2.10.0.sif")
  # DEFAULT_SIF 命中优先 (即使未识别)
  expect_equal(merged$path[sif_default_index(merged, "/x/zzz.sif")], "/x/zzz.sif")
  # 全部未识别 → 首个路径
  sub_df <- merged[-c(1, 2), ]
  expect_equal(sub_df$path[sif_default_index(sub_df, NULL)], "/x/aaa.sif")
})

test_that("sif_version_key / sif_ver_sort_string: 非法版本归未知且不崩", {
  expect_false(is.na(sif_version_key("2.10.0")))
  expect_true(is.na(sif_version_key("latest")))
  expect_true(is.na(sif_version_key("")))
  expect_true(sif_version_key("2.10.0") > sif_version_key("2.9.1"))
  expect_equal(sif_ver_sort_string(c("2.10.0", "latest", NA_character_))[2:3], c("~", "~"))
  expect_true(sif_ver_sort_string("2.10.0") > sif_ver_sort_string("2.9.1"))
})

test_that("端到端排序 (磁盘): 后创建的 2.10 默认选中, 不受创建顺序影响", {
  d <- file.path(tempdir(), sprintf("sife2e_%d", as.integer(runif(1, 1, 1e9))))
  dir.create(d, showWarnings = FALSE)
  for (v in c("2.3.2", "2.7.0", "2.10.0", "2.9.1")) mk_fake_sif(file.path(d, sprintf("diann-%s.sif", v)))
  scan <- scan_sif_images(d)
  probe <- list(entries = list(), version = 1L)
  for (i in seq_len(nrow(scan))) probe <- sif_probe_record(
    probe, scan$path[i], scan$size[i], scan$mtime[i],
    ver = sub("\\.sif$", "", sub("^diann-", "", scan$name[i])), ok = TRUE, message = "ok")
  merged <- sif_merge_probe(scan, probe)
  expect_equal(merged$ver, c("2.10.0", "2.9.1", "2.7.0", "2.3.2"))
  expect_equal(basename(merged$path[sif_default_index(merged, NULL)]), "diann-2.10.0.sif")
  expect_equal(sum(merged$verified), 4L)
})

test_that("sif_version_of: 命中缓存返回版本, 否则空", {
  f <- mk_fake_sif(file.path(tempdir(), "ver_of.sif"))
  expect_equal(sif_version_of(f, probe = list(entries = list(), version = 1L)), "")
  fi <- file.info(f)
  probe <- sif_probe_record(list(entries = list(), version = 1L), f,
                            unname(fi$size), as.numeric(fi$mtime),
                            ver = "2.3.1", ok = TRUE, message = "ok")
  expect_equal(sif_version_of(f, probe = probe), "2.3.1")
  expect_equal(sif_version_of("/no/such.sif"), "")
})
