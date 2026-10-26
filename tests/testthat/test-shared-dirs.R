# fix_shared_dirs(): legacy 共享组模式的安全边界
# 2026-10 审查: 旧实现未规范化 DATA_HOME, 当 DATA_HOME 为空/带尾斜杠时会一路
# chmod 2770 + chgrp 到 DATA_HOME 之上 (甚至 $HOME、/share)。

test_that("SHARED_GROUP 为空时完全 no-op", {
  old <- diann.gui::cfg_get("SHARED_GROUP")
  on.exit(diann.gui::set_core_const("SHARED_GROUP", old), add = TRUE)
  diann.gui::set_core_const("SHARED_GROUP", "")
  expect_null(diann.gui:::fix_shared_dirs(tempdir()))
  expect_silent(diann.gui:::fix_shared_dirs(tempdir()))
})

test_that("DATA_HOME 为空时跳过并警告 (不改动上层目录)", {
  old_g <- diann.gui::cfg_get("SHARED_GROUP")
  old_dh <- diann.gui::cfg_get("DATA_HOME")
  on.exit({
    diann.gui::set_core_const("SHARED_GROUP", old_g)
    diann.gui::set_core_const("DATA_HOME", old_dh)
  }, add = TRUE)
  diann.gui::set_core_const("SHARED_GROUP", "somegroup")
  diann.gui::set_core_const("DATA_HOME", "")
  expect_warning(diann.gui:::fix_shared_dirs(tempdir()), "DATA_HOME")
})

test_that("叶子不在 DATA_HOME 之下时跳过并警告", {
  old_g <- diann.gui::cfg_get("SHARED_GROUP")
  old_dh <- diann.gui::cfg_get("DATA_HOME")
  on.exit({
    diann.gui::set_core_const("SHARED_GROUP", old_g)
    diann.gui::set_core_const("DATA_HOME", old_dh)
  }, add = TRUE)
  base <- file.path(tempdir(), sprintf("shared_%d_%d", Sys.getpid(), as.integer(runif(1, 1, 1e9))))
  dh <- file.path(base, "dh"); outside <- file.path(base, "outside")
  dir.create(dh, recursive = TRUE, showWarnings = FALSE)
  dir.create(outside, recursive = TRUE, showWarnings = FALSE)
  diann.gui::set_core_const("SHARED_GROUP", "somegroup")
  diann.gui::set_core_const("DATA_HOME", dh)
  expect_warning(diann.gui:::fix_shared_dirs(outside), "不在 DATA_HOME")
})
