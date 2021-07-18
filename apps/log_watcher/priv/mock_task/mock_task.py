#!/usr/bin/env python3
import datetime
import json
import os
import random
import time

# TODO: put these in -log.jsonl, -start.json, and/or -result.json
# 'time' 
# 'started_at'
# 'completed_at'
# 'result'
# 'errors'

def format_utcnow():
  return datetime.datetime.utcnow().isoformat(timespec='milliseconds')

def mock_status(line_no, length, error, cancel):
  progress_counter = None
  progress_total = None
  result = None
  errors = []
  if line_no == 1:
    status = 'started'
  elif line_no == 2:
    status = 'validating'
  elif line_no < length:
    status = 'running'
    progress_counter = line_no - 2
    progress_total = length - 3
  else:
    if cancel:
      status = 'canceled'
      errors = [{'message': f'canceled on line {line_no}'}]
    else:
      status = 'completed'
      if error:
        errors = [{'message': f'error on line {line_no}', 'key': 'task_id'}]
      else:
        result = {'params': [['a', 2], ['b', line_no]]}
  return (status, progress_counter, progress_total, result, errors)

def make_log_prefix(task_id, task_type, gen):
  gen_str = str(gen).zfill(4)
  return f'{task_id}-{task_type}-{gen_str}'

def log_file_name(task_id, task_type, gen):
  return f'{make_log_prefix(task_id, task_type, gen)}-log.jsonl'

def arg_file_name(task_id, task_type, gen):
  return f'{make_log_prefix(task_id, task_type, gen)}-arg.json'

def start_file_name(task_id, task_type, gen):
  return f'{make_log_prefix(task_id, task_type, gen)}-start.json'

def result_file_name(task_id, task_type, gen):
  return f'{make_log_prefix(task_id, task_type, gen)}-result.json'

# No 'os_pid' in arg file
ARG_KEYS = ['time', 'session_id', 'task_id', 'task_type', 'gen']

def write_arg_file(path, info):
  with open(path, 'wt') as f:
    arg_info = {k: v for k, v in info.items() if k in ARG_KEYS}
    arg_info.update({'arg': {'space_type': 'mixture'}})
    json.dump(arg_info, f, indent=2)
    f.write('\n')

def write_start_file(path, info):
  with open(path, 'wt') as f:
    json.dump(info, f, indent=2)
    f.write('\n')

def write_result_file(path, info, result_data):
  with open(path, 'wt') as f:
    result_info = {k: v for k, v in info.items() if k not in ['result']}
    result_info['result'] = {
      'succeeded': info['result']['succeeded'],
      'errors': info['result']['errors'],
      'data': result_data
    }
    json.dump(result_info, f, indent=2)
    f.write('\n')

def run_job(args):
  session_log_path = args['log_path']
  session_id = args['session_id']
  task_id = args['task_id']
  task_type = args['task_type']
  gen = args['gen']
  length = args['length']
  error = args['error']
  cancel = args['cancel']

  log_file_path = os.path.join(session_log_path, log_file_name(task_id, task_type, gen))
  print(f'running mock_task, writing {length} lines to {log_file_path}')

  with open(log_file_path, 'wt') as f:
    os_pid = os.getpid()
    started_at = None
    running_at = None
    write_start = False
    write_result = False
    result_file = result_file_name(task_id, task_type, gen)
    for line_no in range(1, length+1):
      time.sleep(1.)
      now = format_utcnow()

      status, progress_counter, progress_total, result, errors = mock_status(line_no, length, error, cancel)
      info = {
        'time': now, 
        'os_pid': os_pid,
        'session_id': session_id, 
        'task_id': task_id, 
        'task_type': task_type, 
        'gen': gen,
        'status': status,
        'message': f'Task {task_id} is {status} {line_no}'
      }
      if progress_counter is not None and progress_total is not None:
        info['progress_counter'] = progress_counter
        info['progress_total'] = progress_total
        info['progress_phase'] = 'Compiling answers'

      if started_at is None:
        write_arg_file(os.path.join(session_log_path, arg_file_name(task_id, task_type, gen)), info)
        info['started_at'] = started_at = now

      if running_at is None and status in ['running', 'completed']:
        info['running_at'] = running_at = now
        write_start = True

      if status in ['canceled', 'completed']:
        if status == 'completed' and len(errors) == 0:
          result_info = {
            'succeeded': True,
            'file': result_file,
            'errors': errors
          }
        else:
          result_info = {
            'succeeded': False,
            'file': result_file,
            'errors': errors
          }
        info.update({
          'completed_at': now,
          'result': result_info
        })
        write_result = True

      if write_start:
        write_start_file(os.path.join(session_log_path, start_file_name(task_id, task_type, gen)), info)
        write_start = False

      if write_result:
        write_result_file(os.path.join(session_log_path, result_file), info, result)
        write_result = False

      json.dump(info, f)
      f.write('\n')
      f.flush()
      if write_result:
        break

if __name__ == '__main__':
  import argparse
  
  parser = argparse.ArgumentParser(description='Run a session task')
  parser.add_argument('-p', '--log-path', help='directory containing log file', required=True)
  parser.add_argument('-s', '--session-id', help='session id', required=True)
  parser.add_argument('-i', '--task-id', help='task id', required=True)
  parser.add_argument('-t', '--task-type', help='task type', required=True)
  parser.add_argument('-g', '--gen', help='generation number', type=int, required=True)
  parser.add_argument('-l', '--length', help='number of lines', type=int, default=10)
  parser.add_argument('-c', '--cancel', help='generate canceled result', action='store_true')
  parser.add_argument('-e', '--error', help='generate error result', action='store_true')
  args = parser.parse_args()
  run_job(vars(args))
