import SwiftUI
import StockMaskCounting

/// The card that slides up after a commit (PRD §7 step 4, FR-27): one row per group, "8 × bottle",
/// with the group's photos (large; tap one to zoom) and, once the labels are read, a suggested
/// product to confirm with one tap (FR-31: nothing is named without a tap). "Other…" opens the
/// picker. Ignoring the card is fine: the groups stay "Unknown A/B/…" in the list until named.
/// Earlier groups that rows behind this commit's front bottles joined are listed too.
public struct CommitCardView: View {
    let card: CommitCard
    let suggestions: [UUID: Suggestion]
    let reading: Set<UUID>
    let photoDirectory: URL?
    let onName: (GroupInfo) -> Void
    let onConfirm: (GroupInfo) -> Void
    let onDismiss: () -> Void
    @State private var zoom: PhotoSet?

    public init(card: CommitCard, suggestions: [UUID: Suggestion] = [:], reading: Set<UUID> = [], photoDirectory: URL? = nil,
                onName: @escaping (GroupInfo) -> Void, onConfirm: @escaping (GroupInfo) -> Void = { _ in },
                onDismiss: @escaping () -> Void) {
        self.card = card
        self.suggestions = suggestions
        self.reading = reading
        self.photoDirectory = photoDirectory
        self.onName = onName
        self.onConfirm = onConfirm
        self.onDismiss = onDismiss
    }

    var rows: [(group: GroupInfo, joined: Bool)] { card.groups.map { ($0, false) } + card.joined.map { ($0, true) } }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(card.added == 0 ? "Already counted" : "+\(card.added) counted").font(.headline)
                if card.possibleMisses > 0 {
                    Label("\(card.possibleMisses) to check", systemImage: "plus.circle.fill")
                        .font(.subheadline).foregroundStyle(.orange)
                }
                Spacer()
                Button("Done", action: onDismiss).buttonStyle(.bordered)
            }
            if rows.count <= 2 {
                groupList
            } else {
                ScrollView { groupList }.frame(maxHeight: 380)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .sheet(item: $zoom) { PhotoZoomView(photos: $0, directory: photoDirectory) }
    }

    private var groupList: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(rows, id: \.group.id) { row in
                GroupCardRow(group: row.group, joined: row.joined, suggestion: suggestions[row.group.id],
                             reading: reading.contains(row.group.id), photoDirectory: photoDirectory,
                             onZoom: { zoom = PhotoSet(title: "\(row.group.count) × \(row.group.cls.displayName)",
                                                       paths: row.group.cropPaths, start: $0) },
                             onName: { onName(row.group) }, onConfirm: { onConfirm(row.group) })
            }
        }
    }
}

/// One group on the commit card.
struct GroupCardRow: View {
    let group: GroupInfo
    let joined: Bool
    let suggestion: Suggestion?
    let reading: Bool
    let photoDirectory: URL?
    let onZoom: (Int) -> Void
    let onName: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(group.count) × \(group.cls.displayName)").font(.headline).monospacedDigit()
                Image(systemName: "arrow.right").font(.caption)
                if let p = group.product {
                    Text(p.title).fontWeight(.semibold).lineLimit(1)
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if group.markedUnknown {
                    Text("\(group.label) (left unknown)").foregroundStyle(.secondary)
                } else {
                    Text(group.label).foregroundStyle(.orange)
                }
                Spacer()
                if group.product != nil || group.markedUnknown {
                    Button("Change", action: onName).font(.caption).buttonStyle(.bordered)
                }
            }
            if joined {
                Text("Rows behind joined this group: naming it names them").font(.caption).foregroundStyle(.secondary)
            }
            if !group.cropPaths.isEmpty {
                PhotoStrip(paths: group.cropPaths, directory: photoDirectory, height: 132, onTap: onZoom)
            }
            if group.product == nil && !group.markedUnknown {
                if let s = suggestion {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.product.title).fontWeight(.semibold).lineLimit(2)
                            Text("\(s.source.rawValue) · \(s.percent)%").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Confirm", action: onConfirm).buttonStyle(.borderedProminent).frame(minHeight: 44)
                        Button("Other…", action: onName).buttonStyle(.bordered).frame(minHeight: 44)
                    }
                } else {
                    HStack {
                        Button(action: onName) {
                            Label("Name it", systemImage: "tag").frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.bordered)
                        if reading {
                            ProgressView().controlSize(.small)
                            Text("Reading labels…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

extension Suggestion {
    /// The confidence as a whole percentage, for the screens.
    public var percent: Int { Int((confidence * 100).rounded()) }
}

/// Photos to look at closely: a group's crops, starting at the one tapped.
public struct PhotoSet: Identifiable, Sendable, Equatable {
    public var id = UUID()
    public var title: String
    public var paths: [String]
    public var start: Int

    public init(title: String, paths: [String], start: Int = 0) {
        self.title = title
        self.paths = paths
        self.start = start
    }
}

/// A row of photo crops, scrolling sideways; tapping one zooms it.
public struct PhotoStrip: View {
    let paths: [String]
    let directory: URL?
    let height: CGFloat
    let onTap: (Int) -> Void

    public init(paths: [String], directory: URL?, height: CGFloat, onTap: @escaping (Int) -> Void) {
        self.paths = paths
        self.directory = directory
        self.height = height
        self.onTap = onTap
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(paths.enumerated()), id: \.offset) { i, path in
                    Button { onTap(i) } label: { CropPhoto(path: path, directory: directory, height: height) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Photo \(i + 1) of \(paths.count): tap to zoom")
                }
            }
        }
        .frame(height: height)
    }
}

/// One saved photo (a crop or a keyframe), loaded off the main thread. With no height it fills the
/// space it is given.
public struct CropPhoto: View {
    let path: String
    let directory: URL?
    let height: CGFloat?
    @State private var image: CGImage?
    @State private var missing = false

    public init(path: String, directory: URL?, height: CGFloat? = nil) {
        self.path = path
        self.directory = directory
        self.height = height
    }

    public var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 8).fill(.gray.opacity(0.25))
                    .aspectRatio(0.45, contentMode: .fit)
                    .overlay { if missing { Image(systemName: "photo").foregroundStyle(.secondary) } }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: path) {
            image = await PhotoLoader.load(path, in: directory)
            missing = image == nil
        }
    }
}

/// A group's photos full screen, one page each; pinch or double-tap to zoom further.
public struct PhotoZoomView: View {
    let photos: PhotoSet
    let directory: URL?
    @State private var page: Int?
    @Environment(\.dismiss) private var dismiss

    public init(photos: PhotoSet, directory: URL?) {
        self.photos = photos
        self.directory = directory
        _page = State(initialValue: photos.start)
    }

    public var body: some View {
        NavigationStack {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(photos.paths.enumerated()), id: \.offset) { i, path in
                        ZoomablePhoto(path: path, directory: directory)
                            .containerRelativeFrame([.horizontal, .vertical])
                            .id(i)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $page)
            .background(.black)
            .navigationTitle(photos.paths.count > 1 ? "\(photos.title) · \((page ?? 0) + 1) of \(photos.paths.count)" : photos.title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

struct ZoomablePhoto: View {
    let path: String
    let directory: URL?
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        CropPhoto(path: path, directory: directory)
            .scaleEffect(scale * pinch)
            .gesture(MagnifyGesture()
                .updating($pinch) { value, state, _ in state = value.magnification }
                .onEnded { scale = min(6, max(1, scale * $0.magnification)) })
            .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2.5 } }
            .padding(8)
    }
}

/// Pick, search or create a product (FR-28; products created mid-count, FR-3). The group's photos
/// are at the top, and a suggested product (teach-once or label text) is first: one tap picks it.
public struct ProductPickerView: View {
    let title: String
    let suggestion: Suggestion?
    let photos: [String]
    let photoDirectory: URL?
    let search: (String) async -> [ProductInfo]
    let create: (ProductDraft) async -> ProductInfo?
    let onPick: (ProductInfo) -> Void
    @State private var query = ""
    @State private var results: [ProductInfo] = []
    @State private var creating = false
    @State private var zoom: PhotoSet?
    @Environment(\.dismiss) private var dismiss

    public init(title: String, suggestion: Suggestion? = nil, photos: [String] = [], photoDirectory: URL? = nil,
                search: @escaping (String) async -> [ProductInfo],
                create: @escaping (ProductDraft) async -> ProductInfo?, onPick: @escaping (ProductInfo) -> Void) {
        self.title = title
        self.suggestion = suggestion
        self.photos = photos
        self.photoDirectory = photoDirectory
        self.search = search
        self.create = create
        self.onPick = onPick
    }

    public var body: some View {
        NavigationStack {
            List {
                if !photos.isEmpty {
                    Section {
                        PhotoStrip(paths: photos, directory: photoDirectory, height: 160) {
                            zoom = PhotoSet(title: title, paths: photos, start: $0)
                        }
                    }
                }
                if let s = suggestion {
                    Section("Suggested") {
                        Button {
                            onPick(s.product)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.product.title).fontWeight(.semibold)
                                    Text(s.evidence.isEmpty ? "\(s.source.rawValue) · \(s.percent)%"
                                         : "\(s.source.rawValue) “\(s.evidence)” · \(s.percent)%")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "checkmark.circle")
                            }
                            .frame(minHeight: 44)
                        }
                    }
                }
                Section {
                    TextField("Search products", text: $query)
                        .autocorrectionDisabled()
                }
                Section(results.isEmpty ? "No products yet" : "Products") {
                    ForEach(results) { p in
                        Button {
                            onPick(p)
                            dismiss()
                        } label: {
                            HStack {
                                Text(p.title)
                                Spacer()
                                if let per = p.unitsPerCase { Text("× \(per)").foregroundStyle(.secondary) }
                            }
                            .frame(minHeight: 44)
                        }
                    }
                }
                Section {
                    Button {
                        creating = true
                    } label: {
                        Label(query.isEmpty ? "Create a product" : "Create “\(query)”", systemImage: "plus")
                    }
                }
            }
            .task(id: query) { results = await search(query) }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .sheet(isPresented: $creating) {
                NewProductForm(name: query, create: create) { p in
                    onPick(p)
                    dismiss()
                }
            }
            .sheet(item: $zoom) { PhotoZoomView(photos: $0, directory: photoDirectory) }
        }
    }
}

/// A new product: name, size in ml, units per case, code. Sizes and quantities are whole numbers (ADR 005).
public struct NewProductForm: View {
    @State private var name: String
    @State private var size = ""
    @State private var perCase = ""
    @State private var code = ""
    @State private var saving = false
    let create: (ProductDraft) async -> ProductInfo?
    let onCreated: (ProductInfo) -> Void
    @Environment(\.dismiss) private var dismiss

    public init(name: String = "", create: @escaping (ProductDraft) async -> ProductInfo?,
                onCreated: @escaping (ProductInfo) -> Void) {
        _name = State(initialValue: name)
        self.create = create
        self.onCreated = onCreated
    }

    var draft: ProductDraft {
        ProductDraft(name: name.trimmingCharacters(in: .whitespaces), sizeML: Int(size), unitsPerCase: Int(perCase),
                     code: code.trimmingCharacters(in: .whitespaces))
    }

    public var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Size (ml)", text: $size).numericKeyboard()
                TextField("Units per case", text: $perCase).numericKeyboard()
                TextField("Code (optional)", text: $code)
            }
            .navigationTitle("New product")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            if let p = await create(draft) {
                                onCreated(p)
                                dismiss()
                            }
                            saving = false
                        }
                    }
                    .disabled(draft.name.isEmpty || saving)
                }
            }
        }
    }
}

extension View {
    /// A number pad on the phone; nothing on a Mac.
    func numericKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.numberPad)
        #else
        self
        #endif
    }
}
