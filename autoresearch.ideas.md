# Autoresearch Ideas — Xtream Feed Parsing

## Completed (10 experiments)
### Channel JSON parsing (38% reduction, 25,102 → 15,601 µs)
- ✅ Replace FlexibleString struct with direct KeyedDecodingContainer helpers (flexString/flexInt)
- ✅ reserveCapacity on channels and categories arrays
- ✅ Direct URL construction (URL(string:) instead of appendingPathComponent)
- ✅ tv_archive == "1" fast path instead of Int() conversion
- ✅ Int-first for truly numeric fields (stream_id, tv_archive, tv_archive_duration)
- ✅ String-first for string fields (category_id, added) — validated against real silksurfer.com data
- ✅ Applied to XtreamStream, XtreamVODStream, XtreamSeries, XtreamCategory, XtreamUserInfo

### XMLTV EPG SAX parsing (109MB, 327K programmes)
- ✅ memcmp replaces byte-by-byte cstrEquals (~2.3M calls per 327K-programme file, SIMD-accelerated)
- ✅ Static SAX handler (avoids per-parse closure thunk allocation)
- ✅ Direct attribute indexing by position (start/stop/channel) instead of loop + cstrEquals (~1M fewer calls)
- ✅ reserveCapacity(262144) instead of 4096 (avoids reallocation for large guides)
- ✅ Python expat baseline: ~763ms for 327K programmes on 109MB file

## Key Learnings
- **JSONDecoder is optimal**: custom byte-level scanner is 1.8x slower on Apple platforms
- **Type ordering matters**: wrong first try incurs ~9-19% penalty from error creation
- **Validate against real data**: category_id is string in real servers, not int as benchmark assumed
- **memcmp beats byte-by-byte**: SIMD acceleration matters at 2M+ calls
- **Direct indexing beats generic loops**: known attribute orders save ~1M comparisons

## Deferred Ideas
- Replace remaining FlexibleString usages in detail types (XtreamVODInfo, XtreamEpisode, etc.) — lower priority
- Replace FlexibleBool with native Bool decoding
- Parallelize categories + streams HTTP fetches with async let
- Pre-hash XMLTV element names for O(1) dispatch instead of sequential memcmp
