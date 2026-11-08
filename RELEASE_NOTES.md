## What's Changed
Graphics (DXMT/Metal): shader cache, CPU/GPU sync and memory reuse.
- Shader cache: a game's first session now reads back the shaders it already compiled in that session (the cache could only be read from the second session on).
- Waiting on the GPU (Map, GetData) now sleeps instead of keeping a CPU core busy, leaving it to the game's emulation.
- When iOS reports memory pressure, DXMT immediately releases the dynamic-buffer memory the GPU no longer uses (64-bit games).
- The CPU now runs at most 2 frames ahead of the GPU by default (was 3): less memory held and lower input latency. Set DXMT_MAX_FRAME_LATENCY=1..16 to change it. Games that asked for "the default latency" (0) no longer turn the limit off.
- The shader cache is now capped at 256 MB per game (DXMT_SHADER_CACHE_MAX_MB) and starts over when it grows past that.
- New, off by default: DXMT_PIPELINE_ARCHIVE=1 saves compiled Metal pipelines between sessions. The first session with it on stutters more; later sessions skip those compiles.
- Updated the application version to 1.6.0 (build 41).
