import SwiftUI

struct GameSessionView: View {
    @ObservedObject var coordinator: SystemCoordinator
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            GeometryReader { geometry in
                WindowsRendererView()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            }
            .ignoresSafeArea(edges: .bottom)
            
            VStack {
                HStack {
                    Button(action: {
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.white.opacity(0.5))
                            .frame(width: 44, height: 44)
                            .padding(8)
                    }
                    Spacer()
                }
                Spacer()
            }
        }
        .onAppear {
            WineInputBridge.shared.startBridging()
        }
    }
}
