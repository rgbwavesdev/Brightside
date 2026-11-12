import AppKit
import IOKit

/// One connected screen as macOS sees it, plus the DDC channel to it when there is one.
struct FoundDisplay {
    let id: CGDirectDisplayID
    let key: String              // vendor-model-serial, stable across reconnects and reboots
    let name: String
    let isApple: Bool            // Apple displays already have system brightness control
    let isBuiltin: Bool
    let mirrors: CGDirectDisplayID
    let bounds: CGRect
    let rotation: Double
    let connection: String?
    let channel: DDCChannel?

    var needsUs: Bool { !isApple && !isBuiltin }
}

enum Discovery {
    static let appleVendor: UInt32 = 0x610

    private typealias InfoFn = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?
    private static let coreDisplayInfo: InfoFn? = {
        let handle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_NOW)
        return dlsym(handle, "CoreDisplay_DisplayCreateInfoDictionary").map { unsafeBitCast($0, to: InfoFn.self) }
    }()

    static func scan() -> [FoundDisplay] {
        let registry = RegistryScan()
        defer { registry.release() }
        return onlineDisplays().map { id in
            let vendor = CGDisplayVendorNumber(id), model = CGDisplayModelNumber(id), serial = CGDisplaySerialNumber(id)
            let info = coreDisplayInfo?(id)?.takeRetainedValue() as NSDictionary?
            // CoreDisplay names the framebuffer that drives this display; fall back to matching EDID numbers.
            let framebuffer = registry.framebuffer(path: info?["IODisplayLocation"] as? String,
                                                   vendor: vendor, model: model, serial: serial)
            let names = info?["DisplayProductName"] as? [String: String]
            let name = names?["en_US"] ?? names?.values.first ?? framebuffer?.name ?? screenName(id) ?? "Display \(id)"
            let isApple = vendor == appleVendor
            let isBuiltin = CGDisplayIsBuiltin(id) != 0
            var channel: DDCChannel?
            if !isApple, !isBuiltin, let framebuffer, let service = registry.avService(for: framebuffer) {
                channel = DDCChannel(registryEntry: service)
            }
            var key = "\(vendor)-\(model)-\(serial)"
            if serial == 0, let token = framebuffer?.token { key += "-\(token)" }   // two identical serial-less monitors
            return FoundDisplay(id: id, key: key, name: name, isApple: isApple, isBuiltin: isBuiltin,
                                mirrors: CGDisplayMirrorsDisplay(id), bounds: CGDisplayBounds(id),
                                rotation: CGDisplayRotation(id), connection: framebuffer?.connection, channel: channel)
        }
    }

    /// "Portrait · right of Pro Display XDR · DisplayPort" — enough to tell two identical monitors apart.
    static func detail(for display: FoundDisplay, among all: [FoundDisplay]) -> String {
        var parts: [String] = []
        if display.mirrors != 0, let source = all.first(where: { $0.id == display.mirrors }) {
            parts.append("mirroring \(source.name)")
        } else {
            if display.rotation == 90 || display.rotation == 270 { parts.append("portrait") }
            if CGDisplayIsMain(display.id) != 0 {
                parts.append("main display")
            } else if let main = all.first(where: { CGDisplayIsMain($0.id) != 0 }) {
                let dx = display.bounds.midX - main.bounds.midX, dy = display.bounds.midY - main.bounds.midY
                let side = abs(dx) >= abs(dy) ? (dx > 0 ? "right of" : "left of") : (dy > 0 ? "below" : "above")
                parts.append("\(side) \(main.name)")
            }
        }
        if let connection = display.connection { parts.append(connection) }
        let text = parts.joined(separator: " · ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Online rather than active: a hardware-mirrored display is online but not "active".
    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    private static func screenName(_ id: CGDirectDisplayID) -> String? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }?.localizedName
    }
}

/// One walk of the IOService plane: display framebuffers and the AV services that carry their I2C.
private final class RegistryScan {
    struct Framebuffer {
        let path: String
        let token: String?        // "dispext1" — also appears in the matching AV service's path
        let vendor: Int?
        let product: Int?
        let serial: Int?
        let name: String?
        let connection: String?
    }

    private(set) var framebuffers: [Framebuffer] = []
    private var avByToken: [String: io_service_t] = [:]
    private var avAfterFramebuffer: [String: io_service_t] = [:]   // MonitorControl's pairing by walk order, as a fallback
    private var retained: [io_service_t] = []

    init() {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        var iterator = io_iterator_t()
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator)
                == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var lastFramebuffer: String?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            var keep = false
            switch Self.name(of: entry) {
            case "IOMobileFramebufferShim", "AppleCLCD2":
                let framebuffer = Self.framebuffer(entry)
                framebuffers.append(framebuffer)
                lastFramebuffer = framebuffer.path
            case "DCPAVServiceProxy":
                guard Self.property(entry, "Location") as? String == "External" else { break }
                if let token = Self.token(in: Self.path(of: entry)), avByToken[token] == nil {
                    avByToken[token] = entry
                    keep = true
                }
                if let framebuffer = lastFramebuffer, avAfterFramebuffer[framebuffer] == nil {
                    avAfterFramebuffer[framebuffer] = entry
                    keep = true
                }
                lastFramebuffer = nil
            default:
                break
            }
            if keep { retained.append(entry) } else { IOObjectRelease(entry) }
        }
    }

    func release() {
        retained.forEach { IOObjectRelease($0) }
        retained = []
    }

    func framebuffer(path: String?, vendor: UInt32, model: UInt32, serial: UInt32) -> Framebuffer? {
        if let path, let match = framebuffers.first(where: { $0.path == path }) { return match }
        return framebuffers.first {
            $0.vendor == Int(vendor) && $0.product == Int(model) && ($0.serial ?? 0) == Int(serial)
        }
    }

    func avService(for framebuffer: Framebuffer) -> io_service_t? {
        if let token = framebuffer.token, let service = avByToken[token] { return service }
        return avAfterFramebuffer[framebuffer.path]
    }

    private static func framebuffer(_ entry: io_registry_entry_t) -> Framebuffer {
        let path = path(of: entry)
        let attributes = (property(entry, "DisplayAttributes") as? NSDictionary)?["ProductAttributes"] as? NSDictionary
        let transport = property(entry, "Transport") as? NSDictionary
        let connection: String? = switch transport?["Downstream"] as? String {
        case "HDMI": "HDMI"
        case "DP": "DisplayPort"
        default: nil
        }
        return Framebuffer(path: path, token: token(in: path),
                           vendor: (attributes?["LegacyManufacturerID"] as? NSNumber)?.intValue,
                           product: (attributes?["ProductID"] as? NSNumber)?.intValue,
                           serial: (attributes?["SerialNumber"] as? NSNumber)?.intValue,
                           name: attributes?["ProductName"] as? String,
                           connection: connection)
    }

    private static func token(in path: String) -> String? {
        path.range(of: #"disp(ext)?[0-9]+"#, options: .regularExpression).map { String(path[$0]) }
    }

    private static func name(of entry: io_registry_entry_t) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(entry, &buffer)
        return String(cString: buffer)
    }

    private static func path(of entry: io_registry_entry_t) -> String {
        var buffer = [CChar](repeating: 0, count: 1024)
        IORegistryEntryGetPath(entry, kIOServicePlane, &buffer)
        return String(cString: buffer)
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
