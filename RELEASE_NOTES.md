## What's Changed
- EA downloads unpack with Apple's built-in decoder and a faster checksum, which was the limit once files came in parallel. A file the decoder gets wrong is unpacked again with the previous decoder.
- The JIT pool defaults to 624 MB also when no size was ever chosen in Settings (it still asked for 896 MB and was cut to as little as 336 MB).
- Updated the application version to 1.4.6 (build 33).
