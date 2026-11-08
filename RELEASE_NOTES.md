## What's Changed
- Store covers and banners load at once while a download runs: they use their own cache and high priority, and EA download requests yield to them.
- Covers and banners are kept on the device, so they no longer reload each time a page opens.
- The JIT pool defaults to 624 MB also when no size was ever chosen in Settings (it still asked for 896 MB and was cut to as little as 336 MB).
- Updated the application version to 1.4.5 (build 32).
