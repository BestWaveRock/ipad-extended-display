import Foundation

struct MuxDevice: Identifiable, Hashable {
    var id: String { udid }
    let deviceID: Int
    let udid: String
    let name: String?
    let model: String?
    let productID: Int?
    let connectionType: String

    var isUSB: Bool { connectionType == "USB" }
    var shortUDID: String {
        guard udid.count > 16 else { return udid }
        return "\(udid.prefix(8))…\(udid.suffix(6))"
    }
    var productKind: String? {
        if let name, !name.isEmpty { return name }
        if let model, !model.isEmpty {
            if model.hasPrefix("iPad") { return "iPad" }
            if model.hasPrefix("iPhone") { return "iPhone" }
            if model.hasPrefix("iPod") { return "iPod" }
        }
        switch productID {
        case 4779: return "iPad"
        case 4776: return "iPhone"
        default: return nil
        }
    }
    var friendlyName: String {
        productKind ?? "iOS 设备"
    }
    var displayName: String {
        let label = friendlyName
        return isUSB ? "\(label) · USB" : "\(label) · Wi-Fi"
    }
}

enum UsbmuxError: LocalizedError {
    case socketUnavailable
    case messaging(String)
    case refused
    case timeout

    var errorDescription: String? {
        switch self {
        case .socketUnavailable: return "无法连接 usbmuxd，是否已开启「USB 配件」信任？"
        case .messaging(let text): return "usbmuxd 返回错误：\(text)"
        case .refused: return "设备拒绝连接，请确认 iPad 端 App 已在前台运行"
        case .timeout: return "usbmuxd 无响应"
        }
    }
}

enum Usbmux {
    private static let socketPath = "/var/run/usbmuxd"
    private static let clientVersion = "usbmuxd-423.100.2"

    private static func openSocket() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            socketPath.utf8.enumerated().forEach { raw[$0.offset] = $0.element }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, length)
            }
        }
        if result != 0 {
            close(fd)
            return nil
        }
        var timeout = timeval(tv_sec: 4, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    private static func send(_ payload: [String: Any], on fd: Int32) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        var packet = Data(count: 16)
        let total = UInt32(16 + data.count)
        packet[0] = UInt8(total & 0xFF)
        packet[1] = UInt8((total >> 8) & 0xFF)
        packet[2] = UInt8((total >> 16) & 0xFF)
        packet[3] = UInt8((total >> 24) & 0xFF)
        packet[4] = 1
        packet[8] = 8
        packet.append(data)
        var sent = 0
        while sent < packet.count {
            let written = packet.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return write(fd, base.advanced(by: sent), packet.count - sent)
            }
            if written <= 0 { throw UsbmuxError.timeout }
            sent += written
        }
    }

    private static func readExactly(_ count: Int, on fd: Int32) throws -> Data {
        var buffer = Data(count: count)
        var received = 0
        while received < count {
            let readBytes = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(fd, base.advanced(by: received), count - received)
            }
            if readBytes <= 0 { throw UsbmuxError.timeout }
            received += readBytes
        }
        return buffer
    }

    private static func receive(on fd: Int32) throws -> [String: Any] {
        let header = try readExactly(16, on: fd)
        let bytes = [UInt8](header)
        let length = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        let bodyLength = length - 16
        guard bodyLength > 0, bodyLength < 4_000_000 else {
            throw UsbmuxError.messaging("异常长度 \(length)")
        }
        let body = try readExactly(bodyLength, on: fd)
        guard let plist = try PropertyListSerialization.propertyList(from: body, options: [], format: nil) as? [String: Any] else {
            throw UsbmuxError.messaging("响应格式错误")
        }
        return plist
    }

    private static func request(_ payload: [String: Any]) throws -> (Int32, [String: Any]) {
        guard let fd = openSocket() else { throw UsbmuxError.socketUnavailable }
        var base = payload
        base["ProgName"] = "iPadExtendedDisplay"
        base["ClientVersionString"] = clientVersion
        base["kLibUSBMuxVersion"] = 3
        do {
            try send(base, on: fd)
            let response = try receive(on: fd)
            return (fd, response)
        } catch {
            close(fd)
            throw error
        }
    }

    static func listDevices() throws -> [MuxDevice] {
        let (fd, response) = try request(["MessageType": "ListDevices"])
        defer { close(fd) }
        guard let list = response["DeviceList"] as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let properties = entry["Properties"] as? [String: Any],
                  let udid = properties["SerialNumber"] as? String else { return nil }
            return MuxDevice(deviceID: entry["DeviceID"] as? Int ?? 0,
                             udid: udid,
                             name: properties["DeviceName"] as? String,
                             model: properties["ProductType"] as? String,
                             productID: properties["ProductID"] as? Int,
                             connectionType: properties["ConnectionType"] as? String ?? "USB")
        }
    }

    static func connect(deviceID: Int, port: UInt16) throws -> Int32 {
        let networkPort = Int(UInt16(port).bigEndian)
        let (fd, response) = try request([
            "MessageType": "Connect",
            "DeviceID": deviceID,
            "PortNumber": networkPort
        ])
        let result = response["Number"] as? Int ?? -1
        guard result == 0 else {
            close(fd)
            throw result == 3 ? UsbmuxError.refused : UsbmuxError.messaging("Connect 失败 (\(result))")
        }
        var timeout = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    static func connect(host: String, port: UInt16, timeout: TimeInterval = 5) throws -> Int32 {
        var hints = addrinfo(ai_flags: AI_ADDRCONFIG,
                             ai_family: AF_UNSPEC,
                             ai_socktype: SOCK_STREAM,
                             ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0,
                             ai_canonname: nil,
                             ai_addr: nil,
                             ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let head = result else {
            throw UsbmuxError.messaging("无法解析 \(host)：\(String(cString: gai_strerror(status)))")
        }
        defer { freeaddrinfo(head) }

        var lastError = "连接 \(host):\(port) 失败"
        var candidate: UnsafeMutablePointer<addrinfo>? = head
        while let info = candidate {
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if fd >= 0 {
                var flags = fcntl(fd, F_GETFL, 0)
                flags |= O_NONBLOCK
                fcntl(fd, F_SETFL, flags)

                let rc = Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
                if rc == 0 || errno == EINPROGRESS {
                    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let ready = poll(&descriptor, 1, Int32(timeout * 1000))
                    if ready > 0 {
                        var soError: Int32 = 0
                        var length = socklen_t(MemoryLayout<Int32>.size)
                        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length)
                        if soError == 0 {
                            flags &= ~O_NONBLOCK
                            fcntl(fd, F_SETFL, flags)
                            var noSigpipe: Int32 = 1
                            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe,
                                       socklen_t(MemoryLayout<Int32>.size))
                            return fd
                        }
                        lastError = "连接 \(host):\(port) 被拒绝（\(String(cString: strerror(soError)))）"
                    } else {
                        lastError = "连接 \(host):\(port) 超时，请确认 iPad 与 Mac 在同一网络"
                    }
                }
                close(fd)
            }
            candidate = info.pointee.ai_next
        }
        throw UsbmuxError.messaging(lastError)
    }
}
