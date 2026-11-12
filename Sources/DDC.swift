import Foundation
import IOKit

/// Private IOKit calls for I2C to external displays on Apple silicon (the same ones MonitorControl and m1ddc use).
/// Looked up at runtime so a missing symbol means "no hardware control" instead of a crash at launch.
enum AVService {
    typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias I2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
    static let create = symbol("IOAVServiceCreateWithService", as: CreateFn.self)
    static let readI2C = symbol("IOAVServiceReadI2C", as: I2CFn.self)
    static let writeI2C = symbol("IOAVServiceWriteI2C", as: I2CFn.self)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let pointer = dlsym(iokit, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }
}

enum VCP {
    static let brightness: UInt8 = 0x10
}

/// DDC/CI over one display's AV service. Calls block for tens of milliseconds, so keep them off the main thread.
final class DDCChannel: @unchecked Sendable {
    private let service: CFTypeRef
    private static let chipAddress: UInt32 = 0x37   // 0x6E/0x6F on the wire
    private static let hostAddress: UInt32 = 0x51

    init?(registryEntry: io_service_t) {
        guard let create = AVService.create, AVService.readI2C != nil, AVService.writeI2C != nil,
              let service = create(kCFAllocatorDefault, registryEntry)?.takeRetainedValue() else { return nil }
        self.service = service
    }

    /// Get VCP Feature. Nil when the display doesn't send a well-formed reply for this code.
    func read(_ code: UInt8, attempts: Int = 3) -> (current: Int, max: Int)? {
        var request: [UInt8] = [0x82, 0x01, code, 0]
        request[3] = Self.checksum(0x6E ^ 0x51, request[0..<3])
        for attempt in 0..<attempts {
            if attempt > 0 { usleep(30_000) }
            guard send(&request) else { continue }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 11)
            guard AVService.readI2C?(service, Self.chipAddress, Self.hostAddress, &reply, UInt32(reply.count)) == kIOReturnSuccess
            else { continue }
            // 6E 88 02 <result> <code> <type> <max hi> <max lo> <current hi> <current lo> <checksum>.
            // Anything else is a "not ready" null message or, on some links, stale bytes from an earlier exchange.
            guard reply[0] == 0x6E, reply[1] == 0x88, reply[2] == 0x02, reply[4] == code,
                  Self.checksum(0x50, reply[0..<10]) == reply[10] else { continue }
            guard reply[3] == 0 else { return nil }   // the display says it doesn't support this code
            return (Int(reply[8]) << 8 | Int(reply[9]), Int(reply[6]) << 8 | Int(reply[7]))
        }
        return nil
    }

    /// Set VCP Feature. True means the bytes went out; DDC has no acknowledgement, so only a read can confirm it.
    @discardableResult
    func write(_ code: UInt8, _ value: Int) -> Bool {
        let v = UInt16(clamping: value)
        var packet: [UInt8] = [0x84, 0x03, code, UInt8(v >> 8), UInt8(v & 0xFF), 0]
        packet[5] = Self.checksum(0x6E ^ 0x51, packet[0..<5])
        return send(&packet)
    }

    /// A lone write is often dropped on Apple silicon (the LG here answered reads only after a double send),
    /// which is why MonitorControl and m1ddc also send every packet more than once.
    private func send(_ packet: inout [UInt8]) -> Bool {
        guard let write = AVService.writeI2C else { return false }
        var sent = false
        for _ in 0..<2 {
            usleep(10_000)
            if write(service, Self.chipAddress, Self.hostAddress, &packet, UInt32(packet.count)) == kIOReturnSuccess { sent = true }
        }
        return sent
    }

    /// XOR of every byte on the wire, starting from the addresses that IOAVService sends for us.
    private static func checksum(_ seed: UInt8, _ bytes: ArraySlice<UInt8>) -> UInt8 {
        bytes.reduce(seed, ^)
    }
}

/// Serializes one display's DDC traffic and coalesces slider drags, so only the newest value is ever queued.
final class BacklightLink: @unchecked Sendable {
    let channel: DDCChannel
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: Int?
    private var draining = false

    init(channel: DDCChannel, label: String) {
        self.channel = channel
        queue = DispatchQueue(label: "Brightside.ddc.\(label)", qos: .userInitiated)
    }

    func set(_ value: Int) {
        lock.lock()
        pending = value
        let start = !draining
        draining = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    /// Reads run behind any queued writes, so they report what the display ended up at.
    func read(_ completion: @escaping ((current: Int, max: Int)?) -> Void) {
        queue.async {
            let result = self.channel.read(VCP.brightness)
            DispatchQueue.main.async { completion(result) }
        }
    }

    func readNow() -> (current: Int, max: Int)? {
        queue.sync { channel.read(VCP.brightness) }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let value = pending else {
                draining = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            channel.write(VCP.brightness, value)
            usleep(20_000)   // DDC/CI asks hosts to leave ~50 ms between commands; the double send covers the rest
        }
    }
}
