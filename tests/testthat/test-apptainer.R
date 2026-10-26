# apptainer 运行环境: 版本解析 / 候选发现 / 缓存 / 手动校验 / 脚本注入
# 全部用假二进制 (#!/bin/sh 打印版本), 不依赖真实 apptainer —— 本集群登录节点没有。

mk_fake_bin <- function(dir, name, version_line = "apptainer version 1.4.5", status = 0L) {
  dir.create(dir, showWarnings = FALSE, recursive = TRUE)
  p <- file.path(dir, name)
  writeLines(c("#!/bin/sh", sprintf("echo '%s'", version_line), sprintf("exit %d", status)), p)
  Sys.chmod(p, "0755")
  p
}
apt_tmpdir <- function(tag) {
  file.path(tempdir(), sprintf("%s_%d_%d", tag, Sys.getpid(), as.integer(runif(1, 1, 1e9))))
}

test_that("版本解析: apptainer/singularity/带发行版后缀/无法解析", {
  expect_equal(apptainer_parse_version("apptainer version 1.4.5"),
               list(kind = "apptainer", version = "1.4.5"))
  expect_equal(apptainer_parse_version("singularity version 3.11.4"),
               list(kind = "singularity", version = "3.11.4"))
  expect_equal(apptainer_parse_version("apptainer version 1.3.6-1.el8")$version, "1.3.6")
  expect_equal(apptainer_parse_version("Apptainer version 1.1.0")$kind, "apptainer")
  expect_null(apptainer_parse_version("no version here"))
  expect_null(apptainer_parse_version(""))
  expect_null(apptainer_parse_version(NULL))
})

test_that("apptainer_check: 空/相对/不存在/目录/不可执行/包装脚本", {
  expect_false(apptainer_check("")$ok)
  expect_match(apptainer_check("apptainer")$message, "绝对路径")
  expect_false(apptainer_check("/nonexistent/apptainer")$ok)
  expect_false(apptainer_check(tempdir())$ok)  # 目录里通常没有 apptainer

  d <- apt_tmpdir("aptcheck")
  p <- mk_fake_bin(d, "apptainer", "apptainer version 1.4.5")
  r <- apptainer_check(p)
  expect_true(r$ok)
  expect_equal(r$version, "1.4.5")
  expect_equal(r$kind, "apptainer")
  expect_equal(r$path, p)

  # 目录输入自动解析为 <dir>/apptainer
  expect_equal(apptainer_check(d)$path, p)

  # 包装脚本名不是 apptainer, 但能打印版本 -> 视为可用
  w <- mk_fake_bin(d, "my-wrapper", "apptainer version 1.2.3")
  expect_true(apptainer_check(w)$ok)

  # 不可执行
  nx <- file.path(d, "apptainer-noexec")
  writeLines("#!/bin/sh", nx)
  Sys.chmod(nx, "0644")
  expect_false(apptainer_check(nx)$ok)

  # --version 打不出可识别版本
  bad <- mk_fake_bin(d, "apptainer-bad", "segfault?", status = 1L)
  expect_false(apptainer_check(bad)$ok)
})

test_that("候选发现: 版本解析 + apptainer 排在前 + 去重", {
  d <- apt_tmpdir("aptcand")
  a <- mk_fake_bin(d, "apptainer", "apptainer version 1.4.5")
  s <- mk_fake_bin(d, "singularity", "singularity version 3.11.4")
  # 同目录同名符号链接: 按 realpath 去重
  link <- file.path(d, "apptainer-link")
  file.symlink(a, link)

  cands <- apptainer_candidates(refresh = TRUE, cache_file = tempfile(),
                                extra_dirs = d, search_dirs = d)
  sub <- cands[startsWith(cands$path, d), , drop = FALSE]
  expect_equal(nrow(sub), 2L)
  expect_equal(sub$kind, c("apptainer", "singularity"))
  expect_equal(sub$version, c("1.4.5", "3.11.4"))
  expect_true(all(sub$ok))
  # 排序: apptainer 优先
  expect_equal(cands$kind[1], "apptainer")
  # 符号链接与目标同 realpath -> 不重复列出
  expect_false(any(grepl("apptainer-link", cands$path, fixed = TRUE)))
})

test_that("候选缓存: 命中不重复探测, 版本变化/TTL 到期才重探", {
  d <- apt_tmpdir("aptcache")
  a <- mk_fake_bin(d, "apptainer", "apptainer version 1.4.5")
  mk_fake_bin(d, "singularity", "singularity version 3.11.4")
  cache <- tempfile("aptcache_")
  count <- 0L
  runner <- function(bin, args, timeout) {
    count <<- count + 1L
    system2(bin, args, stdout = TRUE, stderr = TRUE)
  }
  init <- function(now) {
    apptainer_candidates(refresh = TRUE, cache_file = cache, extra_dirs = d,
                         search_dirs = d, runner = runner, now = now)
  }
  init(1000); expect_equal(count, 2L)
  apptainer_candidates(cache_file = cache, extra_dirs = d, search_dirs = d,
                       runner = runner, now = 2000)
  expect_equal(count, 2L)  # 缓存命中
  # mtime 变化 -> 失效
  Sys.setFileTime(a, Sys.time() + 10)
  apptainer_candidates(cache_file = cache, extra_dirs = d, search_dirs = d,
                       runner = runner, now = 3000)
  expect_equal(count, 4L)
  # TTL 到期 -> 失效
  apptainer_candidates(cache_file = cache, extra_dirs = d, search_dirs = d,
                       runner = runner, now = 3000 + 86400 + 1)
  expect_equal(count, 6L)
})

test_that("候选项标签与默认选择 (DEFAULT_APPTAINER 优先, 否则最高版本)", {
  d <- apt_tmpdir("aptdef")
  a <- mk_fake_bin(d, "apptainer", "apptainer version 1.4.5")
  s <- mk_fake_bin(d, "singularity", "singularity version 9.9.9")
  cands <- apptainer_candidates(refresh = TRUE, cache_file = tempfile(),
                                extra_dirs = d, search_dirs = d)
  sub <- cands[startsWith(cands$path, d), , drop = FALSE]
  ch <- apptainer_choices(sub)
  expect_length(ch, 2L)
  expect_true(any(grepl("apptainer 1.4.5", names(ch), fixed = TRUE)))
  expect_true(any(grepl("singularity 9.9.9", names(ch), fixed = TRUE)))
  # 默认: apptainer 类优先于更高版本的 singularity
  expect_equal(unname(apptainer_default(sub)), a)
  # 显式 DEFAULT_APPTAINER 覆盖
  old <- diann.gui::cfg_get("DEFAULT_APPTAINER")
  on.exit(diann.gui::set_core_const("DEFAULT_APPTAINER", old), add = TRUE)
  diann.gui::set_core_const("DEFAULT_APPTAINER", s)
  expect_equal(unname(apptainer_default(sub)), s)
})

test_that("无法解析版本的候选标记为 ok=FALSE 并显示 (版本未知)", {
  d <- apt_tmpdir("aptbad")
  mk_fake_bin(d, "apptainer", "totally broken", status = 1L)
  cands <- apptainer_candidates(refresh = TRUE, cache_file = tempfile(),
                                extra_dirs = character(0), search_dirs = d)
  expect_equal(nrow(cands), 1L)
  expect_false(cands$ok[1])
  expect_match(names(apptainer_choices(cands))[1], "版本未知")
})

test_that("SIF 版本下限: apptainer ≥ 1.0 / singularity ≥ 3.0", {
  # 分支点: SIF 自 Singularity 3.0 起; 2.x (含 2.4.6) 只读 squashfs/ext3 的 .simg
  expect_true(sif_capable("apptainer", "1.0.0"))
  expect_true(sif_capable("apptainer", "1.4.5"))
  expect_true(sif_capable("singularity", "3.0.1"))
  expect_true(sif_capable("singularity", "3.11.4"))
  expect_false(sif_capable("singularity", "2.4.6"))
  expect_false(sif_capable("singularity", "2.6.1"))
  expect_false(sif_capable("apptainer", "0.9.9"))
  expect_true(is.na(sif_capable("singularity", "")))     # 版本未知: 不拦截
  expect_true(is.na(sif_capable("singularity", NA)))
  # 版本要求文案同时包含两类运行时与下限
  expect_match(sif_min_version_text(), "apptainer ≥ 1.0")
  expect_match(sif_min_version_text(), "singularity ≥ 3.0")
})

test_that("apptainer_check 标注 SIF 能力 (2.4.6 判不支持并给症状)", {
  d <- apt_tmpdir("aptsifchk")
  s <- mk_fake_bin(d, "singularity", "singularity version 2.4.6")
  r <- apptainer_check(s)
  expect_true(r$ok)              # 能跑 --version
  expect_false(r$sif_ok)         # 但读不了 SIF
  expect_match(r$sif_note, "不支持 SIF")
  expect_match(r$sif_note, "Unknown image format/type", fixed = TRUE)

  a <- mk_fake_bin(d, "apptainer", "apptainer version 1.4.5")
  expect_true(apptainer_check(a)$sif_ok)
})

test_that("候选标签标注不支持 SIF, 且默认不再选它", {
  d <- apt_tmpdir("aptsifcand")
  old <- diann.gui::cfg_get("DEFAULT_APPTAINER")
  on.exit(diann.gui::set_core_const("DEFAULT_APPTAINER", old), add = TRUE)
  diann.gui::set_core_const("DEFAULT_APPTAINER", "")
  old_paths <- diann.gui::cfg_get("APPTAINER_PATHS")
  on.exit(diann.gui::set_core_const("APPTAINER_PATHS", old_paths), add = TRUE)
  diann.gui::set_core_const("APPTAINER_PATHS", character(0))

  bad <- mk_fake_bin(d, "singularity", "singularity version 2.4.6")
  cands <- apptainer_candidates(refresh = TRUE, cache_file = tempfile(),
                                extra_dirs = character(0), search_dirs = d)
  sub <- cands[startsWith(cands$path, d), , drop = FALSE]
  expect_equal(nrow(sub), 1L)
  expect_false(sub$sif_ok[1])
  expect_match(names(apptainer_choices(sub))[1], "不支持 SIF")

  # 同目录补一个可读 SIF 的 apptainer: 它不标注, 且成为默认选中项
  good <- mk_fake_bin(d, "apptainer", "apptainer version 1.4.5")
  cands2 <- apptainer_candidates(refresh = TRUE, cache_file = tempfile(),
                                 extra_dirs = character(0), search_dirs = d)
  sub2 <- cands2[startsWith(cands2$path, d), , drop = FALSE]
  expect_true(sub2$sif_ok[sub2$path == good][1])
  expect_false(any(grepl("不支持 SIF", names(apptainer_choices(sub2[sub2$kind == "apptainer", , drop = FALSE])),
                         fixed = TRUE)))
  expect_equal(unname(apptainer_default(sub2)), good)

  # 旧缓存 (无 sif_ok 列) 也要能补算
  expect_false(apptainer_cands_sif(data.frame(
    path = bad, kind = "singularity", source = "common", version = "2.4.6",
    ok = TRUE, checked_at = 1, stringsAsFactors = FALSE))$sif_ok[1])
})

test_that("生成的脚本: 选定路径优先, 保留候选/PATH/module 回退链", {
  old_paths <- diann.gui::cfg_get("APPTAINER_PATHS")
  old_mod <- diann.gui::cfg_get("APPTAINER_MODULE_FALLBACK")
  on.exit({
    diann.gui::set_core_const("APPTAINER_PATHS", old_paths)
    diann.gui::set_core_const("APPTAINER_MODULE_FALLBACK", old_mod)
  }, add = TRUE)
  diann.gui::set_core_const("APPTAINER_PATHS", c("/opt/ap/bin", "/share/app/bin"))
  diann.gui::set_core_const("APPTAINER_MODULE_FALLBACK", "apptainer/1.4.5")

  s <- make_slurm_script(base_params(list(apptainer_bin = "/opt/ap/bin/apptainer")))
  expect_match(s, "APPTAINER_BIN='/opt/ap/bin/apptainer'", fixed = TRUE)
  expect_match(s, "\"$APPTAINER_BIN\" exec", fixed = TRUE)
  expect_match(s, "for d in '/opt/ap/bin' '/share/app/bin'", fixed = TRUE)
  expect_match(s, "command -v apptainer", fixed = TRUE)
  expect_match(s, "module load apptainer/1.4.5", fixed = TRUE)
  expect_match(s, "DIANN_GUI_APPTAINER", fixed = TRUE)
  expect_match(s, "exit $rc", fixed = TRUE)

  # 未选择时按 apptainer 名字走 PATH
  expect_match(make_slurm_script(base_params(list(apptainer_bin = ""))),
               "APPTAINER_BIN='apptainer'", fixed = TRUE)
  # 选 singularity 时脚本原样使用该二进制
  expect_match(make_slurm_script(base_params(list(apptainer_bin = "/opt/sing/bin/singularity"))),
               "APPTAINER_BIN='/opt/sing/bin/singularity'", fixed = TRUE)
})
