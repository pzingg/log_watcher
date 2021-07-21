#!/usr/bin/Rscript

source("script_startup.R")

run_job <- function(args) {
  session_log_path <- args$log_path
  task_id <- args$task_id
  task_type <- args$task_type
  gen <- args$gen
  log_file <- log_file_name(task_id, task_type, gen)
  log_path = file.path(session_log_path, log_file)

  initLogging(log_path)

  session_id <- args$session_id
  error <- args$error
  cancel <- args$cancel
  started_at <- NULL
  running_at <- NULL
  write_start <- FALSE
  write_result <- FALSE

  message <- paste0("Task ", task_id, " created")
  flog.info(message)
  cat("log file created\n")

  arg_file <- arg_file_name(task_id, task_type, gen)
  arg_path <- file.path(session_log_path, arg_file)
  res <- read_arg_file(arg_path)

  options(daptics_script_status = res$status)
  flog.info(res$message)
  cat("read arg file\n")

  num_lines <- res$args$num_lines
  for (line_no in 1:num_lines) {
    Sys.sleep(1)

    res <- mock_status(task_id, line_no, num_lines, error, cancel)
    options(daptics_script_status = res$status)

    status <- res$status
    message <- res$message
    result <- res$result
    errors <- res$errors
    res$result <- NULL
    res$errors <- NULL

    if (is.null(started_at)) {
      started_at <- format_utcnow()
      res$started_at <- started_at
    }

    if (is.null(running_at) && status == "running") {
      running_at <- format_utcnow()
      res$running_at <- running_at
      write_start <- TRUE
    }

    if (status %in% c("canceled", "completed")) {
      result_file <- result_file_name(task_id, task_type, gen)
      if (status == "completed" && length(errors) == 0) {
        result_info <- list(
          succeeded = TRUE,
          file = result_file,
          errors = errors
        )
      } else {
        result_info <- list(
          succeeded = FALSE,
          file = result_file,
          errors = errors
        )
      }
      res$completed_at <- format_utcnow()
      res$result <- result_info
      write_result <- TRUE
    }

    if (write_start) {
      start_file <- start_file_name(task_id, task_type, gen)
      start_path <- file.path(session_log_path, start_file)
      write_start_file(start_path, res)
      cat("wrote start\n")
      write_start <- FALSE
    }

    if (write_result && !is.null(result_file)) {
      result_path <- file.path(session_log_path, result_file)
      write_result_file(result_path, res, result)
      cat("wrote result\n")
    }

    res$status <- NULL
    res$message <- NULL
    logger_args <- c(message, res)
    do.call(futile.logger::flog.info, logger_args)
    cat(paste0("wrote line ", line_no, "\n"))

    if (write_result) {
      break
    }
  }
}

mock_status <- function(task_id, line_no, num_lines, error, cancel) {
  progress_counter <- NULL
  progress_total <- NULL
  result <- NULL
  errors <- list()
  if (line_no == 1) {
    status <- "started"
  } else if (line_no == 2) {
    status <- "validating"
  } else if (line_no < num_lines) {
    status <- "running"
    progress_counter <- line_no - 2
    progress_total <- num_lines - 3
  } else {
    if (cancel) {
      status <- "canceled"
      errors <- list(list(message = paste0("canceled on line ", line_no)))
    } else {
      status <- "completed"
      if (error) {
        errors <- list(list(message = paste0("error on line ", line_no)))
      } else {
        result <- list(params = list(list(a = 2), list(b = line_no)))
      }
    }
  }

  if (!is.null(progress_counter) && !is.null(progress_total)) {
    progress <- list(
      progress_counter = progress_counter,
      progress_total = progress_total,
      progress_phase = paste0("Compiling answers")
    )
  } else {
    progress <- NULL
  }

  list(
    status = status,
    message = paste0("Task ", task_id, " ", status, " on line ", line_no),
    progress = progress,
    result = result,
    errors = errors
  )
}

write_start_file <- function(path, info) {
  info$time  <- format_utcnow()
  info$session_id <- getOption("daptics_session_id")
  info$session_log_path <- getOption("daptics_session_log_path")
  info$task_id  <- getOption("daptics_task_id")
  info$task_type  <- getOption("daptics_task_type")
  info$gen  <- getOption("daptics_task_gen")
  info$os_pid  <- getOption("daptics_script_pid")
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
  info$time  <- format_utcnow()
  info$session_id <- getOption("daptics_session_id")
  info$session_log_path <- getOption("daptics_session_log_path")
  info$task_id  <- getOption("daptics_task_id")
  info$task_type  <- getOption("daptics_task_type")
  info$gen  <- getOption("daptics_task_gen")
  info$os_pid  <- getOption("daptics_script_pid")
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


# Execution starts here

args <- scriptStartup()
run_job(args)
