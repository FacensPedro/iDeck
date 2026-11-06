import Foundation

@main
struct WindowsLaunchArgumentsTests {
    static func main() {
        assert(WindowsLaunchArguments.parse("") == [])
        assert(WindowsLaunchArguments.parse(" --dx11 -windowed ") == ["--dx11", "-windowed"])
        assert(WindowsLaunchArguments.parse(#"--path=C:\Games\Steam\launcher.exe"#) ==
               [#"--path=C:\Games\Steam\launcher.exe"#])
        assert(WindowsLaunchArguments.parse(#""C:\Program Files\Steam\game.exe" -dx12"#) ==
               [#"C:\Program Files\Steam\game.exe"#, "-dx12"])
        assert(WindowsLaunchArguments.parse(#"--path="C:\Program Files\Steam""#) ==
               [#"--path=C:\Program Files\Steam"#])
        assert(WindowsLaunchArguments.parse(#""game data\\""#) == [#"game data\"#])
        // Steamworks install scripts use Wine cmd.exe /c, and some launches
        // chain their installed host with an ampersand in the command string.
        assert(WindowsLaunchArguments.parse(#"/c call C:\\madeira-dock-installers.cmd"#) ==
               ["/c", "call", #"C:\madeira-dock-installers.cmd"#])
        assert(WindowsLaunchArguments.parse(#"/c call C:\\madeira-dock-installers.cmd & C:\\windows\\system32\\dockhost.exe"#) ==
               ["/c", "call", #"C:\madeira-dock-installers.cmd"#, "&", #"C:\windows\system32\dockhost.exe"#])
        assert(WindowsLaunchArguments.parse(#""unterminated"#) == nil)
        assert(WindowsLaunchArguments.parse(String(repeating: "a ", count: 65)) == nil)
        assert(WindowsLaunchArguments.parse("--bad\nargument") == nil)
        assert(WindowsLaunchArguments.parse(String(repeating: "x", count: 4097)) == nil)
        print("PASS: Windows command-line paths, quoting and input limits")
    }
}
