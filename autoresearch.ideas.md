# Autoresearch Ideas — Xtream Feed Parsing

## Completed (12 experiments)
### Channel JSON parsing (25,102 → ~16,000 µs, 36% reduction)
- ✅ Replace FlexibleString with direct KeyedDecodingContainer helpers
- ✅ reserveCapacity on channels/categories arrays
- ✅ Direct URL construction (URL(string:))
- ✅ tv_archive == "1" fast path
- ✅ Int-first for numeric, String-first for string fields (validated against real data)
- ✅ Applied to XtreamStream/VODStream/Series/Category/UserInfo
- ✅ Replace FlexibleBool with flexBool helper
- ✅ Parallelize HTTP fetches with async let (fetchChannels/VODItems/Series)

### XMLTV EPG SAX parsing (109MB, 327K programmes)
- ✅ memcmp replaces byte-by-byte cstrEquals (SIMD)
- ✅ Static SAX handler (no per-parse allocation)
- ✅ Direct attribute indexing (eliminates 1M cstrEquals calls)
- ✅ reserveCapacity(524288) (no reallocation for 327K programmes)

## Key Learnings
- JSONDecoder is optimal (custom scanner 1.8x slower, SIMD-accelerated)
- Type ordering matters (wrong first try costs 9-19%)
- Validate against real data (category_id is string, not int)
- memcmp beats byte-by-byte at 2M+ calls via SIMD
- Direct indexing beats generic loops (consistent attribute order)
- Array(unsafeUninitializedCapacity:) segfaults Swift 6.3 — don't use
- async let parallelizes independent HTTP — saves ~1 RTT per sync

## Remaining Ideas
- Replace remaining FlexibleString usages in detail types (cleanup, low impact)
- Pre-hash XMLTV element names (only beneficial with >2 sub-elements per programme)
