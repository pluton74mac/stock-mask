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
                ProductPickerView(title: "Name \(line.label)", suggestion: line.groupID.flatMap { session.suggestions[$0] },
                                  search: { await session.products(matching: $0) },
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

/// Finish → review → lock → export (FR-9, FR-35/36): groups still unnamed (blockers: name each, or
/// leave it unknown on purpose), warnings, totals, the lock, and the export through the share sheet.
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
                            HStack {
                                Button { naming = line } label: { SheetLineRow(line: line) }.buttonStyle(.plain)
                                Button("Leave unknown") {
                                    if let id = line.groupID { Task { await session.markUnknown(group: id) } }
                                }
                                .buttonStyle(.bordered)
                                .font(.caption)
                            }
                        }
                    } header: {
                        Text("Name these, or leave them unknown on purpose")
                    }
                }
                if !session.sheet.warnings.isEmpty {
                    Section("Warnings") {
                        ForEach(session.sheet.warnings, id: \.self) { w in
                            Label(w, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                    }
                }
                Section("Totals: \(session.sheet.totalUnits) units") {
                    ForEach(session.sheet.lines) { SheetLineRow(line: $0) }
                }
                Section {
                    if session.isLocked {
                        Label("Locked: this count is read-only", systemImage: "lock.fill")
                    } else {
                        Button {
                            Task { await session.lock() }
                        } label: {
                            Label("Lock the count", systemImage: "lock")
                        }
                        .disabled(!session.sheet.canLock)
                    }
                } footer: {
                    if !session.sheet.canLock {
                        Text("\(session.sheet.blockers.count) group(s) still need a product, or to be left unknown.")
                    }
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
                ProductPickerView(title: "Name \(line.label)", suggestion: line.groupID.flatMap { session.suggestions[$0] },
                                  search: { await session.products(matching: $0) },
                                  create: { await session.createProduct($0) }) { product in
                    Task { await session.name(line: line, product: product) }
                }
            }
            .task { await session.refreshSheet() }
        }
    }
}

/// The start screen's catalogue step (FR-4): the product list that suggested names come from.
public struct CatalogStep: Sendable, Equatable {
    public var products: Int
    /// CSV files found in the app's Documents folder (the Files app and Finder show it).
    public var files: [URL]
    public var importing: Bool
    public var message: String?

    public init(products: Int = 0, files: [URL] = [], importing: Bool = false, message: String? = nil) {
        self.products = products
        self.files = files
        self.importing = importing
        self.message = message
    }
}

/// Start count (PRD §7): who counts and which zone; or continue the count in progress (FR-7: one
/// active session per device). One venue and one zone per session in the test app. Below, the
/// product catalogue: import a CSV the owner put in the app's folder.
public struct StartView: View {
    @State private var counter = ""
    @State private var zone = "Storeroom"
    let resumable: ResumedSession?
    let catalog: CatalogStep?
    let onImport: (URL) -> Void
    let onRefreshCatalog: () -> Void
    let onResume: () -> Void
    let onStart: (_ counter: String, _ zone: String) -> Void
    let benchmark: BenchmarkStep?

    public init(resumable: ResumedSession? = nil, catalog: CatalogStep? = nil, onImport: @escaping (URL) -> Void = { _ in },
                onRefreshCatalog: @escaping () -> Void = {}, benchmark: BenchmarkStep? = nil,
                onResume: @escaping () -> Void = {}, onStart: @escaping (_ counter: String, _ zone: String) -> Void) {
        self.resumable = resumable
        self.catalog = catalog
        self.onImport = onImport
        self.onRefreshCatalog = onRefreshCatalog
        self.benchmark = benchmark
        self.onResume = onResume
        self.onStart = onStart
    }

    public var body: some View {
        NavigationStack {
            Form {
                if let r = resumable {
                    Section("Count in progress") {
                        Text("\(r.zone), counted by \(r.counter): \(r.units) units so far")
                        Button("Continue this count", action: onResume).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    Section {
                        Text("Finish it in Review (lock) before starting a new one.").font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Counted by") { TextField("Your name", text: $counter) }
                    Section("Zone") { TextField("Zone", text: $zone) }
                    Section {
                        Button("Start count") { onStart(counter, zone) }
                            .disabled(zone.trimmingCharacters(in: .whitespaces).isEmpty
                                      || counter.trimmingCharacters(in: .whitespaces).isEmpty)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
                if let catalog {
                    CatalogSection(step: catalog, onImport: onImport, onRefresh: onRefreshCatalog)
                }
                if let benchmark {
                    Section {
                        Button(benchmark.running ? "Benchmarking…" : "Benchmark the detector", action: benchmark.start)
                            .disabled(benchmark.running)
                        if let status = benchmark.status { Text(status).font(.footnote) }
                    } header: {
                        Text("Testing")
                    } footer: {
                        Text("The detector on the GPU, the Neural Engine and the CPU in turn, on a test frame and on the "
                             + "last photos counted. About a minute: keep StockMask open. The numbers go to the "
                             + "diagnostics folder.")
                    }
                }
            }
            .navigationTitle("StockMask")
        }
    }
}

/// The start screen's testing row: the detector benchmark, and how it is going.
public struct BenchmarkStep {
    public var running: Bool
    public var status: String?
    public var start: () -> Void

    public init(running: Bool, status: String?, start: @escaping () -> Void) {
        self.running = running
        self.status = status
        self.start = start
    }
}

/// FR-4 in the test app: the CSVs in the app's folder, one tap each to import (StockMaskCore maps
/// the columns from their names and skips duplicates, so importing a file twice adds nothing).
struct CatalogSection: View {
    let step: CatalogStep
    let onImport: (URL) -> Void
    let onRefresh: () -> Void

    var body: some View {
        Section {
            Text(step.products == 0 ? "No products yet" : "\(step.products) products")
            ForEach(step.files, id: \.self) { url in
                Button {
                    onImport(url)
                } label: {
                    Label("Import \(url.lastPathComponent)", systemImage: "square.and.arrow.down")
                        .frame(minHeight: 44)
                }
                .disabled(step.importing)
            }
            if step.importing {
                HStack {
                    ProgressView()
                    Text("Importing…").foregroundStyle(.secondary)
                }
            }
            if let message = step.message { Text(message).font(.footnote) }
            Button("Look for CSV files again", action: onRefresh).font(.footnote)
        } header: {
            Text("Product catalogue")
        } footer: {
            Text("Suggested names come from it. Put a CSV (Excel “CSV UTF-8”, Google Sheets, or ; separated) with "
                 + "columns such as Nombre, Marca, ml, U x caja, Código in StockMask's folder: the Files app › On My "
                 + "iPhone › StockMask, or Finder › the iPhone › Files. Then import it here.")
        }
    }
}

extension SheetLine: Hashable {
    public func hash(into h: inout Hasher) { h.combine(id) }
}
