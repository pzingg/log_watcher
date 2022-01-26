library(jsonlite)

source("json_logging.R")

run_forever <- function() {
  i <- 1
  sleep_for <- 5.
  while (TRUE) {
    cat(paste0("iteration ", i, "\n"))
    if (i == 10) {
      stop("kablooie")
    }
    Sys.sleep(sleep_for)
    sleep_for <- 2.
    i <- i + 1
  }
}

cat(paste0("please try kill -s 2 ", Sys.getpid(), "\n"))
res <- try_capture_stack(run_forever())

# for stops, class(res) == c("simpleError", "error", "condition")
# for interrupts, class(res) == c("interrupt", "condition")
cat("loop broken\n")
cat(paste0("res is ", paste(class(res), collapse = ", "), "\n"))
if (inherits(res, "condition")) {
  info <- get_traceback(res)
  cat(paste0(to_pretty_json(info)), "\n")
}
