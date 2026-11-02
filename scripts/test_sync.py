#!/usr/bin/env python3
"""Production EPGViewModel integration tests against a private loopback API.

Only persistence/keychain/player dependencies are stubbed; actual production
view model, Xtream/Stalker clients and M3U/XMLTV parsers compile unchanged.
"""
import collections
import datetime
import http.server
import json
import pathlib
import subprocess
import threading
import time
import unittest
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parent.parent
BRIDGE_HEADER = 'benchmarks/epg_test_bridge.h'
SOURCES = [
    'Buffer/Models/SourceChannelIdentity.swift', 'Buffer/Models/Channel.swift', 'Buffer/Models/EPGProgram.swift',
    'Buffer/Models/ServerConfig.swift', 'Buffer/Models/VODItem.swift',
    'Buffer/Models/StreamProbe.swift',
    'Buffer/Models/SmartSports.swift', 'Buffer/Services/AccountCapacityLedger.swift',
    'Buffer/Services/SmartSportsCatalog.swift', 'Buffer/Services/SmartSportsCatalogStore.swift',
    'Buffer/Services/SmartSportsSnapshotLoader.swift', 'Buffer/Models/SmartChannelFilter.swift', 'Buffer/Services/AutoChannelGrouper.swift', 'Buffer/Services/BackgroundSourceRefresher.swift', 'Buffer/Services/BackgroundRefreshPolicy.swift', 'Buffer/Services/SmartSportsCoordinator.swift',
    'Buffer/Models/VODSeries.swift', 'Buffer/Models/ServerAccountStatus.swift',
    'Buffer/Models/ProgramReminder.swift', 'Buffer/Models/SyncInterval.swift',
    'Buffer/Models/PlaybackRequest.swift',
    'Buffer/Services/XtreamClient.swift', 'Buffer/Services/StalkerClient.swift',
    'Buffer/Services/M3UParser.swift', 'Buffer/Support/PerfMetrics.swift', 'Buffer/Services/XMLTVParser.swift',
    'Buffer/Support/AppLog.swift', 'Buffer/Support/GuideLookup.swift', 'Buffer/Support/GuideHistory.swift',
    'Buffer/Views/ProgramSearchIndex.swift', 'benchmarks/sync_test_support.swift', 'Buffer/ViewModels/EPGViewModel.swift',
    'benchmarks/sync_integration.swift',
]

class SyncHTTPTests(unittest.TestCase):
    expect_parallel_catalog = True
    expect_visible_priority = True
    measure_only = False
    @classmethod
    def setUpClass(cls):
        cls.executable = ROOT / '.local/bench/sync-tests'
        cls.executable.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['swiftc', '-O', '-D', 'GUIDE_PRODUCTION_METRICS', '-I', 'Buffer/SwiftLibxml2', '-import-objc-header', BRIDGE_HEADER, *SOURCES,
                        '-o', str(cls.executable)], cwd=ROOT, check=True, timeout=90)

    def run_scenario(self, scenario):
        counts = collections.Counter()
        request_times = {}
        request_order = []
        stream_counts = collections.Counter()
        fixture_now = datetime.datetime.now(datetime.timezone.utc)
        lock = threading.Lock()
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self):
                parts = urllib.parse.urlsplit(self.path)
                source = parts.path.split('/')[1]
                query = urllib.parse.parse_qs(parts.query)
                action = query.get('action', ['guide' if parts.path.endswith('xmltv.php') else 'account'])[0]
                revision = query.get('password', [''])[0]
                with lock:
                    counts[(source, action)] += 1
                    request_times[(source, action)] = time.monotonic()
                    request_number = counts[(source, action)]
                    if action == 'get_simple_data_table':
                        stream_id = query.get('stream_id', [''])[0]
                        request_order.append(stream_id)
                        stream_counts[stream_id] += 1
                        stream_request_number = stream_counts[stream_id]
                title = source
                if scenario == 'source-edit' and revision == 'revision-B': title += ' New'
                delay = 0.02
                if action == 'guide':
                    if scenario == 'xml-cancel': delay = 1.5
                    elif scenario == 'source-switch': delay = 0.5 if source == 'A' else 0.95
                    elif scenario in ('scope-upgrade', 'lookback-inflight'): delay = 0.3
                    elif scenario == 'source-edit': delay = 0.5 if revision == 'revision-A' else 0.02
                if action in ('get_vod_streams', 'get_series'):
                    if scenario in ('overlap', 'disable-inflight', 'toggle-vod-inflight', 'hydration-toggle-inflight'): delay = 0.65
                    elif scenario == 'source-switch': delay = 0.7 if source == 'A' else 1.0
                    elif scenario == 'source-edit': delay = 0.7 if revision == 'revision-A' else 0.04
                if action in ('get_vod_info', 'get_series_info'):
                    delay = 0.35 if source == 'A' else 0.65
                if scenario == 'status-switch' and source == 'A' and action == 'account': delay = 0.35
                if scenario.startswith('guide-'):
                    if action == 'guide' and (query.get('prev_days', ['1'])[0] != '1' or scenario == 'guide-slow-xml'): delay = 1.5
                    elif action == 'get_simple_data_table':
                        sid = int(query.get('stream_id', ['0'])[0])
                        delay = .04 if sid >= 88 else .09
                if scenario == 'stalker-guide' and action == 'get_epg_info': delay = .03 if query.get('period', ['24'])[0] == '24' else 1.5
                time.sleep(delay)
                if scenario == 'stalker-guide' and action == 'get_epg_info' and query.get('period', ['24'])[0] != '24':
                    self.send_error(503)
                    return
                if scenario.startswith('guide-') and action == 'guide' and query.get('prev_days', ['1'])[0] != '1':
                    self.send_error(503)
                    return
                if scenario.startswith('guide-') and action == 'get_simple_data_table' and int(query.get('stream_id', ['0'])[0]) % 13 == 0:
                    self.send_error(503)
                    return
                if scenario == 'cache-failed-refresh-relaunch' and revision == 'revision-B':
                    self.send_error(503)
                    return
                if scenario == 'episodes-retry' and action == 'get_series_info' and request_number == 1:
                    self.send_error(503)
                    return
                if ((scenario == 'catalog-partial' and action == 'get_vod_streams') or
                    (scenario == 'catalog-all-fail' and action in ('get_vod_streams', 'get_series'))):
                    self.send_error(503)
                    return
                if action == 'guide':
                    now = datetime.datetime.now(datetime.timezone.utc)
                    start = (now - datetime.timedelta(minutes=30)).strftime('%Y%m%d%H%M%S +0000')
                    end = (now + datetime.timedelta(hours=3)).strftime('%Y%m%d%H%M%S +0000')
                    if scenario.startswith('guide-'):
                        listings = []
                        for sid in range(96):
                            if scenario == 'guide-empty-xml': continue
                            listings.append(f'<programme start="{start}" stop="{end}" channel="epg-{sid}"><title>Current {sid}</title></programme>')
                        body = ('<tv>' + ''.join(listings) + '</tv>').encode()
                    else:
                        body = f'<tv><programme channel="epg-1" start="{start}" stop="{end}"><title>{title} Guide</title></programme></tv>'.encode()
                else:
                    if scenario == 'stalker-guide':
                        if action == 'handshake': inner = dict(token='fixture-token')
                        elif action == 'get_main_info': inner = dict(mac='00:11:22:33:44:55')
                        elif action == 'get_genres': inner = [dict(id='1', title='Test')]
                        elif action == 'get_all_channels': inner = dict(total_items=1, max_page_items=1, data=[dict(id='1', name='Stalker Channel', cmd=f'http://127.0.0.1:{self.server.server_port}/1.ts', xmltv_id='external-guide', enable_tv_archive='1', tv_archive_duration='7')])
                        elif action == 'get_epg_info':
                            begin = fixture_now - datetime.timedelta(minutes=30)
                            stop = fixture_now + datetime.timedelta(hours=3)
                            entries = [dict(id=123, ch_id=1, name='Stalker Current', start_timestamp=str(int(begin.timestamp())), stop_timestamp=str(int(stop.timestamp())))]
                            for offset, blank_id in [(-48, ''), (-36, ' ')]:
                                history_start = fixture_now + datetime.timedelta(hours=offset)
                                entries.append(dict(id=blank_id, ch_id=1, name='Stalker Archive', start_timestamp=str(int(history_start.timestamp())), stop_timestamp=str(int((history_start + datetime.timedelta(hours=1)).timestamp()))))
                            entries.append(dict(id='titleless', ch_id=1, name='', start_timestamp=str(int(begin.timestamp())), stop_timestamp=str(int(stop.timestamp()))))
                            inner = dict(data={'1': entries})
                        else: inner = {}
                        payload = dict(js=inner)
                    elif action == 'get_live_streams':
                        if scenario.startswith('guide-'):
                            payload = [dict(stream_id=str(i), name='Sky Sport 1 UHD (NZ)' if scenario == 'guide-unmatched-id' and i == 90 else f'Channel {i}', epg_channel_id=('shared-guide' if scenario == 'guide-alias' and i >= 88 else '' if scenario == 'guide-missing-id' and i == 90 else 'sky-sport-1-nz-uhd' if scenario == 'guide-unmatched-id' and i == 90 else f'epg-{i}'), category_id='priority' if i >= 88 else 'background', tv_archive='1', tv_archive_duration='7') for i in range(96)]
                        else:
                            payload = [dict(stream_id='1', name=f'{source} Channel', epg_channel_id='epg-1', category_id='1')]
                    elif action.endswith('_categories'):
                        payload = [dict(category_id='1', category_name='Test')]
                        if scenario.startswith('guide-') and action == 'get_live_categories':
                            payload = [dict(category_id='priority', category_name='Priority'), dict(category_id='background', category_name='Background')]
                    elif action == 'get_simple_data_table':
                        sid = query.get('stream_id', ['0'])[0]
                        events = []
                        for offset in range(-48, 4, 4):
                            begin = fixture_now + datetime.timedelta(hours=offset)
                            stop = begin + datetime.timedelta(hours=4)
                            events.append(dict(id=f'{sid}-{offset}', title=f'History {sid} {offset}' if scenario.startswith('guide-') else f'{title} Guide', description='Fixture History', start_timestamp=str(int(begin.timestamp())), stop_timestamp=str(int(stop.timestamp()))))
                        payload = dict(epg_listings=[] if scenario == 'guide-retry' and stream_request_number == 1 else events)
                    elif action == 'get_vod_streams':
                        payload = [] if scenario == 'catalog-empty' else [dict(stream_id='1', name=f'{title} Movie', category_id='1', container_extension='mp4')]
                    elif action == 'get_series':
                        payload = [] if scenario == 'catalog-empty' else [dict(series_id='1', name=f'{title} Series', category_id='1')]
                    elif action == 'get_vod_info':
                        payload = {'info': dict(name=f'{source} Detail')}
                    elif action == 'get_series_info':
                        payload = {'episodes': {'1': [dict(id='1', title=f'{source} Episode', episode_num='1', season='1', container_extension='mp4')]}}
                    else:
                        payload = {'user_info': dict(username='fixture', auth=1, status=source)}
                    body = json.dumps(payload).encode()
                try:
                    self.send_response(200)
                    self.send_header('Content-Length', str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError): pass
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        server.daemon_threads = True
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            command = [str(self.executable), f'http://127.0.0.1:{server.server_port}', scenario]
            if scenario.startswith(('credential-', 'cache-')): command.append('--test-bootstrap')
            if self.measure_only: command.append('--measure-only')
            result = subprocess.run(command, capture_output=True, text=True, timeout=12)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr[-2500:])
            if scenario.startswith('credential-'):
                self.assertFalse(counts, 'credential bootstrap sent a provider request while unresolved or automatic refresh was disabled')
            if scenario == 'source-switch':
                self.assertEqual(counts[('B', 'get_live_streams')], 1, 'obsolete task cleanup allowed duplicate source refresh')
                self.assertEqual(counts[('B', 'guide')], 1)
            if scenario.startswith('guide-'):
                if self.expect_visible_priority:
                    self.assertTrue(set(str(i) for i in range(88, 96)).issuperset(request_order[:1 if scenario == 'guide-alias' else 8]), 'visible guide requests did not precede background archives')
                if scenario == 'guide-retry':
                    self.assertEqual(stream_counts, collections.Counter({str(i): 2 for i in range(96)}), 'manual refresh did not retry prior empty/failure responses')
                else:
                    self.assertEqual(len(request_order), len(set(request_order)), 'same guide was repeatedly fetched within a sync')
                payload = next(line.removeprefix('GUIDE_BENCH_JSON ') for line in result.stdout.splitlines() if line.startswith('GUIDE_BENCH_JSON '))
                report = json.loads(payload)
                report['requestedChannels'] = len(request_order)
                report['firstRequestedChannels'] = request_order[:8]
                (ROOT / '.logs').mkdir(exist_ok=True)
                (ROOT / '.logs' / f'{scenario}.json').write_text(json.dumps(report, indent=2) + '\n')
            if scenario == 'lookback-inflight':
                self.assertEqual(counts[('A', 'guide')], 2, 'lookback change was not loaded after current guide refresh')
            if scenario == 'toggle-vod-inflight':
                self.assertEqual(counts[('A', 'get_live_streams')], 2, 'VOD preference change did not coalesce into one follow-up')
            print(result.stdout.strip())
            if scenario.startswith('guide-'): return report
            if scenario == 'overlap':
                payload = next(line.removeprefix('SYNC_BENCH_JSON ') for line in result.stdout.splitlines() if line.startswith('SYNC_BENCH_JSON '))
                report = json.loads(payload)
                report['catalogDispatchSkewMs'] = round(abs(request_times[('A', 'get_vod_streams')] - request_times[('A', 'get_series')]) * 1000, 3)
                if self.expect_parallel_catalog:
                    self.assertLess(report['catalogDispatchSkewMs'], 200, 'movie and series API requests were unexpectedly serialized')
                return report
        finally:
            server.shutdown()
            server.server_close()

    def test_manual_full_refresh_retries_prior_empty_responses(self): self.run_scenario('guide-retry')
    def test_stalker_current_first_and_native_id_mapping(self): self.run_scenario('stalker-guide')
    def test_channel_variants_share_one_archive_request(self): self.run_scenario('guide-alias')
    def test_one_unmatched_xml_id_is_filled_from_its_own_stream(self): self.run_scenario('guide-unmatched-id')
    def test_blank_provider_guide_id_uses_stream_api_fallback(self): self.run_scenario('guide-missing-id')
    def test_visible_api_rows_do_not_wait_for_large_slow_xml(self): self.run_scenario('guide-slow-xml')
    def test_current_guide_publishes_before_slow_partial_history(self): self.run_scenario('guide-progressive')
    def test_blank_xml_falls_back_to_visible_channel_api(self): self.run_scenario('guide-empty-xml')
    def test_cached_history_survives_stale_live_window_and_partial_refresh(self): self.run_scenario('guide-retention')
    def test_slow_keychain_keeps_init_and_main_actor_responsive(self): self.run_scenario('credential-bootstrap')
    def test_ranking_revision_with_unchanged_recents_and_favorites(self): self.run_scenario('preference-revisions')
    def test_m3u_refresh_migrates_cached_uuid_preferences(self): self.run_scenario('m3u-identities')
    def test_disabled_vod_hydration_does_not_read_catalog_caches(self): self.run_scenario('hydration-disabled')
    def test_disabling_during_movie_hydration_skips_series_read(self): self.run_scenario('hydration-disable-inflight')
    def test_disable_enable_during_hydration_rejects_old_catalog_revision(self): self.run_scenario('hydration-toggle-inflight')
    def test_search_reserves_only_programs_with_playable_channels(self): self.run_scenario('search-unmatched')
    def test_search_without_matched_channels_has_no_reserved_storage(self): self.run_scenario('search-empty-match')
    def test_m3u_schema_rollout_migrates_preferences_from_legacy_channel_cache(self): self.run_scenario('m3u-legacy-cache-migration')
    def test_inactive_credential_edit_cannot_hydrate_old_content(self): self.run_scenario('cache-credential-inactive')
    def test_inactive_custom_guide_edit_cannot_hydrate_old_content(self): self.run_scenario('cache-custom-guide-inactive')
    def test_failed_credential_refresh_relaunch_cannot_restore_old_content(self): self.run_scenario('cache-failed-refresh-relaunch')
    def test_missing_keychain_entry_never_becomes_empty_auth(self): self.run_scenario('credential-missing')
    def test_pending_source_rename_preserves_unread_password(self): self.run_scenario('credential-rename')
    def test_pending_source_edit_rejects_stale_metadata(self): self.run_scenario('credential-edit')
    def test_pending_source_deletion_cannot_resurrect(self): self.run_scenario('credential-delete')
    def test_blocked_keychain_worker_does_not_retain_vm(self): self.run_scenario('credential-lifetime')
    def test_failed_legacy_keychain_save_keeps_original_payload(self): self.run_scenario('credential-legacy-failure')
    def test_explicit_password_edit_rejects_pending_read(self): self.run_scenario('credential-provided')
    def test_plaintext_legacy_migrates_password_and_status(self): self.run_scenario('credential-legacy')
    def test_partial_catalog_failure_preserves_cache(self): self.run_scenario('catalog-partial')
    def test_all_catalog_failure_preserves_cache(self): self.run_scenario('catalog-all-fail')
    def test_successful_empty_catalog_clears_cache(self): self.run_scenario('catalog-empty')
    def test_guide_publishes_before_slow_catalog(self): self.run_scenario('overlap')
    def test_switch_rejects_obsolete_sync_and_cleanup(self): self.run_scenario('source-switch')
    def test_same_cache_key_credential_edit_invalidates_work(self): self.run_scenario('source-edit')
    def test_uncached_source_has_no_previous_account_content(self): self.run_scenario('empty-cache-switch')
    def test_cancelled_hydration_rejects_previous_account_content(self): self.run_scenario('hydration-switch')
    def test_detail_completion_does_not_clear_new_source_loading(self): self.run_scenario('details-switch')
    def test_episode_completion_does_not_clear_new_source_loading(self): self.run_scenario('episodes-switch')
    def test_vod_disable_enable_queues_one_followup(self): self.run_scenario('toggle-vod-inflight')
    def test_lookback_change_queues_one_followup(self): self.run_scenario('lookback-inflight')
    def test_xmltv_reordered_short_optional_attributes(self): self.run_scenario('xml-attributes')
    def test_chunked_async_xmltv_content_matches_sync_parser(self): self.run_scenario('xml-chunks')
    def test_transient_episode_failure_can_be_retried(self): self.run_scenario('episodes-retry')
    def test_status_response_from_previous_account_is_rejected(self): self.run_scenario('status-switch')
    def test_direct_guide_replacement_invalidates_prepared_indexes(self): self.run_scenario('lookup-invalidation')
    def test_cancelled_remote_xmltv_stops_transport_promptly(self): self.run_scenario('xml-cancel')
    def test_full_refresh_is_queued_during_guide_refresh(self): self.run_scenario('scope-upgrade')
    def test_vod_disable_rejects_inflight_catalog(self): self.run_scenario('disable-inflight')

if __name__ == '__main__': unittest.main()
