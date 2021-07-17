#!/usr/bin/env python3

import argparse
import json
import time

# TODO: put these in -log.jsonl, -start.json, and/or -result.json
# 'time' 
# 'started_at'
# 'completed_at'
# 'result'
# 'errors'

def run_job(args):
  log_path = args['log_path']
  session_id = args['session_id']
  task_id = args['task_id']
  task_type = args['task_type']
  gen = args['gen']
  length = args['length']

  print(f'running mock_task, writing {length} lines to {log_path}')
  with open(log_path, 'wt') as f:
    for line_no in range(1, length+1):
      time.sleep(1.)
      result = None
      if line_no == 1:
        status = 'started'
      elif line_no == 2:
        status = 'validating'
      elif line_no < length:
        status = 'running'
      else:
        status = 'completed'
        result = line_no
      line = {'timestamp': line_no, 
        'session_id': session_id, 'task_id': task_id, 
        'task_type': task_type, 'gen': gen, 
        'status': status, 'data': line_no}
      if result is not None:
        line['result'] = result
      json_line = json.dumps(line)
      f.write(json_line)
      f.write('\n')
      f.flush()

if __name__ == '__main__':
  parser = argparse.ArgumentParser(description='Run a session task')
  parser.add_argument('--log-path', help='path to log file', required=True)
  parser.add_argument('--session-id', help='session id', required=True)
  parser.add_argument('--task-id', help='task id', required=True)
  parser.add_argument('--task-type', help='task type', required=True)
  parser.add_argument('--gen', help='generation number', type=int, required=True)
  parser.add_argument('--length', help='number of lines', type=int, default=10)
  args = parser.parse_args()
  run_job(vars(args))
