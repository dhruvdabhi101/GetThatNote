// GetThatNote — native macOS shell (single file)
// AppKit + WKWebView host for app.html, providing: global hotkey, dock/menu-bar/dropdown modes,
// pin-on-top, translucency, Apple Vision OCR, AutoPaste clipboard watcher, SQLite notes DB + backups,
// antinote:// URL schemes, Apple Notes / PDF / print export, notifications & sounds, iCloud-Drive sync.
import Cocoa
import WebKit
import Vision
import Carbon.HIToolbox
import UserNotifications
import SQLite3
import CryptoKit
import UniformTypeIdentifiers

let BUNDLE_ID = "com.free.getthatnote"
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
func col(_ st: OpaquePointer?, _ i: Int32) -> String { guard let c = sqlite3_column_text(st, i) else { return "" }; return String(cString: c) }
let APP_NAME = "GetThatNote"

// MARK: - Paths
struct Paths {
    static let support: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(APP_NAME, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        for sub in ["backups", "Themes", "Extensions", "Icon"] { try? FileManager.default.createDirectory(at: u.appendingPathComponent(sub), withIntermediateDirectories: true) }
        // one-time migration from the earlier "Antinote" data folder
        let old = u.deletingLastPathComponent().appendingPathComponent("Antinote", isDirectory: true)
        if !FileManager.default.fileExists(atPath: u.appendingPathComponent("notes.sqlite").path), FileManager.default.fileExists(atPath: old.appendingPathComponent("notes.sqlite").path) {
            for f in ["notes.sqlite", "notes.sqlite-wal", "notes.sqlite-shm"] { try? FileManager.default.copyItem(at: old.appendingPathComponent(f), to: u.appendingPathComponent(f)) }
        }
        return u
    }()
    static var db: URL { support.appendingPathComponent("notes.sqlite") }
    static var backups: URL { support.appendingPathComponent("backups", isDirectory: true) }
    static var themes: URL { support.appendingPathComponent("Themes", isDirectory: true) }
    static var extensions: URL { support.appendingPathComponent("Extensions", isDirectory: true) }
    static var icon: URL { support.appendingPathComponent("Icon/icon.png") }
    static var iCloud: URL? {
        let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        let d = u.appendingPathComponent(APP_NAME, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("sync.json")
    }
}

// MARK: - JSON helpers
func jsonString(_ obj: Any) -> String {
    guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed]), let s = String(data: d, encoding: .utf8) else { return "null" }
    return s
}
func jsonParse(_ s: String) -> Any? { guard let d = s.data(using: .utf8) else { return nil }; return try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) }
func jsLiteral(_ s: String) -> String { jsonString(s) }

// MARK: - SQLite DB
final class DB {
    var db: OpaquePointer?
    init() { open() }
    func open() {
        if sqlite3_open(Paths.db.path, &db) != SQLITE_OK { NSLog("GetThatNote: cannot open db"); return }
        exec("PRAGMA journal_mode=WAL;")
        exec("CREATE TABLE IF NOT EXISTS notes(id TEXT PRIMARY KEY, content TEXT NOT NULL DEFAULT '', created INTEGER, lastModified INTEGER, position REAL, slot INTEGER DEFAULT 0, trashedAt INTEGER, locked INTEGER DEFAULT 0, expanded TEXT DEFAULT '[]');")
        exec("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);")
    }
    func close() { if db != nil { sqlite3_close(db); db = nil } }
    @discardableResult func exec(_ sql: String) -> Bool { var err: UnsafeMutablePointer<CChar>?; let r = sqlite3_exec(db, sql, nil, nil, &err); if r != SQLITE_OK { NSLog("SQL error: %@", String(cString: err!)); sqlite3_free(err); return false }; return true }
    func setMeta(_ k: String, _ v: String) {
        var st: OpaquePointer?; sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", -1, &st, nil)
        sqlite3_bind_text(st, 1, k, -1, SQLITE_TRANSIENT); sqlite3_bind_text(st, 2, v, -1, SQLITE_TRANSIENT); sqlite3_step(st); sqlite3_finalize(st)
    }
    func getMeta(_ k: String) -> String? {
        var st: OpaquePointer?; sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key=?", -1, &st, nil); sqlite3_bind_text(st, 1, k, -1, SQLITE_TRANSIENT)
        var out: String?; if sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) { out = String(cString: c) }; sqlite3_finalize(st); return out
    }
    // Save the whole DB JSON sent by the web app
    func saveAll(_ json: [String: Any]) {
        guard let notes = json["notes"] as? [[String: Any]] else { return }
        exec("BEGIN;")
        exec("DELETE FROM notes;")
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO notes(id,content,created,lastModified,position,slot,trashedAt,locked,expanded) VALUES(?,?,?,?,?,?,?,?,?)", -1, &st, nil)
        for n in notes {
            sqlite3_reset(st)
            sqlite3_bind_text(st, 1, (n["id"] as? String) ?? UUID().uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(st, 2, (n["text"] as? String) ?? "", -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(st, 3, Int64((n["created"] as? NSNumber)?.doubleValue ?? 0))
            sqlite3_bind_int64(st, 4, Int64((n["modified"] as? NSNumber)?.doubleValue ?? 0))
            sqlite3_bind_double(st, 5, (n["pos"] as? NSNumber)?.doubleValue ?? 0)
            sqlite3_bind_int(st, 6, Int32((n["slot"] as? NSNumber)?.intValue ?? 0))
            if let t = n["trashedAt"] as? NSNumber { sqlite3_bind_int64(st, 7, Int64(t.doubleValue)) } else { sqlite3_bind_null(st, 7) }
            sqlite3_bind_int(st, 8, ((n["locked"] as? Bool) ?? false) ? 1 : 0)
            sqlite3_bind_text(st, 9, jsonString(n["expanded"] ?? [Any]()), -1, SQLITE_TRANSIENT)
            sqlite3_step(st)
        }
        sqlite3_finalize(st)
        for k in ["tombstones", "syncBase", "curId", "curSlot", "view"] { if let v = json[k] { setMeta(k, jsonString(v)) } }
        exec("COMMIT;")
    }
    func loadAll() -> [String: Any] {
        var notes: [[String: Any]] = []
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT id,content,created,lastModified,position,slot,trashedAt,locked,expanded FROM notes", -1, &st, nil)
        while sqlite3_step(st) == SQLITE_ROW {
            var n: [String: Any] = [:]
            n["id"] = col(st, 0); n["text"] = col(st, 1)
            n["created"] = sqlite3_column_int64(st, 2); n["modified"] = sqlite3_column_int64(st, 3); n["pos"] = sqlite3_column_double(st, 4); n["slot"] = sqlite3_column_int(st, 5)
            if sqlite3_column_type(st, 6) != SQLITE_NULL { n["trashedAt"] = sqlite3_column_int64(st, 6) } else { n["trashedAt"] = NSNull() }
            n["locked"] = sqlite3_column_int(st, 7) != 0
            n["expanded"] = jsonParse(col(st, 8)) ?? [Any]()
            notes.append(n)
        }
        sqlite3_finalize(st)
        var out: [String: Any] = ["notes": notes]
        for k in ["tombstones", "syncBase", "curId", "curSlot", "view"] { if let s = getMeta(k), let v = jsonParse(s) { out[k] = v } }
        return out
    }
    // Backups
    func backup(keep: Int) -> URL? {
        exec("PRAGMA wal_checkpoint(TRUNCATE);")
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let dest = Paths.backups.appendingPathComponent("notes-\(f.string(from: Date())).sqlite")
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.copyItem(at: Paths.db, to: dest) } catch { NSLog("backup failed: \(error)"); return nil }
        let list = listBackups()
        if list.count > keep { for old in list.dropFirst(keep) { try? FileManager.default.removeItem(at: old) } }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastBackup")
        return dest
    }
    func listBackups() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: Paths.backups, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "sqlite" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
    func restore(_ url: URL) -> Bool {
        _ = backup(keep: 100)
        close()
        for ext in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: Paths.db.path + ext) }
        do { try FileManager.default.copyItem(at: url, to: Paths.db) } catch { NSLog("restore failed: \(error)"); open(); return false }
        open(); return true
    }
}

// MARK: - Crypto for sync file
enum SyncCrypto {
    static func key(_ pass: String) -> SymmetricKey { SymmetricKey(data: SHA256.hash(data: Data(("antinote-sync:" + pass).utf8))) }
    static func encrypt(_ s: String, pass: String) -> String? {
        guard let box = try? AES.GCM.seal(Data(s.utf8), using: key(pass)), let c = box.combined else { return nil }
        return "ANTINOTE-ENC1:" + c.base64EncodedString()
    }
    static func decrypt(_ s: String, pass: String) -> String? {
        guard s.hasPrefix("ANTINOTE-ENC1:"), let d = Data(base64Encoded: String(s.dropFirst(14))), let box = try? AES.GCM.SealedBox(combined: d), let p = try? AES.GCM.open(box, using: key(pass)) else { return nil }
        return String(data: p, encoding: .utf8)
    }
}

// MARK: - Icon drawing
func drawIcon(size: CGFloat, classic: Bool) -> NSImage {
    // GetThatNote icon: a paper note with a folded corner, three text lines and a blue accent dot
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let s = size, m = s * 0.08
    let rect = NSRect(x: m, y: m, width: s - 2 * m, height: s - 2 * m)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    let g: NSGradient
    if classic { g = NSGradient(starting: NSColor(calibratedRed: 1.0, green: 0.93, blue: 0.55, alpha: 1), ending: NSColor(calibratedRed: 0.98, green: 0.82, blue: 0.30, alpha: 1))! }
    else { g = NSGradient(starting: NSColor(calibratedRed: 0.99, green: 0.98, blue: 0.95, alpha: 1), ending: NSColor(calibratedRed: 0.91, green: 0.89, blue: 0.84, alpha: 1))! }
    g.draw(in: path, angle: -90)
    NSColor.black.withAlphaComponent(0.12).setStroke(); path.lineWidth = s * 0.012; path.stroke()
    // folded corner (dog-ear)
    let fold = s * 0.24
    let ear = NSBezierPath(); ear.move(to: NSPoint(x: rect.maxX - fold, y: rect.maxY)); ear.line(to: NSPoint(x: rect.maxX, y: rect.maxY - fold)); ear.line(to: NSPoint(x: rect.maxX - fold, y: rect.maxY - fold)); ear.close()
    (classic ? NSColor(calibratedRed: 0.86, green: 0.66, blue: 0.15, alpha: 1) : NSColor(calibratedRed: 0.80, green: 0.78, blue: 0.72, alpha: 1)).setFill(); ear.fill()
    let cut = NSBezierPath(); cut.move(to: NSPoint(x: rect.maxX - fold, y: rect.maxY)); cut.line(to: NSPoint(x: rect.maxX, y: rect.maxY)); cut.line(to: NSPoint(x: rect.maxX, y: rect.maxY - fold)); cut.close()
    NSColor.clear.setFill(); cut.fill(); // keep corner shape
    // text lines
    let ink = classic ? NSColor(calibratedRed: 0.35, green: 0.25, blue: 0.05, alpha: 1) : NSColor(calibratedRed: 0.17, green: 0.17, blue: 0.16, alpha: 1)
    let widths: [CGFloat] = [0.44, 0.50, 0.32]
    for (i, w) in widths.enumerated() {
        let y = rect.minY + s * (0.60 - CGFloat(i) * 0.15)
        let bar = NSBezierPath(roundedRect: NSRect(x: rect.minX + s * 0.27, y: y, width: s * w, height: s * 0.065), xRadius: s * 0.03, yRadius: s * 0.03)
        ink.setFill(); bar.fill()
    }
    // accent dot before the first line
    NSColor(calibratedRed: 0.21, green: 0.47, blue: 0.96, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: rect.minX + s * 0.14, y: rect.minY + s * 0.585, width: s * 0.095, height: s * 0.095)).fill()
    img.unlockFocus()
    return img
}
func writePNG(_ img: NSImage, to url: URL) {
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: url)
}

// MARK: - Key code map (JS KeyboardEvent.code -> Carbon virtual key code)
let KEYCODES: [String: UInt32] = ["KeyA":0,"KeyS":1,"KeyD":2,"KeyF":3,"KeyH":4,"KeyG":5,"KeyZ":6,"KeyX":7,"KeyC":8,"KeyV":9,"KeyB":11,"KeyQ":12,"KeyW":13,"KeyE":14,"KeyR":15,"KeyY":16,"KeyT":17,"Digit1":18,"Digit2":19,"Digit3":20,"Digit4":21,"Digit6":22,"Digit5":23,"Equal":24,"Digit9":25,"Digit7":26,"Minus":27,"Digit8":28,"Digit0":29,"BracketRight":30,"KeyO":31,"KeyU":32,"BracketLeft":33,"KeyI":34,"KeyP":35,"Enter":36,"KeyL":37,"KeyJ":38,"Quote":39,"KeyK":40,"Semicolon":41,"Backslash":42,"Comma":43,"Slash":44,"KeyN":45,"KeyM":46,"Period":47,"Tab":48,"Space":49,"Backquote":50,"Backspace":51,"Escape":53,"F1":122,"F2":120,"F3":99,"F4":118,"F5":96,"F6":97,"F7":98,"F8":100,"F9":101,"F10":109,"F11":103,"F12":111,"ArrowLeft":123,"ArrowRight":124,"ArrowDown":125,"ArrowUp":126]

// MARK: - Windows
final class NotePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func sendEvent(_ event: NSEvent) { if event.type == .leftMouseDown && event.clickCount == 2 && frame.height - event.locationInWindow.y < 44 { return }; super.sendEvent(event) }
    override func zoom(_ sender: Any?) { }
}
final class NoteWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func sendEvent(_ event: NSEvent) { if event.type == .leftMouseDown && event.clickCount == 2 && frame.height - event.locationInWindow.y < 44 { return }; super.sendEvent(event) }
    override func zoom(_ sender: Any?) { }
}

// MARK: - App delegate
@main
final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate, UNUserNotificationCenterDelegate {
    static var shared: AppDelegate!
    var window: NSWindow!
    var webView: WKWebView!
    var effectView: NSVisualEffectView?
    var statusItem: NSStatusItem?
    let db = DB()
    var settings: [String: Any] = [:]
    var dockMode = "dock"
    var pinned = false
    var hotKeyRef: EventHotKeyRef?
    var clipTimer: Timer?
    var clipCount: Int = NSPasteboard.general.changeCount
    var backupTimer: Timer?
    var syncTimer: Timer?
    var syncMTime: Date?
    var pendingSyncWrite: DispatchWorkItem?
    var booted = false
    var printWebView: WKWebView?
    var alertWindow: NSWindow?
    var isShowingDropdown = false

    // MARK: lifecycle
    static func main() {
        // CLI helper used by build.sh: --make-icon <dir>
        let args = CommandLine.arguments
        if args.count >= 3 && args[1] == "--make-icon" {
            let dir = URL(fileURLWithPath: args[2])
            for sz in [16, 32, 64, 128, 256, 512, 1024] {
                writePNG(drawIcon(size: CGFloat(sz), classic: false), to: dir.appendingPathComponent("icon_\(sz).png"))
            }
            exit(0)
        }
        let app = NSApplication.shared
        let d = AppDelegate(); AppDelegate.shared = d; app.delegate = d
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadSettings()
        dockMode = (settings["dockMode"] as? String) ?? "dock"
        NSApp.setActivationPolicy(dockMode == "dock" || dockMode == "both" ? .regular : .accessory)
        buildMenu()
        buildWindow()
        if dockMode != "dock" && dockMode != "nothing" { buildStatusItem() }
        applyAppIcon()
        registerHotkey()
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURLEvent(_:with:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        NSApp.addObserver(self, forKeyPath: "effectiveAppearance", options: [.new], context: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidResignKey(_:)), name: NSWindow.didResignKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidResignActive), name: NSApplication.didResignActiveNotification, object: nil)
        scheduleBackups()
        setupSync()
        // Escape never reaches the web content through WKWebView's key handling; forward it ourselves.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let s = self, ev.keyCode == 53, ev.window == s.window else { return ev }
            s.eval("(document.activeElement||document.body).dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',code:'Escape',keyCode:27,bubbles:true,cancelable:true}))")
            return nil
        }
        if dockMode != "menubar" { showWindow() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationWillTerminate(_ notification: Notification) {
        eval("AN.onTimerPauseOnQuit&&AN.onTimerPauseOnQuit(); AN.onQuit&&AN.onQuit();")
        // give the web view a moment to flush saves
        let until = Date().addingTimeInterval(0.35)
        while Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        if backupDue() { _ = db.backup(keep: backupsKeep()) }
        db.close()
    }
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "effectiveAppearance" { eval("AN.onAppearance&&AN.onAppearance(\(isDark()))") }
    }
    func isDark() -> Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    // MARK: settings
    func loadSettings() {
        if UserDefaults.standard.string(forKey: "settings") == nil, let legacy = UserDefaults(suiteName: "com.free.antinote")?.string(forKey: "settings") { UserDefaults.standard.set(legacy, forKey: "settings") }
        if let s = UserDefaults.standard.string(forKey: "settings"), let j = jsonParse(s) as? [String: Any] { settings = j }
        pinned = (settings["restorePin"] as? Bool ?? true) && (settings["pinned"] as? Bool ?? false)
    }
    func bool(_ k: String, _ def: Bool = false) -> Bool { (settings[k] as? Bool) ?? def }
    func backupsKeep() -> Int { (settings["backupsKeep"] as? NSNumber)?.intValue ?? 10 }
    func backupIntervalSeconds() -> TimeInterval? {
        let v = (settings["backupInterval"] as? String) ?? "1d"
        let m: [String: TimeInterval] = ["10m": 600, "30m": 1800, "1h": 3600, "3h": 10800, "12h": 43200, "1d": 86400, "3d": 259200, "1w": 604800, "1mo": 2592000]
        return m[v]
    }
    func backupDue() -> Bool { guard let iv = backupIntervalSeconds() else { return false }; let last = UserDefaults.standard.double(forKey: "lastBackup"); return Date().timeIntervalSince1970 - last >= iv }
    func scheduleBackups() {
        backupTimer?.invalidate()
        if backupDue() { _ = db.backup(keep: backupsKeep()) }
        backupTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in guard let s = self else { return }; if s.backupDue() { _ = s.db.backup(keep: s.backupsKeep()) } }
    }

    // MARK: window
    func buildWindow() {
        let frame = NSRect(x: 0, y: 0, width: 460, height: 600)
        if dockMode == "menubar" {
            let w = (settings["dropdownW"] as? NSNumber)?.doubleValue ?? 420, h = (settings["dropdownH"] as? NSNumber)?.doubleValue ?? 520
            let p = NotePanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h), styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
            p.level = .popUpMenu; p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]; p.isFloatingPanel = true; p.hidesOnDeactivate = false
            p.hasShadow = true; p.isOpaque = false; p.backgroundColor = .clear
            window = p
        } else if dockMode == "pseudo" || dockMode == "both" || dockMode == "nothing" {
            let p = NotePanel(contentRect: frame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .floating; p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .moveToActiveSpace]; p.isFloatingPanel = true; p.hidesOnDeactivate = false; p.becomesKeyOnlyIfNeeded = false
            window = p
        } else {
            window = NoteWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        }
        window.title = APP_NAME
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(b)?.isHidden = true }
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 280, height: 240)
        _ = window.setFrameAutosaveName(dockMode == "menubar" ? "" : "GetThatNoteMain")
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(calibratedRed: 0.976, green: 0.973, blue: 0.957, alpha: 1)
        if dockMode != "menubar" && window.frame.origin == .zero { window.center() }

        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "native")
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: window.contentView!.bounds, configuration: cfg)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        window.contentView?.addSubview(webView)
        if let url = Bundle.main.url(forResource: "app", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.loadHTMLString("<h2 style='font-family:-apple-system;padding:40px'>app.html missing from bundle</h2>", baseURL: nil)
        }
        applyPin()
    }
    func applyTranslucency(on: Bool, bg: String) {
        guard let cv = window.contentView else { return }
        if on {
            if effectView == nil {
                let ev = NSVisualEffectView(frame: cv.bounds); ev.autoresizingMask = [.width, .height]; ev.blendingMode = .behindWindow; ev.state = .active; ev.material = .hudWindow
                cv.addSubview(ev, positioned: .below, relativeTo: webView); effectView = ev
            }
            effectView?.material = isDark() ? .hudWindow : .popover
            window.isOpaque = false; window.backgroundColor = .clear
        } else {
            effectView?.removeFromSuperview(); effectView = nil
            window.isOpaque = dockMode != "menubar"; window.backgroundColor = NSColor(hex: bg) ?? .windowBackgroundColor
            if dockMode == "menubar" { window.backgroundColor = .clear }
        }
        window.invalidateShadow()
    }
    func applyPin() {
        guard let w = window else { return }
        if dockMode == "menubar" { return }
        if dockMode == "dock" { w.level = pinned ? .floating : .normal }
        else { w.level = pinned ? .floating : .floating }
        applyFollowSpace()
    }
    // "Open on your current Space & screen": the window joins every Space while open,
    // and summoning it pulls it to the display the pointer is on.
    func applyFollowSpace() {
        guard let w = window else { return }
        if bool("followSpace", true) || pinned || dockMode != "dock" { w.collectionBehavior.insert(.canJoinAllSpaces) }
        else { w.collectionBehavior.remove(.canJoinAllSpaces) }
    }
    func moveToActiveScreen() {
        guard bool("followSpace", true), dockMode != "menubar", window != nil else { return }
        let mouse = NSEvent.mouseLocation
        guard let target = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        if let cur = window.screen, cur == target, window.isVisible { return }
        var f = window.frame
        let tv = target.visibleFrame
        if let cur = window.screen, cur != target {
            let cv = cur.visibleFrame
            let rx = cv.width - f.width > 0 ? (f.minX - cv.minX) / (cv.width - f.width) : 0.5
            let ry = cv.height - f.height > 0 ? (f.minY - cv.minY) / (cv.height - f.height) : 0.5
            f.origin.x = tv.minX + max(0, tv.width - f.width) * min(max(rx, 0), 1)
            f.origin.y = tv.minY + max(0, tv.height - f.height) * min(max(ry, 0), 1)
            window.setFrame(f, display: false)
        } else if window.screen == nil {
            f.origin.x = tv.midX - f.width / 2; f.origin.y = tv.midY - f.height / 2
            window.setFrame(f, display: false)
        }
    }
    func showWindow() {
        moveToActiveScreen()
        if dockMode == "menubar" { positionDropdown() }
        window.makeKeyAndOrderFront(nil)
        if dockMode == "dock" || dockMode == "both" { NSApp.activate(ignoringOtherApps: true) } else { NSApp.activate(ignoringOtherApps: true) }
        window.makeFirstResponder(webView)
        eval("AN.onShow&&AN.onShow()")
    }
    func hideWindow() { window.orderOut(nil); eval("AN.onHide&&AN.onHide()") }
    func toggleWindow() { if window.isVisible && (window.isKeyWindow || dockMode == "menubar") { hideWindow() } else { showWindow() } }
    func positionDropdown() {
        guard let btn = statusItem?.button, let bw = btn.window else { window.center(); return }
        let r = bw.convertToScreen(btn.bounds)
        let size = window.frame.size
        var x = r.midX - size.width / 2, y = r.minY - size.height - 4
        if let scr = bw.screen ?? NSScreen.main { x = max(scr.visibleFrame.minX + 6, min(x, scr.visibleFrame.maxX - size.width - 6)) }
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
    @objc func windowDidResignKey(_ n: Notification) {
        guard (n.object as? NSWindow) == window else { return }
        eval("AN.onBlur&&AN.onBlur()")
        if dockMode == "menubar" { hideWindow(); return }
        if bool("hideOnBlur") && !pinned { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in guard let s = self, !s.window.isKeyWindow else { return }; s.hideWindow() } }
    }
    @objc func windowDidBecomeKey(_ n: Notification) { guard (n.object as? NSWindow) == window else { return }; eval("AN.onFocus&&AN.onFocus()") }
    @objc func appDidResignActive() { if backupDue() { _ = db.backup(keep: backupsKeep()) } }

    // MARK: status item
    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem?.button {
            b.image = NSImage(systemSymbolName: "triangle", accessibilityDescription: APP_NAME) ?? drawIcon(size: 18, classic: false)
            b.image?.isTemplate = true
            b.imagePosition = .imageLeading
            b.target = self; b.action = #selector(statusClicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }
    @objc func statusClicked(_ sender: Any?) {
        if let ev = NSApp.currentEvent, ev.type == .rightMouseUp {
            let m = NSMenu()
            m.addItem(withTitle: window.isVisible ? "Hide GetThatNote" : "Show GetThatNote", action: #selector(menuToggle), keyEquivalent: "")
            m.addItem(withTitle: "New Note", action: #selector(menuNewNote), keyEquivalent: "")
            m.addItem(withTitle: pinned ? "Unpin" : "Pin to Top", action: #selector(menuPin), keyEquivalent: "")
            m.addItem(NSMenuItem.separator())
            m.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: "")
            m.addItem(withTitle: "Quit GetThatNote", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
            statusItem?.menu = m; statusItem?.button?.performClick(nil); statusItem?.menu = nil
            return
        }
        toggleWindow()
    }
    @objc func menuToggle() { toggleWindow() }
    @objc func menuNewNote() { showWindow(); eval("App.action('newNote')") }
    @objc func menuPin() { setPinned(!pinned) }
    @objc func menuSettings() { showWindow(); eval("App.action('settings')") }
    func setPinned(_ on: Bool) { pinned = on; applyPin(); eval("AN.onPinned&&AN.onPinned(\(on))") }

    // MARK: hotkey
    func registerHotkey() {
        if let r = hotKeyRef { UnregisterEventHotKey(r); hotKeyRef = nil }
        let hk = (settings["hotkey"] as? [String: Any]) ?? ["code": "KeyA", "alt": true]
        guard let code = KEYCODES[(hk["code"] as? String) ?? "KeyA"] else { return }
        var mods: UInt32 = 0
        if hk["alt"] as? Bool == true { mods |= UInt32(optionKey) }; if hk["meta"] as? Bool == true { mods |= UInt32(cmdKey) }; if hk["shift"] as? Bool == true { mods |= UInt32(shiftKey) }; if hk["ctrl"] as? Bool == true { mods |= UInt32(controlKey) }
        struct Once { static var installed = false }
        if !Once.installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in DispatchQueue.main.async { AppDelegate.shared.hotkeyPressed() }; return noErr }, 1, &spec, nil, nil)
            Once.installed = true
        }
        let id = EventHotKeyID(signature: 0x414E5448, id: 1)
        RegisterEventHotKey(code, mods, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
    func hotkeyPressed() { if window.isVisible && window.isKeyWindow { hideWindow() } else { showWindow() } }

    // MARK: main menu
    func mi(_ title: String, _ action: String, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: key)
        it.keyEquivalentModifierMask = mods; it.representedObject = action; it.target = self; return it
    }
    @objc func menuAction(_ sender: NSMenuItem) { if let a = sender.representedObject as? String { if a == "quit" { NSApp.terminate(nil) } else { eval("AN.onMenu(\(jsLiteral(a)))") } } }
    func buildMenu() {
        let main = NSMenu()
        let appM = NSMenu(title: APP_NAME)
        appM.addItem(mi("About GetThatNote", "settings")); appM.addItem(NSMenuItem.separator())
        appM.addItem(mi("Settings…", "settings", ","))
        appM.addItem(NSMenuItem.separator())
        appM.addItem(withTitle: "Hide GetThatNote", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appM.addItem(withTitle: "Quit GetThatNote", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = appM; main.addItem(appItem)

        let file = NSMenu(title: "File")
        file.addItem(mi("New Note", "newNote", "n")); file.addItem(mi("Close Window", "closeWindow", "w")); file.addItem(mi("Hide / Show GetThatNote", "hideShow", "o"))
        file.addItem(NSMenuItem.separator()); file.addItem(mi("Pin / Unpin to Top", "pin", "p"))
        file.addItem(mi("Swap Ephemeral vs. Slotted", "swapSlotted", "t")); file.addItem(mi("Toggle Split Screen", "splitScreen", "t", [.command, .shift]))
        file.addItem(NSMenuItem.separator()); file.addItem(mi("Quick Export", "quickExport", "s")); file.addItem(mi("Export Note…", "exportMenu")); file.addItem(mi("Print…", "print", "p", [.command, .shift]))
        file.addItem(NSMenuItem.separator()); file.addItem(mi("Recover Notes from The Void…", "void", "d", [.command, .shift])); file.addItem(mi("Search Notes…", "search", "f"))
        let fileItem = NSMenuItem(); fileItem.submenu = file; main.addItem(fileItem)

        let edit = NSMenu(title: "Edit")
        edit.addItem(mi("Undo", "undo", "z")); edit.addItem(mi("Redo", "redo", "z", [.command, .shift])); edit.addItem(NSMenuItem.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"); edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"); edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(mi("Paste As-Is", "pasteAsIs", "v", [.command, .shift])); edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(NSMenuItem.separator()); edit.addItem(mi("Find and Replace…", "findReplace", "f", [.command, .shift]))
        let editItem = NSMenuItem(); editItem.submenu = edit; main.addItem(editItem)

        let note = NSMenu(title: "Note")
        note.addItem(mi("Previous Note", "prevNote", "[")); note.addItem(mi("Next Note", "nextNote", "]")); note.addItem(mi("Jump to Front", "jumpFront", "1")); note.addItem(mi("Promote Note", "promote", "1", [.command, .shift]))
        note.addItem(NSMenuItem.separator()); note.addItem(mi("Delete Note", "deleteNote", "d")); note.addItem(mi("Lock / Unlock Note", "lock", "l")); note.addItem(mi("Timer Full Screen", "timerFull", "m", [.command, .shift]))
        let noteItem = NSMenuItem(); noteItem.submenu = note; main.addItem(noteItem)

        let fmt = NSMenu(title: "Format")
        fmt.addItem(mi("Bold", "bold", "b")); fmt.addItem(mi("Italic", "italic", "i")); fmt.addItem(mi("Underline", "underline", "u")); fmt.addItem(mi("Strikethrough", "strike", "x", [.command, .shift])); fmt.addItem(mi("Cycle Heading", "heading", "h", [.command, .shift])); fmt.addItem(mi("Toggle Comment", "comment", "/"))
        fmt.addItem(NSMenuItem.separator()); fmt.addItem(mi("Move Line Up", "moveUp", String(UnicodeScalar(NSUpArrowFunctionKey)!), [.option])); fmt.addItem(mi("Move Line Down", "moveDown", String(UnicodeScalar(NSDownArrowFunctionKey)!), [.option]))
        fmt.addItem(NSMenuItem.separator()); fmt.addItem(mi("Bigger Text", "textUp", "=")); fmt.addItem(mi("Smaller Text", "textDown", "-"))
        let fmtItem = NSMenuItem(); fmtItem.submenu = fmt; main.addItem(fmtItem)

        let win = NSMenu(title: "Window"); win.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m"); 
        let winItem = NSMenuItem(); winItem.submenu = win; main.addItem(winItem); NSApp.windowsMenu = win
        NSApp.mainMenu = main
    }

    // MARK: JS bridge
    func eval(_ js: String) { DispatchQueue.main.async { self.webView?.evaluateJavaScript("(function(){ if(!window.AN||!window.App) return; try{ \(js) }catch(e){ console.error(e); throw e; } })()") { _, e in if let e = e { NSLog("JS error: \(e.localizedDescription) in \(js.prefix(80))") } } } }
    func reply(_ id: String, _ obj: Any) { eval("AN.reply(\(jsLiteral(id)),\(jsonString(obj)))") }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let cmd = m["cmd"] as? String else { return }
        let id = (m["id"] as? String) ?? ""
        if cmd == "log" { NSLog("%@", (m["msg"] as? String) ?? "") }
        switch cmd {
        case "log": break
        case "ready": boot()
        case "save":
            if let s = m["json"] as? String, let j = jsonParse(s) as? [String: Any] { db.saveAll(j) }
            if (m["sync"] as? Bool) == true { scheduleSyncWrite() }
        case "saveSettings":
            if let s = m["json"] as? String { UserDefaults.standard.set(s, forKey: "settings"); if let j = jsonParse(s) as? [String: Any] { settings = j } }
        case "settings":
            if let s = m["json"] as? String, let j = jsonParse(s) as? [String: Any] { settings = j; UserDefaults.standard.set(s, forKey: "settings"); registerHotkey(); scheduleBackups(); setupSync(); applyFollowSpace() }
        case "appearance":
            applyTranslucency(on: (m["translucent"] as? Bool) ?? false, bg: (m["bg"] as? String) ?? "#f9f8f4")
        case "fetch": doFetch(id: id, m)
        case "openURL": if let u = m["url"] as? String, let url = URL(string: u) { NSWorkspace.shared.open(url) }
        case "copy": if let t = m["text"] as? String { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string); clipCount = NSPasteboard.general.changeCount }
        case "readClipboard": reply(id, ["text": NSPasteboard.general.string(forType: .string) ?? ""])
        case "watchClipboard": watchClipboard((m["on"] as? Bool) ?? false)
        case "ocr": if let b = m["data"] as? String { ocr(id: id, base64: b) }
        case "notify": notify((m["title"] as? String) ?? APP_NAME, (m["body"] as? String) ?? "")
        case "playSound": playSound(volume: Float((m["volume"] as? NSNumber)?.doubleValue ?? 0.7))
        case "saveFile": saveFile(m)
        case "print": if let h = m["html"] as? String { printHTML(h, pdfName: nil) }
        case "pdf": if let h = m["html"] as? String { printHTML(h, pdfName: (m["name"] as? String) ?? "Note.pdf") }
        case "appleNotes": appleNotes(title: (m["title"] as? String) ?? "GetThatNote", body: (m["body"] as? String) ?? "")
        case "openFolder":
            let which = (m["which"] as? String) ?? "data"
            let u = which == "themes" ? Paths.themes : which == "extensions" ? Paths.extensions : Paths.support
            NSWorkspace.shared.activateFileViewerSelecting([u])
        case "reloadThemes": eval("AN.onThemes(\(jsonString(loadThemes())))")
        case "reloadExtensions": eval("AN.onExtensions(\(jsonString(loadExtensions())))")
        case "chooseIcon": chooseIcon()
        case "appIcon": applyAppIcon(mode: (m["mode"] as? String))
        case "setPinned": setPinned((m["on"] as? Bool) ?? false)
        case "closeWindow": hideWindow()
        case "hideShow": toggleWindow()
        case "hotkey": hotkeyPressed()
        case "dragWindow": if let ev = NSApp.currentEvent { window.performDrag(with: ev) }
        case "menubarTimer": statusItem?.button?.title = ((m["text"] as? String) ?? "").isEmpty ? "" : " " + ((m["text"] as? String) ?? "")
        case "alertShow": showFullscreenAlert(title: (m["title"] as? String) ?? "", body: (m["body"] as? String) ?? "")
        case "backupNow": _ = db.backup(keep: backupsKeep())
        case "listBackups": eval("AN.onBackups(\(jsonString(db.listBackups().map { ["name": $0.lastPathComponent] })))")
        case "restoreBackup":
            if let n = m["name"] as? String { let u = Paths.backups.appendingPathComponent(n); if db.restore(u) { relaunch() } }
        case "reloadDB": eval("AN.boot(\(jsonString(bootPayload())))")
        default: NSLog("unknown cmd \(cmd)")
        }
    }
    func bootPayload() -> [String: Any] {
        var sj: Any = NSNull(); if let s = UserDefaults.standard.string(forKey: "settings"), let j = jsonParse(s) { sj = j }
        return ["settings": sj, "db": db.loadAll(), "dark": isDark(), "themes": loadThemes(), "extensions": loadExtensions(), "pinned": pinned, "version": "2.0-free"]
    }
    func boot() { booted = true; eval("AN.boot(\(jsonString(bootPayload())))"); window.makeFirstResponder(webView); DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.checkSyncFile(force: true) } }
    func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/bin/sh"); task.arguments = ["-c", "sleep 1; /usr/bin/open -n \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: fetch (network for currency rates / AI / extensions)
    func doFetch(id: String, _ m: [String: Any]) {
        guard let u = m["url"] as? String, let url = URL(string: u) else { reply(id, ["error": "bad url"]); return }
        var req = URLRequest(url: url); req.httpMethod = (m["method"] as? String) ?? "GET"; req.timeoutInterval = 60
        if let h = m["headers"] as? [String: String] { for (k, v) in h { req.setValue(v, forHTTPHeaderField: k) } }
        if let b = m["body"] as? String, !b.isEmpty { req.httpBody = b.data(using: .utf8) }
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { self.reply(id, ["error": err.localizedDescription]); return }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            self.reply(id, ["status": status, "body": String(data: data ?? Data(), encoding: .utf8) ?? ""])
        }.resume()
    }

    // MARK: clipboard watcher (AutoPaste)
    func watchClipboard(_ on: Bool) {
        clipTimer?.invalidate(); clipTimer = nil
        guard on else { return }
        clipCount = NSPasteboard.general.changeCount
        clipTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let s = self else { return }
            let c = NSPasteboard.general.changeCount
            if c != s.clipCount { s.clipCount = c; if let t = NSPasteboard.general.string(forType: .string) { s.eval("AN.onClipboard(\(jsLiteral(t)))") } }
        }
    }

    // MARK: OCR
    func ocr(id: String, base64: String) {
        guard let data = Data(base64Encoded: base64), let img = NSImage(data: data), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { reply(id, ["text": ""]); return }
        let req = VNRecognizeTextRequest { r, _ in
            let lines = (r.results as? [VNRecognizedTextObservation] ?? []).compactMap { $0.topCandidates(1).first?.string }
            self.reply(id, ["text": lines.joined(separator: "\n")])
        }
        req.recognitionLevel = .accurate; req.usesLanguageCorrection = true
        if #available(macOS 13, *) { req.automaticallyDetectsLanguage = true }
        DispatchQueue.global(qos: .userInitiated).async { try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req]) }
    }

    // MARK: notifications, sounds, alerts
    func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent(); c.title = title; c.body = body; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)) { e in if let e = e { NSLog("notify: \(e)") } }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .sound]) }
    func playSound(volume: Float) { if let s = NSSound(named: "Glass") { s.volume = volume; s.play() } else { NSSound.beep() } }
    func showFullscreenAlert(title: String, body: String) {
        alertWindow?.orderOut(nil)
        guard let scr = NSScreen.main else { return }
        let w = NSWindow(contentRect: scr.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = .screenSaver; w.backgroundColor = NSColor(calibratedRed: 0.21, green: 0.47, blue: 0.96, alpha: 0.96); w.isOpaque = false; w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let big = NSTextField(labelWithString: body); big.font = NSFont.monospacedDigitSystemFont(ofSize: 140, weight: .bold); big.textColor = .white; big.alignment = .center
        let sub = NSTextField(labelWithString: title); sub.font = NSFont.systemFont(ofSize: 34, weight: .medium); sub.textColor = .white; sub.alignment = .center
        let hint = NSTextField(labelWithString: "click anywhere to dismiss"); hint.font = NSFont.systemFont(ofSize: 16); hint.textColor = NSColor.white.withAlphaComponent(0.8); hint.alignment = .center
        let stack = NSStackView(views: [big, sub, hint]); stack.orientation = .vertical; stack.spacing = 18; stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        w.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: w.contentView!.centerXAnchor), stack.centerYAnchor.constraint(equalTo: w.contentView!.centerYAnchor)])
        let click = NSClickGestureRecognizer(target: self, action: #selector(dismissAlert)); w.contentView?.addGestureRecognizer(click)
        w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); alertWindow = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in if self?.alertWindow == w { self?.dismissAlert() } }
    }
    @objc func dismissAlert() { alertWindow?.orderOut(nil); alertWindow = nil; eval("document.getElementById('talert').classList.remove('on')") }

    // MARK: files / export
    func saveFile(_ m: [String: Any]) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = (m["name"] as? String) ?? "note.txt"; panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { r in
            guard r == .OK, let url = panel.url else { return }
            if let b64 = m["base64"] as? String, let d = Data(base64Encoded: b64) { try? d.write(to: url) }
            else if let c = m["content"] as? String { try? c.write(to: url, atomically: true, encoding: .utf8) }
        }
    }
    func printHTML(_ html: String, pdfName: String?) {
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        printWebView = wv
        wv.loadHTMLString(html, baseURL: nil)
        let info = NSPrintInfo.shared; info.topMargin = 40; info.bottomMargin = 40; info.leftMargin = 40; info.rightMargin = 40
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let s = self else { return }
            if let name = pdfName {
                let cfg = WKPDFConfiguration()
                wv.createPDF(configuration: cfg) { res in
                    switch res {
                    case .success(let data):
                        let panel = NSSavePanel(); panel.nameFieldStringValue = name
                        panel.beginSheetModal(for: s.window) { r in if r == .OK, let u = panel.url { try? data.write(to: u) } }
                    case .failure(let e): NSLog("pdf: \(e)")
                    }
                    s.printWebView = nil
                }
            } else {
                let op = wv.printOperation(with: info)
                op.showsPrintPanel = true; op.showsProgressPanel = true
                op.view?.frame = NSRect(x: 0, y: 0, width: 612, height: 792)
                op.runModal(for: s.window, delegate: nil, didRun: nil, contextInfo: nil)
            }
        }
    }
    func appleNotes(title: String, body: String) {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        func html(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        let htmlBody = "<div>" + body.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? "<br>" : html(String($0)) }.joined(separator: "<br>") + "</div>"
        let script = "tell application \"Notes\"\n activate\n tell default account\n make new note at folder \"Notes\" with properties {name:\"\(esc(title))\", body:\"\(esc(htmlBody))\"}\n end tell\nend tell"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let e = err { NSLog("Apple Notes export: \(e)"); self.eval("toast('Apple Notes export failed — allow GetThatNote to control Notes in System Settings > Privacy > Automation')") }
    }
    func chooseIcon() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.png, .jpeg, .heic, .image]; p.allowsMultipleSelection = false
        p.beginSheetModal(for: window) { r in
            guard r == .OK, let u = p.url, let img = NSImage(contentsOf: u) else { return }
            writePNG(img, to: Paths.icon); self.applyAppIcon(mode: "custom")
        }
    }
    func applyAppIcon(mode: String? = nil) {
        let m = mode ?? (settings["appIcon"] as? String) ?? "default"
        if m == "custom", let img = NSImage(contentsOf: Paths.icon) { NSApp.applicationIconImage = img }
        else if m == "classic" { NSApp.applicationIconImage = drawIcon(size: 512, classic: true) }
        else { NSApp.applicationIconImage = nil }
    }

    // MARK: themes & extensions folders
    func loadThemes() -> [[String: Any]] {
        let items = (try? FileManager.default.contentsOfDirectory(at: Paths.themes, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "json" }.compactMap { u in guard let s = try? String(contentsOf: u, encoding: .utf8) else { return nil }; return ["name": u.deletingPathExtension().lastPathComponent, "json": s] }
    }
    func loadExtensions() -> [[String: Any]] {
        var out: [[String: Any]] = []
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: Paths.extensions, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for u in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDir: ObjCBool = false; fm.fileExists(atPath: u.path, isDirectory: &isDir)
            if isDir.boolValue {
                let idx = u.appendingPathComponent("index.js"); guard let src = try? String(contentsOf: idx, encoding: .utf8) else { continue }
                var meta: Any = [:]; if let ms = try? String(contentsOf: u.appendingPathComponent("extension.json"), encoding: .utf8), let mj = jsonParse(ms) { meta = mj }
                out.append(["name": u.lastPathComponent, "source": src, "meta": meta])
            } else if u.pathExtension == "js", let src = try? String(contentsOf: u, encoding: .utf8) {
                out.append(["name": u.deletingPathExtension().lastPathComponent, "source": src, "meta": [:]])
            }
        }
        return out
    }

    // MARK: iCloud Drive sync
    func setupSync() {
        syncTimer?.invalidate(); syncTimer = nil
        guard bool("syncNotes") && bool("pSync", true), Paths.iCloud != nil else { return }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.checkSyncFile(force: false) }
    }
    func scheduleSyncWrite() {
        guard bool("syncNotes") && bool("pSync", true) else { return }
        pendingSyncWrite?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.writeSyncFile() }
        pendingSyncWrite = w; DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
    }
    func writeSyncFile() {
        guard let url = Paths.iCloud else { return }
        webView.evaluateJavaScript("AN.syncPayload()") { res, _ in
            guard var s = res as? String else { return }
            if let pass = self.settings["syncPass"] as? String, !pass.isEmpty, let enc = SyncCrypto.encrypt(s, pass: pass) { s = enc }
            do { try s.write(to: url, atomically: true, encoding: .utf8); self.syncMTime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date; self.eval("AN.onSynced&&AN.onSynced()") } catch { NSLog("sync write failed: \(error)") }
        }
    }
    func checkSyncFile(force: Bool) {
        guard bool("syncNotes") && bool("pSync", true), let url = Paths.iCloud else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let mt = attrs[.modificationDate] as? Date else { return }
        if !force, let last = syncMTime, mt <= last { return }
        syncMTime = mt
        guard var s = try? String(contentsOf: url, encoding: .utf8) else { return }
        if s.hasPrefix("ANTINOTE-ENC1:") {
            guard let pass = settings["syncPass"] as? String, !pass.isEmpty, let dec = SyncCrypto.decrypt(s, pass: pass) else { eval("App.syncWarning='sync file is encrypted — set the same passphrase'; App.renderBottom()"); return }
            s = dec
        }
        eval("AN.onSync(\(jsLiteral(s)))")
    }

    // MARK: URL scheme
    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, with reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue else { return }
        showWindow()
        let run = { self.eval("AN.onURL(\(jsLiteral(s)))") }
        if booted { run() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: run) }
    }

    // MARK: WKUIDelegate (alerts from JS if any)
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert(); a.messageText = message; a.runModal(); completionHandler()
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let p = NSOpenPanel(); p.allowsMultipleSelection = parameters.allowsMultipleSelection; p.canChooseDirectories = parameters.allowsDirectories
        p.beginSheetModal(for: window) { r in completionHandler(r == .OK ? p.urls : nil) }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces); if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(calibratedRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }
}
