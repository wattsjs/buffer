# Autoresearch Ideas — Xtream Feed Parsing

## Completed
- ✅ Replace FlexibleString struct with direct KeyedDecodingContainer helpers (flexString/flexInt)
- ✅ reserveCapacity on channels and categories arrays
- ✅ Direct URL construction (URL(string:) instead of appendingPathComponent)
- ✅ tv_archive == "1" fast path instead of Int() conversion
- ✅ Int-first decoding for known-numeric fields (stream_id, category_id, tv_archive, etc.)
- ✅ Apply same optimizations to XtreamVODStream, XtreamSeries, XtreamCategory

## Deferred Ideas
- Replace remaining FlexibleString usages in XtreamVODInfo, XtreamVODMovieData, XtreamEpisode, etc.
- Replace FlexibleBool with native Bool decoding
- Cache JSONDecoder instance instead of creating new one per call (showed no measurable benefit in benchmarks)
- Parallelize channel mapping with concurrentPerform (likely minimal gain since mapping is <20% of time)
- Investigate XMLTV SAX handler: could pre-hash element names for faster dispatch in startElement
- Consider streaming JSON parser using Foundation's new JSONScanner (macOS 15+)
- Benchmark against real Xtream server responses for more accurate profiling
