import Foundation
import AppKit
import CoreGraphics
import ColorSync

// Herramienta local (solo APIs de macOS): perfil de color, modos HiDPI y ganancia de la 2da pantalla. Uso: ver `ayuda`.

func screenName(_ id: CGDirectDisplayID) -> String {
    for s in NSScreen.screens {
        if let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber, n.uint32Value == id { return s.localizedName }
    }
    return "?"
}
func activeDisplays() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &n); return Array(ids.prefix(Int(n)))
}
var args = Array(CommandLine.arguments.dropFirst())
func takeOpt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...i + 1); return v
}
// Objetivo: la 1.ra pantalla externa ACTIVA, o la que se pida con --display. Si no hay externa activa NO se cae a la integrada.
let displayOpt: CGDirectDisplayID? = {
    if let v = takeOpt("--display"), let id = UInt32(v) { return id }
    return activeDisplays().first { CGDisplayIsBuiltin($0) == 0 }
}()
var display: CGDirectDisplayID {
    guard let d = displayOpt else {
        print("no hay un monitor externo activo; no se toca la pantalla integrada. Si de verdad la quieres, usa --display <id> (ver `info`).")
        exit(1)
    }
    return d
}
func displayUUID(_ id: CGDirectDisplayID) -> CFUUID {
    guard let u = CGDisplayCreateUUIDFromDisplayID(id) else { print("no existe la pantalla con displayID \(id)"); exit(1) }
    return u.takeRetainedValue()
}

struct Prof { let name: String; let url: URL }
nonisolated(unsafe) var collected: [Prof] = []
func installedProfiles() -> [Prof] {
    collected = []
    ColorSyncIterateInstalledProfiles({ d, _ in
        guard let d = d as? [String: Any] else { return true }
        var url: URL?
        for (_, v) in d { if let u = v as? URL { url = u } }
        guard let u = url, let p = ColorSyncProfileCreateWithURL(u as CFURL, nil)?.takeRetainedValue() else { return true }
        let name = (ColorSyncProfileCopyDescriptionString(p)?.takeRetainedValue() as String?) ?? u.lastPathComponent
        collected.append(Prof(name: name, url: u))
        return true
    }, nil, nil, nil)
    let carpeta = NSString(string: "~/Library/ColorSync/Profiles").expandingTildeInPath
    for f in (try? FileManager.default.contentsOfDirectory(atPath: carpeta)) ?? [] where f.lowercased().hasSuffix(".icc") || f.lowercased().hasSuffix(".icm") {
        let u = URL(fileURLWithPath: carpeta + "/" + f)
        if collected.contains(where: { $0.url.path == u.path }) { continue }
        if let p = ColorSyncProfileCreateWithURL(u as CFURL, nil)?.takeRetainedValue() {
            collected.append(Prof(name: (ColorSyncProfileCopyDescriptionString(p)?.takeRetainedValue() as String?) ?? f, url: u))
        }
    }
    return collected.sorted { $0.name.lowercased() < $1.name.lowercased() }
}

func modes(_ id: CGDirectDisplayID) -> [CGDisplayMode] {
    let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
    let all = (CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode]) ?? []
    return all.sorted { ($0.pixelWidth, $0.width, $0.refreshRate) > ($1.pixelWidth, $1.width, $1.refreshRate) }
}
func modeText(_ m: CGDisplayMode) -> String {
    let hidpi = m.pixelWidth > m.width
    return "\(m.width)x\(m.height) @\(Int(m.refreshRate))Hz  (pixeles \(m.pixelWidth)x\(m.pixelHeight))\(hidpi ? "  HiDPI" : "")"
}

func ayuda() {
    print("""
    pantalla (por defecto la 1ra externa; otra: --display <id>)
      reconectar                apaga y enciende el monitor EXTERNO por software (API privada; si no reenciende hay que reconectar el cable; nunca la integrada)
      info                      pantallas, perfil actual, modo actual
      perfiles                  perfiles de color instalados (numerados)
      perfil <n|texto>          asigna ese perfil a la pantalla (n = numero de `perfiles`, o parte del nombre)
      perfil-restaurar          vuelve al perfil de fabrica
      modos                     modos de resolucion (marca HiDPI)
      modo <n>                  cambia al modo n de `modos` (permanente)
      ganancia <factor> [gamma] ganancia por software (1.25 = +25%); se queda corriendo, Ctrl+C restaura (no usarlo con la app Pantalla abierta: se pelean)
      hidpi-plist [WxH ...]     genera el override para ofrecer HiDPI (resoluciones logicas); no instala nada
    """)
}

func cmdInfo() {
    for id in activeDisplays() {
        let cs = CGDisplayCopyColorSpace(id).name as String? ?? "?"
        let m = CGDisplayCopyDisplayMode(id).map(modeText) ?? "?"
        print("displayID \(id)\(id == displayOpt ? " <- objetivo" : ""): \(screenName(id)) | vendor \(CGDisplayVendorNumber(id)) (0x\(String(CGDisplayVendorNumber(id), radix: 16))) modelo \(CGDisplayModelNumber(id)) (0x\(String(CGDisplayModelNumber(id), radix: 16)))")
        print("   perfil: \(cs)\n   modo:   \(m)")
    }
}
func cmdPerfiles() { for (i, p) in installedProfiles().enumerated() { print("\(i): \(p.name)") } }
func cmdPerfil(_ q: String) {
    let all = installedProfiles()
    let hit: Prof? = Int(q).flatMap { $0 < all.count ? all[$0] : nil } ?? all.first { $0.name.lowercased().contains(q.lowercased()) }
    guard let p = hit else { print("no encontre perfil '\(q)'"); exit(1) }
    let info = [kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String: p.url] as CFDictionary
    let ok = ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass.takeUnretainedValue(), displayUUID(display), info)
    print(ok ? "perfil asignado: \(p.name)" : "no se pudo asignar \(p.name)")
}
func cmdRestaurar() {
    let ok = ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass.takeUnretainedValue(), displayUUID(display), nil)
    print(ok ? "perfil de fabrica restaurado" : "no se pudo restaurar")
}
func cmdModos() { for (i, m) in modes(display).enumerated() { print("\(i): \(modeText(m))") } }
func cmdModo(_ n: Int) {
    let ms = modes(display)
    guard n >= 0, n < ms.count else { print("modo fuera de rango"); exit(1) }
    var cfg: CGDisplayConfigRef?
    CGBeginDisplayConfiguration(&cfg)
    CGConfigureDisplayWithDisplayMode(cfg, display, ms[n], nil)
    let r = CGCompleteDisplayConfiguration(cfg, .permanently)
    print(r == .success ? "modo aplicado: \(modeText(ms[n]))" : "error \(r.rawValue)")
}
func cmdGanancia(_ factor: Float, _ gamma: Float) {
    let n = 256
    var t = [CGGammaValue](repeating: 0, count: n)
    for i in 0..<n { t[i] = min(1.0, powf(Float(i) / Float(n - 1), 1.0 / gamma) * factor) }
    func apply() { CGSetDisplayTransferByTable(display, UInt32(n), t, t, t) }
    apply()
    print("ganancia x\(factor) gamma \(gamma) en displayID \(display); Ctrl+C para restaurar")
    setvbuf(stdout, nil, _IOLBF, 0)
    signal(SIGINT) { _ in CGDisplayRestoreColorSyncSettings(); exit(0) }
    signal(SIGTERM) { _ in CGDisplayRestoreColorSyncSettings(); exit(0) }
    let timer = Timer(timeInterval: 2, repeats: true) { _ in apply() }
    RunLoop.main.add(timer, forMode: .common)
    RunLoop.main.run()
}
func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)] }
func cmdHidpiPlist(_ sizes: [String]) {
    let native = modes(display).filter { $0.pixelWidth == $0.width }.max { $0.pixelWidth < $1.pixelWidth }
    var logical: [(UInt32, UInt32)] = sizes.compactMap {
        let p = $0.lowercased().split(separator: "x"); guard p.count == 2, let w = UInt32(p[0]), let h = UInt32(p[1]) else { return nil }; return (w, h)
    }
    if logical.isEmpty, let nm = native { logical = [(UInt32(nm.width), UInt32(nm.height))] }
    // formato de Apple (override de la pantalla integrada): entradas de 8 bytes = tamaño de RESPALDO (ancho, alto) en big-endian
    // 8 bytes = HiDPI (tamano de respaldo); 12 bytes (ancho, alto, 1) = modo base del mismo tamano logico
    let datas = logical.map { Data(be32($0.0 * 2) + be32($0.1 * 2)) } + logical.map { Data(be32($0.0) + be32($0.1) + be32(1)) }
    let plist: [String: Any] = ["DisplayProductName": screenName(display).replacingOccurrences(of: " HiDPI", with: ""), "DisplayVendorID": Int(CGDisplayVendorNumber(display)), "DisplayProductID": Int(CGDisplayModelNumber(display)), "scale-resolutions": datas]
    let dir = FileManager.default.currentDirectoryPath
    let vid = String(CGDisplayVendorNumber(display), radix: 16), pid = String(CGDisplayModelNumber(display), radix: 16)
    let out = "\(dir)/DisplayProductID-\(pid)"
    (plist as NSDictionary).write(toFile: out, atomically: true)
    let dest = "/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-\(vid)"
    print("generado: \(out)  (logicas: \(logical.map { "\($0.0)x\($0.1)" }.joined(separator: ", ")))")
    print("para instalar (requiere admin y reiniciar o reconectar la pantalla):")
    print("sudo mkdir -p \(dest) && sudo cp '\(out)' \(dest)/DisplayProductID-\(pid)")
    print("para quitarlo: sudo rm \(dest)/DisplayProductID-\(pid)")
}

typealias CGSEnable = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
func cmdReconectar() {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSConfigureDisplayEnabled") else { print("funcion no disponible"); exit(1) }
    let fn = unsafeBitCast(sym, to: CGSEnable.self)
    if CGDisplayIsBuiltin(display) != 0 { print("reconectar no se aplica a la pantalla integrada: la apagaria."); exit(1) }
    func set(_ on: Bool) -> CGError {
        var cfg: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&cfg)
        let r = fn(cfg, display, on)
        if r != .success { CGCancelDisplayConfiguration(cfg); return r }
        return CGCompleteDisplayConfiguration(cfg, .forSession)
    }
    print("apagando displayID \(display)..."); let a = set(false)
    if a != .success { print("no se pudo apagar (\(a.rawValue)); no se toco nada"); exit(1) }
    sleep(3)
    for intento in 1...5 {
        let b = set(true)
        print("encendiendo (intento \(intento)): \(b == .success ? "ok" : "error \(b.rawValue)")")
        if b == .success { break }
        sleep(2)
    }
}

switch args.first {
case "reconectar": cmdReconectar()
case "info": cmdInfo()
case "perfiles": cmdPerfiles()
case "perfil": if args.count > 1 { cmdPerfil(args[1...].joined(separator: " ")) } else { ayuda() }
case "perfil-restaurar": cmdRestaurar()
case "modos": cmdModos()
case "modo": if args.count > 1, let n = Int(args[1]) { cmdModo(n) } else { ayuda() }
case "ganancia": if args.count > 1, let f = Float(args[1]) { cmdGanancia(f, args.count > 2 ? Float(args[2]) ?? 1 : 1) } else { ayuda() }
case "hidpi-plist": cmdHidpiPlist(Array(args.dropFirst()))
default: ayuda()
}
