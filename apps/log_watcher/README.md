# LogWatcher

The application provides an Oban-compatible `LogWatcher.CommandJob` worker
module that can start long-running shell scripts, which produce JSON-formatted
log files.

Meanwhile the `LogWatcher.FileWatcher` GenServer uses inotify tools to monitor
changes in the log files that the scripts produce, and broadcasts these changes
as messages on a PubSub topic.

`LogWatcher.ScriptRunner` invokes commands on a `LogWatcher.CommandManager`
GenServer to launch, cancel and wait on the shell scripts as needed.


## Sessions and Tasks

The idea is that a session is location on the filesystem that
contains executable shell scripts, data, and log files.

Each invocation of a shell script is called a command. Tasks may
read and write data, and record events, state changes, and
results in log files.

Sessions and commands are identified by IDs that are assigned on the
Elixir side.


## JSON data and log files

The following list of files are located in a session subdirectory,
called the `log_dir`. They all use JSON encoding to record
state changes and results. The `jsonl` (and archived `jsonx`) files use
the [JSON Lines](https://jsonlines.org/) format, while the `json`
files are regular JSON files.


### Log files

Log files in the `log_dir` have well-known file names,
based on the session and command IDs, the command name, and the gen
number:

* session_id-sesslog.jsonl - Records session events, including command starts
  and completions.
* session_id-command_id-name-gen-log.jsonl - Active command progress log.
  Each line contains timestamp, command info, phase, state, progress_completed,
  progress_total, message)
* session_id-command_id-name-gen-log.jsonx - Command progress log after it
  has been archived.
* session_id-command_id-name-gen-start.json - Command start file. Contains
  command info, started_at, os_pid, status, start result or errors.
* session_id-command_id-name-gen-result.json - Command result file. Contains
  command info, completed_at, os_pid, status, completion result or errors.


### Arguments file

There is one file with a well-known name that the Elixir side
places in the `log_dir` directory:

* command_id-gen-name-arg.json - Command arguments file, written by
  the Elixir side before the command script is run.


## Ecto.Changeset-compatible database of Sessions and Tasks

The `LogWatcher.Commands` context module can perform a limited number
of read-only database-like operations, using the log files located in
the `log_dir` directory, and returning data in
`LogWatcher.Commands.Session` and `LogWatcher.Commands.Command` structs.

There is one mutation method, which "archives" a command, by renaming the
command's `log.jsonl` file to `log.jsonx`.


## Command status

Before running the shell script, the `ScriptRunner` module places the
JSON-encoded arguments file for the command in the `log_dir`
directory.

Then the command's shell script is invoked with standard command line
options specifying the `session_id`, `log_dir`, `command_id`,
`name`, and `gen` number.

The shell script (current either Rscript or Python) is responsible for
parsing arguments from the command line and from the arguments file.

While running, a command progresses through seven well-known phases,
identified by the `status` item in the `LogWatcher.Commands.Command` struct:

1. "initializing" - This initial phase comes before command line arguments
  have been parsed and the log file system established. Any errors thrown
  in this phase have to be recovered from the standard output
  (also JSON-encoded) of the script. If no runtime errors (exceptions)
  occur, we do not create a log file but pass directly to the next phase:
2. "created" - The first entry in the log file has been written, and
  therefore, the FileWatcher has been notified. If no exceptions
  occur, we pass to the next phase:
3. "reading" - The command is parsing the JSON-encoded arguments file.
  If no exceptions occur, we pass to the next phase:
4. "validating" - The command is validating the command line and file-based
  arguments. Validation may produce exceptions or non-fatal errors
  such as those produced when arguments do not conform to the
  current state of the session, or if performing the command is not
  permitted while other operations are in progress.
  If no exceptions occur, we pass to the next phase:
5. "running" - The command is performing what could be a long-term
  process. A start file is also written, recording the parsed
  arguments and the time that execution started. The ScriptRunner
  process is sent a `:command_started` message when the FileWatcher
  parses the first log message written in a "running", "cancelled",
  or "completed" phase. Normal execution will pass to either the
  "cancelled" or "completed" phase.
6. "cancelled" - The command system received a message to cancel
  the current command.  If the command can be halted, or happens to
  fail before it can be halted the phase is set to "cancelled".
  The log file may contain errors, but a valid result file will
  never be written for commands that exit in the "cancelled" state.
  If the command manages to complete successfully, despite the
  cancellation request we pass to the next phase:
7. "completed" - The command script was able to complete, whether
  or not a cancellation request was received. The log file may
  contain errors. If no errors were encountered, a result file is
  also written, and the log file will include a pointer
  to the result file.


## Exceptions and cancellations

The Python and Rscript examples will catch any exception
generated while the command is running, convert it into
a structured error, set the command status to "completed",
and exit.

The Python and Rscript examples also trap the POSIX SIGINT
process signal, convert it into a structured error,
set the command status to "cancelled", and exit.

There is testing support on the Elixir side to generate
errors, and to send a "kill -s SIGINT" cancellation message
to a running command.

In a real world system, a command that receives the SIGINT
system will need to clean up and restore any non-log
session data to the state it was prior to the command being
run.

Note: Oban will send an exit signal to a running worker when
a job is canceled, but only if PostgreSQL notifications are
active. In the test environment, we must manually send a
`cancel` command to the `LogWatcher.CommandManager`.


## Oban compatibility

The `LogWatcher.ScriptRunner` module implements the `Oban.Worker`
behaviour, so that a `LogWatcher.Commands.Command` can be
started using Oban's scheduling sytem. Tasks that
encounter exceptions or script-generated errors, return an
`{:ok, result}` tuple, since they are expected to complete
(writing errors to the log file).

Tasks that cannot be started, or have other structural
problems, return a `{:discard, result}` tuple
so that Oban will not attempt to re-run them.

## Supervision tree and processes

![log_watcher_tree.png](log_watcher_tree.png)

The tree below annotates the PIDs in the diagram above.

```
0.322.0 - application_master.init
  0.323.0 - application_master.start_it
    LogWatcher.Supervisor
      0.355.0 - Oban
        0.356.0 - Oban.PostgresNotifier
          0.359.0 - Postgrex.Notifications
        0.357.0 - Oban.Midwife
        0.358.0 - Oban.Plugins.Pruner
        0.360.0 - Oban.Plugins.Stager
        0.361.0 - Oban.Queue.Supervisor
          0.362.0 - Task.Supervisor
          0.363.0 - Oban.Queue.Producer
          0.364.0 - Oban.Queue.Watchman
      LogWatcher.FileWatcherSupervisor
        0.423.0 - LogWatcher.FileWatcher
          0.424.0 - FileSystem.Worker
            0.425.0 - FileSystem.Backends.FSInotify
      LogWatcher.PubSubSupervisor
        LogWatcher.PubSub
          LogWatcher.PubSub.PIDPartition0
          LogWatcher.PubSub.PIDPartition1
        LogWatcher.PubSub.Adapter
      LogWatcher.Repo
        0.326.0 - DBConnection.ConnectionPool
      LogWatcher.CommandManager
      LogWatcher.TaskSupervisor
        0.427.0 - Task [monitored by LogWatcher.CommandManager]
```