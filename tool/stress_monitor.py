#!/usr/bin/env python3
"""Launch only the isolated pressure binary and sample its process every 10 s."""
import ctypes
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import time

# Struct and flavor from the local macOS SDK sys/resource.h (rusage_info_v4).
class RusageV4(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        'user_time system_time pkg_idle_wkups interrupt_wkups pageins wired_size resident_size phys_footprint '
        'proc_start_abstime proc_exit_abstime child_user_time child_system_time child_pkg_idle_wkups '
        'child_interrupt_wkups child_pageins child_elapsed_abstime diskio_bytesread diskio_byteswritten '
        'cpu_time_qos_default cpu_time_qos_maintenance cpu_time_qos_background cpu_time_qos_utility '
        'cpu_time_qos_legacy cpu_time_qos_user_initiated cpu_time_qos_user_interactive billed_system_time '
        'serviced_system_time logical_writes lifetime_max_phys_footprint instructions cycles billed_energy '
        'serviced_energy interval_max_phys_footprint runnable_time'
    ).split()]
libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
libproc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
libproc.proc_pid_rusage.restype = ctypes.c_int

root = Path(sys.argv[1]).resolve()
max_seconds = int(sys.argv[2]) + 240 if len(sys.argv) > 2 else 7800
with (root / 'process.txt').open('w') as output, (root / 'process.jsonl').open('w') as metrics:
    process = subprocess.Popen([str(root / 'PortlyPressure.app/Contents/MacOS/Portly')], stdout=output, stderr=subprocess.STDOUT)
    (root / 'pid').write_text(str(process.pid))
    caffeine = subprocess.Popen(['/usr/bin/caffeinate', '-d', '-i', '-w', str(process.pid)])
    started = time.monotonic()
    previous_cpu = None
    previous_time = None
    while True:
        # Keep an exited child unreaped long enough to read complete kernel IO.
        # Verified on this macOS with a controlled 4 MiB child write.
        ended = os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOWAIT | os.WNOHANG)
        if ended is not None:
            break
        if time.monotonic() - started > max_seconds:
            metrics.write(json.dumps({'event':'monitor_timeout'})+'\n')
            process.kill()
            os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOWAIT)
            break
        result = subprocess.run(['/bin/ps', '-p', str(process.pid), '-o', 'pid=,etime=,pcpu=,rss=,vsz=,state=,time='], text=True, capture_output=True)
        row = {'at':datetime.datetime.now(datetime.timezone.utc).isoformat(), 'ps':result.stdout.strip()}
        usage = RusageV4()
        if libproc.proc_pid_rusage(process.pid, 4, ctypes.byref(usage)) == 0:
            row.update({name:getattr(usage,name) for name in ['phys_footprint','lifetime_max_phys_footprint','diskio_bytesread','diskio_byteswritten','logical_writes']})
        else:
            row['rusage_error'] = ctypes.get_errno()
        cells = result.stdout.split()
        now = time.monotonic()
        if len(cells) >= 7:
            parts = cells[-1].split(':')
            cpu = 0.0
            for part in parts:
                cpu = cpu * 60 + float(part)
            row.update({'rss_kib':int(cells[3]),'cpu_seconds':cpu,'pcpu_ps':float(cells[2])})
            if previous_cpu is not None:
                row['cpu_percent_interval'] = (cpu - previous_cpu) * 100 / (now - previous_time)
            previous_cpu, previous_time = cpu, now
        metrics.write(json.dumps(row)+'\n')
        metrics.flush()
        time.sleep(10)
    final_usage = RusageV4()
    final_row = {'event':'process_final_rusage','at':datetime.datetime.now(datetime.timezone.utc).isoformat()}
    if libproc.proc_pid_rusage(process.pid, 4, ctypes.byref(final_usage)) == 0:
        final_row.update({name:getattr(final_usage,name) for name in ['phys_footprint','lifetime_max_phys_footprint','diskio_bytesread','diskio_byteswritten','logical_writes']})
    else:
        final_row['rusage_error'] = ctypes.get_errno()
    metrics.write(json.dumps(final_row)+'\n')
    process.wait(timeout=10)
    metrics.write(json.dumps({'at':datetime.datetime.now(datetime.timezone.utc).isoformat(), 'exit':process.returncode})+'\n')
    (root / 'exit_code').write_text(str(process.returncode))
    caffeine.wait(timeout=5)
    sys.exit(process.returncode)
