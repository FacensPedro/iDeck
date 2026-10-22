import Foundation

/// In-app language selection. "system" follows the device language (falling back to English).
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case portuguese = "pt"
    case spanish = "es"

    var id: String { rawValue }

    static let storageKey = "appLanguage"

    var displayName: String {
        switch self {
        case .system: return tr("System default")
        case .english: return "English"
        case .portuguese: return "Português"
        case .spanish: return "Español"
        }
    }

    /// The language strings are currently shown in: "en", "pt" or "es".
    static var currentCode: String {
        let stored = UserDefaults.standard.string(forKey: storageKey) ?? AppLanguage.system.rawValue
        if let language = AppLanguage(rawValue: stored), language != .system { return language.rawValue }
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        if preferred.hasPrefix("pt") { return "pt" }
        if preferred.hasPrefix("es") { return "es" }
        return "en"
    }
}

/// Translates an English UI string. Unknown strings are returned unchanged.
func tr(_ key: String) -> String {
    let code = AppLanguage.currentCode
    if code == "en" { return key }
    return Translations.table[key]?[code] ?? key
}

func tr(_ key: String, _ args: CVarArg...) -> String {
    String(format: tr(key), arguments: args)
}

/// Translates a status line. Dynamic statuses look like "JIT Failed: <detail>": only the part
/// before the first ": " is translated.
func trStatus(_ status: String) -> String {
    if Translations.table[status] != nil { return tr(status) }
    if let range = status.range(of: ": ") {
        let head = String(status[status.startIndex..<range.lowerBound])
        return tr(head) + ": " + trStatus(String(status[range.upperBound...]))
    }
    return status
}

enum Translations {
    static let table: [String: [String: String]] = [
        // Modes
        "Run Windows apps and Steam through Wine": ["pt": "Execute apps do Windows e o Steam via Wine", "es": "Ejecuta apps de Windows y Steam con Wine"],
        "Run iOS apps inside iDeck": ["pt": "Execute apps iOS dentro do iDeck", "es": "Ejecuta apps de iOS dentro de iDeck"],
        "Mode": ["pt": "Modo", "es": "Modo"],
        "Settings": ["pt": "Ajustes", "es": "Ajustes"],
        "Done": ["pt": "Concluído", "es": "Listo"],
        "Container": ["pt": "Container", "es": "Contenedor"],
        "Gamepad": ["pt": "Controle", "es": "Mando"],
        "Installing Windows environment...": ["pt": "Instalando ambiente Windows...", "es": "Instalando entorno de Windows..."],
        "Start Windows Environment": ["pt": "Iniciar ambiente Windows", "es": "Iniciar entorno de Windows"],
        "Install & Run Steam": ["pt": "Instalar e abrir o Steam", "es": "Instalar y abrir Steam"],
        "Run Executable (.exe)": ["pt": "Executar programa (.exe)", "es": "Ejecutar programa (.exe)"],
        "Start LiveContainer": ["pt": "Iniciar LiveContainer", "es": "Iniciar LiveContainer"],
        "LiveContainer Apps": ["pt": "Apps do LiveContainer", "es": "Apps de LiveContainer"],
        "No apps installed. Tap + to install an .ipa": ["pt": "Nenhum app instalado. Toque em + para instalar um .ipa", "es": "No hay apps instaladas. Toca + para instalar un .ipa"],

        // Settings
        "Language": ["pt": "Idioma", "es": "Idioma"],
        "System default": ["pt": "Padrão do sistema", "es": "Predeterminado del sistema"],
        "JIT & Debugging": ["pt": "JIT e depuração", "es": "JIT y depuración"],
        "Activate JIT": ["pt": "Ativar JIT", "es": "Activar JIT"],
        "Confirm JIT activated in StikDebug": ["pt": "Confirmar JIT ativado no StikDebug", "es": "Confirmar JIT activado en StikDebug"],
        "Activate JIT in StikDebug first, then return here and confirm. iDeck does not activate JIT itself.": ["pt": "Ative o JIT pelo StikDebug primeiro e depois volte aqui para confirmar. O iDeck não ativa o JIT por conta própria.", "es": "Activa JIT primero desde StikDebug y vuelve aquí para confirmarlo. iDeck no activa JIT por sí mismo."],
        "JIT confirmed via StikDebug": ["pt": "JIT confirmado pelo StikDebug", "es": "JIT confirmado mediante StikDebug"],
        "Activate JIT with StikDebug, then confirm it in iDeck Settings.": ["pt": "Ative o JIT pelo StikDebug e depois confirme nos Ajustes do iDeck.", "es": "Activa JIT con StikDebug y después confírmalo en los ajustes de iDeck."],
        "Import Pairing File": ["pt": "Importar arquivo de pareamento", "es": "Importar archivo de emparejamiento"],
        "Mount Developer Disk Image": ["pt": "Montar imagem de disco do desenvolvedor", "es": "Montar imagen de disco de desarrollador"],
        "JIT Pool": ["pt": "Pool de JIT", "es": "Pool de JIT"],
        "VPN JIT Trigger": ["pt": "Gatilho de JIT por VPN", "es": "Disparador de JIT por VPN"],
        "Graphics & Performance": ["pt": "Gráficos e desempenho", "es": "Gráficos y rendimiento"],
        "MetalFX Upscaling": ["pt": "Upscaling MetalFX", "es": "Escalado MetalFX"],
        "Hold Display at Maximum Rate": ["pt": "Manter a tela na taxa máxima", "es": "Mantener la pantalla a la tasa máxima"],
        "DXVK HUD": ["pt": "HUD do DXVK", "es": "HUD de DXVK"],
        "D3DMetal Rendering": ["pt": "Renderização D3DMetal", "es": "Renderizado D3DMetal"],
        "Updates": ["pt": "Atualizações", "es": "Actualizaciones"],
        "LiveContainer": ["pt": "LiveContainer", "es": "LiveContainer"],
        "Inject Guest Hooks": ["pt": "Injetar hooks nos apps convidados", "es": "Inyectar hooks en apps invitadas"],
        "Pairing file: imported": ["pt": "Arquivo de pareamento: importado", "es": "Archivo de emparejamiento: importado"],
        "Pairing file: none": ["pt": "Arquivo de pareamento: nenhum", "es": "Archivo de emparejamiento: ninguno"],
        "JIT helper server": ["pt": "Servidor auxiliar de JIT", "es": "Servidor auxiliar de JIT"],
        "Token (JIT_SERVER_TOKEN)": ["pt": "Token (JIT_SERVER_TOKEN)", "es": "Token (JIT_SERVER_TOKEN)"],
        "Run server_jit/server.py on a computer connected to this device, then enter its address here. The pairing file stays on the device and is not sent to the server.":
            ["pt": "Execute server_jit/server.py num computador conectado a este aparelho e digite o endereço dele aqui. O arquivo de pareamento fica no aparelho e não é enviado ao servidor.",
             "es": "Ejecuta server_jit/server.py en un ordenador conectado a este dispositivo e introduce su dirección aquí. El archivo de emparejamiento se queda en el dispositivo y no se envía al servidor."],

        "Controller": ["pt": "Controle", "es": "Mando"],
        "Connected controller": ["pt": "Controle conectado", "es": "Mando conectado"],
        "Not connected": ["pt": "Não conectado", "es": "No conectado"],
        "Left stick sensitivity": ["pt": "Sensibilidade do analógico esquerdo", "es": "Sensibilidad del stick izquierdo"],
        "Right stick sensitivity": ["pt": "Sensibilidade do analógico direito", "es": "Sensibilidad del stick derecho"],
        "Stick dead zone": ["pt": "Zona morta dos analógicos", "es": "Zona muerta de los sticks"],
        "IPA installation": ["pt": "Instalação de IPA", "es": "Instalación de IPA"],
        "OK": ["pt": "OK", "es": "Aceptar"],
        "Unknown installation result": ["pt": "Resultado de instalação desconhecido", "es": "Resultado de instalación desconocido"],
        "IPA installed. Select the app to launch it.": ["pt": "IPA instalado. Selecione o app para iniciá-lo.", "es": "IPA instalado. Selecciona la app para iniciarla."],
        "The selected file is not a readable IPA/ZIP archive.": ["pt": "O arquivo selecionado não é um arquivo IPA/ZIP válido ou legível.", "es": "El archivo seleccionado no es un archivo IPA/ZIP válido o legible."],
        "This IPA uses a ZIP feature that the current extractor does not support (for example ZIP64 or encryption).": ["pt": "Este IPA usa um recurso ZIP não compatível com o extrator atual, como ZIP64 ou criptografia.", "es": "Este IPA utiliza una función ZIP no compatible con el extractor actual, como ZIP64 o cifrado."],
        "The IPA contains an unsafe file path and was rejected.": ["pt": "O IPA contém um caminho de arquivo inseguro e foi rejeitado.", "es": "El IPA contiene una ruta de archivo no segura y se rechazó."],
        "The archive does not contain a top-level Payload directory.": ["pt": "O arquivo não contém uma pasta Payload na raiz.", "es": "El archivo no contiene una carpeta Payload en la raíz."],
        "The Payload directory does not contain a valid .app bundle with Info.plist.": ["pt": "A pasta Payload não contém um pacote .app válido com Info.plist.", "es": "La carpeta Payload no contiene un paquete .app válido con Info.plist."],
        "JIT server address is not configured. Enter the reachable computer/server address in Settings.": ["pt": "O endereço do servidor JIT não está configurado. Informe em Ajustes o endereço acessível do computador/servidor.", "es": "La dirección del servidor JIT no está configurada. Introduce en Ajustes la dirección accesible del ordenador/servidor."],
        "Invalid JIT server URL. Enter a valid http:// or https:// address.": ["pt": "URL do servidor JIT inválida. Informe um endereço http:// ou https:// válido.", "es": "La URL del servidor JIT no es válida. Introduce una dirección http:// o https:// válida."],
        "JIT server unreachable": ["pt": "Servidor JIT inacessível", "es": "Servidor JIT inaccesible"],
        "JIT server rejected the token": ["pt": "O servidor JIT rejeitou o token", "es": "El servidor JIT rechazó el token"],
        "Could not connect to the server": ["pt": "Não foi possível conectar ao servidor", "es": "No se pudo conectar con el servidor"],
        "Could not copy the app bundle": ["pt": "Não foi possível copiar o pacote do app", "es": "No se pudo copiar el paquete de la app"],

        // Updates
        "Check for Updates": ["pt": "Verificar atualizações", "es": "Buscar actualizaciones"],
        "Checking...": ["pt": "Verificando...", "es": "Comprobando..."],
        "Install iDeck %@": ["pt": "Instalar o iDeck %@", "es": "Instalar iDeck %@"],
        "no IPA release": ["pt": "sem release com IPA", "es": "sin release con IPA"],
        "unavailable": ["pt": "indisponível", "es": "no disponible"],

        // Status lines
        "Ready": ["pt": "Pronto", "es": "Listo"],
        "Initializing LiveContainer...": ["pt": "Iniciando o LiveContainer...", "es": "Iniciando LiveContainer..."],
        "LiveContainer Running": ["pt": "LiveContainer em execução", "es": "LiveContainer en ejecución"],
        "Container Error": ["pt": "Erro no container", "es": "Error del contenedor"],
        "Requires JIT": ["pt": "Requer JIT", "es": "Requiere JIT"],
        "Installing Windows Environment...": ["pt": "Instalando o ambiente Windows...", "es": "Instalando el entorno de Windows..."],
        "Container not initialized": ["pt": "Container não inicializado", "es": "Contenedor no inicializado"],
        "Windows Ready": ["pt": "Windows pronto", "es": "Windows listo"],
        "Failed to Install Windows Environment": ["pt": "Falha ao instalar o ambiente Windows", "es": "Error al instalar el entorno de Windows"],
        "Activating JIT...": ["pt": "Ativando o JIT...", "es": "Activando JIT..."],
        "JIT Activated": ["pt": "JIT ativado", "es": "JIT activado"],
        "JIT Failed": ["pt": "Falha no JIT", "es": "Error de JIT"],
        "Starting LocalDevVPN...": ["pt": "Iniciando o LocalDevVPN...", "es": "Iniciando LocalDevVPN..."],
        "Failed to start VPN": ["pt": "Falha ao iniciar a VPN", "es": "Error al iniciar la VPN"],
        "Pairing file imported": ["pt": "Arquivo de pareamento importado", "es": "Archivo de emparejamiento importado"],
        "Pairing import failed": ["pt": "Falha ao importar o pareamento", "es": "Error al importar el emparejamiento"],
        "Not a valid pairing file": ["pt": "Arquivo de pareamento inválido", "es": "Archivo de emparejamiento no válido"],
        "Mounting DDI...": ["pt": "Montando o DDI...", "es": "Montando DDI..."],
        "DDI Mounted": ["pt": "DDI montado", "es": "DDI montado"],
        "DDI Mount Failed": ["pt": "Falha ao montar o DDI", "es": "Error al montar el DDI"],
        "Downloading Steam...": ["pt": "Baixando o Steam...", "es": "Descargando Steam..."],
        "Steam Running": ["pt": "Steam em execução", "es": "Steam en ejecución"],
        "Steam Error": ["pt": "Erro no Steam", "es": "Error de Steam"],
        "Loading Executable...": ["pt": "Carregando o programa...", "es": "Cargando el programa..."],
        "Running": ["pt": "Em execução", "es": "En ejecución"],
        "Execution Error": ["pt": "Erro de execução", "es": "Error de ejecución"],
        "Requires JIT & LiveContainer": ["pt": "Requer JIT e LiveContainer", "es": "Requiere JIT y LiveContainer"],
        "Guest app not found": ["pt": "App convidado não encontrado", "es": "App invitada no encontrada"],
        "Launching": ["pt": "Abrindo", "es": "Abriendo"],
        "Guest app running": ["pt": "App convidado em execução", "es": "App invitada en ejecución"],
        "Guest launch failed": ["pt": "Falha ao abrir o app convidado", "es": "Error al abrir la app invitada"],
        "Windows": ["pt": "Windows", "es": "Windows"],
        "Back": ["pt": "Voltar", "es": "Volver"],
        "Game Library": ["pt": "Biblioteca de jogos", "es": "Biblioteca de juegos"],
        "Steam games and imported Windows installers": ["pt": "Jogos do Steam e instaladores do Windows importados", "es": "Juegos de Steam e instaladores de Windows importados"],
        "Connect Steam": ["pt": "Conectar ao Steam", "es": "Conectar Steam"],
        "Steam library integration is not configured": ["pt": "A integração da biblioteca Steam não está configurada", "es": "La integración de la biblioteca de Steam no está configurada"],
        "This iDeck build does not include Madeira's FEX, Wine ARM64EC, DXMT and Steam Dock runtime. Opening Steam's website does not connect an account or load games.": ["pt": "Esta versão do iDeck não inclui o runtime FEX, Wine ARM64EC, DXMT e Steam Dock do Madeira. Abrir o site do Steam não conecta uma conta nem carrega jogos.", "es": "Esta versión de iDeck no incluye el runtime FEX, Wine ARM64EC, DXMT y Steam Dock de Madeira. Abrir el sitio de Steam no conecta una cuenta ni carga juegos."],
        "Install a Windows .exe": ["pt": "Instalar um arquivo .exe do Windows", "es": "Instalar un archivo .exe de Windows"],
        "Steam integration unavailable": ["pt": "Integração do Steam indisponível", "es": "Integración de Steam no disponible"],
        "Steam account sign-in and library loading require Madeira's runtime integration, which is not included in this build yet.": ["pt": "Entrar na conta Steam e carregar a biblioteca exige a integração do runtime Madeira, que ainda não está incluída nesta versão.", "es": "Iniciar sesión en Steam y cargar la biblioteca requiere la integración del runtime Madeira, que todavía no está incluida en esta versión."],
        "Steam": ["pt": "Steam", "es": "Steam"],
        "Steam account": ["pt": "Conta Steam", "es": "Cuenta de Steam"],
        "Connected": ["pt": "Conectada", "es": "Conectada"],
        "Disconnect Steam": ["pt": "Desconectar Steam", "es": "Desconectar Steam"],
        "JIT detected": ["pt": "JIT detectado", "es": "JIT detectado"],
        "JIT not detected": ["pt": "JIT não detectado", "es": "JIT no detectado"],
        "JIT is detected automatically. To activate it, enable JIT for iDeck in StikDebug, then return here.": ["pt": "O JIT é detectado automaticamente. Para ativá-lo, ative o JIT do iDeck no StikDebug e volte para cá.", "es": "El JIT se detecta automáticamente. Para activarlo, activa el JIT de iDeck en StikDebug y vuelve aquí."],
        "Steam disconnected": ["pt": "Steam desconectado", "es": "Steam desconectado"],
        "Madeira runtime missing": ["pt": "Runtime do Madeira ausente", "es": "Falta el runtime de Madeira"],
        "Executable imported. Enable JIT for iDeck in StikDebug before running it.": ["pt": "Executável importado. Ative o JIT do iDeck no StikDebug antes de executá-lo.", "es": "Ejecutable importado. Activa el JIT de iDeck en StikDebug antes de ejecutarlo."],
        "Executable import failed": ["pt": "Falha ao importar o executável", "es": "Error al importar el ejecutable"],
        "Container initialization failed": ["pt": "Falha ao inicializar o contêiner", "es": "Error al inicializar el contenedor"],
        "dlopen failed": ["pt": "Falha no dlopen", "es": "Falló dlopen"],
        "Home": ["pt": "Início", "es": "Inicio"],
        "Choose a mode to continue": ["pt": "Escolha um modo para continuar", "es": "Elige un modo para continuar"],
        "Sign in to Steam": ["pt": "Entrar no Steam", "es": "Iniciar sesión en Steam"],
        "Madeira keeps a Steam sign-in so it can start your Steam games with your own account.": ["pt": "O Madeira mantém uma sessão do Steam para iniciar jogos com sua própria conta.", "es": "Madeira mantiene una sesión de Steam para iniciar juegos con tu propia cuenta."],
        "Sign-in method": ["pt": "Método de login", "es": "Método de inicio de sesión"],
        "Password": ["pt": "Senha", "es": "Contraseña"],
        "QR code": ["pt": "Código QR", "es": "Código QR"],
        "Madeira signs in with Steam directly. Your password is sent only to Steam and is never stored. A sign-in token is kept in this device's Keychain until you sign out.": ["pt": "O login é feito diretamente com o Steam. Sua senha é enviada apenas ao Steam e nunca é armazenada. O token da sessão fica no Chaves do iPad até você sair da conta.", "es": "El inicio de sesión se realiza directamente con Steam. Tu contraseña solo se envía a Steam y nunca se guarda. El token de sesión permanece en el llavero del dispositivo hasta que cierres sesión."],
        "Cancel": ["pt": "Cancelar", "es": "Cancelar"],
        "Sign out": ["pt": "Sair da conta", "es": "Cerrar sesión"],
        "Signing out removes the token from this device's Keychain.": ["pt": "Ao sair, o token é removido do Chaves deste dispositivo.", "es": "Al cerrar sesión, se elimina el token del llavero de este dispositivo."],
        "Steam account name": ["pt": "Nome de usuário Steam", "es": "Nombre de usuario de Steam"],
        "Sign in": ["pt": "Entrar", "es": "Iniciar sesión"],
        "Use your Steam account name, which can differ from your email address.": ["pt": "Use o nome de usuário da sua conta Steam, que pode ser diferente do seu e-mail.", "es": "Usa el nombre de tu cuenta de Steam, que puede ser distinto de tu correo electrónico."],
        "Code": ["pt": "Código", "es": "Código"],
        "Continue": ["pt": "Continuar", "es": "Continuar"],
        "Enter the Steam Guard code shown in the Steam app on your phone.": ["pt": "Digite o código Steam Guard exibido no aplicativo Steam do celular.", "es": "Introduce el código de Steam Guard que aparece en la aplicación de Steam de tu teléfono."],
        "Enter the code Steam sent to your email": ["pt": "Digite o código que o Steam enviou para seu e-mail", "es": "Introduce el código que Steam envió a tu correo electrónico"],
        "Approve this sign-in in the Steam app on your phone.": ["pt": "Aprove este login no aplicativo Steam do celular.", "es": "Aprueba este inicio de sesión en la aplicación de Steam de tu teléfono."],
        "Or approve this sign-in in the Steam app.": ["pt": "Ou aprove este login no aplicativo Steam.", "es": "O aprueba este inicio de sesión en la aplicación de Steam."],
        "Start over": ["pt": "Recomeçar", "es": "Empezar de nuevo"],
        "Steam Guard": ["pt": "Steam Guard", "es": "Steam Guard"],
        "Steam sign-in QR code": ["pt": "Código QR de login do Steam", "es": "Código QR de inicio de sesión de Steam"],
        "On another device, open the Steam app, go to Steam Guard, and scan this code.": ["pt": "Em outro dispositivo, abra o app Steam, acesse o Steam Guard e leia este código.", "es": "En otro dispositivo, abre la aplicación Steam, entra en Steam Guard y escanea este código."],
        "Open in the Steam app on this device": ["pt": "Abrir no aplicativo Steam deste dispositivo", "es": "Abrir en la aplicación Steam de este dispositivo"],
        "Waiting for approval…": ["pt": "Aguardando aprovação…", "es": "Esperando aprobación…"],
        "Getting a sign-in code…": ["pt": "Obtendo código de login…", "es": "Obteniendo código de inicio de sesión…"],
        "Get a new code": ["pt": "Gerar novo código", "es": "Obtener un código nuevo"],
        "Steam connected": ["pt": "Steam conectado", "es": "Steam conectado"],
        "Connected to Steam": ["pt": "Conectado ao Steam", "es": "Conectado a Steam"],
        "Connect Steam to continue": ["pt": "Conecte o Steam para continuar", "es": "Conecta Steam para continuar"],
        "Signed in as %@": ["pt": "Conectado como %@", "es": "Conectado como %@"],
        "Steam sign-in is connected. Loading the owned-games library and launching games requires the Madeira native runtime.": ["pt": "A conta Steam está conectada. Para carregar sua biblioteca de jogos e executá-los, ainda é necessário integrar o runtime nativo do Madeira.", "es": "La cuenta de Steam está conectada. Para cargar la biblioteca de juegos y ejecutarlos, todavía es necesario integrar el entorno nativo de Madeira."],
        "Sign in directly with Steam. iDeck does not store your password; the sign-in token is saved in this device's Keychain.": ["pt": "Entre diretamente com o Steam. O iDeck não armazena sua senha; o token da sessão é salvo no Chaves deste dispositivo.", "es": "Inicia sesión directamente con Steam. iDeck no guarda tu contraseña; el token de sesión se almacena en el llavero de este dispositivo."],
    ]
}
