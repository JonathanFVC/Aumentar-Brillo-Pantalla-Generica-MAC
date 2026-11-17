import Cocoa
import ColorSync
import ServiceManagement

// App de barra de menu (APIs de macOS; una sola privada, CGSConfigureDisplayEnabled, para reconectar el monitor tras instalar o quitar los modos HiDPI): ganancia, perfil de color y HiDPI/resolucion de la 1ra pantalla externa.

func activeDisplays() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &n); return Array(ids.prefix(Int(n)))
}
func screenName(_ id: CGDirectDisplayID) -> String {
    for s in NSScreen.screens {
        if let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber, n.uint32Value == id { UserDefaults.standard.set(s.localizedName, forKey: "lastName"); return s.localizedName }
    }
    return UserDefaults.standard.string(forKey: "lastName") ?? "Pantalla externa"
}
func isHiDPI(_ m: CGDisplayMode) -> Bool { m.pixelWidth > m.width }
func onlineDisplays() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &n); return Array(ids.prefix(Int(n)))
}

// BEGIN reconectar
// Reconexion por software del monitor externo (API privada CGSConfigureDisplayEnabled, la de `pantalla-cli reconectar`): lo apaga ~3 s y lo enciende
// para que macOS vuelva a leer el override HiDPI sin tocar el cable ni reiniciar. Nunca toca la pantalla integrada; si la funcion no existe, avisa.
nonisolated(unsafe) var reconectando = false
func reconnect(_ id: CGDirectDisplayID, done: @escaping (Bool, String) -> Void) {
    typealias Enable = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
    if reconectando { done(false, "ya hay una reconexión en curso"); return }
    if CGDisplayIsBuiltin(id) != 0 { done(false, "no se aplica a la pantalla integrada"); return }
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSConfigureDisplayEnabled") else { done(false, "esta versión de macOS no ofrece la función"); return }
    let fn = unsafeBitCast(sym, to: Enable.self)
    func set(_ on: Bool) -> CGError {
        var cfg: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&cfg)
        let r = fn(cfg, id, on)
        if r != .success { CGCancelDisplayConfiguration(cfg); return r }
        return CGCompleteDisplayConfiguration(cfg, .forSession)
    }
    let a = set(false)
    if a != .success { done(false, "macOS no apagó el monitor (error \(a.rawValue)); no se tocó nada"); return }
    reconectando = true
    func encender(_ intento: Int) {
        let b = set(true)
        if b == .success { reconectando = false; done(true, "") }
        else if intento < 5 { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { encender(intento + 1) } }
        else { reconectando = false; done(false, "el monitor no volvió a encenderse (error \(b.rawValue))") }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { encender(1) }
}
// END reconectar

nonisolated(unsafe) var collected: [(String, URL)] = []
func installedProfiles() -> [(String, URL)] {
    collected = []
    ColorSyncIterateInstalledProfiles({ d, _ in
        guard let d = d as? [String: Any] else { return true }
        var url: URL?
        for (_, v) in d { if let u = v as? URL { url = u } }
        guard let u = url, let p = ColorSyncProfileCreateWithURL(u as CFURL, nil)?.takeRetainedValue() else { return true }
        let name = (ColorSyncProfileCopyDescriptionString(p)?.takeRetainedValue() as String?) ?? u.lastPathComponent
        collected.append((name, u))
        return true
    }, nil, nil, nil)
    // ColorSync no indexa al instante los perfiles de la carpeta de usuario: se leen directo
    let carpeta = NSString(string: "~/Library/ColorSync/Profiles").expandingTildeInPath
    for f in (try? FileManager.default.contentsOfDirectory(atPath: carpeta)) ?? [] where f.lowercased().hasSuffix(".icc") || f.lowercased().hasSuffix(".icm") {
        let u = URL(fileURLWithPath: carpeta + "/" + f)
        if collected.contains(where: { $0.1.path == u.path }) { continue }
        if let p = ColorSyncProfileCreateWithURL(u as CFURL, nil)?.takeRetainedValue() {
            collected.append(((ColorSyncProfileCopyDescriptionString(p)?.takeRetainedValue() as String?) ?? f, u))
        }
    }
    return collected.sorted { $0.0.lowercased() < $1.0.lowercased() }
}

// Un perfil "claro" es RGB y no oscurece gris medio ni gris oscuro frente a sRGB (medido con el motor de color de macOS, panel de gamma 2.2).
// Oculta los que dejan la pantalla casi negra (ACES CG Linear 0.15x), oscuros (Generic RGB / ROMM RGB 0.70x) y los no RGB (CMYK, Gray, Lab, XYZ).
nonisolated(unsafe) var perfilClaroCache: [String: Bool] = [:]
func perfilClaro(_ url: URL) -> Bool {
    if let c = perfilClaroCache[url.path] { return c }
    func lum(_ cs: CGColorSpace, _ v: CGFloat) -> CGFloat? {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB), let src = CGColor(colorSpace: srgb, components: [v, v, v, 1]),
              let c = src.converted(to: cs, intent: .defaultIntent, options: nil), let k = c.components, k.count >= 3 else { return nil }
        return pow(max(0, (k[0] + k[1] + k[2]) / 3), 2.2)
    }
    var ok = false
    if let data = try? Data(contentsOf: url), let cs = CGColorSpace(iccData: data as CFData), cs.model == .rgb,
       let m = lum(cs, 0.5), let o = lum(cs, 0.15) { ok = m / pow(0.5, 2.2) >= 0.9 && o / pow(0.15, 2.2) >= 0.9 }
    perfilClaroCache[url.path] = ok
    return ok
}

// BEGIN curvaTonos
// Tabla de 256 puntos: v = entrada^(1/gamma) * ganancia. Con ganancia > 1, v pasa de 1 y antes se cortaba (todo blanco).
// Rodilla suave: hasta K la curva es igual que antes; de K a la entrada maxima (v = ganancia) se comprime de forma continua (C1) y monotona
// para que la entrada maxima llegue exactamente a 1.0 (el blanco no se pierde) y las luces conserven detalle. luces: 0 = recorte duro, 1 = rodilla desde 0.5.
func curvaTonos(gain g: Double, gamma gm: Double, luces l: Double) -> [Float] {
    let K = 1 - 0.5 * l, r = 1 - K, D = g - K
    var s = 0.0
    if g > 1 && l > 0 && D > r {                        // resolver s * (1 - e^(-D/s)) = r por biseccion
        var lo = 1e-9, hi = D * 1e4
        for _ in 0..<200 { let mid = (lo + hi) / 2; if mid * (-expm1(-D / mid)) < r { lo = mid } else { hi = mid } }
        s = (lo + hi) / 2
    }
    var t = [Float](repeating: 0, count: 256)
    for i in 0..<256 {
        let v = pow(Double(i) / 255.0, 1.0 / gm) * g
        var o = min(1.0, v)
        if s > 0 && v > K { o = K + r * (-expm1(-(v - K) / s)) / (-expm1(-D / s)) }
        t[i] = Float(min(1.0, max(0.0, o)))
    }
    return t
}
// END curvaTonos

final class Dot: NSView {
    override func hitTest(_ p: NSPoint) -> NSView? { nil }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.backgroundColor = NSColor.systemBlue.cgColor; layer?.cornerRadius = frame.width / 2 }
    required init?(coder: NSCoder) { fatalError() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let ud = UserDefaults.standard
    var labels: [Int: NSTextField] = [:]
    var dots: [Int: Dot] = [:]
    let snapRange = 0.04  // distancia (en valor del deslizador) a la que se pega al original

    var gain: Double { get { ud.object(forKey: "gain") == nil ? 1.25 : ud.double(forKey: "gain") } set { ud.set(newValue, forKey: "gain") } }
    var gamma: Double { get { ud.object(forKey: "gamma") == nil ? 1.0 : ud.double(forKey: "gamma") } set { ud.set(newValue, forKey: "gamma") } }
    var luces: Double { get { ud.object(forKey: "luces") == nil ? 0.5 : ud.double(forKey: "luces") } set { ud.set(newValue, forKey: "luces") } }
    var enabled: Bool { get { ud.object(forKey: "enabled") == nil ? true : ud.bool(forKey: "enabled") } set { ud.set(newValue, forKey: "enabled") } }
    var target: CGDirectDisplayID? { onlineDisplays().first { CGDisplayIsBuiltin($0) == 0 } }

    func updateIcon() {
        item.button?.image = NSImage(systemSymbolName: enabled ? "display" : "display.trianglebadge.exclamationmark", accessibilityDescription: "Pantalla")
        item.button?.image?.isTemplate = true
        item.button?.appearsDisabled = !enabled
    }
    @objc func toggleEnabled() { enabled.toggle(); updateIcon(); applyGain() }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        updateIcon()
        menu.delegate = self
        item.menu = menu
        if !ud.bool(forKey: "loginRegistered") {
            do { try SMAppService.mainApp.register(); ud.set(true, forKey: "loginRegistered") } catch { NSLog("login item: \(error)") }
        }
        applyGain()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.reapplyOnce() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.reapplyOnce() }
    }
    // macOS reinicia la tabla de color varias veces tras cambiar de modo: se reaplica en rafaga durante unos segundos
    // macOS reinicia la tabla de color al cambiar el tamano del escritorio (~0.3 s despues): se reaplica UNA vez, sin vigilar nada
    func reapplyOnce() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.applyGain() } }

    // MARK: ganancia
    func applyGain() {
        guard let id = target else { return }
        let t = curvaTonos(gain: enabled ? gain : 1.0, gamma: enabled ? gamma : 1.0, luces: luces)
        // solo escribe si la tabla actual difiere: reescribir la misma tabla reprograma el controlador y puede dar destellos
        var r = [CGGammaValue](repeating: 0, count: 256), gg = r, bb = r; var k: UInt32 = 0
        if CGGetDisplayTransferByTable(id, 256, &r, &gg, &bb, &k) == .success, k == 256 {
            var diff: Float = 0
            for i in 0..<256 { diff = Swift.max(diff, abs(r[i] - t[i]), abs(gg[i] - t[i]), abs(bb[i] - t[i])) }
            if diff < 0.01 { return }
        }
        CGSetDisplayTransferByTable(id, 256, t, t, t)
    }
    func labelText(_ tag: Int) -> String {
        switch tag { case 0: return "Ganancia  \(Int((gain * 100).rounded())) %"; case 1: return String(format: "Gamma  %.2f", gamma); default: return "Luces (rodilla suave)  \(Int((luces * 100).rounded())) %" }
    }
    func factoria(_ tag: Int) -> Double { tag == 2 ? 0.5 : 1.0 }   // valor de fabrica: donde va el punto azul y el iman
    @objc func sliderChanged(_ s: NSSlider) {
        if abs(s.doubleValue - factoria(s.tag)) < snapRange { s.doubleValue = factoria(s.tag) }  // imán: cerca del valor de fabrica, se pega
        let v = (s.doubleValue * 100).rounded() / 100
        switch s.tag { case 0: gain = v; case 1: gamma = v; default: luces = v }
        labels[s.tag]?.stringValue = labelText(s.tag)
        applyGain()
    }
    func sliderItem(tag: Int, min: Double, max: Double, value: Double) -> NSMenuItem {
        let fab = factoria(tag)
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 48))
        let l = NSTextField(labelWithString: labelText(tag)); l.frame = NSRect(x: 14, y: 28, width: 220, height: 16); l.font = .menuFont(ofSize: 13)
        let s = NSSlider(value: value, minValue: min, maxValue: max, target: self, action: #selector(sliderChanged(_:)))
        s.frame = NSRect(x: 14, y: 6, width: 220, height: 20); s.tag = tag; s.isContinuous = true
        v.addSubview(l); v.addSubview(s); labels[tag] = l
        // punto azul fijo en la posicion del valor de fabrica (1.0; luces 50 %), siempre visible; la perilla mide ~20 pt de ancho
        let cx = s.frame.minX + 10 + CGFloat((fab - min) / (max - min)) * (s.frame.width - 20)
        let d = Dot(frame: NSRect(x: cx - 4, y: s.frame.midY - 4, width: 8, height: 8))
        v.addSubview(d); dots[tag] = d
        let it = NSMenuItem(); it.view = v; return it
    }
    @objc func resetGain() { gain = 1.0; gamma = 1.0; luces = 0.5; applyGain() }

    // MARK: perfil de color
    @objc func setProfile(_ s: NSMenuItem) {
        guard let id = target, let url = s.representedObject as? URL, let uuid = CGDisplayCreateUUIDFromDisplayID(id) else { alert("No se pudo asignar el perfil", "No se encontró la pantalla externa."); return }
        let info = [kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String: url] as CFDictionary
        if ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid.takeRetainedValue(), info) {
            ud.set(url.path, forKey: "profilePath")
        } else { alert("No se pudo asignar el perfil", "macOS rechazó \(url.lastPathComponent); la pantalla se queda como estaba.") }
    }
    @objc func resetProfile() {
        guard let id = target, let uuid = CGDisplayCreateUUIDFromDisplayID(id) else { alert("No se pudo restaurar el perfil", "No se encontró la pantalla externa."); return }
        if ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid.takeRetainedValue(), nil) { ud.removeObject(forKey: "profilePath") }
        else { alert("No se pudo restaurar el perfil", "macOS rechazó el cambio.") }
    }

    // MARK: resolucion / HiDPI
    func allModes(_ id: CGDirectDisplayID) -> [CGDisplayMode] {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let all = (CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode]) ?? []
        var seen = Set<String>(); var out: [CGDisplayMode] = []
        for m in all.sorted(by: { ($0.width, $0.pixelWidth, $0.refreshRate) > ($1.width, $1.pixelWidth, $1.refreshRate) }) where m.isUsableForDesktopGUI() && !(m.width == 1920 && m.height == 1080) {
            let k = "\(m.width)x\(m.height)-\(m.pixelWidth)-\(Int(m.refreshRate))"
            if seen.insert(k).inserted { out.append(m) }
        }
        return out
    }
    func same(_ a: CGDisplayMode, _ b: CGDisplayMode) -> Bool {
        a.width == b.width && a.height == b.height && a.pixelWidth == b.pixelWidth && Int(a.refreshRate) == Int(b.refreshRate)
    }
    func applyMode(_ m: CGDisplayMode, on id: CGDirectDisplayID) {
        let nombre = "\(m.width) × \(m.height)" + (isHiDPI(m) ? " (HiDPI)" : "")
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { alert("No se pudo cambiar a \(nombre)", "macOS no inició la configuración de pantalla."); return }
        let r1 = CGConfigureDisplayWithDisplayMode(cfg, id, m, nil)
        if r1 != .success { CGCancelDisplayConfiguration(cfg); alert("No se pudo cambiar a \(nombre)", "macOS rechazó el modo (error \(r1.rawValue)); la pantalla se queda como estaba."); return }
        let r2 = CGCompleteDisplayConfiguration(cfg, .permanently)
        if r2 != .success { alert("No se pudo cambiar a \(nombre)", "macOS no aplicó el modo (error \(r2.rawValue)); la pantalla se queda como estaba."); return }
        reapplyOnce()
    }
    // el boton "Alta resolucion" guarda si los tamanos se aplican con HiDPI; la lista solo muestra tamanos (modos base)
    @objc func setResolution(_ s: NSMenuItem) {
        guard let id = target, let obj = s.representedObject, CFGetTypeID(obj as CFTypeRef) == CGDisplayMode.typeID else { return }
        let base = obj as! CGDisplayMode
        let hi = allModes(id).first { $0.width == base.width && $0.height == base.height && Int($0.refreshRate) == Int(base.refreshRate) && isHiDPI($0) }
        applyMode(ud.bool(forKey: "hidpiOn") ? (hi ?? base) : base, on: id)
    }
    @objc func toggleHiDPI() {
        guard let id = target, let cur = CGDisplayCopyDisplayMode(id) else { return }
        let want = !ud.bool(forKey: "hidpiOn")
        ud.set(want, forKey: "hidpiOn")
        if let m = allModes(id).first(where: { $0.width == cur.width && $0.height == cur.height && Int($0.refreshRate) == Int(cur.refreshRate) && isHiDPI($0) == want }) { applyMode(m, on: id) }
    }

    // MARK: override HiDPI del sistema (archivo en /Library/Displays; pide contrasena de administrador)
    func overridePath(_ id: CGDirectDisplayID) -> (dir: String, file: String) {
        let dir = "/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-\(String(CGDisplayVendorNumber(id), radix: 16))"
        return (dir, "\(dir)/DisplayProductID-\(String(CGDisplayModelNumber(id), radix: 16))")
    }
    func alert(_ t: String, _ info: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = t; a.informativeText = info; a.runModal()
    }
    func runAdmin(_ shell: String) -> String? {
        var err: NSDictionary?
        NSAppleScript(source: "do shell script \"\(shell)\" with administrator privileges")?.executeAndReturnError(&err)
        return err.map { ($0[NSAppleScript.errorMessage] as? String) ?? "cancelado" }
    }
    @objc func installHiDPI() {
        guard let id = target else { return }
        func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)] }
        let logical: [(UInt32, UInt32)] = [(1856, 1044), (1792, 1008), (1760, 990), (1680, 945), (1600, 900), (1440, 810), (1280, 720)]
        // 8 bytes = HiDPI (tamano de respaldo); 12 bytes (ancho, alto, 1) = modo base del mismo tamano logico
        let datas = logical.map { Data(be32($0.0 * 2) + be32($0.1 * 2)) } + logical.map { Data(be32($0.0) + be32($0.1) + be32(1)) }
        let plist: [String: Any] = ["DisplayProductName": screenName(id).replacingOccurrences(of: " HiDPI", with: ""), "DisplayVendorID": Int(CGDisplayVendorNumber(id)), "DisplayProductID": Int(CGDisplayModelNumber(id)), "scale-resolutions": datas]
        // el contenido viaja en base64 dentro del propio comando con privilegios: no hay archivo intermedio que otro proceso pueda cambiar
        guard let xml = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { alert("No se pudo preparar el archivo", "No se pudo serializar el override."); return }
        let b64 = xml.base64EncodedString()
        let p = overridePath(id)
        let nuevo = p.file + ".nuevo"
        if let e = runAdmin("mkdir -p '\(p.dir)' && printf '%s' '\(b64)' | /usr/bin/base64 -D > '\(nuevo)' && chmod 644 '\(nuevo)' && mv -f '\(nuevo)' '\(p.file)'") { alert("No se instaló", e); return }
        // macOS solo relee el override al reconectar el monitor: se hace solo, por software (el monitor se apaga ~3 s)
        reconnect(id) { ok, detalle in
            self.reapplyOnce()
            if ok { self.alert("Modos HiDPI instalados", "El monitor se reconectó solo y ya aparecen en Resolución: 1856×1044, 1792×1008, 1760×990, 1680×945, 1600×900, 1440×810 y 1280×720. Abre el menú otra vez para elegirlos.") }
            else { self.alert("Modos HiDPI instalados", "No se pudo reconectar el monitor solo (\(detalle)). Desconecta y vuelve a conectar el cable, o reinicia la Mac, para que aparezcan.") }
        }
    }
    @objc func removeHiDPI() {
        guard let id = target else { return }
        if let e = runAdmin("rm -f '\(overridePath(id).file)'") { alert("No se quitó", e); return }
        reconnect(id) { ok, detalle in
            self.reapplyOnce()
            if ok { self.alert("Modos HiDPI quitados", "El monitor se reconectó solo y ya no aparecen. Abre el menú otra vez.") }
            else { self.alert("Modos HiDPI quitados", "No se pudo reconectar el monitor solo (\(detalle)). Desconecta y vuelve a conectar el cable, o reinicia la Mac, para que desaparezcan.") }
        }
    }

    @objc func toggleLogin() {
        let svc = SMAppService.mainApp
        do { if svc.status == .enabled { try svc.unregister() } else { try svc.register() } } catch { NSLog("login item: \(error)") }
    }

    // MARK: menu
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems(); labels = [:]; dots = [:]
        guard let id = target else {
            let h = NSMenuItem(title: "No hay pantalla externa conectada", action: nil, keyEquivalent: ""); h.isEnabled = false
            menu.addItem(h); menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")); return
        }
        let h = NSMenuItem(title: screenName(id), action: nil, keyEquivalent: ""); h.isEnabled = false
        menu.addItem(h)
        let onoff = NSMenuItem(title: "Ganancia y gamma activadas", action: #selector(toggleEnabled), keyEquivalent: "")
        onoff.state = enabled ? .on : .off
        menu.addItem(onoff); menu.addItem(.separator())

        menu.addItem(sliderItem(tag: 0, min: 0.8, max: 1.6, value: gain))
        menu.addItem(sliderItem(tag: 1, min: 0.6, max: 1.6, value: gamma))
        menu.addItem(sliderItem(tag: 2, min: 0, max: 1, value: luces))
        menu.addItem(NSMenuItem(title: "Restablecer ganancia, gamma y luces", action: #selector(resetGain), keyEquivalent: ""))
        menu.addItem(.separator())

        let modes = allModes(id)
        let cur = CGDisplayCopyDisplayMode(id)
        func sameLogical(_ x: CGDisplayMode, _ y: CGDisplayMode) -> Bool { x.width == y.width && x.height == y.height && Int(x.refreshRate) == Int(y.refreshRate) }
        // si el tamano actual tiene version con y sin HiDPI, el estado real manda sobre lo guardado
        if let c = cur, modes.contains(where: { sameLogical($0, c) && isHiDPI($0) != isHiDPI(c) }) { ud.set(isHiDPI(c), forKey: "hidpiOn") }
        let hi = NSMenuItem(title: "Alta resolución (HiDPI)", action: #selector(toggleHiDPI), keyEquivalent: "")
        hi.state = ud.bool(forKey: "hidpiOn") ? .on : .off
        menu.addItem(hi)

        let res = NSMenuItem(title: "Resolución", action: nil, keyEquivalent: ""); let rs = NSMenu()
        // solo tamanos 16:9 de 1280+ de ancho con las dos versiones (base y HiDPI), a la frecuencia MAXIMA que ofrece el monitor
        // (75 Hz en un LF27T35, 60 Hz en el JH207, donde los 50 Hz parpadeaban); si a esa frecuencia no hay ningun tamano, baja a la siguiente
        func sizeList(_ hz: Int) -> [CGDisplayMode] {
            modes.filter { m in !isHiDPI(m) && m.width >= 1280 && Int(m.refreshRate.rounded()) == hz && abs(Double(m.width) / Double(m.height) - 16.0 / 9.0) < 0.01 && modes.contains(where: { sameLogical($0, m) && isHiDPI($0) }) }
        }
        let idealHz = Set(modes.map { Int($0.refreshRate.rounded()) }).sorted(by: >).first { !sizeList($0).isEmpty } ?? 60
        for m in sizeList(idealHz) {
            let mi = NSMenuItem(title: "\(m.width) × \(m.height) · \(idealHz) Hz", action: #selector(setResolution(_:)), keyEquivalent: ""); mi.representedObject = m
            if let c = cur, sameLogical(m, c) { mi.state = .on }
            rs.addItem(mi)
        }
        rs.addItem(.separator())
        let installed = FileManager.default.fileExists(atPath: overridePath(id).file)
        rs.addItem(installed ? NSMenuItem(title: "Quitar modos HiDPI instalados…", action: #selector(removeHiDPI), keyEquivalent: "")
                             : NSMenuItem(title: "Instalar modos HiDPI (pide contraseña)…", action: #selector(installHiDPI), keyEquivalent: ""))
        res.submenu = rs; menu.addItem(res)

        let pm = NSMenuItem(title: "Perfil de color", action: nil, keyEquivalent: ""); let ps = NSMenu()
        let chosen = ud.string(forKey: "profilePath")
        for (name, url) in installedProfiles() where perfilClaro(url) {
            let pi = NSMenuItem(title: name, action: #selector(setProfile(_:)), keyEquivalent: ""); pi.representedObject = url
            if url.path == chosen { pi.state = .on }
            ps.addItem(pi)
        }
        ps.addItem(.separator())
        ps.addItem(NSMenuItem(title: "Restaurar el de fábrica", action: #selector(resetProfile), keyEquivalent: ""))
        pm.submenu = ps; menu.addItem(pm)

        menu.addItem(.separator())
        let lg = NSMenuItem(title: "Abrir al iniciar sesión", action: #selector(toggleLogin), keyEquivalent: "")
        lg.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(lg)
        menu.addItem(NSMenuItem(title: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for m in menu.items where m.action != nil && m.view == nil { m.target = self }
        menu.items.last?.target = NSApp
    }
}

if CommandLine.arguments.contains("--estado-login") { print(SMAppService.mainApp.status.rawValue, "(0 no registrada, 1 activa, 2 requiere aprobacion, 3 no encontrada)"); exit(0) }
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
