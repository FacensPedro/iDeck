# Madeira rendering parity and Wine startup

## Black screen: root causes and guardrails

The pinned upstream Madeira `ContentView.swift` explains why presenting
directly into a SwiftUI-managed Metal view can intermittently show a black
screen on iOS 26/27 even when the Metal present counter advances.
Its solution is one process-lifetime `CAMetalLayer` hosted by a raw
`UIView` attached to `UIWindow`, outside SwiftUI's snapshot path.

iDeck now uses the same approach in `WindowsRendererView.swift`.
The SwiftUI `UIViewRepresentable` is only a layout placeholder.
A persistent window-level host owns the presenting `CAMetalLayer`.
Only DXMT/Winemetal may resize its drawable after the initial nonzero
800x600 seed; SwiftUI layout merely moves the native UIView's frame.

The raw surface is placed below a reserved top strip for the session
Close control and status overlay. This is a pragmatic UI compromise
until the entire control overlay is moved into a separate top-level
layer. The window host retains its Metal layer across SwiftUI view
recreation, avoiding a stale DXMT swapchain pointer.

Madeira also publishes coordinates for its GDI/window compositor via
`winios_set_compositor_frame` and `winios_set_desktop_rect`.
iDeck now invokes those entry points when they are linked, so a
Win32/GDI window and a DXMT swapchain share the same presentation
viewport. On session teardown it hides the compositor and removes the
host view from the window without destroying the Metal layer object.

A separate, fundamental cause of a black screen is an interface-only
IPA. The default automated GitHub Actions build does not ship the
Wine/FEX/Metal/Madeira runtime. iDeck now fails fast with a specific
missing-native-renderer error, rather than allowing a long blank wait.
**Do not consider interface-only IPAs game-capable.** A real native
IPA requires a compatible Apple Metal Shader Converter build and the
necessary redistribution rights, as enforced by the iOS Build workflow.
Nothing in this change claims successful game rendering on a device.

## Reduced startup overhead

- Poll wineserver readiness at 5 ms intervals initially, then back off
  to 25 ms intervals while preserving the original overall timeout.
  Do not use fixed pauses or bypass server readiness.
- Configure Steam's `user.reg` overrides once per existing prefix,
  avoiding repeated registry reads on each game launch.
- Give the first bundled Wine-prefix extraction user-initiated QoS.
  Existing prefixes still bypass extraction.
- Poll the initial Metal surface at 50 ms intervals and bound the
  waiting period to 4 seconds. If no native display backend is linked,
  show an explicit execution error immediately.

These are latency-oriented changes, not benchmark claims. First-game
Wine initialization, shader compilation, JIT preparation, and DXIL
conversion still require real work.

## HUD

The automatic DXVK environment configuration introduced previously
remains active when a game loads DXVK. The separate HUD Settings toggle
is removed. The independent iDeck FPS/CPU/Metal-memory overlay remains
opt-in and disabled by default.

## Validation

The host tests cover the renderer lifecycle, compositor integration,
native-backend readiness, and startup scheduling. The iOS Build compiles
the interface and checks static bundling invariants. Verify a native
IPA on an iPad by launching both a DXMT/D3D11 game and a GDI/desktop
window, confirming visible frames and correct input before merging.

## Geometry and input contract for virtual monitor modes

The iDeck game profile now persists a display scaling choice (Fit, Fill,
Stretch, Aspect). The renderer reads the live virtual monitor dimensions
from Madeira's `winios_screen_size` export, and uses the saved
`IDECK_DISPLAY_SCALING` mode to compute one `RuntimeConfiguration.surfaceRect`.
This rectangle sizes the persistent `UIWindow` Metal layer and informs
`winios_set_desktop_rect` for GDI/desktop compositing; the compositor's
hosting frame stays the full view. The same pure mathematical transform is
available as `RuntimeConfiguration.guestPoint` and through
`WindowsRendererView.guestPoint(fromWindow:)` for on-screen input.

- Fit preserves the guest monitor's ratio and letterboxes.
- Fill preserves that ratio while cropping the excess.
- Stretch occupies the full guest area without preserving the ratio.
- Aspect preserves the actual Metal swapchain drawable ratio, using the
  guest monitor dimensions until a real drawable size exists.

The code does not force or rewrite `CAMetalLayer.drawableSize` after
native registration: DXMT/WineMetal owns it. The layer observes drawable
size changes and requests a layout refresh on the main thread. The
runtime monitor may change through `ChangeDisplaySettings`; reading
`winios_screen_size` rather than a static launch-time `MADEIRA_SCREEN_W/H`
avoids stale aspect ratio and misaligned touch coordinates.

The geometry is validated in the Swift host tests with compact and
regular-sized views. Actual guest mouse/touch event delivery and device
presentation are **NOT RUN** until the input integration and real signed
Madeira-native IPA are tested on an iPhone/iPad. The PR's interface-only
IPA must not claim hardware frame output.

