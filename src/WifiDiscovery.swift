import Foundation

struct WifiDisplay: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let host: String
    let port: Int
}

final class WifiDiscovery: NSObject {
    var onChange: (([WifiDisplay]) -> Void)?
    private(set) var devices: [WifiDisplay] = []

    private let browser = NetServiceBrowser()
    private var resolving: [NetService] = []
    private var found: [String: WifiDisplay] = [:]

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        browser.searchForServices(ofType: "_ipaddisplay._tcp.", inDomain: "local.")
    }

    func stop() {
        browser.stop()
        resolving.forEach { $0.stop() }
        resolving.removeAll()
        found.removeAll()
        publish()
    }

    private func publish() {
        devices = found.values.sorted { $0.name < $1.name }
        onChange?(devices)
    }
}

extension WifiDiscovery: NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolving.append(service)
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        found.removeValue(forKey: service.name)
        publish()
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        publish()
    }
}

extension WifiDiscovery: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        resolving.removeAll { $0 === sender }
        guard let host = sender.hostName, !host.isEmpty, sender.port > 0 else { return }
        found[sender.name] = WifiDisplay(name: sender.name, host: host, port: sender.port)
        publish()
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.removeAll { $0 === sender }
    }
}
