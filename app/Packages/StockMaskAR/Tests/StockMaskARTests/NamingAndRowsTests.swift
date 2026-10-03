import CoreGraphics
import CoreText
import Foundation
import RealityKit
import Testing
import simd
import StockMaskCounting
@testable import StockMaskAR

// The owner's decisions of 2 October: rows behind take the front bottle's group; names are
// suggested (label text against the imported catalogue, teach-once), never assigned without a tap;
// counted bottles stand upright. Product names here are invented.

/// Two "kinds" of label by box height: the front row's boxes are taller (nearer) than the back row's.
struct RowEmbedder: AppearanceEmbedder {
    var split: Float = 0.22
    func embeddings(of boxes: [SIMD4<Float>], in image: DetectorInput) async throws -> [[Float]?] {
        boxes.map { ($0.w - $0.y) > split ? [1, 0, 0] : [0, 1, 0] }
    }
}

/// Every item looks the same.
struct SameEmbedder: AppearanceEmbedder {
    func embeddings(of boxes: [SIMD4<Float>], in image: DetectorInput) async throws -> [[Float]?] {
        boxes.map { _ in [0.6, 0.8, 0] }
    }
}

/// Reads the same label text off any photo.
struct FakeLabelReader: LabelReader {
    var texts: [String]
    func read(_ images: [CGImage], hints: [String]) async throws -> [String] { texts }
}

let catalogCSV = """
    Código;Nombre;Marca;Contenido;U x caja
    A1;Gin Aurora London Dry;Destilería Norte;700 ml;6
    A2;Vermut Monte Rojo;Bodega Monte;1 L;12
    A3;Licor Tres Ríos;;750 cc;6
    A1;Gin Aurora (repetido);Destilería Norte;700 ml;6
    A9;;Sin nombre;1 L;6
    """

@Suite("Naming: rows, catalogue, suggestions", .serialized)
@MainActor
struct NamingAndRowsTests {
    /// Three bottles in front, three right behind them (12 cm deeper, 1 cm to the side).
    static let rows = SyntheticScene(bottles: [-0.12, 0, 0.12].map { SyntheticScene.Bottle(x: $0, front: 1.0) }
        + [-0.11, 0.01, 0.13].map { SyntheticScene.Bottle(x: $0, front: 1.12) })

    func session(_ embedder: (any AppearanceEmbedder)? = RowEmbedder(), reader: (any LabelReader)? = nil,
                 data: URL? = nil) async throws -> (CountingSession, CoreStockStore, FakeEnvironment) {
        let store = try CoreStockStore.inMemory()
        let session = CountingSession(store: store, detector: FakeDetector(), embedder: embedder, labelReader: reader)
        let environment = FakeEnvironment()
        if let data {
            environment.files = CommitFileStore(dataDirectory: data)
            session.dataDirectory = data
        }
        session.environment = environment
        try await store.startSession(venue: CoreStockStore.defaultVenue, zone: "Storeroom", counter: "Tester")
        return (session, store, environment)
    }

    /// Three detector frames of `indices`, then a commit (the lifter is skipped: true positions).
    func see(_ indices: [Int], in scene: SyntheticScene, session: CountingSession, at t0: Double,
             image: CGImage = tinyImage) async {
        let observations = indices.map { i in
            let b = scene.bottles[i]
            return LiveTracks.Observation(cls: .bottle, score: 0.8, box: scene.box(b), position: scene.centre(b))
        }
        for k in 0..<3 { session.tracks.update(observations, at: t0 + 0.1 * Double(k)) }
        await session.commit(.shutter, frame: scene.snapshot(t0 + 0.2, withDepth: false), image: DetectorInput(image: image))
    }

    @Test func rowsFrontToBack() {
        let id = (0..<6).map { _ in UUID() }
        let items = [
            RowGrouper.Item(id: id[0], cls: .bottle, position: SIMD3(0, 0, -1)),
            RowGrouper.Item(id: id[1], cls: .bottle, position: SIMD3(0.01, 0, -1.09)),       // right behind
            RowGrouper.Item(id: id[2], cls: .bottleTop, position: SIMD3(0.005, 0.15, -1.18)), // two rows back, by its top
            RowGrouper.Item(id: id[3], cls: .bottle, position: SIMD3(0.09, 0, -1.09)),       // the next row along
            RowGrouper.Item(id: id[4], cls: .bottle, position: SIMD3(0, 0.36, -1.09)),       // the shelf above
            RowGrouper.Item(id: id[5], cls: .can, position: SIMD3(0, 0, -1.09)),             // another kind
        ]
        let fronts = RowGrouper().fronts(of: items, among: items, forward: SIMD3(0, -0.2, -1))
        #expect(fronts[id[1]] == id[0])
        #expect(fronts[id[2]] == id[1] && RowGrouper.frontOfRow(id[2], fronts: fronts) == id[0])
        #expect(fronts[id[0]] == nil && fronts[id[3]] == nil && fronts[id[4]] == nil && fronts[id[5]] == nil)

        // Seen from 40° to the side, "behind" is still along the view (flattened).
        let turn = simd_quatf(angle: 40 * .pi / 180, axis: SIMD3(0, 1, 0))
        let turned = items.map { RowGrouper.Item(id: $0.id, cls: $0.cls, position: turn.act($0.position)) }
        let seen = RowGrouper().fronts(of: turned, among: turned, forward: turn.act(SIMD3(0, 0, -1)))
        #expect(seen == fronts)
        // Looking straight down there is no "behind".
        #expect(RowGrouper().fronts(of: items, among: items, forward: SIMD3(0, -1, 0)).isEmpty)
    }

    @Test func aRowBehindTakesTheFrontBottlesGroupInOneCommit() async throws {
        let (s, _, _) = try await session()
        await see(Array(0..<6), in: Self.rows, session: s, at: 0)
        let card = try #require(s.card)
        #expect(card.added == 6)
        #expect(card.groups.count == 1 && card.groups.first?.count == 6)

        // Without the row rule the two rows look different: two groups.
        let (plain, _, _) = try await session()
        plain.rows.maxDepthGap = 0
        await see(Array(0..<6), in: Self.rows, session: plain, at: 0)
        #expect(plain.card?.groups.map(\.count) == [3, 3])
    }

    @Test func aRowBehindSeenLaterJoinsTheEarlierGroupAndNamingNamesTheRow() async throws {
        let (s, store, _) = try await session()
        await see([0, 1, 2], in: Self.rows, session: s, at: 0)
        let front = try #require(s.card?.groups.first)
        #expect(front.count == 3)
        await see(Array(0..<6), in: Self.rows, session: s, at: 1)
        let card = try #require(s.card)
        #expect(card.added == 3)
        #expect(card.groups.isEmpty)                       // its items all joined the front row's group
        #expect(card.joined.map(\.id) == [front.id] && card.joined.first?.count == 6)
        #expect(s.sheet.totalUnits == 6 && s.sheet.unnamed.count == 1)

        let product = try #require(await s.createProduct(ProductDraft(name: "Gin Aurora", sizeML: 700)))
        await s.name(group: try #require(card.joined.first), product: product)
        #expect(s.sheet.lines.map(\.label) == ["Gin Aurora"] && s.sheet.lines.first?.units == 6)
        #expect(s.card?.joined.first?.product == product)
        let groups = try await store.groups(ofCommit: front.commitID)
        #expect(groups.first?.count == 6 && groups.first?.product == product)
    }

    @Test func catalogueImportSkipsDuplicatesAndNamelessRows() async throws {
        let store = try CoreStockStore.inMemory()
        #expect(await store.productCount() == 0)
        let summary = try await store.importCatalog(csv: Data(catalogCSV.utf8))
        #expect(summary.rows == 5 && summary.created == 3 && summary.skipped == 2 && summary.products == 3)
        #expect(summary.nameColumn == "Nombre")
        #expect(summary.text.hasPrefix("3 new, 2 skipped"))
        #expect(await store.productCount() == 3)
        // Importing the same file again adds nothing.
        let again = try await store.importCatalog(csv: Data(catalogCSV.utf8))
        #expect(again.created == 0 && again.skipped == 5 && again.products == 3)
        // No column that looks like a name: nothing.
        let none = try await store.importCatalog(csv: Data("code;size\nA1;700\n".utf8))
        #expect(none.nameColumn == nil && none.created == 0)
        #expect(none.text.hasPrefix("No column looks like the product name"))

        try await store.startSession(venue: CoreStockStore.defaultVenue, zone: "Storeroom", counter: "Tester")
        let catalog = try await store.catalog()
        #expect(catalog.count == 3)
        let gin = try #require(catalog.first { $0.name == "Gin Aurora London Dry" })
        #expect(gin.brand == "Destilería Norte" && gin.sizeML == 700 && gin.unitsPerCase == 6)
    }

    @Test func labelTextMatchesTheCatalogueDespiteOCRSlips() {
        let products = [
            ProductInfo(id: UUID(), name: "Gin Aurora London Dry", sizeML: 700, brand: "Destilería Norte"),
            ProductInfo(id: UUID(), name: "Vermut Monte Rojo", sizeML: 1000, brand: "Bodega Monte"),
            ProductInfo(id: UUID(), name: "Licor Tres Ríos", sizeML: 750),
        ]
        let m = ProductMatcher()
        let gin = m.best(texts: ["AUR0RA", "LONDON DRY GIN", "DESTILERIA NORTE", "700ml"], among: products)
        #expect(gin?.product.id == products[0].id)
        #expect((gin?.confidence ?? 0) > 0.9)
        let licor = m.best(texts: ["TRES RIOS", "licor"], among: products)
        #expect(licor?.product.id == products[2].id)
        #expect(m.best(texts: ["Agua mineral"], among: products) == nil)
        #expect(m.best(texts: [], among: products) == nil)
        #expect(m.best(texts: ["GIN"], among: [ProductInfo(id: UUID(), name: "Gin")]) == nil)   // three letters: too little
        // One shared word ("monte") isn't enough to pick between two products that both carry it.
        let twins = [ProductInfo(id: UUID(), name: "Monte Rojo"), ProductInfo(id: UUID(), name: "Monte Blanco")]
        let tie = m.best(texts: ["MONTE"], among: twins)
        #expect(tie == nil || tie!.confidence < 0.6)
        #expect(ProductMatcher.similarity("aurora", "aur0ra") > 0.8)
        #expect(ProductMatcher.words("Destilería NORTE 70cl") == ["destileria", "norte", "70cl"])
    }

    @Test func teachOnceSuggestsWhatLooksLikeANamedProduct() {
        var t = TeachOnce()
        let gin = ProductInfo(id: UUID(), name: "Gin Aurora")
        #expect(t.suggest([[1, 0, 0]]) == nil)
        t.learn(gin, embeddings: [[1, 0, 0], [0.98, 0.1, 0]])
        let s = t.suggest([[0.99, 0.05, 0]])
        #expect(s?.product == gin && (s?.confidence ?? 0) > 0.8)
        #expect(t.suggest([[0, 1, 0]]) == nil)
    }

    /// Vision reads synthetic label text; the matcher picks the product.
    @Test func visionReadsALabel() async throws {
        let w = 600, h = 300
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for (text, y, size) in [("AURORA", 170, 90.0), ("LONDON DRY GIN", 80, 44.0)] {
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, CGFloat(size), nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
            ]))
            ctx.textPosition = CGPoint(x: 30, y: y)
            CTLineDraw(line, ctx)
        }
        let texts = try await VisionLabelReader().read([ctx.makeImage()!], hints: ["aurora"])
        print("Vision read: \(texts)")
        #expect(texts.joined(separator: " ").uppercased().contains("AURORA"))
        let products = [ProductInfo(id: UUID(), name: "Gin Aurora London Dry", sizeML: 700),
                        ProductInfo(id: UUID(), name: "Vermut Monte Rojo", sizeML: 1000)]
        #expect(ProductMatcher().best(texts: texts, among: products)?.product.id == products[0].id)
    }

    /// The card's suggestion: label text first (the catalogue), then teach-once for a later commit
    /// of the same-looking product. Each is only pre-selected: naming takes the confirming tap.
    @Test func suggestionsComeFromTheLabelThenFromTeachOnce() async throws {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("naming-\(UUID().uuidString)")
        let (s, store, environment) = try await session(SameEmbedder(), reader: FakeLabelReader(texts: ["AUR0RA", "LONDON DRY", "700 ml"]),
                                                        data: data)
        _ = try await store.importCatalog(csv: Data(catalogCSV.utf8))
        let image = CGContext(data: nil, width: 1440, height: 1920, bitsPerComponent: 8, bytesPerRow: 1440 * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            .makeImage()!
        await see([0, 1, 2], in: Self.rows, session: s, at: 0, image: image)
        let group = try #require(s.card?.groups.first)
        #expect(group.cropPaths.count == 3)
        #expect(group.cropPaths.allSatisfy { FileManager.default.fileExists(atPath: data.appendingPathComponent($0).path) })
        await s.suggesting?.value
        let suggestion = try #require(s.suggestions[group.id])
        #expect(suggestion.source == .labelText && suggestion.product.name == "Gin Aurora London Dry")
        #expect(suggestion.confidence > 0.8)   // the brand isn't on this label: no mark-down for it
        #expect(s.card?.groups.first?.product == nil)      // FR-31: suggested, not assigned
        #expect(s.readingLabels.isEmpty)

        await s.confirmSuggestion(for: group)
        #expect(s.card?.groups.first?.product?.name == "Gin Aurora London Dry")
        #expect(s.suggestions[group.id] == nil)

        // Further back on the same shelf (out of the counted zone, not behind a counted bottle):
        // the same look, so teach-once suggests the product just named.
        let far = SyntheticScene(bottles: [-0.12, 0, 0.12].map { SyntheticScene.Bottle(x: $0, front: 1.8) })
        await see([0, 1, 2], in: far, session: s, at: 1, image: image)
        let second = try #require(s.card?.groups.first)
        #expect(second.id != group.id && second.product == nil)
        await s.suggesting?.value
        #expect(s.suggestions[second.id]?.source == .teachOnce)
        #expect(s.suggestions[second.id]?.product.name == "Gin Aurora London Dry")
        #expect(environment.saved.count == 2)   // (the session only holds its environment weakly)
    }

    /// The counted zone's axes are the camera's: in portrait the sensor's x axis points up, so a
    /// cylinder left in the anchor's axes lay on its side. Items must stand up in the world.
    @Test func countedBottlesStandUpright() throws {
        let portrait = simd_quatf(angle: -.pi / 2, axis: SIMD3(0, 0, 1))                 // sensor x along world -y
        let pitch = simd_quatf(angle: -20 * .pi / 180, axis: SIMD3(1, 0, 0))            // looking a bit down
        let yawed = simd_quatf(angle: 30 * .pi / 180, axis: SIMD3(0, 1, 0))
        var anchor = simd_float4x4(yawed * pitch * portrait)
        anchor.columns.3 = SIMD4(0.2, 1.1, -1, 1)
        let commitID = UUID()
        var state = OverlayState()
        let zone = CountedZone(commitID: commitID, transform: anchor, halfExtents: SIMD3(0.4, 0.3, 0.1))
        state.add(CommitResult(commitID: commitID, newItems: [CountedItem(cls: .bottle, position: SIMD3(0.2, 1.0, -1.1), commitID: commitID),
                                                              CountedItem(cls: .case, position: SIMD3(0.4, 1.0, -1.1), commitID: commitID)],
                               matched: [], possibleMisses: [], zone: zone, driftAlarm: false), detections: [])
        let scene = Entity()
        // On the phone the root is an AnchorEntity that ARKit places at the anchor; here, by hand.
        let renderer = OverlayRenderer(makeRoot: { c in
            let root = Entity()
            root.setTransformMatrix(c.anchor, relativeTo: nil)
            return root
        }, attach: { scene.addChild($0, preservingWorldTransform: true) })
        renderer.sync(state)
        let root = try #require(scene.children.first)
        let items = root.children.filter { $0.name.hasPrefix("item:") }
        #expect(items.count == 2)
        for item in items {
            let up = item.convert(direction: SIMD3(0, 1, 0), to: nil)
            #expect(simd_distance(up, SIMD3(0, 1, 0)) < 1e-4, "up is \(up)")
            // Still at the item's place in the world.
            let p = item.position(relativeTo: nil)
            #expect(abs(p.y - 1.0) < 1e-4 && abs(p.z + 1.1) < 1e-4)
        }
        // A box's front faces the camera's side, horizontally.
        let front = items[1].convert(direction: SIMD3(0, 0, 1), to: nil)
        #expect(abs(front.y) < 1e-4)
        #expect(simd_dot(front, yawed.act(SIMD3(0, 0, 1))) > 0.99)
    }
}
