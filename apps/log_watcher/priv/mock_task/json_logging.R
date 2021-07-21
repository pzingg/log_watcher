library(futile.logger, quietly = TRUE)
library(jsonlite, quietly = TRUE)

#' Custom API JSON layout for use with \code{futile.logger}
#'
#' Reads session and command information from R runtime \code{options},
#' generates a named list, and then converts it to JSON.
#'
#' @param level The futile.logger log level ("INFO", "TRACE", etc.)
#' @param msg Character vector for the message, or condition from warning, stop, etc.
#' @param id For backward compatibility, deprecated and ignored.
#' @param ... Any other named items to be included in the log file.
#' @return A JSON-encoded character vector.
#'
#' @section Log file details:
#' These are the keys found in the JSON log entries (starred items are ALWAYS included):
#'   time*:           ISO 8601-formatted UTC time
#'   session_id*:     session ID string
#'   task_id*:        command ID string
#'   os_pid*:         PID of current process
#'   level*:          "TRACE", "DEBUG", "INFO", "WARN", or "ERROR"
#'   status*:         "created", "input", "validating", "running", "completed", or "canceled"
#'   message*:        string message
#'   result:          if the process was detached or completed: an object that will be used for the resolver's "data"
#'   errors:          if the process was detached or completed: a list of "categorized error" objects with these items:
#'     message:       the readable error message
#'     category:      "validation" or "execution"
#'     system:        true if this was an internal system error
#'     fatal:         true if thiw was a fatal error
jsonLayout <- function(level, msg, id = "", ...) {
  if (is(msg, "condition")) {
    msg <- msg$message
  }
  outputList <- list(
    session_id = getOption("daptics_session_id"),
    session_log_path = getOption("daptics_session_log_path"),
    task_id = getOption("daptics_task_id"),
    task_type = getOption("daptics_task_type"),
    gen = getOption("daptics_task_gen"),
    os_pid = getOption("daptics_script_pid"),
    status = getOption("daptics_script_status"),
    time = format_utcnow(),
    level = level,
    message = paste(msg, collapse = "\n"),
    additional = ...
  )
  paste0(jsonlite::toJSON(outputList,
    Date = "ISO8601",
    POSIXt = "ISO8601",
    factor = "string",
    null = "null",
    na = "null",
    auto_unbox = TRUE,
    pretty = FALSE
  ), "\n")
}

format_utcnow <- function() {
  format(Sys.time(), "%Y-%m-%dT%H:%M:%S")
}

# Initialize futile.logger
initLogging <- function(logFilePath, level = futile.logger::INFO) {
  force(logFilePath)

  futile.logger::flog.threshold(level)
  futile.logger::flog.layout(jsonLayout)
  futile.logger::flog.appender(futile.logger::appender.file(logFilePath))
}

set_script_status <- function(status) {
  options(daptics_script_status = status)
}

# borrowed from
# https://github.com/r-lib/evaluate/blob/f0119259b3a1d335e399ac2235e91bb0e5b769b6/R/traceback.r#L29
try_capture_stack <- function(expr, env = environment()) {
  quoted_code <- quote(expr)
  capture_calls <- function(e) {
    e$calls <- utils::head(sys.calls()[-seq_len(frame + 7)], -2)
    signalCondition(e)
  }
  frame <- sys.nframe()
  tryCatch(
    withCallingHandlers(eval(quoted_code, env), error = capture_calls),
    error = identity
  )
}

get_traceback <- function(err) {
  # no expanded traceback
  if (inherits(err, "try-error")) {
    condition <- attr(err, "condition")[["call"]]
    list(
      error = condition[["message"]],
      call = as.character(condition[["call"]]),
      traceback = list()
    )
  } else {
    err_msg <- err$message
    stack_msg <- lapply(err$calls, function(x) utils::capture.output(print(x)))
    call_msg <- utils::capture.output(print(err$call))
    list(error = err_msg, call = call_msg, traceback = stack_msg)
  }
}

log_res <- function(message, res, level = "INFO") {
  res$status <- NULL
  res$message <- NULL
  logger_args <- c(message, res)
  log_fn <- switch(level,
    INFO = futile.logger::flog.info,
    ERROR = futile.logger::flog.error,
    WARN = futile.logger::flog.warn,
    DEBUG = futile.logger::flog.debug,
    futile.logger::flog.info
  )
  do.call(futile.logger::flog.info, logger_args)
}

log_error <- function(res, args) {
  # If there is an error, class(res) <- c("simpleError", "error", "condition")
  if (is(res, "error")) {
    trace <- get_traceback(res)
    cat(paste0("log_error: ", trace$error, "\n"))

    result_file <- result_file_name(args$task_id, args$task_type, args$gen)
    result_path <- file.path(args$log_path, result_file)

    result_info <- list(
      succeeded = FALSE,
      file = result_file,
      errors = list(list(message = trace$error))
    )
    info <- list(result = result_info, call = trace$call, traceback = trace$traceback)
    write_result_file(result_path, info, NULL)

    set_script_status("completed")
    res <- list(
      completed_at = format_utcnow(),
      result = result_info
    )
    log_res(trace$error, res, level = "ERROR")

    trace$error
  } else {
    res
  }
}

write_start_file <- function(path, info) {
  info$time <- format_utcnow()
  info$session_id <- getOption("daptics_session_id")
  info$session_log_path <- getOption("daptics_session_log_path")
  info$task_id <- getOption("daptics_task_id")
  info$task_type <- getOption("daptics_task_type")
  info$gen <- getOption("daptics_task_gen")
  info$os_pid <- getOption("daptics_script_pid")
  contents <- jsonlite::toJSON(info,
    Date = "ISO8601",
    POSIXt = "ISO8601",
    factor = "string",
    null = "null",
    na = "null",
    auto_unbox = TRUE,
    pretty = TRUE
  )
  write(contents, path)
}

write_result_file <- function(path, info, result_data) {
  info$time <- format_utcnow()
  info$session_id <- getOption("daptics_session_id")
  info$session_log_path <- getOption("daptics_session_log_path")
  info$task_id <- getOption("daptics_task_id")
  info$task_type <- getOption("daptics_task_type")
  info$gen <- getOption("daptics_task_gen")
  info$os_pid <- getOption("daptics_script_pid")
  info$result <- list(
    succeeded = info$result$succeeded,
    errors = info$result$errors,
    data = result_data
  )
  contents <- jsonlite::toJSON(info,
    Date = "ISO8601",
    POSIXt = "ISO8601",
    factor = "string",
    null = "null",
    na = "null",
    auto_unbox = TRUE,
    pretty = TRUE
  )
  write(contents, path)
}
