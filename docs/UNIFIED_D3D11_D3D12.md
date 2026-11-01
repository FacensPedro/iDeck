# One IPA with Direct3D 11 and Direct3D 12

## Profiles

| Profile | Contents | Use |
|---|---|---|
| `unified` (default) | DXMT (D3D11, D3D10, DXGI, winemetal) **and** Madeira D3D12 (`madeira_d3d12.dll`, `d3d12.dll`, `d3d12core.dll`, Metal Shader Converter), one FEX, one Wine ARM64EC, one wineserver | Every game |
| `d3d11` | DXMT only, no Apple converter | When the converter may not be redistributed |
| `d3d12` | Legacy name: identical to `unified` | Existing workflows |

`unified` is not a second pipeline. The `d3d12` payload already staged DXMT next
to Madeira D3D12 (`stage_madeira_payload.sh` requires the DXMT modules in every
profile and only adds the D3D12 ones); `unified` names that build and records it.
Nothing is compiled or bundled twice: FEXCore, Wine ARM64EC and wineserver are
shared by both renderers.

Select it with `IDECK_GRAPHICS_PROFILE=unified` (or `IDECK_MADEIRA_GRAPHICS=unified`)
for `scripts/build_ipa.sh`, or the *graphics_profile* input of the iOS workflow.

## Manifest

`MadeiraRuntimeManifest.plist` and `iDeckRuntimeProfile.plist` record each
backend on its own: `d3d11Available`, `d3d12Available`, `graphicsProfile`.
`stamp_ideck_runtime_profile.py` derives them from the files actually in the
app and fails if DXMT is missing or the D3D12 files disagree with the build. The
workflow's IPA check fails on any mismatch. D3D12 is never read as "no DXMT".

## How a game gets its API

Wine loads a Direct3D DLL only when the game calls it: `d3d11.dll` (DXMT) for
D3D11, `d3d12.dll` (Madeira D3D12) for D3D12, both in the same run if the game
uses both. Madeira D3D12 loads the Metal Shader Converter on its first shader
(`dlopen` in `madeira_ir_unix.mm`), so a D3D11-only game never initialises it.

At launch iDeck reads which APIs the game uses (`GraphicsAPIScan.c`): the PE
import and delay-import tables, and DLL names in the first and last 4 MB (games
that `LoadLibrary` their renderer). For Unity it also reads `UnityPlayer.dll`.
The result is logged (`[graphics] Game.exe uses: D3D11, D3D12, DXGI`), and a game
that needs D3D12 on a `d3d11` IPA is reported in Bugs & logs.

### Per-game *Graphics API* setting

- **Automatic** (default): the game chooses.
- **DXMT** / **D3D12**: passed to the game's own engine switch — Unity
  `-force-d3d11` / `-force-d3d12`, Unreal `-dx11` / `-dx12`. Ignored, with a
  logged reason, when the game does not use that API, has no known switch, or
  the IPA lacks D3D12. No API is ever translated into another.

The old setting stored "Direct3D 9/10/11/12" in an environment variable nothing
read; profiles migrate (11 → DXMT, 12 → D3D12, others → Automatic).

## Validation status

| Item | Status |
|---|---|
| Profile plumbing, manifests, workflow checks | Host tests pass |
| PE API scanner | Tested on real PE files built with clang + lld-link (imports, delay imports, UTF-16 LoadLibrary names) |
| Native unified IPA build | The `d3d12` payload already built and verified in CI (native build log, 2026-11-01); a `unified` native run is needed to confirm the new manifest fields |
| First D3D11 frame, first D3D12 frame, hybrid game, switching games, 20 cycles, CPU/GPU/RAM vs a d3d11-only IPA | **Not tested** — requires a physical device |
| Metal Shader Converter licensing | Unchanged: `IDECK_ACCEPT_METAL_CONVERTER_LICENSE=1` records the build owner's decision; it is not a legal authorisation |
