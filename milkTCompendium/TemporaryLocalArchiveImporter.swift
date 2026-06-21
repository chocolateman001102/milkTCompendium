import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct LocalArchiveImportPreview {
    var archive: SharedCompendiumArchive
    var fileName: String
    var duplicateCount: Int

    var totalCount: Int {
        archive.drinks.count
    }

    var importableCount: Int {
        max(0, totalCount - duplicateCount)
    }
}

struct LocalArchiveImportResult {
    var insertedCount: Int
    var skippedCount: Int
}

enum LocalArchiveImporter {
    static func previewArchive(at url: URL, existingDrinks: [Drink]) throws -> LocalArchiveImportPreview {
        let data = try Data(contentsOf: url)
        let archive = try SharedCompendiumStore.decodeArchiveData(data)
        let existingKeys = Set(existingDrinks.map(duplicateKey(for:)))
        let duplicateCount = archive.drinks.filter { existingKeys.contains(duplicateKey(for: $0)) }.count

        return LocalArchiveImportPreview(
            archive: archive,
            fileName: url.lastPathComponent,
            duplicateCount: duplicateCount
        )
    }

    @MainActor
    static func importArchive(_ archive: SharedCompendiumArchive, existingDrinks: [Drink], into modelContext: ModelContext) throws -> LocalArchiveImportResult {
        let existingKeys = Set(existingDrinks.map(duplicateKey(for:)))
        var insertedCount = 0
        var skippedCount = 0

        for archivedDrink in archive.drinks {
            guard !existingKeys.contains(duplicateKey(for: archivedDrink)) else {
                skippedCount += 1
                continue
            }

            let stickerName = try saveSticker(from: archivedDrink)
            let drink = Drink(
                brand: archivedDrink.brand,
                name: archivedDrink.name,
                sweetness: archivedDrink.sweetness,
                iceLevel: archivedDrink.iceLevel,
                rating: archivedDrink.rating,
                consumedAt: archivedDrink.consumedAt,
                location: archivedDrink.location,
                note: archivedDrink.note,
                isLimited: archivedDrink.isLimited,
                cupCount: archivedDrink.cupCount,
                originalImageName: nil,
                stickerImageName: stickerName
            )
            drink.createdAt = archivedDrink.createdAt
            modelContext.insert(drink)
            insertedCount += 1
        }

        try modelContext.save()
        return LocalArchiveImportResult(insertedCount: insertedCount, skippedCount: skippedCount)
    }

    private static func saveSticker(from drink: SharedDrinkArchive) throws -> String? {
        guard let data = drink.stickerData else { return nil }
        return try ImageStore.saveStickerData(
            data,
            preferredExtension: SharedCompendiumStore.stickerFileExtension(for: drink.stickerImageFormat)
        )
    }

    private static func duplicateKey(for drink: Drink) -> String {
        duplicateKey(
            brand: drink.brand,
            name: drink.name,
            sweetness: drink.sweetness,
            iceLevel: drink.iceLevel,
            rating: drink.rating,
            consumedAt: drink.consumedAt,
            location: drink.location,
            note: drink.note,
            isLimited: drink.isLimited,
            cupCount: drink.cupCount
        )
    }

    private static func duplicateKey(for drink: SharedDrinkArchive) -> String {
        duplicateKey(
            brand: drink.brand,
            name: drink.name,
            sweetness: drink.sweetness,
            iceLevel: drink.iceLevel,
            rating: drink.rating,
            consumedAt: drink.consumedAt,
            location: drink.location,
            note: drink.note,
            isLimited: drink.isLimited,
            cupCount: drink.cupCount
        )
    }

    private static func duplicateKey(
        brand: String,
        name: String,
        sweetness: String,
        iceLevel: String,
        rating: Double,
        consumedAt: Date,
        location: String,
        note: String,
        isLimited: Bool,
        cupCount: Int
    ) -> String {
        [
            normalize(brand),
            normalize(name),
            normalize(sweetness),
            normalize(iceLevel),
            String(format: "%.3f", rating),
            String(Int(consumedAt.timeIntervalSince1970.rounded())),
            normalize(location),
            normalize(note),
            isLimited ? "1" : "0",
            "\(max(1, cupCount))"
        ].joined(separator: "#")
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct TemporaryLocalArchiveImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var existingDrinks: [Drink]

    @State private var preview: LocalArchiveImportPreview?
    @State private var isShowingFileImporter = false
    @State private var isImporting = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        isShowingFileImporter = true
                    } label: {
                        Label("选择 .mtcpack 文件", systemImage: "doc.badge.plus")
                    }
                } footer: {
                    Text("这是临时迁移工具，会把旧 App 导出的档案合并进当前本地图鉴。")
                }

                if preview != nil {
                    previewSection
                    importSection
                }
            }
            .navigationTitle("临时导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $isShowingFileImporter,
                allowedContentTypes: [.milkTCompendiumPackage, .data],
                allowsMultipleSelection: false,
                onCompletion: handleFileSelection
            )
            .alert("临时导入", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
        }
    }

    private var previewSection: some View {
        Section("预览") {
            LabeledContent("文件", value: preview?.fileName ?? "")
            LabeledContent("档案名", value: preview?.archive.ownerName ?? "")
            LabeledContent("总记录", value: "\(preview?.totalCount ?? 0)")
            LabeledContent("重复记录", value: "\(preview?.duplicateCount ?? 0)")
            LabeledContent("将导入", value: "\(preview?.importableCount ?? 0)")
        }
    }

    private var importSection: some View {
        Section {
            Button {
                importSelectedArchive()
            } label: {
                if isImporting {
                    ProgressView()
                } else {
                    Label("导入到我的图鉴", systemImage: "square.and.arrow.down")
                }
            }
            .disabled(isImporting || (preview?.importableCount ?? 0) == 0)
        }
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            preview = try LocalArchiveImporter.previewArchive(at: url, existingDrinks: existingDrinks)
        } catch {
            message = error.localizedDescription
        }
    }

    private func importSelectedArchive() {
        guard let preview else { return }
        isImporting = true
        defer { isImporting = false }

        do {
            let result = try LocalArchiveImporter.importArchive(
                preview.archive,
                existingDrinks: existingDrinks,
                into: modelContext
            )
            self.preview = nil
            message = "已导入 \(result.insertedCount) 条，跳过 \(result.skippedCount) 条重复记录。"
        } catch {
            message = error.localizedDescription
        }
    }
}

private extension UTType {
    static let milkTCompendiumPackage = UTType(exportedAs: "com.yangchen.milktcompendium.package")
}
