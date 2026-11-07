import Foundation

@main
enum LocalizationLaunchSmokeTests {
    static func main() {
        // Evaluating this property reproduces the launch-time SIGTRAP if a
        // dictionaryLiteral repeats any top-level key, even if the UI compiles.
        precondition(Translations.table.count > 250)

        UserDefaults.standard.set("pt", forKey: AppLanguage.storageKey)
        precondition(tr("Madeira") == "Madeira")
        precondition(tr("Debugger connection") == "Conexão do depurador")
        precondition(tr("Pairing code") == "Código de pareamento")
        precondition(trStatus("Madeira") == "Madeira")

        UserDefaults.standard.set("es", forKey: AppLanguage.storageKey)
        precondition(tr("Madeira") == "Madeira")
        precondition(tr("Debugger connection") == "Conexión del depurador")
        precondition(tr("Pairing code") == "Código de emparejamiento")

        UserDefaults.standard.set("en", forKey: AppLanguage.storageKey)
        precondition(tr("Madeira") == "Madeira")
        precondition(tr("Pairing code") == "Pairing code")
        UserDefaults.standard.removeObject(forKey: AppLanguage.storageKey)
        print("PASS: iDeck localization initializes safely in Portuguese, Spanish and English")
    }
}
