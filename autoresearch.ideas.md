# Autoresearch Ideas — Xtream Feed Parsing

## Completed (11 experiments, 37% overall reduction)
### Channel JSON parsing (25,102 → 15,810 µs)
- ✅ Replace FlexibleString with direct KeyedDecodingContainer helpers
- ✅ reserveCapacity on channels/categories arrays
- ✅ Direct URL construction (URL(string:))
- ✅ tv_archive == "1" fast path
- ✅ Int-first for numeric fields, String-first for string fields (validated against real data)
- ✅ Applied to XtreamStream, XtreamVODStream, XtreamSeries, XtreamCategory, XtreamUserInfo
- ✅ Replace FlexibleBool with flexBool helper (avoids struct allocation in auth path)

### XMLTV EPG SAX parsing (109MB, 327K programmes)
- ✅ memcmp replaces byte-by-byte cstrEquals (SIMD-accelerated)
- ✅ Static SAX handler (avoids per-parse closure thunk allocation)
- ✅ Direct attribute indexing (eliminates 1M cstrEquals calls per file)
- ✅ reserveCapacity(524288) — avoids reallocation for observed 327K programmes

## Key Learnings
- JSONDecoder is optimal: custom scanner 1.8x slower
- Type ordering matters: wrong first try costs 9-19%
- Validate against real data: category_id is string, not int
- memcmp beats byte-by-byte at 2M+ calls via SIMD
- Direct indexing beats generic loops when order is consistent
- Array(unsafeUninitializedCapacity:) segfaults with Swift 6.3 for non-trivial types — do not use

## Deferred Ideas
- Replace remaining FlexibleString usages in detail types (XtreamVODInfo, XtreamEpisode, etc.)
- Pre-hash XMLTV element names for O(1) dispatch (only beneficial if sub-elements beyond title/desc)
- Parallelize categories + streams HTTP fetches with async let
