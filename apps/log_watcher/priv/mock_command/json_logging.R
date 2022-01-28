library(futile.logger, quietly = TRUE)
library(jsonlite, quietly = TRUE)
library(utils, quietly = TRUE)

## JSON logging for futile.logger

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
#'   command_id*:        command ID string
#'   os_pid*:         PID of current process
#'   level*:          "TRACE", "DEBUG", "INFO", "WARN", or "ERROR"
#'   status*:         "created", "input", "validating", "running", "completed", or "cancelled"
#'   message*:        string message
#'   result:          if the process was detached or completed: an object that will be used for the resolver's "data"
#'   errors:          if the process was detached or completed: a list of "categorized error" objects with these items:
#'     message:       the readable error message
#'     category:      "validation" or "execution"
#'     system:        true if this was an internal system error
#'     fatal:         true if this was a fatal error
json_command_layout <- function(level, msg, id = "", ...) {
  if (inherits(msg, "condition")) {
    msg <- msg$message
  }
  message <- paste(msg, collapse = "\n")
  message_data <- list(
    session_id = getOption("daptics_session_id"),
    log_dir = getOption("daptics_log_dir"),
    command_id = getOption("daptics_command_id"),
    name = getOption("daptics_command_name"),
    gen = getOption("daptics_command_gen"),
    os_pid = getOption("daptics_script_pid"),
    status = getOption("daptics_script_status"),
    time = format_utcnow(),
    level = level,
    message = trimws(message),
    additional = ...
  )
  to_json_line(message_data)
}

jcat <- function(message) {
  if (is.character(message)) {
    message_data <- list(
      time = format_utcnow(),
      message = trimws(message),
      status = getOption("daptics_script_status")
    )
  } else {
    message_data <- message
  }
  cat(to_json_line(message_data))
}

to_json_line <- function(data, append_newline = TRUE) {
  line <- jsonlite::toJSON(data,
    Date = "ISO8601",
    POSIXt = "ISO8601",
    factor = "string",
    null = "null",
    na = "null",
    auto_unbox = TRUE,
    pretty = FALSE
  )
  if (append_newline) {
    paste0(line, "\n")
  } else {
    line
  }
}

to_pretty_json <- function(data) {
  jsonlite::toJSON(data,
    Date = "ISO8601",
    POSIXt = "ISO8601",
    factor = "string",
    null = "null",
    na = "null",
    auto_unbox = TRUE,
    pretty = TRUE
  )
}

# Initialize futile.logger
init_logging <- function(log_file_path, level = futile.logger::INFO) {
  force(log_file_path)

  futile.logger::flog.threshold(level)
  futile.logger::flog.layout(json_command_layout)
  futile.logger::flog.appender(futile.logger::appender.file(log_file_path))

  invisible(log_file_path)
}

setup_logging <- function(args) {
  log_file <- log_file_name(args$session_id, args$gen, args$command_id, args$command_name)
  log_file_path <- file.path(args$log_dir, log_file)
  init_logging(log_file_path)

  jcat(paste0("logging setup done, will append to ", log_file_path, "\n"))

  invisible(log_file_path)
}


set_script_status <- function(status) {
  options(daptics_script_status = status)
}

## Capture traceback and other formatting

format_utcnow <- function() {
  format(Sys.time(), "%Y-%m-%dT%H:%M:%0S")
}

# Borrowed from
# https://github.com/r-lib/evaluate/blob/f0119259b3a1d335e399ac2235e91bb0e5b769b6/R/traceback.r#L29
# For stops, class(res) == c("simpleError", "error", "condition")
# For interrupts, class(res) == c("interrupt", "condition")
try_capture_stack <- function(expr, env = environment()) {
  quoted_code <- quote(expr)
  frame <- sys.nframe()
  capture_calls <- function(e) {
    e$calls <- utils::head(sys.calls()[-seq_len(frame + 7)], -2)
    signalCondition(e)
  }
  res <- tryCatch(
    withCallingHandlers(eval(quoted_code, env),
      error = capture_calls,
      interrupt = capture_calls
    ),
    error = identity, interrupt = identity
  )
  res
}

get_traceback <- function(cond) {
  error_type <- ifelse(inherits(cond, "interrupt"), "interrupt", "error")
  if (inherits(cond, "try-error")) {
    # no expanded traceback for try-error
    condition <- attr(cond, "condition")[["call"]]
    err_msg <- condition[["message"]]
    call_msg <- condition[["call"]]
    stack_msg <- list()
  } else if (inherits(cond, "interrupt")) {
    # interrupt
    err_msg <- "interrupt received"
    stack_msg <- lapply(cond$calls, function(x) utils::capture.output(print(x)))
    call_msg <- tail(stack_msg, 1)
  } else {
    # simpleError
    err_msg <- cond$message
    call_msg <- utils::capture.output(print(cond$call))
    stack_msg <- lapply(cond$calls, function(x) utils::capture.output(print(x)))
  }
  list(
    error_type = error_type,
    error = as.character(err_msg),
    call = as.character(call_msg),
    traceback = stack_msg
  )
}

make_error_list <- function(errors, system = TRUE, fatal = TRUE) {
  category <- getOption("daptics_script_status", default = "running")
  lapply(errors, function(e) {
    list(message = e, category = category, system = system, fatal = fatal)
  })
}

## Log file name functions

session_log_file_name <- function(session_id) {
  paste0(session_id, "-sesslog.jsonl")
}

make_log_prefix <- function(session_id, gen, command_id, name) {
  gen_str <- paste0("0000", gen)
  gen_str <- substring(gen_str, nchar(gen_str) - 3)
  paste0(session_id, "-", gen_str, "-", name, "-", command_id)
}

log_file_name <- function(session_id, gen, command_id, name) {
  paste0(make_log_prefix(session_id, gen, command_id, name), "-log.jsonl")
}

arg_file_name <- function(session_id, gen, command_id, name) {
  paste0(make_log_prefix(session_id, gen, command_id, name), "-arg.json")
}

start_file_name <- function(session_id, gen, command_id, name) {
  paste0(make_log_prefix(session_id, gen, command_id, name), "-start.json")
}

result_file_name <- function(session_id, gen, command_id, name) {
  paste0(make_log_prefix(session_id, gen, command_id, name), "-result.json")
}

## Main logging functions

log_event <- function(event_type, info) {
  event_file <- session_log_file_name(info$session_id)
  path <- file.path(info$log_dir, event_file)
  con <- file(path, open = "at")
  event <- build_event(event_type, info)
  writeLines(to_json_line(event, append_newline = FALSE), con = con)
  flush(con)
  close(con)
  con <- NULL
}

build_event <- function(event_type, info) {
  event <- list(
    session_id = getOption("daptics_session_id"),
    log_dir = getOption("daptics_log_dir"),
    gen = getOption("daptics_command_gen"),
    command_id = getOption("daptics_command_id"),
    name = getOption("daptics_command_name"),
    gen = getOption("daptics_command_gen"),
    os_pid = getOption("daptics_script_pid"),
    status = getOption("daptics_script_status"),
    event_type = event_type,
    time = format_utcnow()
  )
  utils::modifyList(event, info)
}

log_res <- function(message, res, level = "INFO") {
  log_fn <- switch(level,
    INFO = futile.logger::flog.info,
    ERROR = futile.logger::flog.error,
    WARN = futile.logger::flog.warn,
    FATAL = futile.logger::flog.fatal,
    DEBUG = futile.logger::flog.debug,
    TRACE = futile.logger::flog.trace,
    futile.logger::flog.info
  )
  res$status <- NULL
  res$message <- NULL
  logger_args <- c(message, res)
  do.call(log_fn, logger_args)
}

# cond should normally be a "simpleError", "try-error", or "interrupt"
log_error <- function(cond, args) {
  trace <- get_traceback(cond)
  message <- trimws(trace$error)

  if (is.null(args)) {
    result_file <- NULL
  } else {
    result_file <- result_file_name(args$session_id, args$gen, args$command_id, args$command_name)
  }

  result_info <- list(
    succeeded = FALSE,
    file = result_file,
    errors = make_error_list(message)
  )

  status <- ifelse(identical(trace$error_type, "interrupt"), "cancelled", "completed")
  info <- list(
    message = message,
    status = status,
    result = result_info,
    call = trace$call,
    traceback = trace$traceback
  )

  if (is.null(result_file)) {
    # Error occurred before args were correctly parsed.
    jcat(info)
  } else {
    set_script_status(status)
    write_result_file(result_file, info, NULL)
    res <- list(
      completed_at = format_utcnow(),
      result = result_info
    )
    log_res(message, res, level = "ERROR")
  }
  message
}

read_arg_file <- function(arg_path) {
  args <- jsonlite::read_json(arg_path, simplifyVector = TRUE)
  command_id <- args$command_id

  opt_session_id <- getOption("daptics_session_id")
  stopifnot(!is.null(args$session_id))
  stopifnot(identical(args$session_id, opt_session_id))
  opt_command_id <- getOption("daptics_command_id")
  stopifnot(!is.null(command_id))
  stopifnot(identical(command_id, opt_command_id))
  opt_command_name <- getOption("daptics_command_name")
  stopifnot(!is.null(args$command_name))
  stopifnot(identical(args$command_name, opt_command_name))
  opt_gen <- getOption("daptics_command_gen")
  stopifnot(!is.null(args$gen))
  stopifnot(identical(args$gen, opt_gen))

  args["session_id"] <- NULL
  args["log_dir"] <- NULL
  args["command_id"] <- NULL
  args["command_name"] <- NULL
  args["gen"] <- NULL

  res <- list(
    status = "validating",
    message = paste0("Task ", command_id, " parsed ", length(args), " args"),
    args = args
  )

  set_script_status("validating")
  res
}

write_start_file <- function(start_file, info) {
  info$time <- format_utcnow()
  info$session_id <- getOption("daptics_session_id")
  info$log_dir <- getOption("daptics_log_dir")
  info$command_id <- getOption("daptics_command_id")
  info$name <- getOption("daptics_command_name")
  info$gen <- getOption("daptics_command_gen")
  info$os_pid <- getOption("daptics_script_pid")
  path <- file.path(info$log_dir, start_file)
  cat(to_pretty_json(info), file = path)

  log_event("command_started", info)
}

write_result_file <- function(result_file, info, result_data) {
  info$status <- getOption("daptics_script_status")
  if (!identical(info$status, "cancelled")) {
    if (!identical(info$status, "completed")) {
      info$status <- "completed"
      set_script_status(info$status)
    }
  }

  info$time <- format_utcnow()
  info$session_id <- getOption("daptics_session_id")
  info$log_dir <- getOption("daptics_log_dir")
  info$command_id <- getOption("daptics_command_id")
  info$name <- getOption("daptics_command_name")
  info$gen <- getOption("daptics_command_gen")
  info$os_pid <- getOption("daptics_script_pid")

  saved_result <- info$result
  info$result <- list(
    succeeded = info$result$succeeded,
    errors = info$result$errors,
    data = result_data
  )
  path <- file.path(info$log_dir, result_file)
  cat(to_pretty_json(info), file = path)

  event_type <- paste0("command_", info$status)
  info$result <- saved_result
  log_event(event_type, info)
}
