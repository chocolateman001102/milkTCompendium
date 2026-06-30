import AVFoundation
import ImageIO
import PhotosUI
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var sharedStore = SharedCompendiumStore()
    @StateObject private var tasteStatsStore = TasteExchangeStatsStore()
    @StateObject private var pendingDraftStore = PendingDrinkDraftStore()
    @State private var showingCamera = false
    @State private var showingPhotoPicker = false
    @State private var showingPendingDrafts = false
    @State private var pendingCameraImage: UIImage?
    @State private var activeDrinkForm: ActiveDrinkForm?
    @State private var photoItem: PhotosPickerItem?
    @State private var cameraErrorMessage: String?

    var body: some View {
        NavigationStack {
            CollectionView(sharedStore: sharedStore, tasteStatsStore: tasteStatsStore, onStartCapture: {
                startCamera()
            }, onStartPhotoImport: {
                showingPhotoPicker = true
            }, pendingDrafts: pendingDraftStore.drafts, pendingDraftThumbnail: { draft in
                pendingDraftStore.thumbnail(for: draft)
            }, onOpenPendingDrafts: {
                showingPendingDrafts = true
            })
        }
        .tint(.primary)
        .preferredColorScheme(.light)
        .photosPicker(isPresented: $showingPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        return
                    }
                    let image = try data.downsampledImage(maxDimension: 4_000)
                    await MainActor.run {
                        photoItem = nil
                        activeDrinkForm = .new(CapturedDrinkPhoto(image: image))
                    }
                } catch {
                    await MainActor.run {
                        photoItem = nil
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showingCamera, onDismiss: {
            if let pendingCameraImage {
                self.pendingCameraImage = nil
                activeDrinkForm = .new(CapturedDrinkPhoto(image: pendingCameraImage))
            }
        }) {
            CameraPicker { image in
                pendingCameraImage = image
            } onCancel: {
                pendingCameraImage = nil
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showingPendingDrafts) {
            PendingDraftInboxView(
                drafts: pendingDraftStore.drafts,
                thumbnail: { pendingDraftStore.thumbnail(for: $0) },
                onContinue: { draft in
                    showingPendingDrafts = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        activeDrinkForm = .draft(draft)
                    }
                },
                onDelete: { draft in
                    pendingDraftStore.delete(draft)
                }
            )
        }
        .sheet(item: $activeDrinkForm) { form in
            NavigationStack {
                switch form {
                case .new(let photo):
                    DrinkFormView(
                        mode: .create,
                        initialImage: photo.image,
                        onSaveDraft: { input in
                            try pendingDraftStore.saveDraft(input: input)
                        },
                        onFinalSaveDraft: { draft in
                            pendingDraftStore.delete(draft)
                        }
                    ) {
                        activeDrinkForm = nil
                    }

                case .draft(let draft):
                    if let originalImage = pendingDraftStore.originalImage(for: draft),
                       let stickerImage = pendingDraftStore.stickerImage(for: draft) {
                        DrinkFormView(
                            mode: .create,
                            initialDraft: draft,
                            initialDraftOriginalImage: originalImage,
                            initialDraftStickerImage: stickerImage,
                            onSaveDraft: { input in
                                try pendingDraftStore.saveDraft(input: input)
                            },
                            onFinalSaveDraft: { draft in
                                pendingDraftStore.delete(draft)
                            }
                        ) {
                            activeDrinkForm = nil
                        }
                    } else {
                        MissingPendingDraftView {
                            pendingDraftStore.delete(draft)
                            activeDrinkForm = nil
                        }
                    }
                }
            }
        }
        .alert("无法打开相机", isPresented: Binding(
            get: { cameraErrorMessage != nil },
            set: { if !$0 { cameraErrorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(cameraErrorMessage ?? "")
        }
        .onOpenURL { url in
            importSharedCompendium(from: url)
        }
        .onReceive(sharedStore.$compendiums) { compendiums in
            tasteStatsStore.recordImportedCompendiumsIfMissing(compendiums)
        }
        .dismissKeyboardOnTap()
    }

    private func startCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            cameraErrorMessage = "当前设备没有可用相机。"
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showingCamera = true

        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                await MainActor.run {
                    if granted {
                        showingCamera = true
                    } else {
                        cameraErrorMessage = "没有相机权限，请在系统设置中允许访问相机。"
                    }
                }
            }

        case .denied, .restricted:
            cameraErrorMessage = "没有相机权限，请在系统设置中允许访问相机。"

        @unknown default:
            cameraErrorMessage = "无法确认相机权限，请稍后再试。"
        }
    }

    private func importSharedCompendium(from url: URL) {
        Task {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let compendium = try await sharedStore.importArchive(at: url)
                recordImportedSharedCompendium(compendium)
            } catch {
                cameraErrorMessage = error.localizedDescription
            }
        }
    }

    private func recordImportedSharedCompendium(_ compendium: SharedCompendium) {
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
    }

}

private struct CapturedDrinkPhoto: Identifiable {
    let id = UUID()
    let image: UIImage
}

private enum ActiveDrinkForm: Identifiable {
    case new(CapturedDrinkPhoto)
    case draft(PendingDrinkDraft)

    var id: String {
        switch self {
        case .new(let photo):
            return "new-\(photo.id.uuidString)"
        case .draft(let draft):
            return "draft-\(draft.id.uuidString)"
        }
    }
}

private struct MissingPendingDraftView: View {
    @Environment(\.dismiss) private var dismiss
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("找不到这张待记录照片")
                .font(.headline)
            Text("照片文件可能已经被清理，请重新拍摄。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("移除这条待记录") {
                onDelete()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("待记录")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PendingDraftInboxView: View {
    @Environment(\.dismiss) private var dismiss
    let drafts: [PendingDrinkDraft]
    let thumbnail: (PendingDrinkDraft) -> UIImage?
    let onContinue: (PendingDrinkDraft) -> Void
    let onDelete: (PendingDrinkDraft) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if drafts.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("没有待记录照片")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGroupedBackground))
                } else {
                    List {
                        ForEach(drafts) { draft in
                            Button {
                                onContinue(draft)
                            } label: {
                                PendingDraftRow(draft: draft, image: thumbnail(draft))
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button("删除", role: .destructive) {
                                    onDelete(draft)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .background(Color(.systemGroupedBackground))
                }
            }
            .navigationTitle("待记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.light)
    }
}

private struct PendingDraftRow: View {
    let draft: PendingDrinkDraft
    let image: UIImage?

    private var title: String {
        let brand = draft.brand.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if brand.isEmpty, name.isEmpty {
            return "未命名饮品"
        }
        if brand.isEmpty {
            return name
        }
        if name.isEmpty {
            return brand
        }
        return "\(brand) \(name)"
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 58, height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(draft.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(String(format: "评分 %.2f · %d 杯", draft.rating, max(1, draft.cupCount)))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .accessibilityLabel("\(title)，待记录")
    }
}
