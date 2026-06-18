import MultipeerConnectivity
import SwiftUI

struct NearbyTransferView: View {
    let drinks: [Drink]
    let sharedStore: SharedCompendiumStore
    let onImported: (SharedCompendium) -> Void

    @AppStorage("NearbyTransferDisplayName") private var savedDisplayName = NearbyDisplayNameStore.displayName
    @State private var draftDisplayName = NearbyDisplayNameStore.displayName

    var body: some View {
        NearbyTransferSessionView(
            drinks: drinks,
            sharedStore: sharedStore,
            displayName: NearbyDisplayNameStore.cleanDisplayName(savedDisplayName),
            draftDisplayName: $draftDisplayName,
            onSaveDisplayName: { name in
                let cleaned = NearbyDisplayNameStore.cleanDisplayName(name)
                NearbyDisplayNameStore.displayName = cleaned
                savedDisplayName = cleaned
                draftDisplayName = cleaned
            },
            onImported: onImported
        )
        .id(savedDisplayName)
    }
}

private struct NearbyTransferSessionView: View {
    let drinks: [Drink]
    let sharedStore: SharedCompendiumStore
    let displayName: String
    @Binding var draftDisplayName: String
    let onSaveDisplayName: (String) -> Void
    let onImported: (SharedCompendium) -> Void

    @StateObject private var manager = NearbyTransferManager()
    @State private var message: String?
    @State private var sendTask: Task<Void, Never>?
    @State private var showingSystemBrowser = false
    @State private var sharePackage: SharePackage?

    init(
        drinks: [Drink],
        sharedStore: SharedCompendiumStore,
        displayName: String,
        draftDisplayName: Binding<String>,
        onSaveDisplayName: @escaping (String) -> Void,
        onImported: @escaping (SharedCompendium) -> Void
    ) {
        self.drinks = drinks
        self.sharedStore = sharedStore
        self.displayName = displayName
        _draftDisplayName = draftDisplayName
        self.onSaveDisplayName = onSaveDisplayName
        self.onImported = onImported
        _manager = StateObject(wrappedValue: NearbyTransferManager(displayName: displayName))
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                identityCard

                statusCard

                Button {
                    shareWithSystemSheet()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("用 AirDrop/系统分享发送")
                                .font(.body.weight(.semibold))
                            Text("Multipeer 连接失败时使用这个离线兜底")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "square.and.arrow.up")
                            .font(.headline)
                    }
                    .padding()
                    .foregroundStyle(.primary)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(manager.isSending)

                VStack(alignment: .leading, spacing: 10) {
                    Text("附近设备")
                        .font(.headline)

                    if manager.peers.isEmpty {
                        ContentUnavailableView("等待附近设备", systemImage: "dot.radiowaves.left.and.right", description: Text("让对方也打开互传页面"))
                            .frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        ForEach(manager.peers) { peer in
                            Button {
                                send(to: peer)
                            } label: {
                                HStack {
                                    Text(peer.name)
                                        .font(.body.weight(.medium))
                                    Spacer()
                                    Text("连接并发送")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .padding()
                                .background(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(manager.isSending)
                        }
                    }
                }

                Spacer()
            }
            .padding(18)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("近场互传")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                draftDisplayName = manager.localDisplayName
                manager.onReceivedPackage = importPackage(at:)
                manager.start()
            }
            .onDisappear {
                sendTask?.cancel()
                manager.stop()
            }
            .alert("互传", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
            .sheet(isPresented: $showingSystemBrowser) {
                NearbySystemBrowserView(manager: manager) {
                    showingSystemBrowser = false
                }
                .ignoresSafeArea()
            }
            .sheet(item: $sharePackage) { package in
                ActivityShareView(items: [package.url])
                    .ignoresSafeArea()
            }
        }
    }

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("本机 ID")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                TextField("本机 ID", text: $draftDisplayName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Button("保存") {
                    onSaveDisplayName(draftDisplayName)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.black)
                .clipShape(Capsule())
            }

            Text("附近设备会看到这个名字")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            ProgressView()
                .opacity(manager.isSending || manager.peers.isEmpty ? 1 : 0)

            Text(manager.statusMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding()
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func send(to peer: NearbyPeer) {
        sendTask?.cancel()
        message = nil
        manager.prepareToSend(to: peer)
        let ownerName = manager.localDisplayName
        let snapshots = SharedCompendiumStore.exportSnapshots(from: drinks)

        sendTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(120))
                try Task.checkCancellation()
                let data = try await SharedCompendiumStore.exportArchiveData(
                    from: snapshots,
                    ownerName: ownerName
                )
                try Task.checkCancellation()
                await MainActor.run {
                    do {
                        try manager.prepareSystemBrowserSend(data, targetName: peer.name)
                        showingSystemBrowser = true
                    } catch {
                        manager.failPendingSend("发送失败：\(error.localizedDescription)")
                        message = error.localizedDescription
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    manager.failPendingSend("发送已取消")
                }
            } catch {
                await MainActor.run {
                    manager.failPendingSend("发送失败：\(error.localizedDescription)")
                    message = error.localizedDescription
                }
            }
        }
    }

    private func shareWithSystemSheet() {
        sendTask?.cancel()
        message = nil
        manager.prepareToShare()
        let ownerName = manager.localDisplayName
        let snapshots = SharedCompendiumStore.exportSnapshots(from: drinks)

        sendTask = Task {
            do {
                let data = try await SharedCompendiumStore.exportArchiveData(
                    from: snapshots,
                    ownerName: ownerName
                )
                let url = try await writeSharePackage(data: data, ownerName: ownerName)
                try Task.checkCancellation()
                await MainActor.run {
                    manager.finishPreparingShare()
                    sharePackage = SharePackage(url: url)
                }
            } catch is CancellationError {
                await MainActor.run {
                    manager.failPendingSend("发送已取消")
                }
            } catch {
                await MainActor.run {
                    manager.failPendingSend("分享失败：\(error.localizedDescription)")
                    message = error.localizedDescription
                }
            }
        }
    }

    private func writeSharePackage(data: Data, ownerName: String) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let safeName = ownerName
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(safeName)-奶茶图鉴")
                .appendingPathExtension("mtcpack")
            try data.write(to: url, options: .atomic)
            return url
        }.value
    }

    private func importPackage(at url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let compendium = try sharedStore.importArchiveData(data)
            onImported(compendium)
            message = "已导入 \(compendium.ownerName) 的天梯图"
        } catch {
            message = error.localizedDescription
        }
    }
}

private struct SharePackage: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ActivityShareView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct NearbySystemBrowserView: UIViewControllerRepresentable {
    let manager: NearbyTransferManager
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> MCBrowserViewController {
        manager.makeSystemBrowserViewController(delegate: context.coordinator)
    }

    func updateUIViewController(_ uiViewController: MCBrowserViewController, context: Context) {}

    final class Coordinator: NSObject, MCBrowserViewControllerDelegate {
        let parent: NearbySystemBrowserView

        init(parent: NearbySystemBrowserView) {
            self.parent = parent
        }

        func browserViewControllerDidFinish(_ browserViewController: MCBrowserViewController) {
            parent.manager.sendToFirstConnectedPeerIfReady()
            parent.manager.resumePeerBrowsing()
            parent.onDismiss()
        }

        func browserViewControllerWasCancelled(_ browserViewController: MCBrowserViewController) {
            parent.manager.cancelSystemBrowserSelectionIfNeeded()
            parent.manager.resumePeerBrowsing()
            parent.onDismiss()
        }

        func browserViewController(
            _ browserViewController: MCBrowserViewController,
            shouldPresentNearbyPeer peerID: MCPeerID,
            withDiscoveryInfo info: [String: String]?
        ) -> Bool {
            parent.manager.shouldShowSystemPeer(peerID, discoveryInfo: info)
        }
    }
}
