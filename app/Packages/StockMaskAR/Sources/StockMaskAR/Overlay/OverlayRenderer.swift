#if canImport(RealityKit)
import Foundation
import RealityKit
import StockMaskCounting
#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformColor = UIColor
#endif

/// Keeps RealityKit entities in step with `OverlayState` (PRD §9's visual language):
/// - counted item: a green shape (35-45% opacity) at the item, anchored in 3D, so it stays stuck
///   to the bottle whether or not the detector runs;
/// - counted zone: a faint green tint over the shelf area;
/// - possible miss: an amber "+", facing the camera, tappable (`missID(of:)`).
///
/// Each commit gets its own root entity from `makeRoot`: on the phone an `AnchorEntity` on the
/// commit's ARAnchor (so ARKit's refinements move the overlays), in tests a world anchor.
@MainActor
public final class OverlayRenderer {
    public typealias MakeRoot = @MainActor (OverlayState.Commit) -> Entity

    private let makeRoot: MakeRoot
    private let attach: @MainActor (Entity) -> Void
    private var roots: [UUID: Entity] = [:]
    private var shown: [UUID: OverlayState.Commit] = [:]
    private var faded = false

    public init(makeRoot: @escaping MakeRoot, attach: @escaping @MainActor (Entity) -> Void) {
        self.makeRoot = makeRoot
        self.attach = attach
    }

    public var commitCount: Int { roots.count }

    public func sync(_ state: OverlayState) {
        let wanted = Set(state.commits.map(\.id))
        for (id, root) in roots where !wanted.contains(id) {
            root.removeFromParent()
            roots[id] = nil
            shown[id] = nil
        }
        for c in state.commits where shown[c.id] != c {
            roots[c.id]?.removeFromParent()
            let root = makeRoot(c)
            root.name = "commit:\(c.id.uuidString)"
            build(c, into: root)
            if faded { root.components.set(OpacityComponent(opacity: 0.3)) }
            attach(root)
            roots[c.id] = root
            shown[c.id] = c
        }
        if state.faded != faded {
            faded = state.faded
            for root in roots.values { root.components.set(OpacityComponent(opacity: faded ? 0.3 : 1)) }
        }
    }

    /// The possible miss an entity belongs to (for a tap: `ARView.entity(at:)`), if any.
    public static func missID(of entity: Entity?) -> String? {
        var e = entity
        while let current = e {
            if current.name.hasPrefix("miss:") { return String(current.name.dropFirst(5)) }
            e = current.parent
        }
        return nil
    }

    private func build(_ c: OverlayState.Commit, into root: Entity) {
        let tint = ModelEntity(mesh: .generateBox(size: SIMD3(c.halfExtents.x * 2, c.halfExtents.y * 2, 0.005)),
                               materials: [Self.material(Self.green, opacity: 0.12)])
        tint.name = "zone:\(c.id.uuidString)"
        root.addChild(tint)
        for item in c.items {
            let e = ModelEntity(mesh: Self.mesh(item.cls), materials: [Self.material(Self.green, opacity: 0.4)])
            e.name = "item:\(item.id.uuidString)"
            e.position = item.local
            root.addChild(e)
        }
        for miss in c.misses {
            let plus = Entity()
            plus.name = "miss:\(miss.id)"
            plus.position = miss.local
            for size in [SIMD3<Float>(0.07, 0.016, 0.004), SIMD3<Float>(0.016, 0.07, 0.004)] {
                plus.addChild(ModelEntity(mesh: .generateBox(size: size), materials: [Self.material(Self.amber, opacity: 0.95)]))
            }
            plus.components.set(BillboardComponent())
            plus.components.set(CollisionComponent(shapes: [.generateBox(size: SIMD3(0.09, 0.09, 0.04))]))
            root.addChild(plus)
        }
    }

    static let green = (r: 0.27, g: 0.85, b: 0.35)
    static let amber = (r: 1.0, g: 0.65, b: 0.0)

    static func material(_ c: (r: Double, g: Double, b: Double), opacity: Float) -> UnlitMaterial {
        var m = UnlitMaterial(color: PlatformColor(red: c.r, green: c.g, blue: c.b, alpha: 1))
        m.blending = .transparent(opacity: .init(floatLiteral: opacity))
        return m
    }

    /// A proxy shape per class, centred on the item (the Lifter puts items at mid-height on their axis).
    static func mesh(_ cls: ObjectClass) -> MeshResource {
        switch cls {
        case .bottle: .generateCylinder(height: 0.28, radius: 0.04)
        case .can: .generateCylinder(height: 0.12, radius: 0.033)
        case .case: .generateBox(size: SIMD3(0.30, 0.24, 0.24))
        case .bottleTop: .generateSphere(radius: 0.02)
        }
    }
}
#endif
