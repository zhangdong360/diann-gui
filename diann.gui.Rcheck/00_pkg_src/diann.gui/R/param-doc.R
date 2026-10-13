# ============================================================
# param-doc.R — 参数速查文档解析
# ============================================================
param_doc_candidates <- function() {
  c(
    system.file("docs", "DIANN_param_reference.md", package = "diann.gui"),
    file.path(getwd(), "DIANN_param_reference.md")
  )
}

param_doc_path <- function() {
  cand <- param_doc_candidates()
  ok <- cand[file.exists(cand)]
  if (length(ok)) ok[1] else ""
}

html_unescape <- function(x) {
  x <- gsub("&lt;", "<", x, fixed = TRUE)
  x <- gsub("&gt;", ">", x, fixed = TRUE)
  x <- gsub("&quot;", "\"", x, fixed = TRUE)
  x <- gsub("&#39;", "'", x, fixed = TRUE)
  gsub("&amp;", "&", x, fixed = TRUE)
}
parse_param_doc <- function(path) {
  txt <- readLines(path, n = 6, warn = FALSE)
  idx <- which(grepl("<li", txt))[1]
  if (is.na(idx)) return(NULL)
  line <- txt[idx]
  entries <- regmatches(line, gregexpr("<li[^>]*><strong[^>]*>(--[^<]+)</strong>(.*?)</li>", line, perl = TRUE))[[1]]
  if (!length(entries)) return(NULL)
  flag <- sub(".*<strong[^>]*>(--[^<]+)</strong>.*", "\\1", entries, perl = TRUE)
  desc <- gsub("<[^>]+>", "", sub(".*</strong>", "", entries, perl = TRUE))
  data.frame(flag = flag, desc = html_unescape(desc), stringsAsFactors = FALSE)
}
