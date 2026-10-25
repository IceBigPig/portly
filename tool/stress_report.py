#!/usr/bin/env python3
"""Summarize actual stress evidence without turning missing phases into passes."""
import argparse
import datetime
import json
import math
from pathlib import Path
import statistics

parser = argparse.ArgumentParser()
parser.add_argument('directory', type=Path)
parser.add_argument('--output', type=Path)
args = parser.parse_args()
root = args.directory.resolve()
events = [json.loads(line) for line in (root / 'events.jsonl').read_text().splitlines() if line.strip()]
process = [json.loads(line) for line in (root / 'process.jsonl').read_text().splitlines() if line.strip()] if (root / 'process.jsonl').exists() else []
def last(name):
    return next((e for e in reversed(events) if e.get('event') == name), {})
def quantile(values, fraction):
    values = sorted(values)
    return values[math.ceil((len(values)-1)*fraction)] if values else None
start, final, library, archive, history = [last(name) for name in ['start', 'final', 'library_verification', 'archive_verification', 'history_verification']]
source = final.get('source', {}) or last('source_stats')
final_usage = next((row for row in reversed(process) if row.get('event')=='process_final_rusage'),{})
seconds = source.get('elapsed_us', 0) / 1e6
samples = [e for e in events if e.get('event') == 'sample']
early = [e['rss_bytes'] for e in samples if 600 <= e['elapsed_us']/1e6 <= 1200]
late = [e['rss_bytes'] for e in samples if max(1200, seconds-600) <= e['elapsed_us']/1e6 <= seconds]
cpu = [p['cpu_percent_interval'] for p in process if 'cpu_percent_interval' in p]
error_names = {'flutter_error', 'uncaught_error', 'action_error', 'action_overlap', 'input_not_committed', 'input_target_missing', 'pause_target_missing', 'ui_stall', 'recorder_error', 'watchdog_timeout', 'library_ui_target_missing', 'search_verification_error', 'history_verification_error', 'background_query_error', 'shutdown_error'}
errors = [e for e in events if e.get('event') in error_names]
received, sent = final.get('received', []), source.get('sent', [])
max_rss = max([e.get('max_rss_bytes', 0) for e in samples] + [final.get('max_rss_bytes', 0)])
ratio = statistics.mean(late)/statistics.mean(early)-1 if early and late else None
latency_keys = ['switch_latency', 'input_latency', 'pause_latency', 'page_latency']
interaction_ok = bool(final) and all(final.get(key, {}).get('n', 0) >= 100 and final[key]['p95_us'] <= 150000 for key in latency_keys)
retained_rss = [e['rss_bytes'] for e in samples]
report = {
    'generated_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'label':start.get('label'), 'directory':str(root), 'start_at':start.get('at'), 'end_at':final.get('at'),
    'source_wall_seconds':seconds, 'target_events_per_second':start.get('target_events_per_second'),
    'sent_events':sum(sent), 'received_events':sum(received), 'actual_source_events_per_second':sum(sent)/seconds if seconds else None,
    'received_bytes':sum(final.get('rx_bytes', [])),
    'transmitted_bytes':sum(final.get('tx_bytes', [])),
    'source_received_tx_bytes':source.get('tx_bytes'),
    'source_tx_corrupt':source.get('tx_corrupt'),
    'checkpoint_30m':last('checkpoint_30m'),
    'per_session_sent':sent, 'per_session_received':received,
    'gaps':sum(final.get('gaps', [])), 'duplicates':sum(final.get('duplicates', [])), 'corrupt':sum(final.get('corrupt', [])), 'source_send_failures':sum(source.get('failed', [])),
    'max_observed_rss_bytes':max(retained_rss+[final.get('rss_bytes', 0)]), 'process_peak_rss_bytes':max_rss,
    'stable_window_600_1200_average_rss_bytes':statistics.mean(early) if early else None,
    'last_600_seconds_average_rss_bytes':statistics.mean(late) if late else None,
    'stable_window_rss_growth_fraction':ratio,
    'cpu_interval_percent_p50':quantile(cpu,.5),'cpu_interval_percent_p95':quantile(cpu,.95),
    'process_final_rusage':final_usage,
    'process_final_rusage_available':bool(final_usage) and 'rusage_error' not in final_usage,
    'process_diskio_byteswritten_complete':final_usage.get('diskio_byteswritten'),
    'process_logical_writes_complete':final_usage.get('logical_writes'),
    'shutdown':last('shutdown_verification'),
    'process_diskio_bytesread_last_sample':max([p.get('diskio_bytesread',0) for p in process], default=0),
    'process_diskio_byteswritten_last_sample':max([p.get('diskio_byteswritten',0) for p in process], default=0),
    'process_logical_writes_last_sample':max([p.get('logical_writes',0) for p in process], default=0),
    'process_peak_physical_footprint_last_sample':max([p.get('lifetime_max_phys_footprint',0) for p in process], default=0),
    'cache_records':final.get('cache_records'),'cache_bytes':final.get('cache_bytes'),'cache_evicted':final.get('cache_evicted'),
    'wave_samples':final.get('wave_samples'),'wave_errors':final.get('wave_errors'),
    'reopens':len([e for e in events if e.get('event')=='reopen']),
    'archive':archive, 'history':history, 'library':library,
    'latencies':{key:final.get(key) for key in latency_keys+['archive_search_latency','history_query_latency','frame_total','frame_build','frame_raster','event_loop_delay']},
    'error_events':errors, 'recorder_errors':final.get('recorder_errors'),
    'process_exit':process[-1].get('exit') if process else None,
    'checks': {
        'complete_2h_wall_clock':bool(final) and seconds >= 7200,
        'target_source_rate_within_0_1_percent':bool(seconds) and abs(sum(sent)/seconds-start.get('target_events_per_second',2000)) <= start.get('target_events_per_second',2000)*.001,
        'checkpoint_30m_complete':last('checkpoint_30m').get('source',{}).get('elapsed_us',0)>=1800000000,
        'checkpoint_30m_interaction_p95_150ms':bool(last('checkpoint_30m')) and all(last('checkpoint_30m').get(key,{}).get('n',0)>=100 and last('checkpoint_30m')[key]['p95_us']<=150000 for key in latency_keys),
        'no_1_second_ui_isolate_stall':bool(final) and final.get('event_loop_delay',{}).get('n',0)>0 and final['event_loop_delay']['max_us']<1000000,
        'exact_transmitted_byte_counts_and_fields':bool(final) and len(source.get('tx_bytes',[]))==8 and source['tx_bytes']==final.get('tx_bytes') and sum(source.get('tx_corrupt',[]))==0,
        'exact_datagram_counts':bool(final) and len(sent)==8 and sent==received,
        'no_gaps_duplicates_or_corrupt_data':bool(final) and all(sum(final.get(k,[]))==0 for k in ['gaps','duplicates','corrupt']),
        'no_source_send_errors':bool(source) and sum(source.get('failed', []))==0,
        'no_instrumented_error_events':not errors and bool(final),
        'interaction_p95_budget_150ms_100_samples_each':interaction_ok,
        'load_rss_budget_450mib':bool(final) and max_rss<=450*1024*1024,
        'stable_memory_growth_10_percent':ratio is not None and ratio<=.1,
        'no_residual_send_tasks':bool(final) and final.get('active_tasks')==0,
        'raw_cache_bounded_100000':bool(final) and final.get('cache_records', 100001)<=100000,
        'wave_cache_bounded_250000':bool(final) and final.get('wave_samples',250001)<=250000,
        'archive_records_match_expected':bool(archive) and archive.get('records')==archive.get('expected_records'),
        'shutdown_drained_and_storage_closed':last('shutdown_verification').get('shutdown_complete') is True and not last('shutdown_verification').get('close_error') and last('shutdown_verification').get('active_tasks')==0,
        'full_retained_history_has_no_nonterminal':bool(history) and history.get('verified_all_records')==history.get('retained_count') and history.get('unique_ids')==history.get('retained_count') and history.get('nonterminal')==0,
        'history_bounded_1000_32mib':bool(history) and history.get('retained_count',1001)<=1000 and history.get('retained_bytes',32*1024*1024+1)<=32*1024*1024 and not history.get('error') and history.get('dropped')==0,
        '5000_library_100_groups_export_roundtrip':bool(library) and library.get('commands')==5000 and library.get('groups')==100 and library.get('exported_commands')==5000,
        'library_search_group_p95_budget_200ms':bool(library) and all(library.get(key,{}).get('n',0)>=100 and library[key]['p95_us']<=200000 for key in ['search_latency','group_latency']),
    },
    'measurement_notes':[
        'Disk IO counters come from macOS proc_pid_rusage v4. They are process kernel accounting, not physical NAND wear or disk lifespan estimates.',
        'The CPU measure includes the independent UDP source isolate and harness in the application process.',
        'Input/pause are production widget callbacks; switch/page are production model callbacks. End-of-frame latency excludes OS input scheduling and physical screen presentation.',
        'Frame and event-loop percentiles use fixed 50 microsecond histogram buckets and report upper bucket edges.',
        'A missing or too-short phase remains false, including 2h and stable-memory checks on a calibration.',
    ],
}
text = json.dumps(report, ensure_ascii=False, indent=2)+'\n'
if args.output:
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(text)
else:
    print(text)
