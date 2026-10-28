import Foundation

enum WineExitDiagnostics {
    static func message(exitCode: Int32?, crashStatus: UInt32?) -> String {
        if let crashStatus {
            let hex = String(format: "0x%08X", crashStatus)
            let detail: String
            switch crashStatus {
            case 0xC0000135:
                detail = "A required Windows DLL was not found. Inspect Wine's DLL loader logs."
            case 0xC000007B:
                detail = "A DLL or executable has the wrong architecture or is invalid."
            case 0xC0000005:
                detail = "The program encountered a Windows access violation."
            case 0xC000001D:
                detail = "The program attempted an unsupported CPU instruction."
            case 0xC0000142:
                detail = "A Windows DLL initialization failed."
            case 0xC0000139:
                detail = "A required DLL entry point was not found."
            default:
                detail = "Check the Wine/FEX runtime logs for the underlying error."
            }
            return "Execution Error: Windows program crashed (NTSTATUS \(hex)). \(detail)"
        }
        guard let exitCode else {
            return "Execution Error: Wine stopped, but no native exit code was available. Check the Wine/FEX logs."
        }
        if exitCode == 0 {
            return "Windows program closed normally (Wine exit code 0)."
        }
        return "Execution Error: Windows program stopped (Wine exit code \(exitCode)). Check the Wine/FEX logs."
    }
}
