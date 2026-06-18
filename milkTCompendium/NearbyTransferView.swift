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
    enum PeerFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case notImported = "未导入"
        case imported = "已导入"

        var id: String { rawValue }
    }

    let drinks: [Drink]
    let sharedStore: SharedCompendiumStore
    let displayName: String
    @Binding var draftDisplayName: String
    let onSaveDisplayName: (String) -> Void
    let onImported: (SharedCompendium) -> Void

    @StateObject private var manager: NearbyTransferManager
    @State private var message: String?
    @State private var sharePackage: SharePackage?
    @State private var selectedPeer: NearbyPeer?
    @State private var searchText = ""
    @State private var filter: PeerFilter = .all

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
        _manager = StateObject(wrappedValue: NearbyTransferManager(summary: Self.summary(for: drinks, displayName: displayName)))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    myCard
                    statusCard
                    controls
                    partyWall
                }
                .padding(18)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("近场互传")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            shareWithSystemSheet()
                        } label: {
                            Label("AirDrop/系统分享", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .onAppear {
                draftDisplayName = manager.localDisplayName
                manager.onReceivedPackage = importPackage(at:)
                manager.makePackageData = makePackageData
                manager.start()
            }
            .onDisappear {
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
            .alert(item: $manager.pendingInvitation) { invitation in
                Alert(
                    title: Text(invitation.mode.title),
                    message: Text(invitation.mode == .receivingCompendium ? "\(invitation.peerName) 想发送图鉴给你" : "\(invitation.peerName) 想查看你的图鉴"),
                    primaryButton: .default(Text("同意")) {
                        manager.acceptInvitation()
                    },
                    secondaryButton: .cancel(Text("拒绝")) {
                        manager.declineInvitation()
                    }
                )
            }
            .sheet(item: $selectedPeer) { peer in
                PeerExchangePanel(
                    peer: peer,
                    isImported: isImported(peer),
                    onSend: {
                        manager.sendMine(to: peer)
                        selectedPeer = nil
                    },
                    onRequest: {
                        manager.requestCompendium(from: peer)
                        selectedPeer = nil
                    },
                    onDisconnect: {
                        manager.disconnect(from: peer)
                        selectedPeer = nil
                    }
                )
                .presentationDetents([.height(310)])
            }
            .sheet(item: $sharePackage) { package in
                ActivityShareView(items: [package.url])
                    .ignoresSafeArea()
            }
        }
    }

    private var myCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("我的图鉴")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(displayName)
                        .font(.title3.weight(.semibold))
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(drinks.count) 杯")
                        .font(.headline)
                    Text(String(format: "均分 %.2f", averageRating))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                TextField("本机 ID", text: $draftDisplayName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
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
        }
        .padding()
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
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

    private var controls: some View {
        VStack(spacing: 10) {
            TextField("搜索附近的人", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(.white)
                .clipShape(Capsule())

            Picker("筛选", selection: $filter) {
                ForEach(PeerFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var partyWall: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("附近的人")
                .font(.headline)

            if filteredPeers.isEmpty {
                ContentUnavailableView(
                    "等待附近的人",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text("让对方也打开近场互传")
                )
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(filteredPeers) { peer in
                        Button {
                            selectedPeer = peer
                        } label: {
                            PeerCard(peer: peer, isImported: isImported(peer))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var averageRating: Double {
        guard !drinks.isEmpty else { return 0 }
        return drinks.map(\.rating).reduce(0, +) / Double(drinks.count)
    }

    private var filteredPeers: [NearbyPeer] {
        manager.peers.filter { peer in
            let imported = isImported(peer)
            let matchesFilter = switch filter {
            case .all:
                true
            case .notImported:
                !imported
            case .imported:
                imported
            }
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchesSearch = query.isEmpty || peer.name.localizedCaseInsensitiveContains(query)
            return matchesFilter && matchesSearch
        }
    }

    private func isImported(_ peer: NearbyPeer) -> Bool {
        sharedStore.compendiums.contains { $0.ownerID == peer.stableID }
    }

    private func makePackageData() async throws -> Data {
        let snapshots = SharedCompendiumStore.exportSnapshots(from: drinks)
        return try await SharedCompendiumStore.exportArchiveData(
            from: snapshots,
            ownerName: manager.localDisplayName
        )
    }

    private func shareWithSystemSheet() {
        manager.prepareToShare()
        Task {
            do {
                let data = try await makePackageData()
                let url = try await writeSharePackage(data: data, ownerName: manager.localDisplayName)
                await MainActor.run {
                    manager.finishPreparingShare()
                    sharePackage = SharePackage(url: url)
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

    private static func summary(for drinks: [Drink], displayName: String) -> NearbyLocalSummary {
        let average = drinks.isEmpty ? 0 : drinks.map(\.rating).reduce(0, +) / Double(drinks.count)
        return NearbyLocalSummary(
            ownerID: SharedCompendiumStore.localOwnerID,
            ownerName: displayName,
            drinkCount: drinks.count,
            averageRating: average,
            exportedAt: .now
        )
    }
}

private struct PeerCard: View {
    let peer: NearbyPeer
    let isImported: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(peer.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Circle()
                    .fill(isImported ? .green : .black)
                    .frame(width: 8, height: 8)
            }

            HStack(spacing: 10) {
                stat("\(peer.drinkCount)", "杯")
                stat(String(format: "%.2f", peer.averageRating), "均分")
            }

            Text(isImported ? "已导入" : "可交换")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isImported ? .green : .secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.semibold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PeerExchangePanel: View {
    let peer: NearbyPeer
    let isImported: Bool
    let onSend: () -> Void
    let onRequest: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Capsule()
                .fill(.secondary.opacity(0.28))
                .frame(width: 42, height: 5)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 5) {
                Text(peer.name)
                    .font(.title2.weight(.semibold))
                Text("\(peer.drinkCount) 杯 · 均分 \(String(format: "%.2f", peer.averageRating)) · \(isImported ? "已导入" : "未导入")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button(action: onSend) {
                Label("发送我的图鉴", systemImage: "arrow.up.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button(action: onRequest) {
                Label("请求对方图鉴", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button("断开连接", role: .destructive, action: onDisconnect)
                .frame(maxWidth: .infinity)
        }
        .padding(22)
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
