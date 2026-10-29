# Madeira C compatibility backports and native build caches

## Upstream revision and ABI rules

iDeck pins Madeira **fd9f2f3d0434a4116e4c3351f286a0fc376b4e36**
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

### Imported source: Vulkan / MoltenVK / OpenGL / WGL

The following sources are now available for a **separate coordinated Wine
ABI port**:

- `build/vulkan-ios/backend.c`: MoltenVK static Vulkan entrypoints.
- `build/win32u-unix/vulkan_ios.c`: Wine's Unix Vulkan dispatch.
- `build/win32u-unix/vulkan_surface_ios.c`: real CAMetalLayer surfaces.
- `build/win32u-unix/opengl_ios.c`: WGL, OpenGL ES and Mesa/Zink paths.

**Not yet runnable:** These are source files, not automatic runtime
providers. They are deliberately not compiled into the current native
runtime. A correct implementation also requires the matching later
Wine/FEX/DXMT ABI, the Wine `opengl32` and `winevulkan` Unix thunk tables,
rebuilding `libntdll_unix.a` and `libwin32u_unix.a`, the newer
`WiniosGL.m` and `IOSDisplayShim.m` host APIs, licensed/validated
MoltenVK and Mesa/Zink runtimes, and per-session Vulkan/D3D12 DLL
selection. Simply linking the C files would produce unresolved symbols
or a Vulkan/GL implementation that never presents a frame. Until the
coordinated port compiles and passes iOS hardware tests, the iDeck
Direct3D 11 path remains DXMT, and Direct3D 12 remains madeira-d3d12.

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
