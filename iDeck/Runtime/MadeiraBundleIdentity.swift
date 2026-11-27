// MadeiraBundleIdentity.swift
// Split from WindowsEnvironment.swift (iDeck 3.0 architecture).

import Foundation

enum MadeiraBundleIdentity {
    static let missingRuntimeMessage = "This iDeck IPA contains only the interface. Download iDeck.ipa from an iOS Build Run workflow with Require Madeira runtime enabled."

    static var nativeManifest: [String: Any]? {
        let file = Bundle.main.bundleURL.appendingPathComponent("MadeiraRuntimeManifest.plist")
        guard let data = try? Data(contentsOf: file),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, format: nil) as? [String: Any],
              plist["fexInProcess"] as? Bool == true,
              plist["wineInProcess"] as? Bool == true,
              plist["dxmtLinked"] as? Bool == true,
              let graphics = plist["graphicsBackend"] as? String,
              graphics == "d3d11" || graphics == "d3d12",
              plist["d3d12Linked"] as? Bool == (graphics == "d3d12") else {
            return nil
        }
        return plist
    }

    static var isNative: Bool { nativeManifest != nil }

    /// Each backend's availability in this IPA. DXMT (D3D11, D3D10, DXGI)
    /// is part of every native profile; Madeira D3D12 is added next to it
    /// by the unified (and legacy d3d12) profile, never in its place.
    static var d3d11Available: Bool { nativeManifest != nil }
    static var d3d12Available: Bool {
        guard let manifest = nativeManifest else { return false }
        return manifest["d3d12Available"] as? Bool ?? (manifest["graphicsBackend"] as? String == "d3d12")
    }
    /// "unified", "d3d11" or "d3d12" (legacy), as recorded at build time.
    static var graphicsProfile: String {
        guard let manifest = nativeManifest else { return "none" }
        return manifest["graphicsProfile"] as? String
            ?? ((manifest["graphicsBackend"] as? String) == "d3d12" ? "unified" : "d3d11")
    }

    static var profile: [String: Any] {
        let path = Bundle.main.bundleURL.appendingPathComponent("iDeckRuntimeProfile.plist")
        guard let data = try? Data(contentsOf: path),
              let value = try? PropertyListSerialization.propertyList(
                  from: data, format: nil) as? [String: Any],
              value["profileSchema"] as? Int == 1,
              let manifest = nativeManifest,
              value["runtimeKind"] as? String == "madeira-native",
              value["graphicsBackend"] as? String == manifest["graphicsBackend"] as? String,
              value["wow64Enabled"] as? Bool == manifest["wow64Enabled"] as? Bool else {
            if let manifest = nativeManifest {
                return [
                    "runtimeKind": "madeira-native",
                    "graphicsBackend": manifest["graphicsBackend"] ?? "none",
                    "wow64Enabled": manifest["wow64Enabled"] ?? false,
                    "wineMonoBundled": false,
                    "metalShaderConverterBundled": manifest["d3d12Linked"] ?? false
                ]
            }
            return [
                "runtimeKind": "interface-only", "graphicsBackend": "none",
                "wow64Enabled": false, "wineMonoBundled": false,
                "metalShaderConverterBundled": false
            ]
        }
        return value
    }
}
