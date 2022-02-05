#!/usr/bin/env python3

import datetime
import json
import os
import signal
import sys
import time
import traceback

class CancelException(RuntimeError):
  pass

# TODO: put these in -log.jsonl, -start.json, and/or -result.json
# 'time'
# 'started_at'
# 'completed_at'
# 'result'
# 'errors'

def format_utcnow():
  return datetime.datetime.utcnow().isoformat(timespec='milliseconds')

def read_arg_file(info, arg_file):
  path = os.path.join(info['log_dir'], arg_file)
  with open(path, 'rt') as f:
    args = json.load(f)
    assert info['session_id'] == args['session_id']
    assert info['command_id'] == args['command_id']
    assert info['command_name'] == args['command_name']
    assert info['gen'] == args['gen']

    for key in ['session_id', 'log_dir', 'command_id', 'command_name', 'gen']:
        if key in args:
            del args[key]

    command_id = info['command_id']
    info['time'] = format_utcnow()
    info['status'] = 'input'
    info['message'] = f'Command {command_id} parsed {len(args.keys())} args'

    return (info, args)

def mock_status(info, line_no, num_lines, error):
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
    status = 'completed'
    result = {'params': [['a', 2], ['b', line_no]]}

  command_id = info['command_id']
  info['time'] = format_utcnow()
  info['status'] = status
  info['message'] = f'Command {command_id} {status} on line {line_no}'
  set_script_status(status)

  if progress_counter is not None and progress_total is not None:
    info['progress_counter'] = progress_counter
    info['progress_total'] = progress_total
    info['progress_phase'] = 'Compiling answers'

  if raise_error:
    raise RuntimeError(f'error on line {line_no}')

  return (info, result, errors)

def make_log_prefix(session_id, gen, command_id, name):
  gen_str = str(gen).zfill(4)
  return f'{session_id}-{gen_str}-{name}-{command_id}'

def log_file_name(session_id, gen, command_id, name):
  return f'{make_log_prefix(session_id, gen, command_id, name)}-log.jsonl'

def arg_file_name(session_id, gen, command_id, name):
  return f'{make_log_prefix(session_id, gen, command_id, name)}-arg.json'

def start_file_name(session_id, gen, command_id, name):
  return f'{make_log_prefix(session_id, gen, command_id, name)}-start.json'

def result_file_name(session_id, gen, command_id, name):
  return f'{make_log_prefix(session_id, gen, command_id, name)}-result.json'

# No 'os_pid' in arg file
ARG_KEYS = ['session_id', 'command_id', 'command_name', 'gen', 'time']

def write_start_file(start_file, info):
  path = os.path.join(info['log_dir'], start_file)
  try:
    with open(path, 'wt') as f:
      json.dump(info, f, indent=2)
      f.write('\n')
  except:
    pass

  log_event('command_started', info)

def write_result_file(result_file, info, result_data):
  path = os.path.join(info['log_dir'], result_file)
  try:
    with open(path, 'wt') as f:
      result_info = {k: v for k, v in info.items() if k not in ['result']}
      result_info['result'] = {
        'succeeded': info['result']['succeeded'],
        'errors': info['result']['errors'],
        'data': result_data
      }
      json.dump(result_info, f, indent=2)
      f.write('\n')
  except:
    pass

  event_type = f'''command_{info['status']}'''
  log_event(event_type, info)

def log_event(event_type, info):
  info['event_type'] = event_type
  log_file = f'''{info['session_id']}-sesslog.jsonl'''
  path = os.path.join(info['log_dir'], log_file)
  try:
    f = open(path, 'at')
    json.dump(info, f)
    f.write('\n')
    f.close()
  except:
    pass

def make_error_list(errors, system = True, fatal = True):
  global _global_args
  category = _global_args['status']
  return [{
    'message': error,
    'category': category,
    'system': system,
    'fatal': fatal} for error in errors]

def get_traceback(error_type):
  _type, value, tb = sys.exc_info()
  tb_summary = traceback.extract_tb(tb)
  tb_list = [frame.line for frame in tb_summary]

  # tb_stack = traceback.extract_stack(limit=7)
  # tb_list = traceback.format_list(tb_stack)
  # tb_list = [text for (file, line, func, text) in tb_stack]

  if error_type == 'interrupt':
    stack_msg = tb_list[0:-2]
  else:
    stack_msg = tb_list
  info = {
    'error_type': error_type,
    'error': str(value),
    'call': tb_summary[-1].name,
    'traceback': stack_msg
  }
  return info

def log_error(error_type):
  global _global_args

  trace = get_traceback(error_type)
  message = trace['error']

  result_file = result_file_name(_global_args['session_id'], _global_args['gen'], _global_args['command_id'], _global_args['command_name'])

  result_info = {
    'succeeded': False,
    'file': result_file,
    'errors': make_error_list([message])
  }

  if trace['error_type'] == 'interrupt':
    status = 'cancelled'
  else:
    status = 'completed'

  set_script_status(status)
  info = {
    'time': format_utcnow(),
    'os_pid': _global_args['os_pid'],
    'session_id': _global_args['session_id'],
    'log_dir': _global_args['log_dir'],
    'command_id': _global_args['command_id'],
    'command_name': _global_args['command_name'],
    'gen': _global_args['gen'],
    'message': message,
    'status': status,
    'result': result_info,
    'call': trace['call'],
    'traceback': trace['traceback']
  }
  write_result_file(result_file, info, None)
  if _global_args['log_f']:
    log_info(info, _global_args['log_f'], suppress_exception = True)

def set_script_status(status):
  global _global_args
  _global_args['status'] = status

def cancel_command(signal_number, frame):
  raise CancelException(f'signal #{signal_number} received')

def run_command():
  global _global_args
  log_dir = _global_args['log_dir']
  session_id = _global_args['session_id']
  command_id = _global_args['command_id']
  command_name = _global_args['command_name']
  gen = _global_args['gen']
  error = _global_args['error']
  os_pid = _global_args['os_pid']

  log_file = log_file_name(session_id, gen, command_id, command_name)
  log_file_path = os.path.join(log_dir, log_file)
  _global_args['log_f'] = log_file_path
  started_at = None
  running_at = None
  write_start = False
  write_result = False

  set_script_status('created')
  info = {
    'time': format_utcnow(),
    'os_pid': os_pid,
    'session_id': session_id,
    'log_dir': log_dir,
    'command_id': command_id,
    'command_name': command_name,
    'gen': gen,
    'status': 'created',
    'message': f'Command {command_id} created'
  }

  jcat('writing initial log file')
  log_info(info, log_file_path, initial = True)
  log_event('command_created', info)

  signal.signal(signal.SIGINT, cancel_command)

  arg_file = arg_file_name(session_id, gen, command_id, command_name)
  try:
    info, command_args = read_arg_file(info, arg_file)
  except:
    set_script_status('completed')
    jcat(f'could not parse args from {arg_file}')
    sys.exit(1)

  jcat(f'command_args are {command_args}')
  log_info(info, log_file_path)

  sleep_time = 1.0
  num_lines = command_args['num_lines']
  for line_no in range(1, num_lines+1):
    info, result, errors = mock_status(info, line_no, num_lines, error)

    if started_at is None:
      info['started_at'] = started_at = info['time']

    if running_at is None and info['status'] in ['running', 'completed']:
      info['running_at'] = running_at = info['time']
      write_start = True

    if info['status'] in ['cancelled', 'completed']:
      result_file = result_file_name(session_id, gen, command_id, command_name)
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
      jcat('writing start file')
      start_file = start_file_name(session_id, gen, command_id, command_name)
      write_start_file(start_file, info)
      write_start = False
      sleep_time = 0.25

    if write_result and result_file is not None:
      jcat('writing result file')
      write_result_file(result_file, info, result)
      write_result = False

    log_info(info, log_file_path)
    if write_result:
      if error == 'forever':
        jcat('running forever...')
        while True:
          time.sleep(sleep_time)
      else:
        break
    else:
      time.sleep(sleep_time)

  jcat('closing log file')

def jcat(message):
  global _global_args
  if type(message) is dict:
    message_data = message
  else:
    message_data = {
      'time': format_utcnow(),
      'message': message.strip(),
      'status': _global_args['status']
    }
  print(to_json_line(message_data, append_newline = False))

def to_json_line(data, append_newline = True):
  line = json.dumps(data)
  if append_newline:
    line = line + '\n'
  return line

def log_info(info, log_file_path, initial = False, suppress_exception = False):
  mode = 'wt' if initial else 'at'
  try:
    f = open(log_file_path, mode)
    json.dump(info, f)
    f.write('\n')
    f.close()
  except OSError:
    if initial and not suppress_exception:
      raise RuntimeError(f'cannot open log file {log_file_path}')
    else:
      jcat(info, info)

if __name__ == '__main__':
  import argparse

  # In Python 3.9, we can use exit_on_error = False
  parser = argparse.ArgumentParser(description='Run a session command')
  parser.add_argument('-p', '--log-dir', help='directory containing log file', required=True)
  parser.add_argument('-s', '--session-id', help='session id', required=True)
  parser.add_argument('-i', '--command-id', help='command id', required=True)
  parser.add_argument('-n', '--command-name', help='command name', choices = ['create', 'update', 'generate', 'analytics'], required=True)
  parser.add_argument('-g', '--gen', help='gen', type=int, required=True)
  parser.add_argument('-e', '--error', help='phase in which to generate error result')

  try:
    args = parser.parse_args()
  except argparse.ArgumentError as e:
    _global_args = {}
    _global_args['os_pid'] = os_pid = os.getpid()
    _global_args['status'] = 'initializing'
    _global_args['log_f'] = None
    jcat(f'invalid arguments: {e}')
    sys.exit(1)

  _global_args = vars(args)
  _global_args['os_pid'] = os_pid = os.getpid()
  _global_args['status'] = 'initializing'
  _global_args['log_f'] = None
  jcat(f'script started. cancel with:\n  kill -s INT {os_pid}')
  try:
    run_command()
  except CancelException:
    log_error('interrupt')
  except Exception:
    log_error('error')
