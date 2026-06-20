import Foundation
import MultipeerConnectivity
import UIKit

struct NearbyPeer: Identifiable, Hashable {
    let peerID: MCPeerID
    let stableID: String
    let ownerName: String
    let drinkCount: Int
    let effectiveDrinkCount: Int
    let averageRating: Double
    let exportedAt: Date?

    var id: String {
        stableID
    }

    var name: String {
        ownerName.isEmpty ? peerID.displayName : ownerName
    }
}

struct NearbyLocalSummary {
    let ownerID: String
    let ownerName: String
    let drinkCount: Int
    let effectiveDrinkCount: Int
    let averageRating: Double
    let exportedAt: Date

    var discoveryInfo: [String: String] {
        [
            "ownerID": ownerID,
            "ownerName": ownerName,
            "drinkCount": "\(drinkCount)",
            "effectiveDrinkCount": "\(effectiveDrinkCount)",
            "averageRating": String(format: "%.2f", averageRating),
            "exportedAt": ISO8601DateFormatter().string(from: exportedAt),
            "packageVersion": "\(SharedCompendiumStore.packageVersion)"
        ]
    }
}

struct NearbyInvitation: Identifiable {
    enum Mode {
        case receivingCompendium
        case sharingMine

        var title: String {
            switch self {
            case .receivingCompendium:
                return "接收档案"
            case .sharingMine:
                return "发送档案"
            }
        }
    }

    let id = UUID()
    let peerName: String
    let mode: Mode
}

private struct NearbyInviteContext: Codable {
    enum Action: String, Codable {
        case sendCompendium
        case requestCompendium
    }

    let action: Action
}

private struct NearbyControlMessage: Codable {
    enum Action: String, Codable {
        case requestCompendium
    }

    let action: Action
}

enum NearbyDisplayNameStore {
    private static let displayNameKey = "NearbyTransferDisplayName"
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
        let baseName = (!deviceName.isEmpty && !genericNames.contains(deviceName)) ? deviceName : "我的档案"
        return cleanDisplayName(baseName)
    }

    static func cleanDisplayName(_ name: String) -> String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = cleaned.isEmpty ? "我的档案" : cleaned
        let nameWithoutOldSuffix = baseName
            .replacingOccurrences(
            of: #"·[A-F0-9]{4}$"#,
            with: "",
            options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((nameWithoutOldSuffix.isEmpty ? "我的档案" : nameWithoutOldSuffix).prefix(48))
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
    @Published var pendingInvitation: NearbyInvitation?

    var onReceivedPackage: ((URL) -> Void)?
    var onSentPackage: ((NearbyPeer) -> Void)?
    var makePackageData: (() async throws -> Data)?

    private static let serviceType = "mtc-share"
    private let summary: NearbyLocalSummary
    private let localPeerID: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private var pendingInvitationHandler: ((Bool, MCSession?) -> Void)?
    private var pendingResourceURL: URL?
    private var pendingPeerID: MCPeerID?
    private var pendingRequestPeerID: MCPeerID?
    private var sendTimeoutID: UUID?

    init(summary: NearbyLocalSummary) {
        self.summary = summary
        localPeerID = MCPeerID(displayName: summary.ownerName)
        session = MCSession(peer: localPeerID, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(
            peer: localPeerID,
            discoveryInfo: summary.discoveryInfo,
            serviceType: Self.serviceType
        )
        browser = MCNearbyServiceBrowser(peer: localPeerID, serviceType: Self.serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    var localDisplayName: String {
        localPeerID.displayName
    }

    func start() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        statusMessage = "正在寻找附近设备"
    }

    func stop() {
        sendTimeoutID = nil
        browser.stopBrowsingForPeers()
        advertiser.stopAdvertisingPeer()
        session.disconnect()
    }

    func prepareToShare() {
        isSending = true
        statusMessage = "正在准备档案文件"
    }

    func finishPreparingShare() {
        isSending = false
        statusMessage = "档案文件已准备好"
    }

    func sendMine(to peer: NearbyPeer) {
        statusMessage = "正在连接 \(peer.name)"
        isSending = true
        pendingPeerID = peer.peerID
        if session.connectedPeers.contains(peer.peerID) {
            prepareAndSendPackage(to: peer.peerID)
            return
        }
        invite(peer, action: .sendCompendium)
    }

    func requestCompendium(from peer: NearbyPeer) {
        statusMessage = "正在请求 \(peer.name) 的档案"
        isSending = true
        pendingRequestPeerID = peer.peerID
        if session.connectedPeers.contains(peer.peerID) {
            sendRequestMessage(to: peer.peerID)
            scheduleSendTimeout(for: peer)
            return
        }
        invite(peer, action: .requestCompendium)
    }

    func acceptInvitation() {
        pendingInvitationHandler?(true, session)
        pendingInvitationHandler = nil
        pendingInvitation = nil
        statusMessage = "正在建立连接"
    }

    func declineInvitation() {
        pendingInvitationHandler?(false, nil)
        pendingInvitationHandler = nil
        pendingInvitation = nil
        statusMessage = "已拒绝邀请"
    }

    func disconnect(from peer: NearbyPeer) {
        if session.connectedPeers.contains(peer.peerID) {
            session.disconnect()
        }
        sendTimeoutID = nil
        pendingPeerID = nil
        pendingRequestPeerID = nil
        isSending = false
        statusMessage = "已断开 \(peer.name)"
    }

    func failPendingSend(_ message: String) {
        isSending = false
        if let pendingResourceURL {
            try? FileManager.default.removeItem(at: pendingResourceURL)
        }
        sendTimeoutID = nil
        pendingResourceURL = nil
        pendingPeerID = nil
        pendingRequestPeerID = nil
        statusMessage = message
    }

    private func invite(_ peer: NearbyPeer, action: NearbyInviteContext.Action) {
        let context = NearbyInviteContext(action: action)
        let data = try? JSONEncoder().encode(context)
        browser.invitePeer(peer.peerID, to: session, withContext: data, timeout: 30)
        scheduleSendTimeout(for: peer)
    }

    private func prepareAndSendPackage(to peerID: MCPeerID) {
        guard let makePackageData else {
            failPendingSend("没有可发送的档案数据")
            return
        }

        isSending = true
        statusMessage = "正在打包档案"
        Task {
            do {
                let data = try await makePackageData()
                try Task.checkCancellation()
                let url = try await Self.writeTemporaryPackage(data)
                await MainActor.run {
                    self.pendingResourceURL = url
                    self.pendingPeerID = peerID
                    self.sendPendingResource()
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.failPendingSend("发送已取消")
                }
            } catch {
                await MainActor.run {
                    self.failPendingSend("发送失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private static func writeTemporaryPackage(_ data: Data) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mtcpack")
            try data.write(to: url, options: .atomic)
            return url
        }.value
    }

    private func sendPendingResource() {
        sendTimeoutID = nil
        guard let url = pendingResourceURL,
              let peerID = pendingPeerID,
              session.connectedPeers.contains(peerID) else {
            return
        }

        statusMessage = "正在发送档案"
        session.sendResource(at: url, withName: url.lastPathComponent, toPeer: peerID) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                let sentPeer = self.peers.first { $0.peerID == peerID }
                self.isSending = false
                self.pendingResourceURL = nil
                self.pendingPeerID = nil
                try? FileManager.default.removeItem(at: url)
                if let error {
                    self.statusMessage = "发送失败：\(error.localizedDescription)"
                } else {
                    if let sentPeer {
                        self.onSentPackage?(sentPeer)
                    }
                    self.statusMessage = "已发送"
                }
            }
        }
    }

    private func sendRequestMessage(to peerID: MCPeerID) {
        let message = NearbyControlMessage(action: .requestCompendium)
        guard let data = try? JSONEncoder().encode(message) else { return }
        do {
            try session.send(data, toPeers: [peerID], with: .reliable)
            statusMessage = "已请求对方档案"
        } catch {
            failPendingSend("请求失败：\(error.localizedDescription)")
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self,
                  self.sendTimeoutID == timeoutID,
                  self.pendingPeerID == peer.peerID || self.pendingRequestPeerID == peer.peerID,
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
            guard let stableID = info?["ownerID"],
                  stableID != self.summary.ownerID else { return }
            let date = info?["exportedAt"].flatMap { ISO8601DateFormatter().date(from: $0) }
            let peer = NearbyPeer(
                peerID: peerID,
                stableID: stableID,
                ownerName: info?["ownerName"] ?? peerID.displayName,
                drinkCount: Int(info?["drinkCount"] ?? "") ?? 0,
                effectiveDrinkCount: Int(info?["effectiveDrinkCount"] ?? "") ?? Int(info?["drinkCount"] ?? "") ?? 0,
                averageRating: Double(info?["averageRating"] ?? "") ?? 0,
                exportedAt: date
            )
            self.peers.removeAll { $0.id == peer.id }
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

extension NearbyTransferManager: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        updateStatus("广播失败：\(error.localizedDescription)")
    }

    func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        DispatchQueue.main.async {
            let invite = context.flatMap { try? JSONDecoder().decode(NearbyInviteContext.self, from: $0) }
            let mode: NearbyInvitation.Mode = invite?.action == .requestCompendium ? .sharingMine : .receivingCompendium
            self.pendingInvitationHandler = invitationHandler
            self.pendingInvitation = NearbyInvitation(peerName: peerID.displayName, mode: mode)
            self.statusMessage = "收到 \(peerID.displayName) 的邀请"
        }
    }
}

extension NearbyTransferManager: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            switch state {
            case .connected:
                self.statusMessage = "已连接 \(peerID.displayName)"
                if self.pendingPeerID == peerID {
                    self.prepareAndSendPackage(to: peerID)
                } else if self.pendingRequestPeerID == peerID {
                    self.sendRequestMessage(to: peerID)
                }
            case .connecting:
                self.statusMessage = "正在连接 \(peerID.displayName)"
            case .notConnected:
                if self.pendingPeerID == peerID || self.pendingRequestPeerID == peerID {
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
            self.isSending = false
            self.sendTimeoutID = nil
            self.pendingRequestPeerID = nil
            self.statusMessage = "已收到 \(peerID.displayName) 的档案"
            self.onReceivedPackage?(localURL)
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let message = try? JSONDecoder().decode(NearbyControlMessage.self, from: data),
              message.action == .requestCompendium else { return }
        DispatchQueue.main.async {
            self.prepareAndSendPackage(to: peerID)
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}

    func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {
        updateStatus("正在接收 \(peerID.displayName) 的档案")
    }
}
