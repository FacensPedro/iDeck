## What's Changed
- Store covers and banners load at once while a download runs: they use their own cache and high priority, and EA download requests yield to them.
- Covers and banners are kept on the device, so they no longer reload each time a page opens.
- The JIT pool defaults to 624 MB also when no size was ever chosen in Settings (it still asked for 896 MB and was cut to as little as 336 MB).
- EA downloads unpack with Apple's built-in decoder and a faster checksum, which was the limit once files came in parallel. A file the decoder gets wrong is unpacked again with the previous decoder.
- Updated the application version to 1.4.5 (build 32).
