import Foundation
import MultipeerConnectivity
import UIKit

struct NearbyPeer: Identifiable, Hashable {
    let peerID: MCPeerID
    let stableID: String

    var id: String {
        stableID
    }

    var name: String {
        peerID.displayName
    }
}

enum NearbyDisplayNameStore {
    private static let displayNameKey = "NearbyTransferDisplayName"
    private static let suffixKey = "NearbyTransferDisplayNameSuffix"
    private static let peerIDKey = "NearbyTransferStablePeerID"

    static var displayName: String {
        get {
            if let stored = UserDefaults.standard.string(forKey: displayNameKey),
               !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return cleanDisplayName(stored)
            }
            return defaultDisplayName
        }
        set {
            UserDefaults.standard.set(cleanDisplayName(newValue), forKey: displayNameKey)
        }
    }

    private static var defaultDisplayName: String {
        let deviceName = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let genericNames: Set<String> = ["iPhone", "iPad", "iPod touch"]
        let baseName = (!deviceName.isEmpty && !genericNames.contains(deviceName)) ? deviceName : "MilkT"
        return cleanDisplayName(baseName)
    }

    private static var stableSuffix: String {
        if let stored = UserDefaults.standard.string(forKey: suffixKey) {
            return stored
        }
        let suffix = String(UUID().uuidString.prefix(4)).uppercased()
        UserDefaults.standard.set(suffix, forKey: suffixKey)
        return suffix
    }

    static func cleanDisplayName(_ name: String) -> String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = cleaned.isEmpty ? "MilkT" : cleaned
        let suffix = "·\(stableSuffix)"
        let nameWithoutOldSuffix = baseName.replacingOccurrences(
            of: #"·[A-F0-9]{4}$"#,
            with: "",
            options: .regularExpression
        )
        return String("\(nameWithoutOldSuffix)\(suffix)".prefix(48))
    }

    static var stablePeerID: String {
        if let stored = UserDefaults.standard.string(forKey: peerIDKey) {
            return stored
        }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: peerIDKey)
        return newID
    }
}

final class NearbyTransferManager: NSObject, ObservableObject {
    @Published private(set) var peers: [NearbyPeer] = []
    @Published private(set) var statusMessage = "正在寻找附近设备"
    @Published private(set) var isSending = false

    var onReceivedPackage: ((URL) -> Void)?

    private static let serviceType = "mtc-share"
    private let stablePeerID: String
    private let localPeerID: MCPeerID
    private let session: MCSession
    private let advertiserAssistant: MCAdvertiserAssistant
    private let browser: MCNearbyServiceBrowser
    private var pendingResourceURL: URL?
    private var pendingPeerID: MCPeerID?
    private var sendTimeoutID: UUID?

    init(displayName: String = NearbyDisplayNameStore.displayName) {
        let cleanedName = NearbyDisplayNameStore.cleanDisplayName(displayName)
        stablePeerID = NearbyDisplayNameStore.stablePeerID
        localPeerID = MCPeerID(displayName: cleanedName)
        session = MCSession(peer: localPeerID, securityIdentity: nil, encryptionPreference: .required)
        advertiserAssistant = MCAdvertiserAssistant(
            serviceType: Self.serviceType,
            discoveryInfo: ["peerID": stablePeerID],
            session: session
        )
        browser = MCNearbyServiceBrowser(peer: localPeerID, serviceType: Self.serviceType)
        super.init()
        session.delegate = self
        advertiserAssistant.delegate = self
        browser.delegate = self
    }

    var localDisplayName: String {
        localPeerID.displayName
    }

    func start() {
        advertiserAssistant.start()
        browser.startBrowsingForPeers()
    }

    func stop() {
        sendTimeoutID = nil
        browser.stopBrowsingForPeers()
        advertiserAssistant.stop()
    }

    func prepareToSend(to peer: NearbyPeer) {
        isSending = true
        statusMessage = "正在打包要发送给 \(peer.name) 的图鉴"
    }

    func prepareToShare() {
        isSending = true
        statusMessage = "正在准备图鉴文件"
    }

    func finishPreparingShare() {
        isSending = false
        statusMessage = "图鉴文件已准备好"
    }

    func failPendingSend(_ message: String) {
        isSending = false
        if let pendingResourceURL {
            try? FileManager.default.removeItem(at: pendingResourceURL)
        }
        sendTimeoutID = nil
        pendingResourceURL = nil
        pendingPeerID = nil
        statusMessage = message
    }

    func sendPackageData(_ data: Data, to peer: NearbyPeer) throws {
        guard !data.isEmpty else {
            statusMessage = "没有可发送的图鉴数据"
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mtcpack")
        try data.write(to: url, options: .atomic)

        pendingResourceURL = url
        pendingPeerID = peer.peerID
        isSending = true
        statusMessage = "已准备图鉴，正在连接 \(peer.name)"

        if session.connectedPeers.contains(peer.peerID) {
            sendPendingResource()
        } else {
            browser.invitePeer(peer.peerID, to: session, withContext: nil, timeout: 30)
            scheduleSendTimeout(for: peer)
        }
    }

    func prepareSystemBrowserSend(_ data: Data, targetName: String?) throws {
        guard !data.isEmpty else {
            statusMessage = "没有可发送的图鉴数据"
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mtcpack")
        try data.write(to: url, options: .atomic)

        pendingResourceURL = url
        pendingPeerID = nil
        isSending = true
        browser.stopBrowsingForPeers()

        if let connectedPeer = session.connectedPeers.first {
            pendingPeerID = connectedPeer
            statusMessage = "已连接 \(connectedPeer.displayName)，正在发送图鉴"
            sendPendingResource()
        } else {
            let targetText = targetName.map { "给 \($0)" } ?? ""
            statusMessage = "请在系统窗口中选择\(targetText)要发送的设备"
        }
    }

    func makeSystemBrowserViewController(delegate: MCBrowserViewControllerDelegate) -> MCBrowserViewController {
        let controller = MCBrowserViewController(serviceType: Self.serviceType, session: session)
        controller.delegate = delegate
        controller.minimumNumberOfPeers = 1
        controller.maximumNumberOfPeers = 1
        return controller
    }

    func sendToFirstConnectedPeerIfReady() {
        guard pendingResourceURL != nil else { return }
        if pendingPeerID == nil {
            pendingPeerID = session.connectedPeers.first
        }
        sendPendingResource()
    }

    func cancelSystemBrowserSelectionIfNeeded() {
        guard pendingResourceURL != nil, pendingPeerID == nil else { return }
        failPendingSend("已取消连接")
    }

    func resumePeerBrowsing() {
        browser.startBrowsingForPeers()
    }

    func shouldShowSystemPeer(_ peerID: MCPeerID, discoveryInfo: [String: String]?) -> Bool {
        discoveryInfo?["peerID"] != stablePeerID
    }

    private func sendPendingResource() {
        sendTimeoutID = nil
        guard let url = pendingResourceURL,
              let peerID = pendingPeerID,
              session.connectedPeers.contains(peerID) else {
            return
        }

        statusMessage = "正在发送图鉴"
        session.sendResource(at: url, withName: url.lastPathComponent, toPeer: peerID) { [weak self] error in
            DispatchQueue.main.async {
                self?.isSending = false
                self?.pendingResourceURL = nil
                self?.pendingPeerID = nil
                self?.sendTimeoutID = nil
                try? FileManager.default.removeItem(at: url)
                if let error {
                    self?.statusMessage = "发送失败：\(error.localizedDescription)"
                } else {
                    self?.statusMessage = "已发送"
                }
            }
        }
    }

    private func updateStatus(_ message: String) {
        DispatchQueue.main.async {
            self.statusMessage = message
        }
    }

    private func scheduleSendTimeout(for peer: NearbyPeer) {
        let timeoutID = UUID()
        sendTimeoutID = timeoutID
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self,
                  self.sendTimeoutID == timeoutID,
                  self.pendingPeerID == peer.peerID,
                  !self.session.connectedPeers.contains(peer.peerID) else {
                return
            }
            self.failPendingSend("连接 \(peer.name) 超时，请确认两台手机都停留在互传页面")
        }
    }
}

extension NearbyTransferManager: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async {
            guard let stableID = info?["peerID"], stableID != self.stablePeerID else { return }
            let peer = NearbyPeer(peerID: peerID, stableID: stableID)
            guard !self.peers.contains(peer) else { return }
            self.peers.append(peer)
            self.peers.sort { $0.name < $1.name }
            self.statusMessage = "发现 \(peer.name)"
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            self.peers.removeAll { $0.peerID == peerID }
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        updateStatus("查找失败：\(error.localizedDescription)")
    }
}

extension NearbyTransferManager: MCAdvertiserAssistantDelegate {
    func advertiserAssistantWillPresentInvitation(_ advertiserAssistant: MCAdvertiserAssistant) {
        updateStatus("收到连接邀请")
    }

    func advertiserAssistantDidDismissInvitation(_ advertiserAssistant: MCAdvertiserAssistant) {
        updateStatus("邀请已处理")
    }
}

extension NearbyTransferManager: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            switch state {
            case .connected:
                self.statusMessage = "已连接 \(peerID.displayName)"
                if self.pendingResourceURL != nil, self.pendingPeerID == nil {
                    self.pendingPeerID = peerID
                }
                self.sendPendingResource()
            case .connecting:
                self.statusMessage = "正在连接 \(peerID.displayName)"
            case .notConnected:
                if self.pendingPeerID == peerID {
                    self.failPendingSend("\(peerID.displayName) 已断开")
                } else {
                    self.statusMessage = "\(peerID.displayName) 已断开"
                }
            @unknown default:
                self.statusMessage = "连接状态变化"
            }
        }
    }

    func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: Error?
    ) {
        DispatchQueue.main.async {
            if let error {
                self.statusMessage = "接收失败：\(error.localizedDescription)"
                return
            }
            guard let localURL else {
                self.statusMessage = "接收失败"
                return
            }
            self.statusMessage = "已收到 \(peerID.displayName) 的图鉴"
            self.onReceivedPackage?(localURL)
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        updateStatus("正在接收 \(peerID.displayName) 的图鉴")
    }
}
