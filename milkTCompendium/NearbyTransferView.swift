import SwiftUI
import UniformTypeIdentifiers

struct NearbyTransferView: View {
    let drinks: [Drink]
    let sharedStore: SharedCompendiumStore
    @ObservedObject var tasteStatsStore: TasteExchangeStatsStore
    let canExportBackup: Bool
    let onImportBackup: (URL) -> Void
    let onExportBackup: () -> Void
    let onImported: (SharedCompendium) -> Void
    let onCompare: (SharedCompendium) -> Void
    let onDeleted: (SharedCompendium) -> Void

    @AppStorage("NearbyTransferDisplayName") private var savedDisplayName = NearbyDisplayNameStore.displayName

    var body: some View {
        NearbyTransferSessionView(
            drinks: drinks,
            sharedStore: sharedStore,
            tasteStatsStore: tasteStatsStore,
            displayName: NearbyDisplayNameStore.cleanDisplayName(savedDisplayName),
            onSaveDisplayName: { name in
                let cleaned = NearbyDisplayNameStore.cleanDisplayName(name)
                NearbyDisplayNameStore.displayName = cleaned
                savedDisplayName = cleaned
            },
            canExportBackup: canExportBackup,
            onImportBackup: onImportBackup,
            onExportBackup: onExportBackup,
            onImported: onImported,
            onCompare: onCompare,
            onDeleted: onDeleted
        )
        .id(savedDisplayName)
        .dismissKeyboardOnTap()
    }
}

private struct NearbyTransferSessionView: View {
    let drinks: [Drink]
    let sharedStore: SharedCompendiumStore
    @ObservedObject var tasteStatsStore: TasteExchangeStatsStore
    let displayName: String
    let onSaveDisplayName: (String) -> Void
    let canExportBackup: Bool
    let onImportBackup: (URL) -> Void
    let onExportBackup: () -> Void
    let onImported: (SharedCompendium) -> Void
    let onCompare: (SharedCompendium) -> Void
    let onDeleted: (SharedCompendium) -> Void

    @StateObject private var manager: NearbyTransferManager
    @State private var message: String?
    @State private var selectedPeer: NearbyPeer?
    @State private var pendingDeleteCompendium: SharedCompendium?
    @State private var searchText = ""
    @State private var showingDisplayNameEditor = false
    @State private var showingBackupImportPicker = false

    init(
        drinks: [Drink],
        sharedStore: SharedCompendiumStore,
        tasteStatsStore: TasteExchangeStatsStore,
        displayName: String,
        onSaveDisplayName: @escaping (String) -> Void,
        canExportBackup: Bool,
        onImportBackup: @escaping (URL) -> Void,
        onExportBackup: @escaping () -> Void,
        onImported: @escaping (SharedCompendium) -> Void,
        onCompare: @escaping (SharedCompendium) -> Void,
        onDeleted: @escaping (SharedCompendium) -> Void
    ) {
        self.drinks = drinks
        self.sharedStore = sharedStore
        self.tasteStatsStore = tasteStatsStore
        self.displayName = displayName
        self.onSaveDisplayName = onSaveDisplayName
        self.canExportBackup = canExportBackup
        self.onImportBackup = onImportBackup
        self.onExportBackup = onExportBackup
        self.onImported = onImported
        self.onCompare = onCompare
        self.onDeleted = onDeleted
        _manager = StateObject(wrappedValue: NearbyTransferManager(summary: Self.summary(for: drinks, displayName: displayName)))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SharedArchiveOverviewPanel(
                        displayName: displayName,
                        tasteScore: tasteScore,
                        profileCupCount: profileCupCount,
                        collectionCount: drinks.count,
                        averageRating: averageRating,
                        exchangeCount: tasteStatsStore.stats.successfulExchangeCount,
                        totalCupCountWithFriends: totalCupCountWithFriends,
                        totalCollectionCountWithFriends: totalCollectionCountWithFriends,
                        favoriteBrands: favoriteBrands
                    )

                    TransferRadarStrip(
                        isActive: manager.isSending,
                        statusMessage: manager.statusMessage,
                        nearbyCount: manager.peers.count,
                        onCancel: {
                            manager.cancelCurrentExchange()
                        }
                    )

                    archiveBrowser
                }
                .padding(18)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("档案")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showingDisplayNameEditor = true
                        } label: {
                            Label("修改档案名", systemImage: "person.text.rectangle")
                        }

                        Button {
                            showingBackupImportPicker = true
                        } label: {
                            Label("导入备份", systemImage: "square.and.arrow.down")
                        }

                        Button {
                            onExportBackup()
                        } label: {
                            Label("导出备份", systemImage: "square.and.arrow.up")
                        }
                        .disabled(!canExportBackup)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .onAppear {
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
                    message: Text("\(invitation.peerName) 想和你交换档案"),
                    primaryButton: .default(Text("同意")) {
                        manager.acceptInvitation()
                    },
                    secondaryButton: .cancel(Text("拒绝")) {
                        manager.declineInvitation()
                    }
                )
            }
            .confirmationDialog(
                "删除已经交换来的档案？",
                isPresented: Binding(
                    get: { pendingDeleteCompendium != nil },
                    set: { if !$0 { pendingDeleteCompendium = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let pendingDeleteCompendium {
                    Button("删除 \(pendingDeleteCompendium.ownerName) 的档案", role: .destructive) {
                        deleteSharedCompendium(pendingDeleteCompendium)
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                if let pendingDeleteCompendium {
                    Text("这会删除 \(pendingDeleteCompendium.ownerName) 已经交换来的档案、相关贴纸和交换统计。此操作不能撤销。")
                }
            }
            .sheet(item: $selectedPeer) { peer in
                PeerExchangePanel(
                    peer: peer,
                    importedCompendium: importedCompendium(for: peer),
                    onCompare: { compendium in
                        selectedPeer = nil
                        onCompare(compendium)
                    },
                    onExchange: {
                        manager.exchange(with: peer)
                        selectedPeer = nil
                    },
                    onDelete: { compendium in
                        selectedPeer = nil
                        pendingDeleteCompendium = compendium
                    },
                    onDisconnect: {
                        manager.disconnect(from: peer)
                        selectedPeer = nil
                    }
                )
                .presentationDetents([.height(importedCompendium(for: peer) == nil ? 250 : 370)])
            }
            .sheet(isPresented: $showingDisplayNameEditor) {
                DisplayNameEditor(
                    initialDisplayName: manager.localDisplayName,
                    onSave: { name in
                        showingDisplayNameEditor = false
                        DispatchQueue.main.async {
                            onSaveDisplayName(name)
                        }
                    }
                )
                .presentationDetents([.height(230)])
            }
            .fileImporter(
                isPresented: $showingBackupImportPicker,
                allowedContentTypes: [.milkTCompendiumPackage, .data],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    onImportBackup(url)
                case .failure(let error):
                    message = "导入失败: \(error.localizedDescription)"
                }
            }
        }
    }

    private var archiveBrowser: some View {
        VStack(alignment: .leading, spacing: 14) {
            archiveSearchField

            VStack(alignment: .leading, spacing: 18) {
                nearbyArchivesSection
                exchangedArchivesSection
            }
            .padding(14)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(.black.opacity(0.07), lineWidth: 1)
            )
        }
    }

    private var archiveSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("搜索附近档案", text: $searchText)
                .font(.subheadline)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
        }
        .padding(.horizontal, 13)
        .frame(height: 42)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.black.opacity(0.07), lineWidth: 1)
        )
    }

    private var nearbyArchivesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SharedArchiveSectionHeader(title: "附近档案", count: filteredPeers.count)

            if filteredPeers.isEmpty {
                SharedArchiveEmptyRow(
                    title: searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "等待附近档案" : "没有找到附近档案",
                    subtitle: searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "让对方也打开档案页。" : "换个名字试试看。"
                )
            } else {
                VStack(spacing: 8) {
                    ForEach(filteredPeers) { peer in
                        Button {
                            selectedPeer = peer
                        } label: {
                            SharedArchiveListRow(
                                title: peer.name,
                                subtitle: isImported(peer) ? "已交换档案 · 可更新" : "可交换档案",
                                metrics: [
                                    SharedArchiveMetric(value: "\(peer.drinkCount)", label: "总杯"),
                                    SharedArchiveMetric(value: String(format: "%.2f", peer.averageRating), label: "均分")
                                ],
                                status: isImported(peer) ? .exchanged : .nearby,
                                person: nil,
                                actionStyle: .chevron
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var exchangedArchivesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SharedArchiveSectionHeader(title: "已交换档案", count: sharedStore.compendiums.count)

            if sharedStore.compendiums.isEmpty {
                SharedArchiveEmptyRow(
                    title: "还没有交换来的档案",
                    subtitle: "和朋友交换后，可以在这里查看共饮或删除档案。"
                )
            } else {
                VStack(spacing: 8) {
                    ForEach(sharedStore.compendiums) { compendium in
                        ExchangedArchiveRow(
                            compendium: compendium,
                            pixelPerson: pixelPerson(for: compendium),
                            onCompare: {
                                onCompare(compendium)
                            },
                            onDelete: {
                                pendingDeleteCompendium = compendium
                            }
                        )
                    }
                }
            }
        }
    }

    private var averageRating: Double {
        guard !drinks.isEmpty else { return 0 }
        return drinks.map(\.rating).reduce(0, +) / Double(drinks.count)
    }

    private var profileCupCount: Int {
        TasteScoreCalculator.totalActualCupCount(drinks: drinks)
    }

    private var friendsCupCount: Int {
        tasteStatsStore.stats.peers.map(\.drinkCount).reduce(0, +)
    }

    private var totalCupCountWithFriends: Int {
        profileCupCount + friendsCupCount
    }

    private var totalCollectionCountWithFriends: Int {
        TasteScoreCalculator.fuzzyUniqueProductCount(
            localDrinks: drinks,
            peers: tasteStatsStore.stats.peers
        )
    }

    private var tasteScore: TasteScoreResult {
        TasteScoreCalculator.calculate(localDrinks: drinks, stats: tasteStatsStore.stats)
    }

    private var favoriteBrands: [FavoriteBrandSummary] {
        let grouped = Dictionary(grouping: drinks) { drink in
            let brand = drink.brand.trimmingCharacters(in: .whitespacesAndNewlines)
            return brand.isEmpty ? "未知品牌" : brand
        }

        return grouped.map { brand, drinks in
            FavoriteBrandSummary(
                brand: brand,
                drinkCount: drinks.map { max(1, $0.cupCount) }.reduce(0, +),
                averageRating: drinks.map(\.rating).reduce(0, +) / Double(drinks.count)
            )
        }
        .sorted {
            if $0.drinkCount == $1.drinkCount {
                if $0.averageRating == $1.averageRating {
                    return $0.brand.localizedStandardCompare($1.brand) == .orderedAscending
                }
                return $0.averageRating > $1.averageRating
            }
            return $0.drinkCount > $1.drinkCount
        }
        .prefix(3)
        .map { $0 }
    }

    private var filteredPeers: [NearbyPeer] {
        manager.peers.filter { peer in
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchesSearch = query.isEmpty || peer.name.localizedCaseInsensitiveContains(query)
            return matchesSearch
        }
    }

    private func isImported(_ peer: NearbyPeer) -> Bool {
        importedCompendium(for: peer) != nil
    }

    private func importedCompendium(for peer: NearbyPeer) -> SharedCompendium? {
        sharedStore.compendiums.first { $0.ownerID == peer.stableID }
    }

    private func pixelPerson(for compendium: SharedCompendium) -> PixelPersonProfile {
        tasteStatsStore.stats.peers.first { $0.ownerID == compendium.ownerID }?.pixelPerson
            ?? compendium.pixelPerson
            ?? PixelPersonProfile.make(compendium: compendium)
    }

    private func makePackageData() async throws -> Data {
        let snapshots = SharedCompendiumStore.exportSnapshots(from: drinks)
        return try await SharedCompendiumStore.exportArchiveData(
            from: snapshots,
            ownerName: manager.localDisplayName
        )
    }

    private func importPackage(at url: URL) {
        Task {
            defer {
                try? FileManager.default.removeItem(at: url)
            }
            do {
                let existingOwnerIDs = Set(sharedStore.compendiums.map(\.ownerID))
                let compendium = try await sharedStore.importArchive(at: url)
                let profile = TasteScoreCalculator.profile(from: compendium)
                tasteStatsStore.recordSuccessfulExchange(
                    ownerID: compendium.ownerID,
                    ownerName: compendium.ownerName,
                    drinkCount: TasteScoreCalculator.totalActualCupCount(profile: profile),
                    effectiveDrinkCount: TasteScoreCalculator.effectiveCupCount(profile: profile),
                    averageRating: TasteScoreCalculator.averageRating(profile: profile),
                    profile: profile,
                    pixelPerson: compendium.pixelPerson ?? PixelPersonProfile.make(compendium: compendium)
                )
                onImported(compendium)
                message = existingOwnerIDs.contains(compendium.ownerID)
                    ? "已更新 \(compendium.ownerName) 已经交换来的档案"
                    : "已保存 \(compendium.ownerName) 已经交换来的档案"
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func deleteSharedCompendium(_ compendium: SharedCompendium) {
        Task {
            do {
                try await sharedStore.deleteCompendium(ownerID: compendium.ownerID)
                tasteStatsStore.removePeer(ownerID: compendium.ownerID)
                onDeleted(compendium)
                message = "已删除 \(compendium.ownerName) 已经交换来的档案"
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private static func summary(for drinks: [Drink], displayName: String) -> NearbyLocalSummary {
        let average = drinks.isEmpty ? 0 : drinks.map(\.rating).reduce(0, +) / Double(drinks.count)
        return NearbyLocalSummary(
            ownerID: SharedCompendiumStore.localOwnerID,
            ownerName: displayName,
            drinkCount: TasteScoreCalculator.totalActualCupCount(drinks: drinks),
            effectiveDrinkCount: TasteScoreCalculator.effectiveCupCount(drinks: drinks),
            averageRating: average,
            exportedAt: .now
        )
    }
}

private struct FavoriteBrandSummary: Identifiable {
    let brand: String
    let drinkCount: Int
    let averageRating: Double

    var id: String {
        brand
    }
}

private enum ArchiveReferenceTypography {
    static func title(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold)
    }

    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .rounded).monospacedDigit()
    }

    static func terminal(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

private struct SharedArchiveMetric: Identifiable {
    let value: String
    let label: String

    var id: String {
        "\(label)-\(value)"
    }
}

private enum SharedArchiveRowStatus {
    case nearby
    case exchanged
    case local

    var text: String {
        switch self {
        case .nearby:
            "附近"
        case .exchanged:
            "已交换"
        case .local:
            "我的"
        }
    }

    var color: Color {
        switch self {
        case .nearby:
            .secondary
        case .exchanged:
            Color(red: 0.10, green: 0.57, blue: 0.31)
        case .local:
            .primary
        }
    }
}

private enum SharedArchiveRowActionStyle {
    case chevron
    case menu
    case none
}

private struct SharedArchiveOverviewPanel: View {
    let displayName: String
    let tasteScore: TasteScoreResult
    let profileCupCount: Int
    let collectionCount: Int
    let averageRating: Double
    let exchangeCount: Int
    let totalCupCountWithFriends: Int
    let totalCollectionCountWithFriends: Int
    let favoriteBrands: [FavoriteBrandSummary]

    private var personalMetrics: [SharedArchiveMetric] {
        [
            SharedArchiveMetric(value: "\(profileCupCount)", label: "我的总杯"),
            SharedArchiveMetric(value: "\(collectionCount)", label: "我的收集"),
            SharedArchiveMetric(value: String(format: "%.2f", averageRating), label: "我的均分"),
            SharedArchiveMetric(value: "\(exchangeCount)", label: "交换次数")
        ]
    }

    private var sharedMetrics: [SharedArchiveMetric] {
        [
            SharedArchiveMetric(value: "\(totalCupCountWithFriends)", label: "合计总杯"),
            SharedArchiveMetric(value: "\(totalCollectionCountWithFriends)", label: "合计收集")
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(displayName)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(profileCupCount) 杯 · \(collectionCount) 项 · \(tasteScore.levelName)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 10)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(String(format: "%.2f", tasteScore.score))
                        .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                    Text("档案分")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            metricGroup(title: "我的记录", metrics: personalMetrics, columnCount: 4)
            metricGroup(title: "和朋友一起", metrics: sharedMetrics, columnCount: 2)

            VStack(alignment: .leading, spacing: 8) {
                Text("常喝品牌")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)

                if favoriteBrands.isEmpty {
                    Text("记录几杯之后，这里会显示你的口味趋势。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                } else {
                    VStack(spacing: 7) {
                        ForEach(Array(favoriteBrands.enumerated()), id: \.element.id) { index, brand in
                            FavoriteBrandRow(rank: index + 1, summary: brand)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.black.opacity(0.07), lineWidth: 1)
        )
    }

    private func metricGroup(title: String, metrics: [SharedArchiveMetric], columnCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columnCount),
                spacing: 8
            ) {
                ForEach(metrics) { metric in
                    SharedArchiveMetricCell(metric: metric)
                }
            }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground).opacity(0.56))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.black.opacity(0.045), lineWidth: 1)
        )
    }
}

private struct SharedArchiveMetricCell: View {
    let metric: SharedArchiveMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(metric.value)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(metric.label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.systemBackground).opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.black.opacity(0.04), lineWidth: 1)
        )
    }
}

private struct TransferRadarStrip: View {
    let isActive: Bool
    let statusMessage: String
    let nearbyCount: Int
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(tint.opacity(isActive ? 0.16 : 0.10))
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(tint)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text("交换雷达")
                    .font(.subheadline.weight(.bold))
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if isActive {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .tint(.orange)
                .accessibilityLabel("取消交换")
            } else if nearbyCount == 0 {
                ProgressView()
                    .tint(.secondary)
            } else {
                Text("\(nearbyCount)")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(Capsule())
                    .accessibilityLabel("附近 \(nearbyCount) 个档案")
            }
        }
        .padding(14)
        .background(isActive ? Color.orange.opacity(0.07) : .white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isActive ? Color.orange.opacity(0.34) : Color.black.opacity(0.07), lineWidth: 1)
        )
    }

    private var tint: Color {
        isActive ? .orange : Color(red: 0.10, green: 0.57, blue: 0.31)
    }
}

private struct SharedArchiveSectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.bold))
            Spacer()
            Text("\(count) 个")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

private struct SharedArchiveEmptyRow: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct SharedArchiveListRow: View {
    let title: String
    let subtitle: String
    let metrics: [SharedArchiveMetric]
    let status: SharedArchiveRowStatus
    let person: PixelPersonProfile?
    let actionStyle: SharedArchiveRowActionStyle

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            avatar

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(subtitle)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 6)

                    Text(status.text)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(status.color)
                        .padding(.horizontal, 7)
                        .frame(height: 21)
                        .background(status.color.opacity(status == .nearby ? 0.07 : 0.10))
                        .clipShape(Capsule())
                }

                HStack(spacing: 7) {
                    ForEach(metrics) { metric in
                        SharedArchiveMiniMetric(metric: metric)
                    }
                }
            }

            trailingIcon
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground).opacity(0.62))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(status == .exchanged ? Color.green.opacity(0.18) : Color.black.opacity(0.05), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var avatar: some View {
        if let person {
            PixelTinyPersonView(profile: person)
                .frame(width: 34, height: 40)
                .accessibilityLabel("\(title) 的像素小小人")
        } else {
            Circle()
                .fill(Color(.systemBackground))
                .overlay(
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                )
                .frame(width: 36, height: 36)
        }
    }

    @ViewBuilder
    private var trailingIcon: some View {
        switch actionStyle {
        case .chevron:
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.tertiary)
                .frame(width: 14)
        case .menu, .none:
            EmptyView()
        }
    }
}

private struct SharedArchiveMiniMetric: View {
    let metric: SharedArchiveMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(metric.value)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(metric.label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(.systemBackground).opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct ExchangedArchiveRow: View {
    let compendium: SharedCompendium
    let pixelPerson: PixelPersonProfile
    let onCompare: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            SharedArchiveListRow(
                title: compendium.ownerName,
                subtitle: "已经交换来的档案",
                metrics: [
                    SharedArchiveMetric(value: "\(cupCount)", label: "总杯"),
                    SharedArchiveMetric(value: "\(compendium.drinks.count)", label: "收集")
                ],
                status: .exchanged,
                person: pixelPerson,
                actionStyle: .none
            )

            Menu {
                Button(action: onCompare) {
                    Label("查看共饮", systemImage: "rectangle.split.2x1")
                }

                Button(role: .destructive, action: onDelete) {
                    Label("删除档案", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(Circle())
            }
            .accessibilityLabel("\(compendium.ownerName) 的档案操作")
        }
    }

    private var cupCount: Int {
        compendium.drinks.map { max(1, $0.cupCount) }.reduce(0, +)
    }
}

private struct FavoriteBrandRow: View {
    let rank: Int
    let summary: FavoriteBrandSummary

    var body: some View {
        HStack(spacing: 10) {
            Text("\(rank)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Color(.systemBackground))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(summary.brand)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(summary.drinkCount) 杯")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(String(format: "%.2f", summary.averageRating))
                .font(.caption.weight(.semibold).monospacedDigit())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct DisplayNameEditor: View {
    @State private var draftDisplayName: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    init(initialDisplayName: String, onSave: @escaping (String) -> Void) {
        _draftDisplayName = State(initialValue: initialDisplayName)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                TextField("档案名", text: $draftDisplayName)
                    .font(ArchiveReferenceTypography.terminal(14))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Text("附近的人会用这个名字识别你的档案。")
                    .font(ArchiveReferenceTypography.terminal(11))
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(18)
            .navigationTitle("修改档案名")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(draftDisplayName)
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

private struct PeerExchangePanel: View {
    let peer: NearbyPeer
    let importedCompendium: SharedCompendium?
    let onCompare: (SharedCompendium) -> Void
    let onExchange: () -> Void
    let onDelete: (SharedCompendium) -> Void
    let onDisconnect: () -> Void

    private var isImported: Bool {
        importedCompendium != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Capsule()
                .fill(.secondary.opacity(0.28))
                .frame(width: 42, height: 5)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(peer.name)
                            .font(.title3.weight(.bold))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(isImported ? "已经交换来的档案" : "还没交换过档案")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isImported ? Color(red: 0.10, green: 0.57, blue: 0.31) : .secondary)
                    }
                    Spacer()
                }

                HStack(spacing: 8) {
                    SharedArchiveMetricCell(metric: SharedArchiveMetric(value: "\(peer.drinkCount)", label: "总杯"))
                    SharedArchiveMetricCell(metric: SharedArchiveMetric(value: String(format: "%.2f", peer.averageRating), label: "均分"))
                }
            }

            if let importedCompendium {
                Button {
                    onCompare(importedCompendium)
                } label: {
                    Label("查看共饮", systemImage: "rectangle.split.2x1")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Divider()

            if let importedCompendium {
                Button(action: onExchange) {
                    Label("交换并更新档案", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button(role: .destructive) {
                    onDelete(importedCompendium)
                } label: {
                    Label("删除已经交换来的档案", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            } else {
                Button(action: onExchange) {
                    Label("交换档案", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Button("断开连接", role: .destructive, action: onDisconnect)
                .frame(maxWidth: .infinity)
        }
        .padding(20)
    }
}
