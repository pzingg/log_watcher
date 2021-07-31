library(futile.logger, quietly = TRUE)
library(jsonlite, quietly = TRUE)
library(rlist, quietly = TRUE)

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
#'     fatal:         true if this was a fatal error
json_task_layout <- function(level, msg, id = "", ...) {
  if (is(msg, "condition")) {
    msg <- msg$message
  }
  message_data <- list(
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
  paste0(jsonlite::toJSON(message_data,
    Date = "ISO8601",
    POSIXt = "ISO8601",
    factor = "string",
    null = "null",
    na = "null",
    auto_unbox = TRUE,
    pretty = FALSE
  ), "\n")
}

# Initialize futile.logger
init_logging <- function(log_file_path, level = futile.logger::INFO) {
  force(log_file_path)

  futile.logger::flog.threshold(level)
  futile.logger::flog.layout(json_task_layout)
  futile.logger::flog.appender(futile.logger::appender.file(log_file_path))
}

set_script_status <- function(status) {
  options(daptics_script_status = status)
}

## Capture traceback and other formatting

format_utcnow <- function() {
  format(Sys.time(), "%Y-%m-%dT%H:%M:%0S")
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

make_log_prefix <- function(task_id, task_type, gen) {
  gen_str <- paste0("0000", gen)
  gen_str <- substring(gen_str, nchar(gen_str) - 3)
  paste0(task_id, "-", task_type, "-", gen_str)
}

log_file_name <- function(task_id, task_type, gen) {
  paste0(make_log_prefix(task_id, task_type, gen), "-log.jsonl")
}

arg_file_name <- function(task_id, task_type, gen) {
  paste0(make_log_prefix(task_id, task_type, gen), "-arg.json")
}

start_file_name <- function(task_id, task_type, gen) {
  paste0(make_log_prefix(task_id, task_type, gen), "-start.json")
}

result_file_name <- function(task_id, task_type, gen) {
  paste0(make_log_prefix(task_id, task_type, gen), "-result.json")
}

## Main logging functions

log_event <- function(event_type, info) {
  event <- create_event(event_type, info)
  contents <- jsonlite::toJSON(event,
    Date = "ISO8601",
    POSIXt = "ISO8601",
    factor = "string",
    null = "null",
    na = "null",
    auto_unbox = TRUE,
    pretty = FALSE
  )

  event_file <- session_log_file_name(event$session_id)
  path <- file.path(event$session_log_path, event_file)
  con <- file(path, open = "at")
  writeLines(contents, con = con)
  flush(con)
  close(con)
  con <- NULL
}

create_event <- function(event_type, info) {
  event <- list(
    session_id = getOption("daptics_session_id"),
    session_log_path = getOption("daptics_session_log_path"),
    gen = getOption("daptics_task_gen"),
    task_id = getOption("daptics_task_id"),
    task_type = getOption("daptics_task_type"),
    gen = getOption("daptics_task_gen"),
    os_pid = getOption("daptics_script_pid"),
    status = getOption("daptics_script_status"),
    event_type = event_type,
    time = format_utcnow()
  )
  rlist::list.merge(event, info)
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

maybe_log_error <- function(res, args) {
  # If there is an error, class(res) <- c("simpleError", "error", "condition")
  if (is(res, "error")) {
    trace <- get_traceback(res)
    cat(paste0("maybe_log_error: ", trace$error, "\n"))

    result_file <- result_file_name(args$task_id, args$task_type, args$gen)
    result_info <- list(
      succeeded = FALSE,
      file = result_file,
      errors = make_error_list(trace$error)
    )
    info <- list(
      result = result_info,
      call = trace$call,
      traceback = trace$traceback
    )
    write_result_file(result_file, info, NULL)

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

read_arg_file <- function(arg_path) {
  args <- jsonlite::read_json(arg_path, simplifyVector = TRUE)
  task_id <- args$task_id

  opt_session_id <- getOption("daptics_session_id")
  stopifnot(!is.null(args$session_id))
  stopifnot(identical(args$session_id, opt_session_id))
  opt_task_id <- getOption("daptics_task_id")
  stopifnot(!is.null(task_id))
  stopifnot(identical(task_id, opt_task_id))
  opt_task_type <- getOption("daptics_task_type")
  stopifnot(!is.null(args$task_type))
  stopifnot(identical(args$task_type, opt_task_type))
  opt_gen <- getOption("daptics_task_gen")
  stopifnot(!is.null(args$gen))
  stopifnot(identical(args$gen, opt_gen))

  args["session_id"] <- NULL
  args["session_log_path"] <- NULL
  args["task_id"] <- NULL
  args["task_type"] <- NULL
  args["gen"] <- NULL

  list(
    status = "input",
    message = paste0("Task ", task_id, " parsed ", length(args), " args"),
    args = args
  )
}

write_start_file <- function(start_file, info) {
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
  path <- file.path(info$session_log_path, start_file)
  write(contents, file = path)

  log_event("task_started", info)
}

write_result_file <- function(result_file, info, result_data) {
  info$status <- getOption("daptics_script_status")
  if (!identical(info$status, "canceled")) {
    if (!identical(info$status, "completed")) {
      info$status <- "completed"
      set_script_status(info$status)
    }
  }

  info$time <- format_utcnow()
  info$session_id <- getOption("daptics_session_id")
  info$session_log_path <- getOption("daptics_session_log_path")
  info$task_id <- getOption("daptics_task_id")
  info$task_type <- getOption("daptics_task_type")
  info$gen <- getOption("daptics_task_gen")
  info$os_pid <- getOption("daptics_script_pid")

  saved_result <- info$result
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
  path <- file.path(info$session_log_path, result_file)
  write(contents, file = path)

  event_type <- paste0("task_", info$status)
  info$result <- saved_result
  log_event(event_type, info)
}
