import SwiftUI
import StockMaskCounting

/// The card that slides up after a commit (PRD §7 step 4, FR-27): one row per group,
/// "8 × bottle → name it". Tapping a row names it (FR-28); ignoring the card is fine, the groups
/// stay "Unknown A/B/…" in the list until named.
public struct CommitCardView: View {
    let card: CommitCard
    let onName: (GroupInfo) -> Void
    let onDismiss: () -> Void

    public init(card: CommitCard, onName: @escaping (GroupInfo) -> Void, onDismiss: @escaping () -> Void) {
        self.card = card
        self.onName = onName
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(card.added == 0 ? "Already counted" : "+\(card.added) counted").font(.headline)
                if card.possibleMisses > 0 {
                    Label("\(card.possibleMisses) to check", systemImage: "plus.circle.fill")
                        .font(.subheadline).foregroundStyle(.orange)
                }
                Spacer()
                Button("Done", action: onDismiss).buttonStyle(.bordered)
            }
            ForEach(card.groups) { g in
                Button {
                    onName(g)
                } label: {
                    HStack {
                        Text("\(g.count) × \(g.cls.displayName)").monospacedDigit()
                        Image(systemName: "arrow.right").font(.caption)
                        if let p = g.product {
                            Text(p.title).fontWeight(.semibold)
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if g.markedUnknown {
                            Text("\(g.label) (left unknown)").foregroundStyle(.secondary)
                        } else {
                            Text("\(g.label): name it").foregroundStyle(.orange)
                        }
                        Spacer()
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

/// Pick, search or create a product (FR-28; products created mid-count, FR-3).
public struct ProductPickerView: View {
    let title: String
    let search: (String) async -> [ProductInfo]
    let create: (ProductDraft) async -> ProductInfo?
    let onPick: (ProductInfo) -> Void
    @State private var query = ""
    @State private var results: [ProductInfo] = []
    @State private var creating = false
    @Environment(\.dismiss) private var dismiss

    public init(title: String, search: @escaping (String) async -> [ProductInfo],
                create: @escaping (ProductDraft) async -> ProductInfo?, onPick: @escaping (ProductInfo) -> Void) {
        self.title = title
        self.search = search
        self.create = create
        self.onPick = onPick
    }

    public var body: some View {
        NavigationStack {
            List {
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
