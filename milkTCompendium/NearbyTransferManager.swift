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
        case exchangingCompendium

        var title: String {
            switch self {
            case .exchangingCompendium:
                return "交换档案"
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
        case exchangeCompendium
    }

    let action: Action
}

private struct NearbyControlMessage: Codable {
    enum Action: String, Codable {
        case requestCompendium
        case exchangeCompendium
        case cancelExchange
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
    private var pendingExchangePeerID: MCPeerID?
    private var activeSendPeerID: MCPeerID?
    private var activeSendTask: Task<Void, Never>?
    private var activeSendOperationID: UUID?
    private var sendTimeoutID: UUID?
    private var exchangeSentPeerIDs: Set<MCPeerID> = []
    private var exchangeReceivedPeerIDs: Set<MCPeerID> = []
    private var cancelledExchangePeerIDs: Set<MCPeerID> = []

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
        cancelCurrentExchange(notifyPeer: true, statusMessage: nil)
        activeSendTask?.cancel()
        activeSendTask = nil
        activeSendPeerID = nil
        activeSendOperationID = nil
        sendTimeoutID = nil
        browser.stopBrowsingForPeers()
        advertiser.stopAdvertisingPeer()
        session.disconnect()
    }

    func exchange(with peer: NearbyPeer) {
        resetExchangeProgress(for: peer.peerID)
        statusMessage = "正在连接 \(peer.name) 交换档案"
        isSending = true
        pendingExchangePeerID = peer.peerID
        if session.connectedPeers.contains(peer.peerID) {
            guard sendExchangeMessage(to: peer.peerID) else { return }
            prepareAndSendPackage(to: peer.peerID)
            return
        }
        invite(peer, action: .exchangeCompendium)
    }

    func acceptInvitation() {
        pendingInvitationHandler?(true, session)
        pendingInvitationHandler = nil
        pendingInvitation = nil
        statusMessage = "正在建立交换连接"
    }

    func declineInvitation() {
        if let peerID = pendingExchangePeerID {
            sendControlMessage(.cancelExchange, to: peerID)
        }
        pendingInvitationHandler?(false, nil)
        pendingInvitationHandler = nil
        pendingInvitation = nil
        pendingExchangePeerID = nil
        statusMessage = "已拒绝邀请"
    }

    func disconnect(from peer: NearbyPeer) {
        let isCurrentExchangePeer = pendingPeerID == peer.peerID
            || pendingExchangePeerID == peer.peerID
            || activeSendPeerID == peer.peerID
        if isCurrentExchangePeer {
            cancelledExchangePeerIDs.insert(peer.peerID)
            sendControlMessage(.cancelExchange, to: peer.peerID)
        }
        if session.connectedPeers.contains(peer.peerID) {
            session.disconnect()
        }
        if activeSendPeerID == peer.peerID {
            activeSendTask?.cancel()
            activeSendTask = nil
            activeSendPeerID = nil
            activeSendOperationID = nil
        }
        if pendingPeerID == peer.peerID, let pendingResourceURL {
            try? FileManager.default.removeItem(at: pendingResourceURL)
            self.pendingResourceURL = nil
        }
        sendTimeoutID = nil
        pendingPeerID = nil
        pendingExchangePeerID = nil
        clearExchangeProgress(for: peer.peerID)
        isSending = false
        statusMessage = "已断开 \(peer.name)"
    }

    func cancelCurrentExchange() {
        cancelCurrentExchange(notifyPeer: true, statusMessage: "已取消交换")
    }

    func failPendingSend(_ message: String) {
        activeSendTask?.cancel()
        activeSendTask = nil
        activeSendPeerID = nil
        activeSendOperationID = nil
        isSending = false
        if let pendingResourceURL {
            try? FileManager.default.removeItem(at: pendingResourceURL)
        }
        sendTimeoutID = nil
        pendingResourceURL = nil
        pendingPeerID = nil
        if let pendingExchangePeerID {
            clearExchangeProgress(for: pendingExchangePeerID)
        }
        pendingExchangePeerID = nil
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
        if let activeSendPeerID {
            if activeSendPeerID == peerID {
                return
            }
            statusMessage = "正在交换档案，请稍后再试"
            return
        }

        activeSendPeerID = peerID
        let operationID = UUID()
        activeSendOperationID = operationID
        isSending = true
        statusMessage = "正在打包档案"
        activeSendTask = Task {
            do {
                let data = try await makePackageData()
                try Task.checkCancellation()
                let url = try await Self.writeTemporaryPackage(data)
                try Task.checkCancellation()
                await MainActor.run {
                    guard self.activeSendOperationID == operationID,
                          self.activeSendPeerID == peerID,
                          !self.cancelledExchangePeerIDs.contains(peerID) else {
                        try? FileManager.default.removeItem(at: url)
                        return
                    }
                    self.pendingResourceURL = url
                    self.pendingPeerID = peerID
                    self.sendPendingResource()
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard self.activeSendOperationID == operationID else { return }
                    self.failPendingSend("发送已取消")
                }
            } catch {
                await MainActor.run {
                    guard self.activeSendOperationID == operationID else { return }
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

    private static func copyReceivedPackage(from url: URL) throws -> URL {
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mtcpack")
        try FileManager.default.copyItem(at: url, to: destinationURL)
        return destinationURL
    }

    private func sendPendingResource() {
        sendTimeoutID = nil
        guard let url = pendingResourceURL,
              let peerID = pendingPeerID,
              session.connectedPeers.contains(peerID) else {
            failPendingSend("发送失败：连接已断开")
            return
        }

        let operationID = activeSendOperationID
        statusMessage = "正在交换档案"
        session.sendResource(at: url, withName: url.lastPathComponent, toPeer: peerID) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.activeSendOperationID == operationID,
                      self.activeSendPeerID == peerID,
                      !self.cancelledExchangePeerIDs.contains(peerID) else {
                    return
                }
                self.activeSendTask = nil
                self.activeSendPeerID = nil
                self.activeSendOperationID = nil
                self.pendingResourceURL = nil
                self.pendingPeerID = nil
                try? FileManager.default.removeItem(at: url)
                if let error {
                    self.statusMessage = "发送失败：\(error.localizedDescription)"
                    self.isSending = false
                } else {
                    self.markExchangeSent(to: peerID)
                }
            }
        }
    }

    private func sendExchangeMessage(to peerID: MCPeerID) -> Bool {
        guard sendControlMessage(.exchangeCompendium, to: peerID) else {
            return false
        }
        statusMessage = "已发起交换"
        return true
    }

    @discardableResult
    private func sendControlMessage(_ action: NearbyControlMessage.Action, to peerID: MCPeerID) -> Bool {
        let message = NearbyControlMessage(action: action)
        guard let data = try? JSONEncoder().encode(message) else { return false }
        do {
            try session.send(data, toPeers: [peerID], with: .reliable)
            return true
        } catch {
            if action != .cancelExchange {
                failPendingSend("交换失败：\(error.localizedDescription)")
            }
            return false
        }
    }

    private func cancelCurrentExchange(notifyPeer: Bool, statusMessage message: String?) {
        let peerID = pendingExchangePeerID ?? pendingPeerID ?? activeSendPeerID
        if let peerID {
            cancelledExchangePeerIDs.insert(peerID)
        }
        if notifyPeer, let peerID {
            sendControlMessage(.cancelExchange, to: peerID)
        }
        activeSendTask?.cancel()
        activeSendTask = nil
        activeSendPeerID = nil
        activeSendOperationID = nil
        if let pendingResourceURL {
            try? FileManager.default.removeItem(at: pendingResourceURL)
        }
        pendingResourceURL = nil
        pendingPeerID = nil
        if let peerID {
            clearExchangeProgress(for: peerID)
        }
        pendingExchangePeerID = nil
        sendTimeoutID = nil
        isSending = false
        pendingInvitationHandler?(false, nil)
        pendingInvitationHandler = nil
        pendingInvitation = nil
        if let peerID, session.connectedPeers.contains(peerID) {
            session.disconnect()
        }
        if let message {
            statusMessage = message
        }
    }

    private func resetExchangeProgress(for peerID: MCPeerID) {
        exchangeSentPeerIDs.remove(peerID)
        exchangeReceivedPeerIDs.remove(peerID)
        cancelledExchangePeerIDs.remove(peerID)
    }

    private func clearExchangeProgress(for peerID: MCPeerID) {
        exchangeSentPeerIDs.remove(peerID)
        exchangeReceivedPeerIDs.remove(peerID)
    }

    private func markExchangeSent(to peerID: MCPeerID) {
        exchangeSentPeerIDs.insert(peerID)
        updateExchangeCompletionStatus(with: peerID)
    }

    private func markExchangeReceived(from peerID: MCPeerID) {
        exchangeReceivedPeerIDs.insert(peerID)
        updateExchangeCompletionStatus(with: peerID)
    }

    private func updateExchangeCompletionStatus(with peerID: MCPeerID) {
        let didSend = exchangeSentPeerIDs.contains(peerID)
        let didReceive = exchangeReceivedPeerIDs.contains(peerID)
        isSending = didSend && didReceive ? false : pendingExchangePeerID == peerID
        if didSend && didReceive {
            sendTimeoutID = nil
            pendingExchangePeerID = nil
            clearExchangeProgress(for: peerID)
            statusMessage = "已完成与 \(peerID.displayName) 的交换"
        } else if didSend {
            statusMessage = "已送出，等待对方档案"
        } else if didReceive {
            statusMessage = "已收到对方档案，正在发送你的档案"
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
                  self.pendingPeerID == peer.peerID || self.pendingExchangePeerID == peer.peerID,
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
            guard invite?.action == .exchangeCompendium else {
                invitationHandler(false, nil)
                self.statusMessage = "\(peerID.displayName) 使用了旧版单向传输，请双方都更新后再交换"
                return
            }
            let mode: NearbyInvitation.Mode = .exchangingCompendium
            self.pendingInvitationHandler = invitationHandler
            self.pendingExchangePeerID = peerID
            self.resetExchangeProgress(for: peerID)
            self.pendingInvitation = NearbyInvitation(peerName: peerID.displayName, mode: mode)
            self.statusMessage = "收到 \(peerID.displayName) 的交换邀请"
        }
    }
}

extension NearbyTransferManager: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            switch state {
            case .connected:
                self.statusMessage = "已连接 \(peerID.displayName)"
                if self.pendingExchangePeerID == peerID || self.pendingPeerID == peerID {
                    self.prepareAndSendPackage(to: peerID)
                }
            case .connecting:
                self.statusMessage = "正在连接 \(peerID.displayName)"
            case .notConnected:
                if self.cancelledExchangePeerIDs.contains(peerID) {
                    return
                } else if self.pendingPeerID == peerID || self.pendingExchangePeerID == peerID {
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
            guard !self.cancelledExchangePeerIDs.contains(peerID) else {
                return
            }
            if let error {
                self.statusMessage = "接收失败：\(error.localizedDescription)"
                return
            }
            guard let localURL else {
                self.statusMessage = "接收失败"
                return
            }
            do {
                let receivedURL = try Self.copyReceivedPackage(from: localURL)
                self.isSending = false
                self.sendTimeoutID = nil
                self.markExchangeReceived(from: peerID)
                self.onReceivedPackage?(receivedURL)
            } catch {
                self.statusMessage = "接收失败：\(error.localizedDescription)"
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let message = try? JSONDecoder().decode(NearbyControlMessage.self, from: data) else { return }
        DispatchQueue.main.async {
            switch message.action {
            case .exchangeCompendium:
                self.resetExchangeProgress(for: peerID)
                self.pendingExchangePeerID = peerID
                self.prepareAndSendPackage(to: peerID)
            case .cancelExchange:
                self.cancelCurrentExchange(notifyPeer: false, statusMessage: "\(peerID.displayName) 已取消交换")
            case .requestCompendium:
                break
            }
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}

    func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {
        DispatchQueue.main.async {
            guard !self.cancelledExchangePeerIDs.contains(peerID) else {
                return
            }
            self.isSending = true
            self.statusMessage = "正在接收 \(peerID.displayName) 的档案"
        }
    }
}
