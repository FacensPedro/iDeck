# Automatic native iDeck IPA (Wine / FEX / DXMT / D3D12)

The GitHub Actions **iOS Build** workflow now builds a native Madeira IPA by
default for every **push, pull request and version tag**. It no longer
publishes a 5 MB interface-only IPA as the result of an automatic build.
An interface-only build is still available only when explicitly requested
in the manual workflow dispatch.

## One-time repository administrator authorization

**The first automatic native build cannot produce or distribute the
Apple Metal Shader Converter binary until distribution is authorized.**

1. Read the applicable Apple Metal Shader Converter agreement, including
   its special dynamic-library redistribution terms; review Madeira/FEX/
   Wine/DXMT and their combined licensing obligations as well. Confirm
   that the app's intended purpose and distribution method are allowed.
2. In the GitHub repository, open **Settings → Secrets and variables →
   Actions → Variables → New repository variable**.
3. Create `IDECK_NATIVE_DISTRIBUTION_APPROVED` with the exact value
   `true` only after the owner has confirmed those rights.
4. Push to `main`, merge an approved pull request, or publish a tag.
   The normal workflow starts building the native runtime automatically.
   For a manual build the workflow's separate
   `accept_converter_license` checkbox still works.

The variable is deliberately **not set in source control**. The workflow
does not treat the user's feature request as acceptance of a third-party
license. If the variable is missing, the workflow displays instructions
in the GitHub Actions summary and fails **without uploading any IPA**.
This is preferable to supplying an interface-only artifact that cannot
launch Windows games.

## Native build process

For authorized builds, the existing pipeline:

1. Downloads the source checkout, including Git LFS objects.
2. Restores a previously validated, versioned Madeira native kit from
   the repository or GitHub Actions cache, if one is available.
3. Otherwise, installs the Metal compiler and native build tools,
   retrieves the pinned Madeira/FEX/Wine/DXMT sources, prepares the
   ARM64EC/iOS LLVM toolchains and compiles the host runtime. The pinned
   Madeira Wine fork is **11.4**.
4. Links the native ARM64 FEX, wineserver, Wine Unix, DXMT/Winemetal
   and D3D12 libraries into the iDeck executable, and stages the
   corresponding Windows ARM64EC DLLs and converter runtime. Native
   WoW64 (32-bit compatibility) is enabled by default.
5. Verifies the app's native linkage, Windows PE formats, SHA-256 kit
   inventory, native manifest, D3D12 binary identity, executable
   signatures and binary presence. The zip-level test also checks
   `xtajit64.dll`, `xinput1_4.dll`, `d3d11.dll`, `dxgi.dll`,
   `madeira_d3d12.dll`, `d3d12.dll`, `d3d12core.dll`,
   `libmetalirconverter.dylib` and the Wine prefix template.
6. Publishes the verified **raw `iDeck.ipa`**, with no extra outer ZIP,
   as a GitHub Actions artifact.

If a native dependency is missing or any verification fails, the
workflow **fails**. There is no fallback to an interface-only IPA.
The normal Actions cache can avoid expensive native recompilation on
subsequent builds with compatible native-kit revisions, but an empty
cache requires the full native toolchain and build.

The current PR is stacked on the preceding Madeira controller and
repeat-Wine-session integration because its native runtime must
incorporate those sources. Cached kits lacking the corresponding
source-patch checksums are rejected.

## Runtime limits

An unsigned IPA must still be signed using an appropriate iOS
sideloading method. App code compilation and successful packaging do
**not** prove that JIT permissions are available, Wine's ARM64EC
execution is functional, DXMT presents frames on a physical GPU, or
Direct3D 12 shaders successfully convert. Use a real iPad and check
a Windows game, XInput/HID and two sequential game launches.

The default `actions/upload-artifact@v7` upload uses `archive: false`
to deliver the IPA directly. Apple's Metal Shader Converter stays
subject to its applicable license, including relevant notices and
approved use.

To see the build after authorization: **Actions → iOS Build → latest
run → iDeck.ipa**.
