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

def read_arg_file(info, arg_file):
  path = os.path.join(info['session_log_path'], arg_file)
  with open(path, 'rt') as f:
    args = json.load(f)
    assert info['session_id'] == args['session_id']
    assert info['task_id'] == args['task_id']
    assert info['task_type'] == args['task_type']
    assert info['gen'] == args['gen']

    for key in ['session_id', 'session_log_path', 'task_id', 'task_type', 'gen']:
        if key in args:
            del args[key]

    task_id = info['task_id']
    info['time'] = format_utcnow()
    info['status'] = 'input'
    info['message'] = f'Task {task_id} parsed {len(args.keys())} args'

    return (info, args)

def mock_status(info, line_no, num_lines, error, cancel):
  raise_error = False
  progress_counter = None
  progress_total = None
  result = None
  errors = []
  if line_no == 1:
    status = 'started'
    if error == 'started':
      raise_error = True
  elif line_no == 2:
    status = 'validating'
    if error == 'validating':
      raise_error = True
  elif line_no < num_lines:
    status = 'running'
    progress_counter = line_no - 2
    progress_total = num_lines - 3
    if line_no == 4:
      if error == 'running':
        raise_error = True
      else:
        if cancel:
          status = 'canceled'
          errors = [{'message': f'canceled on line {line_no}'}]
  else:
    status = 'completed'
    result = {'params': [['a', 2], ['b', line_no]]}

  task_id = info['task_id']
  info['time'] = format_utcnow()
  info['status'] = status
  info['message'] = f'Task {task_id} {status} on line {line_no}'

  if progress_counter is not None and progress_total is not None:
    info['progress_counter'] = progress_counter
    info['progress_total'] = progress_total
    info['progress_phase'] = 'Compiling answers'

  if raise_error:
    raise RuntimeError(f'error on line {line_no}')

  return (info, result, errors)

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

def write_start_file(start_file, info):
  path = os.path.join(info['session_log_path'], start_file)
  with open(path, 'wt') as f:
    json.dump(info, f, indent=2)
    f.write('\n')

  log_event('task_started', info)

def write_result_file(result_file, info, result_data):
  path = os.path.join(info['session_log_path'], result_file)
  with open(path, 'wt') as f:
    result_info = {k: v for k, v in info.items() if k not in ['result']}
    result_info['result'] = {
      'succeeded': info['result']['succeeded'],
      'errors': info['result']['errors'],
      'data': result_data
    }
    json.dump(result_info, f, indent=2)
    f.write('\n')

  event_type = f'''task_{info['status']}'''
  log_event(event_type, info)

def log_event(event_type, info):
  info['event_type'] = event_type
  log_file = f'''{info['session_id']}-sesslog.jsonl'''
  path = os.path.join(info['session_log_path'], log_file)
  with open(path, 'at') as f:
    json.dump(info, f)
    f.write('\n')

def run_job(args):
  session_log_path = args['log_path']
  session_id = args['session_id']
  task_id = args['task_id']
  task_type = args['task_type']
  gen = args['gen']
  error = args['error']
  cancel = args['cancel']

  log_file = log_file_name(task_id, task_type, gen)
  with open(os.path.join(session_log_path, log_file), 'wt') as f:
    os_pid = os.getpid()
    started_at = None
    running_at = None
    write_start = False
    write_result = False

    info = {
      'time': format_utcnow(), 
      'os_pid': os_pid,
      'session_id': session_id, 
      'session_log_path': session_log_path,
      'task_id': task_id, 
      'task_type': task_type, 
      'gen': gen,
      'status': 'created',
      'message': f'Task {task_id} created'
    }
    print(f'mock_task, writing initial log file')
    flush_info(info, f)
    log_event('task_created', info)

    arg_file = arg_file_name(task_id, task_type, gen)
    info, task_args = read_arg_file(info, arg_file)

    print(f'mock_task, task_args are {task_args}')
    flush_info(info, f)

    num_lines = task_args['num_lines']
    for line_no in range(1, num_lines+1):
      time.sleep(0.25)
      info, result, errors = mock_status(info, line_no, num_lines, error, cancel)

      if started_at is None:
        info['started_at'] = started_at = info['time']

      if running_at is None and info['status'] in ['running', 'completed']:
        info['running_at'] = running_at = info['time']
        write_start = True
    
      if info['status'] in ['canceled', 'completed']:
        result_file = result_file_name(task_id, task_type, gen)
        if info['status'] == 'completed' and len(errors) == 0:
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
          'completed_at': info['time'],
          'result': result_info
        })
        write_result = True

      if write_start:
        print(f'mock_task, writing start file')
        start_file = start_file_name(task_id, task_type, gen)
        write_start_file(start_file, info)
        write_start = False

      if write_result and result_file is not None:
        print(f'mock_task, writing result file')
        write_result_file(result_file, info, result)
        write_result = False

      flush_info(info, f)
      if write_result:
        break

    print(f'mock_task, closing log file')


def flush_info(info, f):
  json.dump(info, f)
  f.write('\n')
  f.flush()

if __name__ == '__main__':
  import argparse
  
  parser = argparse.ArgumentParser(description='Run a session task')
  parser.add_argument('-p', '--log-path', help='path containing log file', required=True)
  parser.add_argument('-s', '--session-id', help='session id', required=True)
  parser.add_argument('-i', '--task-id', help='task id', required=True)
  parser.add_argument('-t', '--task-type', help='task type', required=True)
  parser.add_argument('-g', '--gen', help='gen', type=int, required=True)
  parser.add_argument('-c', '--cancel', help='generate canceled result', action='store_true')
  parser.add_argument('-e', '--error', help='phase in which to generate error result')
  args = parser.parse_args()
  run_job(vars(args))
