import PhotosUI
import SwiftUI
import UIKit

struct ContentView: View {
    @State private var showingNewDrink = false
    @State private var showingCamera = false
    @State private var showingPhotoPicker = false
    @State private var pendingCapturedImage: UIImage?
    @State private var photoItem: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            CollectionView(onStartCapture: {
                showingCamera = true
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
                    guard let data = try await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else {
                        return
                    }
                    await MainActor.run {
                        pendingCapturedImage = image
                        photoItem = nil
                        showingNewDrink = true
                    }
                } catch {
                    await MainActor.run {
                        photoItem = nil
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showingCamera, onDismiss: {
            if pendingCapturedImage != nil {
                showingNewDrink = true
            }
        }) {
            CameraPicker { image in
                pendingCapturedImage = image
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showingNewDrink, onDismiss: {
            pendingCapturedImage = nil
        }) {
            NavigationStack {
                DrinkFormView(mode: .create, initialImage: pendingCapturedImage) {
                    showingNewDrink = false
                }
            }
        }
    }
}
