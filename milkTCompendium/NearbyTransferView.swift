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
                    myCard
                    statusCard
                    exchangedArchivesSection
                    controls
                    partyWall
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

    private var myCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(displayName)
                        .font(ArchiveReferenceTypography.title(29))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text("\(profileCupCount) 杯 · \(drinks.count) 项")
                        .font(ArchiveReferenceTypography.terminal(12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                scoreBadge
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                summaryPill(value: "\(profileCupCount)", label: "总杯")
                summaryPill(value: "\(drinks.count)", label: "收集")
                summaryPill(value: String(format: "%.2f", averageRating), label: "均分")
                summaryPill(value: "\(tasteStatsStore.stats.successfulExchangeCount)", label: "交换")
            }
            friendTotalsPanel

            VStack(alignment: .leading, spacing: 9) {
                Text("前三品牌")
                    .font(ArchiveReferenceTypography.terminal(11, weight: .black))
                    .foregroundStyle(.secondary)

                if favoriteBrands.isEmpty {
                    Text("记录几杯之后，这里会长出你的口味坐标。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                } else {
                    VStack(spacing: 8) {
                        ForEach(Array(favoriteBrands.enumerated()), id: \.element.id) { index, brand in
                            FavoriteBrandRow(rank: index + 1, summary: brand)
                        }
                    }
                }
            }
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.white)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.black.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.07), radius: 18, y: 8)
    }

    private var scoreBadge: some View {
        VStack(spacing: 3) {
            Text(String(format: "%.2f", tasteScore.score))
                .font(ArchiveReferenceTypography.display(38))
                .foregroundStyle(.primary)
            Text(tasteScore.levelName)
                .font(ArchiveReferenceTypography.terminal(11, weight: .bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(minWidth: 104)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.black.opacity(0.08), lineWidth: 1)
        )
    }

    private func summaryPill(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(ArchiveReferenceTypography.terminal(17, weight: .black))
            Text(label)
                .font(ArchiveReferenceTypography.terminal(9.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.white.opacity(0.76))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.black.opacity(0.07), lineWidth: 1)
        )
    }

    private var friendTotalsPanel: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.blue.opacity(0.13))
                Image(systemName: "person.2.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.blue)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 8) {
                Text("和朋友一起")
                    .font(ArchiveReferenceTypography.terminal(11, weight: .black))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    friendTotalMetric(value: totalCupCountWithFriends, label: "总杯数")
                    friendTotalMetric(value: totalCollectionCountWithFriends, label: "总收集数")
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.blue.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.blue.opacity(0.16), lineWidth: 1)
        )
    }

    private func friendTotalMetric(value: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(ArchiveReferenceTypography.terminal(17, weight: .black))
            Text(label)
                .font(ArchiveReferenceTypography.terminal(9.5, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.white.opacity(0.74))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.blue.opacity(0.12), lineWidth: 1)
        )
    }

    private var statusCard: some View {
        let isActive = manager.isSending
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isActive ? Color.orange.opacity(0.22) : Color.green.opacity(0.16))
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: isActive ? 22 : 18, weight: .bold))
                    .foregroundStyle(isActive ? .orange : .green)
            }
            .frame(width: 42, height: 42)
            .shadow(color: isActive ? Color.orange.opacity(0.36) : .clear, radius: 14, y: 4)

            VStack(alignment: .leading, spacing: 3) {
                Text("交换雷达")
                    .font(ArchiveReferenceTypography.terminal(14, weight: .black))
                Text(manager.statusMessage)
                    .font(ArchiveReferenceTypography.terminal(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if isActive {
                Button {
                    manager.cancelCurrentExchange()
                } label: {
                    Label("取消交换", systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .tint(.orange)
                .accessibilityLabel("取消交换")
            } else if manager.peers.isEmpty {
                ProgressView()
                    .tint(.secondary)
            } else {
                Text("\(manager.peers.count)")
                    .font(ArchiveReferenceTypography.terminal(17, weight: .black))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(Capsule())
            }
        }
        .padding(14)
        .background(isActive ? Color.orange.opacity(0.08) : .white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(isActive ? Color.orange.opacity(0.42) : Color.black.opacity(0.07), lineWidth: isActive ? 1.5 : 1)
        )
        .shadow(color: isActive ? Color.orange.opacity(0.18) : .clear, radius: 20, y: 8)
    }

    private var exchangedArchivesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("已经交换来的档案")
                    .font(ArchiveReferenceTypography.terminal(15, weight: .black))
                Spacer()
                Text("\(sharedStore.compendiums.count) 个")
                    .font(ArchiveReferenceTypography.terminal(11, weight: .bold))
                    .foregroundStyle(.secondary)
            }

            if sharedStore.compendiums.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("还没有交换来的档案")
                        .font(ArchiveReferenceTypography.terminal(13, weight: .semibold))
                    Text("和朋友交换后，档案会出现在这里，也可以从这里删除。")
                        .font(ArchiveReferenceTypography.terminal(11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.black.opacity(0.07), lineWidth: 1)
                )
            } else {
                VStack(spacing: 10) {
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

    private var controls: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField("搜索档案", text: $searchText)
                .font(ArchiveReferenceTypography.terminal(13))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.black.opacity(0.07), lineWidth: 1)
        )
    }

    private var partyWall: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("附近档案")
                    .font(ArchiveReferenceTypography.terminal(15, weight: .black))
                Spacer()
                Text("\(filteredPeers.count) 个")
                    .font(ArchiveReferenceTypography.terminal(11, weight: .bold))
                    .foregroundStyle(.secondary)
            }

            if filteredPeers.isEmpty {
                ContentUnavailableView(
                    "等待附近档案",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text("让对方也打开档案页")
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
        .system(size: size, weight: .black, design: .serif)
    }

    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .black, design: .serif).monospacedDigit()
    }

    static func terminal(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced).monospacedDigit()
    }
}

private struct ExchangedArchiveRow: View {
    let compendium: SharedCompendium
    let pixelPerson: PixelPersonProfile
    let onCompare: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PixelTinyPersonView(profile: pixelPerson)
                .frame(width: 38, height: 46)
                .padding(.top, 1)
                .accessibilityLabel("\(compendium.ownerName) 的像素小小人")

            VStack(alignment: .leading, spacing: 5) {
                Text(compendium.ownerName)
                    .font(ArchiveReferenceTypography.title(16))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text("\(cupCount) 杯 · \(compendium.drinks.count) 项 · 已交换档案")
                    .font(ArchiveReferenceTypography.terminal(11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Menu {
                Button(action: onCompare) {
                    Label("查看共饮", systemImage: "rectangle.split.2x1")
                }

                Button(role: .destructive, action: onDelete) {
                    Label("删除档案", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel("\(compendium.ownerName) 的档案操作")
        }
        .padding(12)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.black.opacity(0.07), lineWidth: 1)
        )
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
                .font(ArchiveReferenceTypography.terminal(12, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(.black)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(summary.brand)
                    .font(ArchiveReferenceTypography.terminal(13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(summary.drinkCount) 杯")
                    .font(ArchiveReferenceTypography.terminal(10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(String(format: "%.2f", summary.averageRating))
                .font(ArchiveReferenceTypography.terminal(13, weight: .semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
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

private struct PeerCard: View {
    let peer: NearbyPeer
    let isImported: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(peer.name)
                        .font(ArchiveReferenceTypography.title(18))
                        .lineLimit(1)
                    Text(isImported ? "已交换档案 · 可更新" : "可交换档案")
                        .font(ArchiveReferenceTypography.terminal(11, weight: .semibold))
                        .foregroundStyle(isImported ? .green : .secondary)
                }

                Spacer()
            }

            HStack(spacing: 8) {
                stat("\(peer.drinkCount)", "总杯")
                stat(String(format: "%.2f", peer.averageRating), "均分")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isImported ? Color.green.opacity(0.22) : Color.black.opacity(0.07), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.045), radius: 10, y: 4)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(ArchiveReferenceTypography.terminal(14, weight: .black))
            Text(label)
                .font(ArchiveReferenceTypography.terminal(10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        VStack(alignment: .leading, spacing: 18) {
            Capsule()
                .fill(.secondary.opacity(0.28))
                .frame(width: 42, height: 5)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 5) {
                Text(peer.name)
                    .font(ArchiveReferenceTypography.title(25))
                Text("\(peer.drinkCount) 总杯 · 均分 \(String(format: "%.2f", peer.averageRating)) · \(isImported ? "已经交换来的档案" : "还没交换过档案")")
                    .font(ArchiveReferenceTypography.terminal(12))
                    .foregroundStyle(.secondary)
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
        .padding(22)
    }
}
