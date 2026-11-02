# Local HLS transport experiment

`benchmarks/hls_retry_proxy.py` is a local-fixture fetch broker used only when
`scripts/playback.py --transport-proxy` is explicitly selected. Production Buffer
playback and provider requests are unchanged.

The experiment tests whether recovering an exact failed segment prevents FFmpeg
from skipping media and damaging playback clocks. It does not remux media, alter
PTS, rewrite manifests, prefetch future segments, or substitute another stream.
Generated HLS manifests have relative resource paths, so their original bytes can
be returned through a different loopback listener without URI rewriting.

Compare against the same cached corpus, app artifact, renderer and five-second
buffer setting:

```sh
python3 scripts/playback.py --configuration optimized --profile 1080p60 \
  --seconds 45 --ao avfoundation --fault 502 --fault-at 12 --fault-seconds 4 \
  --transport-proxy
```

Do not add `--http-retry` for the first comparison: that would combine FFmpeg
retry policy with the broker policy. Capture clean and failure trials separately.
A successful socket test is not a successful rendered-playback trial.

The default resource retry budget is six seconds including origin permit waits,
body reads and backoff. Only 502, 503, 504 and network failures retry, with at most
16 attempts. Numeric or HTTP-date Retry-After is respected within this budget;
requests cannot sleep beyond the budget. Auth failures, missing content,
throttling and redirects return immediately. A body is served only when complete;
partial responses are discarded and retried from the origin.

The origin must be `http://127.0.0.1:<explicit port>` with no credentials, path or
query. Redirects are disabled. Client authorization and cookies are refused. It
is suitable for the generated fixture server, not arbitrary HLS provider media,
absolute manifest URIs, production auth, encrypted key rotation or redirects.

Identical path/query/range requests share one origin flight. Cancelling one
consumer leaves the others active; cancelling all consumers stops retries.
Disconnected client sockets count as cancelled consumers. Pending flights are
bounded at 32, clients at 64, concurrent origin fetches at eight. Successful media
is cached for up to 120 seconds with a 64 MiB / 32-item LRU bound and a 16 MiB
per-resource read limit. Live manifests and `Cache-Control: no-store` media are
not cached. The source is immutable for each broker instance and the byte range
is part of the cache identity.

Reports label the transport `local-fixture-broker-experiment` and retain bounded
numeric attempt status, retry, cache, coalescing, cancellation and concurrency
counters. Broker events contain no URLs or paths. Existing renderer, A/V sync,
stall, drop and corpus verification gates still apply; missing broker evidence,
internal errors or evidence loss fail the run.

Validation:

```sh
python3 -W error::ResourceWarning scripts/test_hls_retry_proxy.py
python3 -m unittest discover -s scripts -p 'test_playback.py'
```

The 15 socket integration tests cover transient recovery with byte identity,
terminal statuses and forbidden redirects, unchanged uncached manifests, range
and query identity, cache bounds/expiry, shared consumers, permit limits,
partial-body reset, slow trickle deadlines, client disconnects and bounded close.
The 37 existing playback tests still pass. Rendered-playback measurements are
pending and must be retained separately from these transport checks.
