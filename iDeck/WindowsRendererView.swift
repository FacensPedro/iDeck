import SwiftUI
import MetalKit

struct WindowsRendererView: UIViewRepresentable {
    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView(frame: .zero)
        
        if let defaultDevice = MTLCreateSystemDefaultDevice() {
            mtkView.device = defaultDevice
        }
        
        mtkView.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0)
        mtkView.isOpaque = true
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = true
        mtkView.autoResizeDrawable = true
        mtkView.framebufferOnly = false
        mtkView.contentMode = .scaleAspectFit
        mtkView.drawableSize = CGSize(width: 1, height: 1)
        
        setenv("MVK_CONFIG_IOS_SURFACE", "1", 1)
        
        return mtkView
    }
    
    func updateUIView(_ uiView: MTKView, context: Context) {
        uiView.setNeedsLayout()
    }
}
