# sif_check_local: sif 镜像本地静态校验 (存在/大小/可读/SIF 魔数@32/文件名版本)
# SIF 格式事实: 前 32 字节为 "#!/usr/bin/env run-singularity" 引导头, 偏移 32 处为 9 字节魔数 "SIF_MAGIC"

mk_fake_sif <- function(path, magic = TRUE) {
  # R 字符串不允许 nul 字节, 用 raw 向量构造: 28 字节 shebang 头 + nul 填充至 32 偏移处
  hdr <- charToRaw("#!/usr/bin/env run-singularity\n")
  pad <- as.raw(rep(0, 32 - length(hdr)))
  writeBin(c(hdr, pad,
             if (magic) charToRaw("SIF_MAGIC") else charToRaw("NOT_SIF_!"),
             as.raw(rep(0xAA, 1024))), path)
  path
}

test_that("空/NULL 路径与不存在路径", {
  r <- sif_check_local("")
  expect_false(r$exists); expect_false(r$readable); expect_false(r$sif_magic)
  expect_equal(sif_check_local(NULL)$exists, FALSE)
  r2 <- sif_check_local("/nonexistent/diann-9.9.9.sif")
  expect_false(r2$exists)
  expect_true(is.na(r2$readable))   # 前置条件缺失 → NA 而非 FALSE
})

test_that("合法魔数与损坏魔数", {
  f <- mk_fake_sif(file.path(tempdir(), "diann-2.7.0.sif"))
  r <- sif_check_local(f)
  expect_true(r$exists); expect_true(r$readable); expect_true(r$sif_magic)
  expect_gte(r$size_bytes, 1000)
  expect_equal(r$ver_from_name, "2.7.0")

  f2 <- mk_fake_sif(file.path(tempdir(), "diann-2.8.0.sif"), magic = FALSE)
  expect_false(sif_check_local(f2)$sif_magic)
})

test_that("文件名版本提取边界", {
  f <- file.path(tempdir(), "someimage.sif"); file.create(f)
  expect_equal(sif_check_local(f)$ver_from_name, "")       # 无 diann+版本字样
  f2 <- file.path(tempdir(), "diann_1.8_beta.sif"); file.create(f2)
  expect_equal(sif_check_local(f2)$ver_from_name, "1.8")
})

test_that("无读权限时 readable=FALSE 且不读魔数", {
  f <- mk_fake_sif(file.path(tempdir(), "diann-3.0.0.sif"))
  Sys.chmod(f, "0000")
  on.exit(Sys.chmod(f, "0644"), add = TRUE)
  if (identical(Sys.info()[["user"]], "root")) skip("root 不受权限位约束")
  r <- sif_check_local(f)
  expect_true(r$exists)
  expect_false(r$readable)
  expect_true(is.na(r$sif_magic))   # 不可读 → 魔数保持 NA, 不误报
})

test_that("多版本按数值排序: 2.10.0 在 2.9.1 之前 (字符串排序会反)", {
  d <- file.path(tempdir(), sprintf("sifs_%d_%d", Sys.getpid(), as.integer(runif(1, 1, 1e9))))
  dir.create(d, showWarnings = FALSE)
  for (v in c("2.3.2", "2.7.0", "2.10.0", "2.9.1")) {
    file.create(file.path(d, sprintf("diann-%s.sif", v)))
  }
  df <- scan_sif_images(d)
  expect_equal(df$ver, c("2.10.0", "2.9.1", "2.7.0", "2.3.2"))
  expect_equal(basename(df$path[1]), "diann-2.10.0.sif")
})
