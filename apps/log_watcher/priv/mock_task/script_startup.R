library(futile.logger, quietly = TRUE)
library(jsonlite, quietly = TRUE)
library(argparser, quietly = TRUE)

source("json_logging.R")

#' Startup procedure for Rscript-based API
#'
#' \code{scriptStartup} parses command line arguments, creates the API context,
#' writes out command line arguments to a JSON file, and sets
#' up a path for the log file for the command script.
#'
#' @return A named list with these components:
#'  \code{session} The session environment.
#'  \code{commandId} The command ID parsed from the command line.
#'  \code{logFile} The command's log file location on the file system.
scriptStartup <- function() {
  .loadLibraries()

  pa <- .getScriptPathAndArgs()

  # Change to directory of script
  setwd(dirname(pa$script))

  # Create a parser
  p <- argparser::arg_parser("daptics rscript")

  # Add command line arguments. If not specified, missing args default to NA.
  p <- argparser::add_argument(p, "--log-path", "path containing log file", short = "p")
  p <- argparser::add_argument(p, "--session-id", "session id", short = "s")
  p <- argparser::add_argument(p, "--task-id", "task id", short = "i")
  p <- argparser::add_argument(p, "--task-type", "task id", short = "t")
  p <- argparser::add_argument(p, "--gen", "gen", short = "g", type = "integer")
  p <- argparser::add_argument(p, "--cancel", "TRUE to generate canceled result", short = "c", default = FALSE)
  p <- argparser::add_argument(p, "--error", "TRUE to generate error result", short = "e", default = FALSE)

  # Parse the command line arguments
  args <- argparser::parse_args(p, argv = pa$argv)
  cat("arg_parser done:")
  cat(jsonlite::toJSON(args))

  stopifnot(!is.na(args$log_path))
  stopifnot(!is.na(args$session_id))
  stopifnot(!is.na(args$task_id))
  stopifnot(!is.na(args$task_type))
  stopifnot(!is.na(args$gen))

  # Save important data in R options
  context <- list(
    daptics_script_name = basename(pa$script),
    daptics_session_log_path = args$log_path,
    daptics_session_id = args$session_id,
    daptics_task_id = args$task_id,
    daptics_task_type = args$task_type,
    daptics_task_gen = args$gen,
    daptics_script_pid = Sys.getpid(),
    daptics_script_status = "created"
  )
  options(context)

  args
}

#' Parse command line arguments from \code{Rscript} or \code{littler}.
#'
#' \code(getScriptPathAndArgs) accepts command line arguments from
#' either \code{Rscript} or \code{littler} runtimes, parses the "--file="
#' argument, and returns that value, along with any "trailing" arguments.
#'
#' @return A named list with \code{script} and \code{argv} components.
.getScriptPathAndArgs <- function() {
  # With littler, argv is already parsed, and should be a character vector like:
  # [1] "--file=/home/pzingg/..."
  # [2] "-s"
  # [3] "S2kkby1jg77bdma700ct"
  # [4] "-c"
  # [5] "C2kkby2mm0c9vnm682gq"
  littler <- exists("argv", env = globalenv())

  # With Rscript, commandArgs returns a vector like this:
  # [1] "/usr/lib/R/bin/exec/R"
  # [2] "--slave"
  # [3] "--no-restore"
  # [4] "--file=/home/pzingg/..."
  # [5] "--args"
  # [6] "-s"
  # [7] "S2kkmshsqwmkhhfb16fk"
  # [8] "-c"
  # [9] "C2kkmsjs57a10jvzx855"
  if (!littler) {
    argv <- commandArgs(trailingOnly = FALSE)
  }

  # Find the path to our file
  m <- grepl("--file=(.+)", argv)
  if (!any(m)) {
    # When using littler, you must supply "--file=script_path" as an explicit argument
    # Rscript does this automatically
    if (littler) {
      stop("r invocation requires explicit --file=<path.to.script> command line argument.")
    } else {
      stop("Rscript error, no implicit --file=<path.to.script> command line argument found.")
    }
  }

  # Get full path from "--file=xxx" argument
  scriptPath <- gsub("--file=(.+)", "\\1", argv[m])
  scriptPath <- normalizePath(scriptPath)

  # Now remove all but "trailing" args
  if (littler) {
    # Remove --file arg from argv list
    args <- argv[!m]
    if (is.null(args)) args <- character()
  } else {
    # Strip off all args up to and including "--args"
    m <- match("--args", argv, 0L)
    args <- if (m) argv[-seq_len(m)] else character()
  }

  # After processing, we should be left with args like this:
  # [1] "-s"
  # [2] "S2kkmshsqwmkhhfb16fk"
  # [3] "-c"
  # [4] "C2kkmsjs57a10jvzx855"
  list(script = scriptPath, argv = args)
}

# Load required libraries used for Rscripts
# This is handled by rserve_preload.R in Rserve case
.loadLibraries <- function() {
  return(TRUE)

  libraries <- c(
    "doParallel", "httr", "itertools",
    "jose", "openssl",
    "parallel", "plyr", "R6", "synchronicity",
    "sys", "tools", "ulid", "unix", "utils", "withr"
  )

  threshold <- futile.logger::flog.threshold(futile.logger::TRACE,
    name = "installer"
  )
  ow <- options("warn")
  options(warn = 1)
  for (lib in libraries) {
    library(lib, character.only = TRUE, warn.conflicts = FALSE, quietly = TRUE)
    futile.logger::flog.trace(paste(lib, "was installed."),
      name = "installer"
    )
  }
  options(ow)
  TRUE
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

read_arg_file <- function(arg_path) {
  args <- jsonlite::read_json(arg_path, simplifyVector = TRUE)
  task_id <- args$task_id

  opt_session_id = getOption("daptics_session_id")
  stopifnot(!is.null(args$session_id))
  stopifnot(identical(args$session_id, opt_session_id))
  opt_task_id = getOption("daptics_task_id")
  stopifnot(!is.null(task_id))
  stopifnot(identical(task_id, opt_task_id))
  opt_task_type = getOption("daptics_task_type")
  stopifnot(!is.null(args$task_type))
  stopifnot(identical(args$task_type, opt_task_type))
  opt_gen = getOption("daptics_task_gen")
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
