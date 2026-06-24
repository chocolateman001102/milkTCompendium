import AVFoundation
import ImageIO
import PhotosUI
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var sharedStore = SharedCompendiumStore()
    @StateObject private var tasteStatsStore = TasteExchangeStatsStore()
    @State private var showingCamera = false
    @State private var showingPhotoPicker = false
    @State private var pendingCameraImage: UIImage?
    @State private var pendingNewDrinkPhoto: CapturedDrinkPhoto?
    @State private var photoItem: PhotosPickerItem?
    @State private var cameraErrorMessage: String?

    var body: some View {
        NavigationStack {
            CollectionView(sharedStore: sharedStore, tasteStatsStore: tasteStatsStore, onStartCapture: {
                startCamera()
            }, onStartPhotoImport: {
                showingPhotoPicker = true
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
                        pendingNewDrinkPhoto = CapturedDrinkPhoto(image: image)
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
                pendingNewDrinkPhoto = CapturedDrinkPhoto(image: pendingCameraImage)
            }
        }) {
            CameraPicker { image in
                pendingCameraImage = image
            } onCancel: {
                pendingCameraImage = nil
            }
            .ignoresSafeArea()
        }
        .sheet(item: $pendingNewDrinkPhoto) { photo in
            NavigationStack {
                DrinkFormView(mode: .create, initialImage: photo.image) {
                    pendingNewDrinkPhoto = nil
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
                _ = try await sharedStore.importArchive(at: url)
            } catch {
                cameraErrorMessage = error.localizedDescription
            }
        }
    }

}

private struct CapturedDrinkPhoto: Identifiable {
    let id = UUID()
    let image: UIImage
}
