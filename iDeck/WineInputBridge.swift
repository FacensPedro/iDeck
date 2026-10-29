import Foundation
import GameController
import Darwin

class WineInputBridge {
    static let shared = WineInputBridge()
    
    private var isHooked = false
    private var controllerObserver: NSObjectProtocol?
    
    func startBridging() {
        guard !isHooked else { return }
        isHooked = true
        
        controllerObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { notification in
            if let controller = notification.object as? GCController {
                self.mapControllerToWine(controller)
            }
        }
    }
    
    func stopBridging() {
        guard isHooked else { return }
        isHooked = false
        if let controllerObserver {
            NotificationCenter.default.removeObserver(controllerObserver)
            self.controllerObserver = nil
        }
    }

    private func mapControllerToWine(_ controller: GCController) {
        let sdlConfigString = "050000004c050000c405000000010000,PS4 Controller,a:b1,b:b2,x:b0,y:b3,back:b8,guide:b12,start:b9,leftstick:b10,rightstick:b11,leftshoulder:b4,rightshoulder:b5,dpup:h0.1,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,leftx:a0,lefty:a1,rightx:a2,righty:a3,lefttrigger:a4,righttrigger:a5,platform:Mac OS X,"
        
        setenv("SDL_GAMECONTROLLERCONFIG", sdlConfigString, 1)
    }
}
