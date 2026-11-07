# Ubisoft Connect without a Windows launcher: Optima integration plan

Upstream: https://github.com/Starkka15/Optima (GPL-3.0-or-later), Rust CLI for Linux/Proton.

## Current implementation
- Ubisoft games transferred from a PC through iRelay are registered locally and launched by their game executable through Wine/FEX.
- The Settings page no longer asks users to download or run UbisoftConnectInstaller.exe.
- **Optima has NOT been ported, linked or bundled into the iDeck IPA.** No Ubisoft account login, entitlement lookup, CDN downloads or compatibility shims are available in iDeck yet. The UI explicitly states these limitations.
- Some games may still require Ubisoft client services, online authorization or DRM.

## Build compatibility probe
- `scripts/fetch_optima_sources.py` stages a pinned upstream snapshot under `vendor/Optima` for CI only. It retains upstream embedded resource files (including Windows DLLs and a certificate) because Optima's Rust `include_bytes!` declarations require them even for `cargo check`. **These files are not copied into the iDeck IPA** and must undergo source/license/security review before any distribution.
- `.github/workflows/optima-ios.yml` runs `cargo check --locked --target aarch64-apple-ios` with `actions/checkout@v5`. This is a compile check, not a functional iPadOS integration.

## Required work before claiming an Optima integration
1. Audit Optima's Cargo dependencies, Linux-only code, embedded DLLs and third-party licenses. Pin a specific upstream revision and record attribution.
2. Separate the Rust library from the Linux CLI (browser login, local HTTPS capture, config paths, Proton/umu invocation). Build an arm64-apple-ios static library with a stable C ABI and strict concurrency boundaries.
3. Use a supported iOS browser authentication flow with explicit user consent, Keychain storage, session refresh, sign-out and safe error handling. Do not collect passwords in an iDeck form.
4. Implement authenticated ownership listing and CDN download manifests, resume, integrity verification, storage limits and account revocation handling. Only access entitlements issued to the signed-in account.
5. Integrate downloaded files with UbisoftLibrary, iRelay transfers and Madeira's Wine prefix; test actual game launch and identify titles that still need official client services. Do not silently inject or claim compatibility shims work.
6. Add native iOS build/IPA validation and device tests before exposing login or direct download buttons.

This is an integration specification, not a claim that Optima currently runs on iPadOS.
