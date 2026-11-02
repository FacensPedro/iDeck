# iDeck JIT scripts

`universal.jitscript` is Madeira's `app/Madeira/madeira-jit.js`, copied line by line (named so the IPA carries no Windows script file type). `legacy.js` retains the legacy `BRK #0x69` workflow supplied for compatibility.

These are debugger-side scripts and require a runtime that provides `get_pid`, `send_command`, `prepare_memory_region`, and `log`. They are source assets, not JavaScript executed by the iOS app. The current `server_jit/server.py` uses pymobiledevice3's GDB remote protocol and does not interpret these scripts; copying them into the repository alone does not make the helper server execute them.
