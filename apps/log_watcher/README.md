# LogWatcher

Consists of an Oban-compatible TaskStarter worker module that can
shell out to Rscripts which produce JSON-formatted log files.

Meanwhile the FileWatcher module uses inotify tools to monitor
the primary task log file for changes and broadcasts events on
a session topic.

## JSON log files

* session_id-sesslog.jsonl - Records session events, including task starts 
  and completions.
* task_id-gen-task_type-log.jsonl - Active task progress log. Each line 
  contains timestamp, task info, phase, state, progress_completed, 
  progress_total, message)
* task_id-gen-task_type-log.jsonx - Task progress log after it has been archived.
* task_id-gen-task_type-start.json - Task start file. Contains task info,
  started_at, os_pid, status, start result or errors.
* task_id-gen-task_type-result.json - Task result file. Contains task info
  completed_at, os_pid, status, completion result or errors.

## Task status

The Rscript is responsible for parsing arguments from the command line
and from an arguments file placed on disk by the TaskStarter module.

A task progresses through seven well-known phases, identified by the `status`
item in the Task struct:

1. "initializing" - This initial phase comes before command line arguments
  have been parsed and the log file system established. Any errors thrown
  in this phase have to be recovered from the standard output 
  (also JSON-encoded) of the script. If no runtime errors (exceptions) 
  occur, we do not create a log file but pass directly to the next phase:
2. "created" - The first entry in the log file has been written, and
  therefore, the FileWatcher has been notified. If no exceptions 
  occur, we pass to the next phase:
3. "reading" - The task is parsing the JSON-encoded arguments file.
  If no exceptions occur, we pass to the next phase:
4. "validating" - The task is validating the command line and file-based
  arguments. Validation may produce exceptions or non-fatal errors
  such as those produced when arguments do not conform to the 
  current state of the session, or if performing the task is not 
  permitted while other operations are in progress.
  If no exceptions occur, we pass to the next phase:
5. "running" - The task is performing what could be a long-term 
  process. A start file is also written, recording the parsed
  arguments and the time that execution started. The TaskStarter 
  process is sent a `:task_started` message when the FileWatcher 
  parses the first log message written in a "running", "canceled", 
  or "completed" phase. Normal execution will pass to either the 
  "canceled" or "completed" phase.
6. "canceled" - The task system received a message to cancel
  the current task (TODO).  If the task can be halted, or happens to 
  fail before it can be halted the phase is set to "cancelled". 
  The log file may contain errors, but a valid result file will 
  never be written for tasks that exit in the "cancelled" state.
  If the task manages to complete successfully, despite the 
  cancellation request we pass to the next phase:
7. "completed" - The task script was able to complete, whether
  or not a cancellation request was received. The log file may 
  contain errors. If no errors were encountered, a result file is 
  also written, and the log file will include a pointer
  to the result file.
