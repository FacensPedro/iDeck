## What's Changed
### Windows runtime
- The x64 runtime now has 19 Wine modules it lacked although the x86 runtime had them:
  - DirectShow, used for video by many games and their cutscenes: quartz, devenum, amstream, qedit, qcap, the MP3 decoder l3codecx.ax, mciqtz32, and the Cinepak, Microsoft Video 1 and RLE codecs.
  - Media Foundation's Enhanced Video Renderer (evr.dll, which mf.dll loads for video), mfmediaengine and mfplay.
  - What installers use: advpack (INF installs), msiexec.exe, rundll32.exe and regsvr32.exe.
  - bluetoothapis and inetcomm, imported by modules that were already there.

### Release
- Updated the application version to 1.8.2 (build 64).
