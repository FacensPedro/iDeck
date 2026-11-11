# Wine compatibility patches

Applied to Madeira's pinned Wine tree (Wine 11.4) by `scripts/apply_madeira_wine_compat.py`
when the sources are fetched. All of them are LGPL-2.1-or-later, as Wine is.

Only patches to Windows-side (PE) DLL code are taken. A patch is left out when it touches
wineserver or its protocol, ntdll, kernelbase, win32u, wined3d, the loader, the build system
(`configure`, `Makefile.in`, `.spec`), or a Unix display, audio or printing driver: Madeira
replaces those with iOS ports. Sets that depend on another set, or that do not apply to
the pinned tree, are left out too.

The x64 (ARM64EC) DLL farm is Madeira's prebuilt one: these patches reach the x86 (WoW64)
farm, which is compiled from this tree, and the few ARM64EC modules iDeck rebuilds.

## Wine Staging

Source: https://github.com/wine-staging/wine-staging, tag `v11.4`
(commit `f17c9eab35d6557a4533b6df141f424383530ad4`), directory `patches/`.
Of its 117 sets, 93 apply to the pinned tree and 41 are taken:

- `comctl32-rebar-capture`
- `comctl32_animate_avi`
- `comdlg32-lpstrFileTitle`
- `d3dx9-setrawvalue`
- `d3dx9-sprite-state`
- `d3dx9_36_controller`
- `d3dx9_animation_TrackDesc`
- `ddraw-GetPickRecords`
- `ddraw-IDirect3DTexture2_Load`
- `dinput-scancode`
- `dmime_segment_getaudiopath`
- `dmscript_enum_routine`
- `gdiplus-Performance-Improvements`
- `kernel32-limit_heap_old_exe`
- `mshtml-TranslateAccelerator`
- `mshtml-adobe`
- `msi-cabinet`
- `msxml3-whitespace`
- `msxml3-write_out_doc`
- `msxml3_encode_gb2312`
- `oleaut32-CreateTypeLib`
- `oleaut32-default-pic-size`
- `oleaut32_VarAdd`
- `oleaut32_typelib_dispatch`
- `riched20-IText_Interface`
- `richedit20-ImportDataObject`
- `sapi-ISpObjectToken-CreateInstance`
- `shell32-IconCache`
- `shlwapi-AssocGetPerceivedType`
- `user32-DM_SETDEFID`
- `user32-DrawTextExW`
- `user32-msgbox-Support-WM_COPY-mesg`
- `version-VerQueryValue`
- `wbemdisp-ISWbemObject-Invoke`
- `windowscodecs-GIF_Encoder`
- `windowscodecs-TIFF_Support`
- `wininet-Cleanup`
- `wininet-proxy_username`
- `winmm-mciSendCommandA`
- `wintrust-WTHelperGetProvCertFromChain`
- `xactengine3_7-PrepareWave`

## GE-Proton

Source: https://github.com/GloriousEggroll/proton-ge-custom
(commit `2b270a204beb7379efd8357462d3baa301e9dacd`), directories `patches/wine-hotfixes/pending`
and `patches/game-patches`. They are written for Proton's Wine; these 7 apply unchanged
to Wine 11.4 and use only symbols it has:

- `NCryptDecrypt_implementation.patch`
- `assettocorsa-hud.patch`
- `crypt32-reject-ncrypt-only-private-keys.patch`
- `rtworkq-dont-hold-queues-section-during-system-queue-shutdown.patch`
- `secur32-schannel-fix-incomplete-message-missing-size.patch`
- `urlmon-pump-thread-user-messages-during-synchronous-bind.patch`
- `xinput-dont-wait-for-update-thread-under-loader-lock.patch`

## Proton

None. Proton's own changes are commits of Valve's Wine fork, not a patch series, and the
Proton patches GE-Proton carries (`patches/proton`) either do not apply to Wine 11.4 or
change ntdll, win32u or wineserver.
