import AVFoundation
import ImageIO
import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct DrinkFormView: View {
    enum Mode {
        case create
        case edit(Drink)
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Drink.createdAt, order: .reverse) private var existingDrinks: [Drink]

    let mode: Mode
    let initialImage: UIImage?
    let startWithCamera: Bool
    let onSaved: () -> Void

    @State private var brand = ""
    @State private var name = ""
    @State private var sweetness = "正常糖"
    @State private var iceLevel = "正常冰"
    @State private var rating = 4.0
    @State private var consumedAt = Date()
    @State private var location = ""
    @State private var note = ""
    @State private var isLimited = false
    @State private var cupCount = 1

    @State private var originalImage: UIImage?
    @State private var stickerImage: UIImage?
    @State private var photoItem: PhotosPickerItem?
    @State private var showingCamera = false
    @State private var didAutoStartCamera = false
    @State private var didProcessInitialImage = false
    @State private var didChangeImage = false
    @State private var showingBrandPicker = false
    @State private var showingStickerPreview = false
    @State private var isProcessing = false
    @State private var duplicateCandidate: Drink?
    @State private var errorMessage: String?

    private let sweetnessOptions = ["全糖", "正常糖", "少糖", "七分糖", "半糖", "三分糖", "微糖", "无糖", "不另外加糖"]
    private let iceOptions = ["多冰", "正常冰", "少冰", "微冰", "去冰", "常温", "温", "热"]

    init(mode: Mode, initialImage: UIImage? = nil, startWithCamera: Bool = false, onSaved: @escaping () -> Void) {
        self.mode = mode
        self.initialImage = initialImage
        self.startWithCamera = startWithCamera
        self.onSaved = onSaved

        if case .edit(let drink) = mode {
            _brand = State(initialValue: drink.brand)
            _name = State(initialValue: drink.name)
            _sweetness = State(initialValue: drink.sweetness)
            _iceLevel = State(initialValue: drink.iceLevel)
            _rating = State(initialValue: drink.rating)
            _consumedAt = State(initialValue: drink.consumedAt)
            _location = State(initialValue: drink.location)
            _note = State(initialValue: drink.note)
            _isLimited = State(initialValue: drink.isLimited)
            _cupCount = State(initialValue: max(1, drink.cupCount))
            _originalImage = State(initialValue: ImageStore.load(drink.originalImageName))
            _stickerImage = State(initialValue: ImageStore.load(drink.stickerImageName))
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ratingCard
                photoCard
                infoCard
                saveButton
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .scrollDismissesKeyboard(.interactively)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                hideKeyboard()
            }
        )
        .background(Color(.systemGroupedBackground))
        .navigationTitle(isEditing ? "编辑" : "记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isEditing {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            if let initialImage, !didProcessInitialImage, !isEditing {
                didProcessInitialImage = true
                Task { await process(initialImage) }
                return
            }

            guard startWithCamera, !didAutoStartCamera, !isEditing else { return }
            didAutoStartCamera = true
            openCamera()
        }
        .sheet(isPresented: $showingCamera) {
            CameraPicker { image in
                Task { await process(image) }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showingBrandPicker) {
            NavigationStack {
                BrandPickerView(selection: $brand)
            }
        }
        .sheet(isPresented: $showingStickerPreview) {
            if let stickerImage {
                StickerPreviewView(image: stickerImage)
            }
        }
        .onChange(of: photoItem) { _, item in
            guard !isEditing, let item else { return }
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw ProcessingError.invalidImage
                    }
                    let image = try data.downsampledImage(maxDimension: 3_000)
                    await process(image)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        .alert("处理失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("可能已经记录过", isPresented: Binding(
            get: { duplicateCandidate != nil },
            set: { if !$0 { duplicateCandidate = nil } }
        )) {
            Button("+1 杯") {
                if let duplicateCandidate {
                    increment(duplicateCandidate)
                }
                duplicateCandidate = nil
            }
            Button("修正并 +1") {
                if let duplicateCandidate {
                    save(updating: duplicateCandidate)
                }
                duplicateCandidate = nil
            }
            Button("忽略这次") {
                duplicateCandidate = nil
                dismiss()
            }
            Button("取消", role: .cancel) {
                duplicateCandidate = nil
            }
        } message: {
            if let duplicateCandidate {
                Text("\(duplicateCandidate.brand) · \(duplicateCandidate.name)\n已喝 \(duplicateCandidate.cupCount) 杯 · 评分 \(String(format: "%.2f", duplicateCandidate.rating))")
            }
        }
    }

    private var photoCard: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.white)

                if let stickerImage {
                    Button {
                        showingStickerPreview = true
                    } label: {
                        ZStack(alignment: .bottomTrailing) {
                            Image(uiImage: stickerImage)
                                .resizable()
                                .scaledToFit()
                                .padding(18)

                            Image(systemName: "plus.magnifyingglass")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.primary)
                                .padding(10)
                                .background(.white.opacity(0.92))
                                .clipShape(Circle())
                                .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
                                .padding(14)
                        }
                    }
                    .buttonStyle(.plain)
                } else if let originalImage {
                    Image(uiImage: originalImage)
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 36, weight: .light))
                        Text("添加饮品照片")
                            .font(.headline)
                        Text("会自动生成透明背景小贴图")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.secondary)
                }

                if isProcessing {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(.black.opacity(0.28))
                    ProgressView("生成贴图中")
                        .tint(.white)
                        .foregroundStyle(.white)
                }
            }
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

            HStack(spacing: 12) {
                if !isEditing {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("相册", systemImage: "photo")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    openCamera()
                } label: {
                    Label(isEditing ? "重新拍照" : "拍照", systemImage: "camera")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .disabled(isProcessing)

        }
    }

    private var infoCard: some View {
        Card(title: "饮品信息") {
            BrandSelectionField(brand: brand) {
                showingBrandPicker = true
            }
            MinimalTextField(title: "品名", placeholder: "例如 芝芝莓莓", text: $name)

            OptionChips(title: "甜度", options: sweetnessOptions, selection: $sweetness)
            OptionChips(title: "冰度", options: iceOptions, selection: $iceLevel)
            LimitedToggle(isOn: $isLimited)
            cupCountStepper

            DatePicker("饮用时间", selection: $consumedAt, displayedComponents: [.date, .hourAndMinute])
                .font(.subheadline)

            MinimalTextField(title: "地点", placeholder: "可选", text: $location)
            MultilineTextField(title: "备注", placeholder: "加料、做法、非常见选项", text: $note)
        }
    }

    private var ratingCard: some View {
        Card(title: "评分") {
            RatingControl(value: $rating)
        }
    }

    private var cupCountStepper: some View {
        Stepper(value: $cupCount, in: 1...999) {
            HStack {
                Text("喝过杯数")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(cupCount) 杯")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var saveButton: some View {
        Button {
            save()
        } label: {
            Text(isEditing ? "保存" : "加入图鉴")
                .contentTransition(.numericText())
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .clipShape(Capsule())
        .disabled(!canSave)
        .padding(.top, 4)
    }

    private var canSave: Bool {
        (isEditing || (originalImage != nil && stickerImage != nil))
            && !brand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isProcessing
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    @MainActor
    private func process(_ image: UIImage) async {
        stickerImage = nil
        isProcessing = true
        defer { isProcessing = false }

        do {
            let displayImage = await Task.detached(priority: .userInitiated) {
                image.preparedForDrinkForm()
            }.value
            originalImage = displayImage
            let processed = try await DrinkImageProcessor.process(displayImage)
            didChangeImage = true
            stickerImage = processed.sticker
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() {
        if case .create = mode,
           let duplicate = duplicateDrinkCandidate() {
            duplicateCandidate = duplicate
            return
        }
        saveAsNew()
    }

    private func saveAsNew() {
        let cleanedBrand = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var newOriginalName: String?
        var newStickerName: String?
        do {
            switch mode {
            case .create:
                guard let originalImage, let stickerImage else { return }
                let originalName = try ImageStore.saveOriginal(originalImage)
                let stickerName = try ImageStore.saveSticker(stickerImage)
                newOriginalName = originalName
                newStickerName = stickerName
                let drink = Drink(
                    brand: cleanedBrand,
                    name: cleanedName,
                    sweetness: sweetness,
                    iceLevel: iceLevel,
                    rating: rating,
                    consumedAt: consumedAt,
                    location: location.trimmingCharacters(in: .whitespacesAndNewlines),
                    note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                    isLimited: isLimited,
                    cupCount: cupCount,
                    originalImageName: originalName,
                    stickerImageName: stickerName
                )
                modelContext.insert(drink)

            case .edit(let drink):
                drink.brand = cleanedBrand
                drink.name = cleanedName
                drink.sweetness = sweetness
                drink.iceLevel = iceLevel
                drink.rating = rating
                drink.consumedAt = consumedAt
                drink.location = location.trimmingCharacters(in: .whitespacesAndNewlines)
                drink.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
                drink.isLimited = isLimited
                drink.cupCount = max(1, cupCount)

                var oldOriginalName: String?
                var oldStickerName: String?
                if didChangeImage, let originalImage, let stickerImage {
                    oldOriginalName = drink.originalImageName
                    oldStickerName = drink.stickerImageName
                    let originalName = try ImageStore.saveOriginal(originalImage)
                    let stickerName = try ImageStore.saveSticker(stickerImage)
                    newOriginalName = originalName
                    newStickerName = stickerName
                    drink.originalImageName = originalName
                    drink.stickerImageName = stickerName
                }
                try modelContext.save()
                ImageStore.delete(oldOriginalName)
                ImageStore.delete(oldStickerName)
            }
            if case .create = mode {
                try modelContext.save()
            }
            BrandStore.remember(cleanedBrand)
            onSaved()
            dismiss()
        } catch {
            ImageStore.delete(newOriginalName)
            ImageStore.delete(newStickerName)
            errorMessage = error.localizedDescription
        }
    }

    private func save(updating drink: Drink) {
        guard let originalImage, let stickerImage else { return }
        let cleanedBrand = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            ImageStore.delete(drink.originalImageName)
            ImageStore.delete(drink.stickerImageName)
            drink.brand = cleanedBrand
            drink.name = cleanedName
            drink.sweetness = sweetness
            drink.iceLevel = iceLevel
            drink.rating = rating
            drink.consumedAt = consumedAt
            drink.location = location.trimmingCharacters(in: .whitespacesAndNewlines)
            drink.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
            drink.isLimited = isLimited
            drink.cupCount = max(1, drink.cupCount + 1)
            drink.originalImageName = try ImageStore.saveOriginal(originalImage)
            drink.stickerImageName = try ImageStore.saveSticker(stickerImage)
            try modelContext.save()
            BrandStore.remember(cleanedBrand)
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func increment(_ drink: Drink) {
        do {
            drink.cupCount = max(1, drink.cupCount + 1)
            try modelContext.save()
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func duplicateDrinkCandidate() -> Drink? {
        let cleanedBrand = normalizedIdentityText(brand)
        let cleanedName = normalizedIdentityText(name)
        guard cleanedBrand.count >= 2, cleanedName.count >= 2 else { return nil }

        return existingDrinks.first { drink in
            normalizedIdentityText(drink.brand) == cleanedBrand &&
            normalizedIdentityText(drink.name) == cleanedName
        }
    }

    private func normalizedIdentityText(_ text: String) -> String {
        let folded = text.folding(options: [.widthInsensitive, .diacriticInsensitive, .caseInsensitive], locale: nil)
        return folded
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "·", with: "")
            .replacingOccurrences(of: "・", with: "")
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func openCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            errorMessage = "当前设备没有可用相机。"
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
                        errorMessage = "没有相机权限，请在系统设置中允许访问相机。"
                    }
                }
            }

        case .denied, .restricted:
            errorMessage = "没有相机权限，请在系统设置中允许访问相机。"

        @unknown default:
            errorMessage = "无法确认相机权限，请稍后再试。"
        }
    }
}

private struct StickerPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let image: UIImage

    var body: some View {
        NavigationStack {
            ZoomableImageView(image: image)
                .background(Color(.systemGroupedBackground))
                .navigationTitle("贴图")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") {
                            dismiss()
                        }
                    }
                }
        }
        .preferredColorScheme(.light)
    }
}

private extension UIImage {
    func preparedForDrinkForm() -> UIImage {
        let longestSide = max(size.width, size.height)
        let ratio = min(1, 3_000 / longestSide)
        let targetSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}

private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }
    }
}

private struct Card<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct MinimalTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

private struct MultilineTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $text)
                .frame(minHeight: 74)
                .padding(8)
                .scrollContentBackground(.hidden)
                .background(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

private struct LimitedToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 10) {
                Text("限定")
                    .font(.subheadline.weight(.semibold))
                Text(isOn ? "是" : "否")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .foregroundStyle(isOn ? .white : .secondary)
                    .background(isOn ? Color.primary : Color(.secondarySystemGroupedBackground))
                    .clipShape(Capsule())
            }
        }
        .toggleStyle(.switch)
        .padding(.vertical, 2)
    }
}

private struct BrandSelectionField: View {
    let brand: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("品牌")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(action: action) {
                HStack {
                    Text(brand.isEmpty ? "选择品牌" : brand)
                        .foregroundStyle(brand.isEmpty ? .secondary : .primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 12)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
}

private struct OptionChips: View {
    let title: String
    let options: [String]
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(options, id: \.self) { option in
                        Button(option) {
                            selection = option
                        }
                        .buttonStyle(ChipButtonStyle(isSelected: selection == option))
                    }
                }
            }
        }
    }
}

private struct BrandPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String
    @State private var query = ""

    private var recentBrands: [String] {
        filtered(BrandStore.recentBrands)
    }

    private var commonBrands: [String] {
        filtered(BrandStore.commonBrands)
    }

    private var canCreate: Bool {
        let cleaned = cleanedQuery
        return !cleaned.isEmpty
            && !BrandStore.allKnownBrands.contains { $0.caseInsensitiveCompare(cleaned) == .orderedSame }
    }

    private var cleanedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        List {
            if canCreate {
                Section {
                    Button {
                        choose(cleanedQuery)
                    } label: {
                        Label(cleanedQuery, systemImage: "plus")
                    }
                }
            }

            if !recentBrands.isEmpty {
                Section("最近") {
                    ForEach(recentBrands, id: \.self) { brand in
                        brandButton(brand)
                    }
                }
            }

            Section("常见") {
                ForEach(commonBrands, id: \.self) { brand in
                    brandButton(brand)
                }
            }
        }
        .navigationTitle("品牌")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
            }
        }
    }

    private func brandButton(_ brand: String) -> some View {
        Button {
            choose(brand)
        } label: {
            HStack {
                Text(brand)
                Spacer()
                if brand == selection {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.blue)
                }
            }
        }
        .foregroundStyle(.primary)
    }

    private func filtered(_ brands: [String]) -> [String] {
        let cleaned = cleanedQuery
        guard !cleaned.isEmpty else { return brands }
        return brands.filter { $0.localizedCaseInsensitiveContains(cleaned) }
    }

    private func choose(_ brand: String) {
        selection = brand
        BrandStore.remember(brand)
        dismiss()
    }
}

private struct RatingControl: View {
    @Binding var value: Double
    @State private var lastHapticValue = 4.0
    @State private var isHorizontalRatingDrag = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: "%.2f", value))
                    .font(.system(size: 42, weight: .semibold, design: .rounded).monospacedDigit())
                Text("/ 5")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RatingRulerMarks()

                    Capsule()
                        .fill(Color.primary)
                        .frame(width: 4, height: 42)
                        .offset(x: markerOffset(width: proxy.size.width) - 2)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { gesture in
                            if !isHorizontalRatingDrag {
                                let horizontal = abs(gesture.translation.width)
                                let vertical = abs(gesture.translation.height)
                                guard horizontal > vertical * 1.25 else { return }
                                isHorizontalRatingDrag = true
                            }
                            updateValue(at: gesture.location.x, width: proxy.size.width)
                        }
                        .onEnded { _ in
                            isHorizontalRatingDrag = false
                        }
                )
            }
            .frame(height: 54)
        }
    }

    private func markerOffset(width: CGFloat) -> CGFloat {
        CGFloat(value / 5) * width
    }

    private func updateValue(at x: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        let clamped = min(max(x / width, 0), 1)
        let rawValue = Double(clamped) * 5
        let values = RatingScale.values
        let newValue = values.min(by: { abs($0 - rawValue) < abs($1 - rawValue) }) ?? value
        guard abs(newValue - value) > 0.001 else { return }
        value = newValue

        if abs(newValue - lastHapticValue) > 0.001 {
            let generator = UIImpactFeedbackGenerator(style: RatingScale.isEmphasized(newValue) ? .medium : .light)
            generator.impactOccurred()
            lastHapticValue = newValue
        }
    }
}

private enum RatingScale {
    static let values: [Double] = {
        var result: [Double] = stride(from: 0.0, through: 5.0, by: 0.25).map { Double($0) }
        result.append(contentsOf: [0.95, 1.95, 2.95, 3.95, 4.95])
        return Array(Set(result)).sorted()
    }()

    static func isEmphasized(_ value: Double) -> Bool {
        abs(value.rounded() - value) < 0.001
            || abs(value.truncatingRemainder(dividingBy: 1) - 0.95) < 0.001
    }
}

private struct RatingRulerMarks: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(RatingScale.values, id: \.self) { value in
                    Rectangle()
                        .fill(RatingScale.isEmphasized(value) ? Color.primary : Color.secondary.opacity(0.45))
                        .frame(width: 1, height: markHeight(for: value))
                        .offset(x: CGFloat(value / 5) * proxy.size.width)
                }

                ForEach(0...5, id: \.self) { number in
                    Text("\(number)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .offset(
                            x: labelOffset(for: number, width: proxy.size.width),
                            y: 34
                        )
                }
            }
        }
    }

    private func markHeight(for value: Double) -> CGFloat {
        if abs(value.rounded() - value) < 0.001 { return 28 }
        if abs(value.truncatingRemainder(dividingBy: 1) - 0.95) < 0.001 { return 22 }
        return 12
    }

    private func labelOffset(for number: Int, width: CGFloat) -> CGFloat {
        let base = CGFloat(number) / 5 * width
        if number == 5 { return base - 8 }
        return base
    }
}

private struct ChipButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(isSelected ? .white : .primary)
            .background(isSelected ? Color.primary : Color(.secondarySystemGroupedBackground))
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
