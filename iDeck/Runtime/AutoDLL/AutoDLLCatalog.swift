// AutoDLLManager: the catalog of components and the DLLs each ships.
// Split from AutoDLLManager.swift (iDeck 3.0 architecture).

import Foundation

extension AutoDLLManager {
    struct Component {
        let id: String
        let title: String
        let url: URL
        let sizeRange: ClosedRange<Int64>
        let dlls: [String]
    }

    /// Microsoft's DirectX End-User Runtime (June 2010): D3DX 9/10/11, the HLSL compiler,
    /// XInput 1.1-1.3, XAudio2 2.0-2.7, X3DAudio, XACT and XAPOFX, both architectures.
    static let directX = Component(
        id: "directx-jun2010", title: "DirectX End-User Runtime (June 2010)",
        url: NativeD3DX.redistURL, sizeRange: 50_000_000...150_000_000,
        dlls: (24...43).map { "d3dx9_\($0)" } + (33...43).map { "d3dx10_\($0)" } + ["d3dx11_42", "d3dx11_43"]
            + (33...43).map { "d3dcompiler_\($0)" } + ["d3dcsx_42", "d3dcsx_43"]
            + ["xinput1_1", "xinput1_2", "xinput1_3", "xinput9_1_0"]
            + (0...7).map { "xaudio2_\($0)" } + (0...7).map { "x3daudio1_\($0)" }
            + (0...5).map { "xapofx1_\($0)" }
            + ["xactengine2_0", "xactengine2_1", "xactengine2_2", "xactengine2_3", "xactengine2_4", "xactengine2_5",
               "xactengine2_6", "xactengine2_7", "xactengine2_8", "xactengine2_9", "xactengine2_10"]
            + (0...7).map { "xactengine3_\($0)" })

    static let catalog: [Component] = [directX]

    static func component(for dll: String) -> Component? {
        let name = dll.lowercased().replacingOccurrences(of: ".dll", with: "")
        return catalog.first { $0.dlls.contains(name) }
    }
}
