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
