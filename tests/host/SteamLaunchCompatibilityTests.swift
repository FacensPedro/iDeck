import Foundation

@main
struct SteamLaunchCompatibilityTests {
    static func main() {
        let direct = SteamLaunchCompatibility.classify(
            executable: "Binaries/Win64/Game.exe",
            localEntries: ["steam_api64.dll", "data.pak"])
        assert(direct.kind == .direct && direct.warning == nil)

        let launcher = SteamLaunchCompatibility.classify(
            executable: "GameStarter.exe", launchType: "launcher")
        assert(launcher.kind == .launcherChild)
        assert(launcher.warning?.contains("another game process") == true)

        let byName = SteamLaunchCompatibility.classify(executable: "Launcher.exe")
        assert(byName.kind == .launcherChild)

        let steam = SteamLaunchCompatibility.classify(
            executable: "Game.exe",
            localEntries: ["steamclient.dll", "SteamworksCommon.dll"])
        assert(steam.kind == .steamClient)
        assert(steam.warning?.contains("Steam DRM") == true)

        let client = SteamLaunchCompatibility.classify(executable: "Steam.exe")
        assert(client.kind == .steamClient)

        let antiCheat = SteamLaunchCompatibility.classify(
            executable: "Game.exe", localEntries: ["EasyAntiCheat", "game.bin"])
        assert(antiCheat.kind == .antiCheat)
        assert(antiCheat.warning ==
            "Known kernel anti-cheat components are not supported by Wine on iOS.")

        let battleye = SteamLaunchCompatibility.classify(
            executable: "BEService.exe")
        assert(battleye.kind == .antiCheat)

        let falsePositive = SteamLaunchCompatibility.classify(
            executable: "SimpleGame.exe", launchType: "default",
            localEntries: ["steam_api64.dll", "EasyAntiCheat-not-installed.txt"])
        assert(falsePositive.kind == .direct)
        assert(falsePositive.warning == nil)

        print("PASS: conservative offline Steam launch classification without network/account access")
    }
}
