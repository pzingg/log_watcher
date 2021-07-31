#!/usr/bin/Rscript

source("json_logging.R")
source("script_startup.R")

# These functions are defined in json_logging.R:
# init_logging
# set_script_status
# format_utcnow
# arg_file_name
# log_file_name
# result_file_name
# log_event
# log_res
# maybe_log_error
# read_arg_file
# write_result_file
# write_start_file

# These functions are defined in script_startup.R:
# script_startup

setup_logging <- function(args) {
  log_file <- log_file_name(args$task_id, args$task_type, args$gen)
  log_file_path <- file.path(args$log_path, log_file)
  init_logging(log_file_path)
  cat(paste0("logging setup done, will append to ", log_file_path, "\n"))
}

run_job <- function(args) {
  session_log_path <- args$log_path
  task_id <- args$task_id
  task_type <- args$task_type
  gen <- args$gen

  error <- ifelse(is.null(args$error), "", args$error)
  cancel <- args$cancel
  started_at <- NULL
  running_at <- NULL
  write_start <- FALSE
  write_result <- FALSE

  cat(paste0("run_job: cancel ", cancel, " error ", error, "\n"))
  cat("writing first log message\n")
  info <- list(
    status = "created",
    message = paste0("Task ", task_id, " created")
  )
  set_script_status(info$status)
  futile.logger::flog.info(info$message)
  log_event("task_created", info)
  cat("log file created\n")

  arg_file <- arg_file_name(task_id, task_type, gen)
  arg_path <- file.path(session_log_path, arg_file)
  res <- read_arg_file(arg_path)
  set_script_status(res$status)

  futile.logger::flog.info(res$message)
  cat("read arg file\n")

  num_lines <- res$args$num_lines
  for (line_no in 1:num_lines) {
    Sys.sleep(0.25)

    res <- mock_status(task_id, line_no, num_lines, error, cancel)
    set_script_status(res$status)

    status <- res$status
    message <- res$message
    result <- res$result
    errors <- res$errors
    res$result <- NULL
    res$errors <- list()

    if (is.null(started_at)) {
      started_at <- format_utcnow()
      res$started_at <- started_at
    }

    if (is.null(running_at) && identical(status, "running")) {
      running_at <- format_utcnow()
      res$running_at <- running_at
      write_start <- TRUE
    }

    if (status %in% c("canceled", "completed")) {
      result_file <- result_file_name(task_id, task_type, gen)
      if (identical(status, "completed") && length(errors) == 0) {
        result_info <- list(
          succeeded = TRUE,
          file = result_file,
          errors = make_error_list(errors)
        )
      } else {
        result_info <- list(
          succeeded = FALSE,
          file = result_file,
          errors = make_error_list(errors)
        )
      }
      res$completed_at <- format_utcnow()
      res$result <- result_info
      write_result <- TRUE
    }

    if (write_start) {
      start_file <- start_file_name(task_id, task_type, gen)
      write_start_file(start_file, res)
      cat("wrote start\n")
      write_start <- FALSE
    }

    if (write_result && !is.null(result_file)) {
      write_result_file(result_file, res, result)
      cat("wrote result\n")
    }

    log_res(message, res)
    cat(paste0("wrote line ", line_no, "\n"))

    if (write_result) {
      break
    }
  }
}

blowup_a <- function() {
  blowup_b()
}

blowup_b <- function() {
  blowup()
}

blowup <- function() {
  stop("kaboom")
}

mock_status <- function(task_id, line_no, num_lines, error, cancel) {
  raise_error <- FALSE
  progress_counter <- NULL
  progress_total <- NULL
  result <- NULL
  errors <- list()
  if (line_no == 1) {
    status <- "started"
    if (identical(error, "started")) {
      raise_error <- TRUE
    }
  } else if (line_no == 2) {
    status <- "validating"
    if (identical(error, "validating")) {
      raise_error <- TRUE
    }
  } else if (line_no < num_lines) {
    status <- "running"
    progress_counter <- line_no - 2
    progress_total <- num_lines - 3
    if (line_no == 4) {
      if (identical(error, "running")) {
        raise_error <- TRUE
      } else if (cancel) {
        status <- "canceled"
        errors <- paste0("canceled on line ", line_no)
      }
    }
  } else {
    status <- "completed"
    result <- list(params = list(list(a = 2), list(b = line_no)))
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

  if (raise_error) {
    blowup_a()
  }

  list(
    status = status,
    message = paste0("Task ", task_id, " ", status, " on line ", line_no),
    progress = progress,
    result = result,
    errors = errors
  )
}

# Execution starts here

args <- scriptStartup()
setup_logging(args)
res <- try_capture_stack(run_job(args))
maybe_log_error(res, args)
