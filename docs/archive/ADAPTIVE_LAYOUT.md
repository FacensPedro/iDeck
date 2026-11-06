# Adaptive iPhone and iPad layout

The home view now chooses a vertical header and stacked installation actions in compact horizontal size classes or accessibility text sizes. Regular-width iPad windows use horizontal actions, wider cards and more horizontal padding. The library remains centered with a maximum content width. Adaptive grids adjust card minimum/maximum widths.

Settings uses a centered 720-point content column on iPad while retaining a full-width, padded layout on iPhone. The game session's Metal view follows its container geometry and no longer forces content under the top safe area. The renderer automatically resizes Metal drawables when its view bounds change.

The project already targets iPhone and iPad with `TARGETED_DEVICE_FAMILY = "1,2"`. No Java or Rust modules are needed for responsive SwiftUI layout.

Validation still required on an Xcode simulator or physical devices: small iPhones, landscape iPhones, iPad mini, full-screen iPad, Split View, Dynamic Type accessibility sizes, and rotation. This work changes UI layout only; it does not complete the Madeira/FEX/Wine runtime.
