// Fieldnote Companion
// A menu bar app that lets fieldnote-record.github.io change this Mac's
// audio input volume after the browser is paired with a 6-digit code.
//
// The app listens on http://127.0.0.1:47823 (this Mac only) and accepts
// requests only from the Fieldnote website (and localhost, for testing).
//
//   GET  /status                       -> app name, version, whether the token is paired
//   POST /pair     {"code":"123456"}   -> {"token": "..."}
//   GET  /volume?device=<label>        -> volume of the matching input (auth)
//   POST /volume   {"device", "db" | "deltaDb" | "scalar" | "deltaScalar"}   (auth)

import AppKit
import CoreAudio
import CryptoKit
import Network

let appVersion = "1.0.0"
let port: UInt16 = 47823
let siteURL = URL(string: "https://fieldnote-record.github.io")!

func originAllowed(_ origin: String) -> Bool {
    if origin == "https://fieldnote-record.github.io" { return true }
    if let u = URL(string: origin), u.scheme == "http", let h = u.host, h == "localhost" || h == "127.0.0.1" { return true }
    return false
}

// MARK: - Core Audio input volume

struct InputDevice {
    let id: AudioDeviceID
    let name: String
}

enum Audio {
    static func address(_ sel: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: UInt32 = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: element)
    }

    static func inputDevices() -> [InputDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            inputChannels(id) > 0 ? InputDevice(id: id, name: name(id)) : nil
        }
    }

    static func defaultInput() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    static func name(_ id: AudioDeviceID) -> String {
        var addr = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let n = name else { return "Audio input" }
        return n.takeRetainedValue() as String
    }

    static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Elements whose input volume can be changed: the main element if it works, else each channel.
    static func volumeElements(_ id: AudioDeviceID) -> [UInt32] {
        func settable(_ el: UInt32) -> Bool {
            var addr = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput, el)
            guard AudioObjectHasProperty(id, &addr) else { return false }
            var ok: DarwinBoolean = false
            return AudioObjectIsPropertySettable(id, &addr, &ok) == noErr && ok.boolValue
        }
        if settable(kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        let n = inputChannels(id)
        return n > 0 ? (1...UInt32(n)).filter(settable) : []
    }

    static func getFloat(_ id: AudioDeviceID, _ sel: AudioObjectPropertySelector, _ el: UInt32) -> Float32? {
        var addr = address(sel, kAudioDevicePropertyScopeInput, el)
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func setFloat(_ id: AudioDeviceID, _ sel: AudioObjectPropertySelector, _ el: UInt32, _ value: Float32) {
        var addr = address(sel, kAudioDevicePropertyScopeInput, el)
        var v = value
        AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    static func dbRange(_ id: AudioDeviceID, _ el: UInt32) -> (Double, Double)? {
        var addr = address(kAudioDevicePropertyVolumeRangeDecibels, kAudioDevicePropertyScopeInput, el)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var r = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &r) == noErr, r.mMaximum > r.mMinimum else { return nil }
        return (r.mMinimum, r.mMaximum)
    }

    /// Finds the Core Audio device that matches a browser's input label,
    /// e.g. "Default - USB Audio CODEC (08bb:2902)" -> "USB Audio CODEC".
    static func match(label: String?) -> InputDevice? {
        let devices = inputDevices()
        guard var l = label?.trimmingCharacters(in: .whitespaces), !l.isEmpty else {
            return defaultInput().flatMap { id in devices.first { $0.id == id } }
        }
        for prefix in ["Default - ", "Communications - "] where l.hasPrefix(prefix) { l.removeFirst(prefix.count) }
        if let r = l.range(of: #"\s*\([0-9a-fA-F]{4}:[0-9a-fA-F]{4}\)$"#, options: .regularExpression) { l.removeSubrange(r) }
        let low = l.lowercased()
        if let d = devices.first(where: { $0.name.lowercased() == low }) { return d }
        if let d = devices.first(where: { low.contains($0.name.lowercased()) || $0.name.lowercased().contains(low) }) { return d }
        return defaultInput().flatMap { id in devices.first { $0.id == id } }
    }

    static func state(_ d: InputDevice) -> [String: Any] {
        let els = volumeElements(d.id)
        var out: [String: Any] = ["device": d.name, "adjustable": !els.isEmpty]
        guard let el = els.first else { return out }
        let scalars = els.compactMap { getFloat(d.id, kAudioDevicePropertyVolumeScalar, $0) }
        out["scalar"] = scalars.isEmpty ? 0 : Double(scalars.reduce(0, +)) / Double(scalars.count)
        if let range = dbRange(d.id, el), let v = getFloat(d.id, kAudioDevicePropertyVolumeDecibels, el) {
            out["db"] = Double(v)
            out["minDb"] = range.0
            out["maxDb"] = range.1
        }
        return out
    }

    static func apply(_ d: InputDevice, body: [String: Any]) {
        let els = volumeElements(d.id)
        guard let first = els.first else { return }
        let num = { (k: String) -> Double? in (body[k] as? NSNumber)?.doubleValue }
        if let range = dbRange(d.id, first), num("db") != nil || num("deltaDb") != nil {
            let current = Double(getFloat(d.id, kAudioDevicePropertyVolumeDecibels, first) ?? Float32(range.0))
            var target = num("db") ?? (current + (num("deltaDb") ?? 0))
            target = min(range.1, max(range.0, target))
            for el in els { setFloat(d.id, kAudioDevicePropertyVolumeDecibels, el, Float32(target)) }
            return
        }
        // Devices without a decibel scale: work in 0…1.
        let current = Double(getFloat(d.id, kAudioDevicePropertyVolumeScalar, first) ?? 0)
        var target = num("scalar") ?? (current + (num("deltaScalar") ?? 0))
        if let delta = num("deltaDb"), num("scalar") == nil, num("deltaScalar") == nil {
            target = current * pow(10, delta / 20)   // approximate a dB step on a plain scale
            if current == 0 && delta > 0 { target = 0.01 }
        }
        target = min(1, max(0, target))
        for el in els { setFloat(d.id, kAudioDevicePropertyVolumeScalar, el, Float32(target)) }
    }
}

// MARK: - Pairing

final class Pairing {
    // FIELDNOTE_PAIR_CODE lets automated tests start with a known code.
    private(set) var code = ProcessInfo.processInfo.environment["FIELDNOTE_PAIR_CODE"] ?? Pairing.newCode()
    private var failures = 0
    var onChange: (() -> Void)?

    private var tokenHashes: [String] {
        get { UserDefaults.standard.stringArray(forKey: "tokenHashes") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "tokenHashes") }
    }
    var pairedCount: Int { tokenHashes.count }

    static func newCode() -> String { String(format: "%06d", Int.random(in: 0...999_999)) }
    static func hash(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }

    func rotate() { code = Pairing.newCode(); failures = 0; onChange?() }

    func pair(with attempt: String) -> String? {
        let clean = attempt.filter(\.isNumber)
        guard clean == code else {
            failures += 1
            if failures >= 5 { rotate() }   // stop guessing
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        tokenHashes = Array((tokenHashes + [Pairing.hash(token)]).suffix(20))
        rotate()
        return token
    }

    func isPaired(_ token: String?) -> Bool {
        guard let t = token, !t.isEmpty else { return false }
        return tokenHashes.contains(Pairing.hash(t))
    }

    func forgetAll() { tokenHashes = []; rotate() }
}

// MARK: - Local HTTP server

struct Request {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data
}

final class Server {
    private var listener: NWListener?
    let pairing: Pairing
    var onActivity: (() -> Void)?
    private(set) var error: String?

    init(pairing: Pairing) { self.pairing = pairing }

    func start() {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        do {
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { [weak self] s in
                if case .failed(let e) = s { self?.error = "Port \(port) is busy (\(e)). Quit other copies of the app." }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            self.error = "Couldn't start: \(error)"
        }
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: .main)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if buf.count > 128 * 1024 || err != nil { c.cancel(); return }
            if let req = Server.parse(buf) {
                self.respond(c, self.handle(req))
            } else if done {
                c.cancel()
            } else {
                self.receive(c, buffer: buf)
            }
        }
    }

    static func parse(_ data: Data) -> Request? {
        guard let headEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[..<headEnd.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            guard let i = l.firstIndex(of: ":") else { continue }
            headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headEnd.upperBound
        guard data.count - bodyStart >= length else { return nil }
        let target = String(first[1])
        let comps = URLComponents(string: "http://x" + target)
        var query: [String: String] = [:]
        comps?.queryItems?.forEach { query[$0.name] = $0.value ?? "" }
        return Request(method: String(first[0]), path: comps?.path ?? target, query: query,
                       headers: headers, body: data[bodyStart..<(bodyStart + length)])
    }

    struct Response {
        var status: Int
        var json: [String: Any]
        var origin: String?
    }

    private func handle(_ r: Request) -> Response {
        let origin = r.headers["origin"]
        // Only the Fieldnote website may talk to the app.
        guard let o = origin, originAllowed(o) else {
            return Response(status: 403, json: ["error": "This app only answers fieldnote-record.github.io."], origin: nil)
        }
        if r.method == "OPTIONS" { return Response(status: 204, json: [:], origin: o) }

        let auth = r.headers["authorization"].map { $0.replacingOccurrences(of: "Bearer ", with: "") }
        let body = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]

        switch (r.method, r.path) {
        case ("GET", "/status"):
            return Response(status: 200, json: ["app": "fieldnote-companion", "version": appVersion,
                                                "paired": pairing.isPaired(auth)], origin: o)
        case ("POST", "/pair"):
            guard let token = pairing.pair(with: body["code"] as? String ?? "") else {
                return Response(status: 401, json: ["error": "That code doesn't match. Check the code in the Fieldnote menu bar app."], origin: o)
            }
            onActivity?()
            return Response(status: 200, json: ["token": token], origin: o)
        case (_, "/volume"):
            guard pairing.isPaired(auth) else {
                return Response(status: 401, json: ["error": "Not paired."], origin: o)
            }
            let label = (r.method == "POST" ? body["device"] as? String : r.query["device"])
            guard let device = Audio.match(label: label) else {
                return Response(status: 404, json: ["error": "No audio input found on this Mac."], origin: o)
            }
            if r.method == "POST" { Audio.apply(device, body: body); onActivity?() }
            return Response(status: 200, json: Audio.state(device), origin: o)
        default:
            return Response(status: 404, json: ["error": "Not found"], origin: o)
        }
    }

    private func respond(_ c: NWConnection, _ res: Response) {
        let reasons = [200: "OK", 204: "No Content", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found"]
        let body = res.status == 204 ? Data() : ((try? JSONSerialization.data(withJSONObject: res.json)) ?? Data("{}".utf8))
        var head = "HTTP/1.1 \(res.status) \(reasons[res.status] ?? "OK")\r\n"
        head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        if let o = res.origin {
            head += "Access-Control-Allow-Origin: \(o)\r\nVary: Origin\r\n"
            head += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
            head += "Access-Control-Allow-Headers: Content-Type, Authorization\r\n"
            head += "Access-Control-Allow-Private-Network: true\r\n"
            head += "Access-Control-Max-Age: 600\r\n"
        }
        head += "\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }
}

// MARK: - Menu bar

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let pairing = Pairing()
    lazy var server = Server(pairing: pairing)
    var item: NSStatusItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = item.button {
            let img = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Fieldnote Companion")
            img?.isTemplate = true
            b.image = img
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        server.onActivity = { [weak self] in self?.flash() }
        server.start()
    }

    private func flash() {
        guard let b = item.button else { return }
        b.contentTintColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { b.contentTintColor = nil }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(label("Fieldnote Companion", size: 13, weight: .semibold))

        if let err = server.error {
            menu.addItem(label(err, size: 12, color: .systemRed))
        } else {
            menu.addItem(.separator())
            menu.addItem(label("PAIRING CODE", size: 10, weight: .medium, color: .secondaryLabelColor, kern: 1))
            let c = pairing.code
            let spaced = String(c.prefix(3)) + " " + String(c.suffix(3))
            let codeItem = label(spaced, size: 30, weight: .semibold, mono: true)
            menu.addItem(codeItem)
            menu.addItem(label("Type this code into the Turntable Recorder\nwebsite to let it change your input volume.", size: 11, color: .secondaryLabelColor))
        }

        menu.addItem(.separator())
        if let d = Audio.match(label: nil) {
            let s = Audio.state(d)
            var line = "Input: \(d.name)"
            if let db = s["db"] as? Double { line += String(format: " · %+.1f dB", db) }
            else if let sc = s["scalar"] as? Double { line += String(format: " · %.0f%%", sc * 100) }
            else { line += " · fixed volume" }
            menu.addItem(label(line, size: 12))
        }
        let n = pairing.pairedCount
        menu.addItem(label(n == 0 ? "No browsers paired yet" : "\(n) browser\(n == 1 ? "" : "s") paired", size: 12, color: .secondaryLabelColor))

        menu.addItem(.separator())
        menu.addItem(action("Open Turntable Recorder", #selector(openSite), key: "o"))
        menu.addItem(action("New Pairing Code", #selector(newCode), key: "n"))
        menu.addItem(action("Forget Paired Browsers", #selector(forget), key: ""))
        menu.addItem(.separator())
        menu.addItem(action("Quit Fieldnote Companion", #selector(quit), key: "q"))
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor, mono: Bool = false, kern: CGFloat = 0) -> NSMenuItem {
        let i = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        let font = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        i.attributedTitle = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .kern: kern])
        i.isEnabled = false
        return i
    }

    private func action(_ title: String, _ sel: Selector, key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc func openSite() { NSWorkspace.shared.open(siteURL) }
    @objc func newCode() { pairing.rotate() }
    @objc func forget() { pairing.forgetAll() }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
