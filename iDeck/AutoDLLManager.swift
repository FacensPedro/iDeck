import Foundation

/// iDeck Auto DLL Manager. Before a game starts, the DLL check (DependencyCheck) lists
/// the DLLs its program imports that neither the game's folder nor Wine has. For each
/// one this manager:
/// 1. reads the program's architecture from the check (x86 = i386, x64; ARM64EC
///    programs use the x64 copies, as Windows on ARM does),
/// 2. finds the component that ships the DLL (the catalog below),
/// 3. downloads that component once, only from its publisher (Microsoft's download
///    server, checked by VisualCRuntimeBootstrap.isTrustedDownloadURL), into a cache
///    under Files › iDeck › DLL Cache, kept for every later game,
/// 4. copies the DLL of the right architecture next to the game's program, where
///    Windows and Wine look first, in the game's own prefix,
/// 5. checks the program again and takes back any copy that did not resolve its import,
/// 6. records every copy, so Settings › Windows runtime › Undo automatic DLLs removes them.
/// A DLL that appears only in the Wine log after a failed start (status c0000135) is
/// looked up the same way; its component is downloaded at once and the DLL is put in
/// place at the next start, which iDeck asks for ("start the game again"): iDeck needs a
/// fresh process for each Windows session, so it cannot restart the game by itself.
/// Visual C++ and .NET are not here: iDeck installs those before the launch already.
enum AutoDLLManager {

    // MARK: Download and cache

    // MARK: Install, verify, roll back

}
