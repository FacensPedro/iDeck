# Madeira C compatibility backports and native build caches

## Upstream revision and ABI rules

iDeck pins Madeira **c2c1b03a9e36ef986c980b9eae3c14d05a372db1**
(Wine **11.4** ARM64EC/iOS, with individually audited ARM host, Mach context,
and repeat-session patches). The new, selectively imported source files
in this change are from Madeira **c2c1b03a9e36ef986c980b9eae3c14d05a372db1**.
They retain upstream copyright and license notices. Importing the sources
does **not** update or replace the FEX, Wine or DXMT submodule revision.

### Built into an authorized native IPA

**DirectComposition** — `build/dcomp/dcomp.c` and `dcomp.def` are
compiled into a real ARM64EC `dcomp.dll` with LLVM-MinGW. The DLL export
table is compared against the version-controlled definition before replacing
the older file from the pinned Madeira farm. The resulting Windows PE
image is staged into the iDeck IPA. Native-kit metadata records a hash of
both sources and rejects an old prebuilt kit.

**LuaJIT GC64** — `build/wineserver/luajit_compat.c` is backported into
the pinned Wine server with `scripts/apply_madeira_luajit_backport.py`.
The patch changes exactly one known `SEC_IMAGE` mapping block, plus the
wineserver archive's source and replacement tables; it deliberately fails on
unknown upstream code rather than silently building the wrong ABI. A
version-pinned x64 LuaJIT 2.1 library is compiled with GC64 references, with
the guest JIT disabled and internal unwinding enabled, for games whose
own LuaJIT requires the inaccessible low 2 GB address space. The game
installation is not modified. The GC64 DLL and MIT license are included
in the native-kit inventory and IPA. This workaround applies only when
its signature and low-address requirements match. Not all LuaJIT games
are compatible.

Both components are compiled in the existing *licensed native* pipeline,
not an interface-only build. Binary presence, exports, kit provenance and
IPA staging can be verified on macOS CI. Actual game compatibility still
requires testing on an iPad with working JIT.

### OpenGL and Vulkan (built since the c2c1b03 pin)

The pinned Madeira compiles the Wine `opengl32` and `winevulkan` Unix sides
into `libntdll_unix.a` and the winios WGL/Vulkan drivers into
`libwin32u_unix.a`. iDeck completes the runtime:

- `Winios/WiniosGL.m` (the GL presenter onto the game's CAMetalLayer) is
  linked with `OpenGLES.framework` and `IOSurface.framework`.
- `build/host/madeira_host_input.c` supplies `winios_mouse_routing_enabled`,
  which upstream implements in Swift.
- `scripts/build_madeira_gl_vulkan.sh` builds MoltenVK v1.4.2
  (`gl/libMoltenVK.dylib`) and Mesa 25.0.7 OSMesa + Zink
  (`gl/libOSMesa.dylib`) with Madeira's own scripts, and caches them.
- Wine's ARM64EC `winevulkan.dll`/`vulkan-1.dll` are staged in
  `vulkan/arm64ec-windows`, outside the prefix farm.

OpenGL games get desktop OpenGL 3.3–4.x through Zink (or OpenGL ES 3.0 when
chosen). Vulkan is per game: the profile's **Vulkan** setting (Automatic
turns it on when an x64 executable references `vulkan-1.dll`) writes
`vulkan = moltenvk` to the per-game Madeira config (`MADEIRA_CFG_GAME`).
32-bit games get no Vulkan, because upstream binds no WoW64 Vulkan table.
DXVK and vkd3d-proton are not bundled; Direct3D stays on DXMT and
madeira-d3d12. Rendering must still be verified on an iPad.

The files are preserved as an auditable baseline rather than misleading
users with fake Vulkan/OpenGL support.

## Precompiled ARM64EC and iOS LLVM dependencies

The GitHub Actions **iOS Build** workflow now restores the following
compiled outputs on cache hits, *after* checking out the pinned Madeira
sources and *before* trying to rebuild the toolchains:

- ARM64EC/x64 LLVM-MinGW `20260421` cross-compiler (download originally
  verified with the pinned SHA-256 digest).
- iOS arm64 LLVM static archives, headers and generated configuration.
- GnuTLS/GMP/Nettle and FFmpeg iOS static libraries with headers.
- FreeType source plus compiled iOS output.

The existing **Madeira native kit** cache separately contains compiled
FEXCore, Wine Unix/wineserver, DXMT, D3D12, Windows DLL farms, native
bridge archives and the Wine prefix. It is validated against the exact
source patch digests, compiled symbols and file hashes. The new LuaJIT and
DirectComposition backports deliberately invalidate older kits.

The first cache miss **must still compile and populate** these outputs;
the workflow cannot materialize licensed binaries before an authorized
macOS build has finished. GitHub cache entries are not committed as
binaries to source control. The Metal Shader Converter download remains
subject to Apple's terms and the owner's explicit authorization.

To turn on automatic *native* IPA builds on the trusted `main` and version
tags, the repository owner must review the combined distribution terms
and then, only if authorized, set GitHub repository Actions variable:

`IDECK_NATIVE_DISTRIBUTION_APPROVED=true`

Pull requests build an interface-only IPA to avoid running untrusted
native build scripts with privileged release permissions; the full
native compilation can also be triggered explicitly by workflow_dispatch
with `require_madeira=true` and a separate redistribution confirmation.
The mainline GitHub Release job labels interface-only CI prereleases
as such and refuses interface-only versioned releases.

## Node.js 24

All workflows use Node 24-compatible `actions/checkout@v5`,
`actions/cache@v5`, and `actions/upload-artifact@v7`. The iOS host
test job explicitly selects Node.js 24 with `actions/setup-node@v5`
and checks the runtime version. `maxim-lobanov/setup-xcode@v1`
resolves to the Node-24-compatible v1.7 series. The iOS/macOS Xcode
SDK is unaffected by these GitHub Action JavaScript runtime changes.
