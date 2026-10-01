import SwiftUI

/// The live list (FR-32/33): a sheet over the running camera, one line per product (full cases +
/// loose units), unnamed groups flagged, search and an "unknown only" filter, manual lines (FR-30).
public struct LiveListView: View {
    let session: CountingSession
    let onReview: () -> Void
    @State private var query = ""
    @State private var unknownOnly = false
    @State private var naming: SheetLine?
    @State private var addingManual = false

    public init(session: CountingSession, onReview: @escaping () -> Void) {
        self.session = session
        self.onReview = onReview
    }

    var lines: [SheetLine] {
        session.sheet.lines.filter { line in
            (!unknownOnly || line.needsNaming)
                && (query.isEmpty || line.label.localizedCaseInsensitiveContains(query))
        }
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Search", text: $query)
                    Toggle("Unknown only", isOn: $unknownOnly)
                }
                Section("\(session.sheet.totalUnits) units · \(session.sheet.products) products") {
                    if lines.isEmpty { Text("Point at products to start").foregroundStyle(.secondary) }
                    ForEach(lines) { line in
                        Button {
                            if line.needsNaming { naming = line }
                        } label: {
                            SheetLineRow(line: line)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section {
                    Button {
                        addingManual = true
                    } label: {
                        Label("Add manually (kegs, partial cases, closed cupboards)", systemImage: "plus")
                    }
                }
            }
            .navigationTitle("Count")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Finish → Review", action: onReview) }
            }
            .sheet(item: $naming) { line in
                ProductPickerView(title: "Name \(line.label)", search: { await session.products(matching: $0) },
                                  create: { await session.createProduct($0) }) { product in
                    Task { await session.name(line: line, product: product) }
                }
            }
            .sheet(isPresented: $addingManual) { ManualLineForm(session: session) }
            .task { await session.refreshSheet() }
        }
    }
}

struct SheetLineRow: View {
    let line: SheetLine

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(line.label).fontWeight(line.needsNaming ? .regular : .semibold)
                    .foregroundStyle(line.needsNaming ? .orange : .primary)
                Text(line.needsNaming ? "tap to name · \(line.source)" : line.source)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(line.quantityText).font(.title3.monospacedDigit())
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// FR-30: any product and quantity, in cases and/or units. Quantities only: there is no depth
/// multiplier anywhere (FR-29 removed).
public struct ManualLineForm: View {
    let session: CountingSession
    @State private var product: ProductInfo?
    @State private var picking = false
    @State private var cases = 0
    @State private var units = 0
    @State private var note = ""
    @Environment(\.dismiss) private var dismiss

    public init(session: CountingSession) { self.session = session }

    public var body: some View {
        NavigationStack {
            Form {
                Button(product?.title ?? "Choose a product") { picking = true }
                Stepper("Full cases: \(cases)", value: $cases, in: 0...999)
                    .disabled(product?.unitsPerCase == nil)
                Stepper("Units: \(units)", value: $units, in: 0...9999)
                TextField("Note", text: $note)
            }
            .navigationTitle("Add manually")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let product else { return }
                        Task {
                            await session.addManualLine(product: product, fullCases: cases, looseUnits: units, note: note)
                            dismiss()
                        }
                    }
                    .disabled(product == nil || cases + units == 0)
                }
            }
            .sheet(isPresented: $picking) {
                ProductPickerView(title: "Product", search: { await session.products(matching: $0) },
                                  create: { await session.createProduct($0) }) { product = $0 }
            }
        }
    }
}

/// Finish → review → export (FR-35/36): groups still unnamed, possible misses left, totals, and the
/// export through the share sheet.
public struct ReviewView: View {
    let session: CountingSession
    @State private var naming: SheetLine?
    @State private var exported: URL?
    @State private var exportError: String?

    public init(session: CountingSession) { self.session = session }

    public var body: some View {
        NavigationStack {
            List {
                if !session.sheet.unnamed.isEmpty {
                    Section {
                        ForEach(session.sheet.unnamed) { line in
                            Button { naming = line } label: { SheetLineRow(line: line) }.buttonStyle(.plain)
                        }
                    } header: {
                        Text("Name these, or export them as unknown")
                    }
                }
                if session.overlay.possibleMisses > 0 {
                    Section("Warnings") {
                        Label("\(session.overlay.possibleMisses) possible misses not checked (amber +)",
                              systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
                Section("Totals: \(session.sheet.totalUnits) units") {
                    ForEach(session.sheet.lines) { SheetLineRow(line: $0) }
                }
                Section("Export") {
                    ForEach(ExportFormat.allCases) { format in
                        Button(format.title) {
                            Task {
                                do {
                                    exported = try await session.export(format)
                                    exportError = nil
                                } catch {
                                    exported = nil
                                    exportError = "\(format.title): \(error)"
                                }
                            }
                        }
                    }
                    if let exported {
                        ShareLink(item: exported) {
                            Label("Share \(exported.lastPathComponent)", systemImage: "square.and.arrow.up")
                        }
                    }
                    if let exportError { Text(exportError).font(.caption).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Review")
            .sheet(item: $naming) { line in
                ProductPickerView(title: "Name \(line.label)", search: { await session.products(matching: $0) },
                                  create: { await session.createProduct($0) }) { product in
                    Task { await session.name(line: line, product: product) }
                }
            }
            .task { await session.refreshSheet() }
        }
    }
}

/// Start count (PRD §7): who counts and which zone. One venue and one zone per session in the test app.
public struct StartView: View {
    @State private var counter = ""
    @State private var zone = "Storeroom"
    let onStart: (_ counter: String, _ zone: String) -> Void

    public init(onStart: @escaping (_ counter: String, _ zone: String) -> Void) { self.onStart = onStart }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Counted by") { TextField("Your name", text: $counter) }
                Section("Zone") { TextField("Zone", text: $zone) }
                Section {
                    Button("Start count") { onStart(counter, zone) }
                        .disabled(zone.trimmingCharacters(in: .whitespaces).isEmpty)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .navigationTitle("StockMask")
        }
    }
}

extension SheetLine: Hashable {
    public func hash(into h: inout Hasher) { h.combine(id) }
}
