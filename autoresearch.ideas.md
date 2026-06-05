# Autoresearch Ideas — Xtream Feed Parsing

## Completed (9 experiments, 38% total reduction)
- ✅ Replace FlexibleString struct with direct KeyedDecodingContainer helpers (flexString/flexInt)
- ✅ reserveCapacity on channels and categories arrays
- ✅ Direct URL construction (URL(string:) instead of appendingPathComponent)
- ✅ tv_archive == "1" fast path instead of Int() conversion
- ✅ Int-first decoding for truly numeric fields (stream_id, tv_archive, tv_archive_duration)
- ✅ String-first for category_id, added (validated against real silksurfer.com data)
- ✅ Applied same optimizations to XtreamVODStream, XtreamSeries, XtreamCategory, XtreamUserInfo
- ✅ Validated all field types against real server: 14,993 streams, 25,080 VOD, 2,707 series

## Key Learnings
- **JSONDecoder is optimal**: custom byte-level scanner is 1.8x slower on Apple platforms
- **Type ordering matters**: trying the wrong type first incurs a ~9-19% penalty (error creation)
- **Validate against real data**: the benchmark originally used int for category_id, but real servers use strings
- **Real server field types** (783.silksurfer.com):
  - Integers: num, stream_id, tv_archive, tv_archive_duration, series_id, rating_5based
  - Strings: category_id, name, stream_icon, epg_channel_id, rating, added (epoch), year, duration_secs

## Deferred Ideas
- Replace remaining FlexibleString usages in XtreamVODInfo, XtreamVODMovieData, XtreamEpisode, XtreamSeriesInfo, XtreamEpisodeInfo, FlexibleEpisodes (detail fetches, lower priority)
- Replace FlexibleBool with native Bool decoding (auth check, small impact)
- Parallelize categories + streams HTTP fetches with async let (reduces wall-clock time, not CPU)
- Investigate XMLTV SAX handler: could pre-hash element names or cache SAX handler struct
