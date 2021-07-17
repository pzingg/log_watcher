# LogWatcherUmbrella

LogWatcher application shows how to use inotify-type tools to monitor 
JSON-formatted log files to monitor long-running tasks.

## TODO

Real time PubSub notifications are working now. But what is needed is 
a file-system-based query system to check for active tasks, determined
by the absence, or the presence and content of files with well-known
names:

* task_id-gen-task_type-log.jsonl - Active task progress log. Each line contains timestamp, task info, phase, state, progress_completed, progress_total, message)
* task_id-gen-task_type-log.jsonx - Task progress log after it has been archived.
* task_id-gen-task_type-start.json - Task start file. Contains task info, started_at, os_pid, status, start result or errors.
* task_id-gen-task_type-result.json - Task result file. Contains task info, completed_at, os_pid, status, completion result or errors.


## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `log_watcher_umbrella` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:log_watcher_umbrella, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/log_watcher_umbrella](https://hexdocs.pm/log_watcher_umbrella).

