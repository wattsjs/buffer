# Autoresearch Ideas — Xtream Feed Parsing

## Completed (14 experiments, 38% overall reduction)
### Channel JSON parsing (25,102 → 15,556 µs, 38% reduction)
- ✅ Replace FlexibleString/FlexibleBool with inline KeyedDecodingContainer helpers
- ✅ Delete both obsolete wrapper types (~70 lines removed)
- ✅ reserveCapacity on all array allocations
- ✅ Direct URL construction (URL(string:))
- ✅ tv_archive == "1" fast path
- ✅ Int-first for numeric, String-first for string fields (validated against real data)
- ✅ All 12 Decodable types converted (Stream, VODStream, Series, Category, UserInfo, VODInfo, VODMovieData, SeriesInfo, Episode, EpisodeInfo, AuthEnvelope, SeriesInfoEnvelope)
- ✅ Parallelize HTTP fetches with async let (fetchChannels/VODItems/Series)

### XMLTV EPG SAX parsing (109MB, 327K programmes)
- ✅ memcmp replaces byte-by-byte cstrEquals (SIMD-accelerated)
- ✅ Static SAX handler (no per-parse allocation)
- ✅ Direct attribute indexing (eliminates 1M cstrEquals calls)
- ✅ reserveCapacity(524288) (no reallocation)

### EPG post-processing (327K programmes)
- ✅ Skip sort for 89% of channels that are already chronological in XMLTV data
- ✅ reserveCapacity(1024) for channel dictionary

## Key Learnings
- JSONDecoder is optimal (custom scanner 1.8x slower)
- Type ordering matters (wrong first try costs 9-19%)
- Validate against real data (category_id is string, not int)
- memcmp beats byte-by-byte at scale via SIMD
- Direct indexing beats generic loops
- Array(unsafeUninitializedCapacity:) segfaults Swift 6.3
- 89% of XMLTV channels are pre-sorted — skip sort for them

## Deferred Ideas
- Pre-hash XMLTV element names (only beneficial with >2 sub-elements per programme; not applicable to real data)
- Parallelize EPG fetch with channels/VOD in performSync (requires refactoring Stalker path)
