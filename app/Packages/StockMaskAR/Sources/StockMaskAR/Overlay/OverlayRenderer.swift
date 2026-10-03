#if canImport(RealityKit)
import Foundation
import RealityKit
import StockMaskCounting
import simd
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
    private let detach: @MainActor (Entity) -> Void
    private let followsAnchors: Bool
    private var roots: [UUID: Entity] = [:]
    private var shown: [UUID: OverlayState.Commit] = [:]
    private var faded = false
    public private(set) var rebuilds = 0

    /// - Parameters:
    ///   - followsAnchors: the roots follow their commit's anchor by themselves (ARKit-backed
    ///     `AnchorEntity`), so an anchor move needs nothing here. Otherwise the root is moved.
    public init(makeRoot: @escaping MakeRoot, attach: @escaping @MainActor (Entity) -> Void,
                detach: @escaping @MainActor (Entity) -> Void = { $0.removeFromParent() }, followsAnchors: Bool = false) {
        self.makeRoot = makeRoot
        self.attach = attach
        self.detach = detach
        self.followsAnchors = followsAnchors
    }

    public var commitCount: Int { roots.count }

    /// What a commit draws, apart from where its anchor is: an anchor refinement alone never
    /// rebuilds entities (ARKit refines anchors often while it maps).
    static func sameContent(_ a: OverlayState.Commit, _ b: OverlayState.Commit) -> Bool {
        a.items == b.items && a.halfExtents == b.halfExtents && a.misses.map(\.id) == b.misses.map(\.id)
            && a.misses.map(\.local) == b.misses.map(\.local)
    }

    public func sync(_ state: OverlayState) {
        let wanted = Set(state.commits.map(\.id))
        for (id, root) in roots where !wanted.contains(id) {
            detach(root)
            roots[id] = nil
            shown[id] = nil
        }
        for c in state.commits where shown[c.id] != c {
            if let old = shown[c.id], let root = roots[c.id], Self.sameContent(old, c) {
                if !followsAnchors { root.setTransformMatrix(c.anchor, relativeTo: nil) }
                shown[c.id] = c
                continue
            }
            if let old = roots[c.id] { detach(old) }
            rebuilds += 1
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
        let upright = Self.upright(in: c.anchor)
        for item in c.items {
            let e = ModelEntity(mesh: Self.mesh(item.cls), materials: [Self.material(Self.green, opacity: 0.4)])
            e.name = "item:\(item.id.uuidString)"
            e.position = item.local
            e.orientation = upright
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

    /// The rotation, in the anchor's space, that stands a shape upright in the world (ARKit's +y is
    /// up, against gravity) with its front (+z) turned to the zone's, flattened to the horizontal.
    /// A counted zone's axes are the camera's (the sensor's, landscape), so a shape left in the
    /// anchor's axes lies on its side whenever the phone isn't held in landscape.
    static func upright(in anchor: simd_float4x4) -> simd_quatf {
        func axis(_ c: SIMD4<Float>) -> SIMD3<Float> {
            let v = SIMD3(c.x, c.y, c.z)
            return simd_length(v) > 1e-6 ? simd_normalize(v) : v
        }
        let x = axis(anchor.columns.0), y = axis(anchor.columns.1), z = axis(anchor.columns.2)
        var front = SIMD3<Float>(z.x, 0, z.z)
        if simd_length(front) < 1e-3 { front = SIMD3(y.x, 0, y.z) }   // a zone facing straight up or down
        if simd_length(front) < 1e-3 { front = SIMD3(0, 0, 1) }
        front = simd_normalize(front)
        let up = SIMD3<Float>(0, 1, 0)
        let world = simd_float3x3(simd_normalize(simd_cross(up, front)), up, front)
        // anchor rotation⁻¹ × world (the anchor's rotation is orthonormal: its inverse is its transpose)
        return simd_normalize(simd_quatf(simd_float3x3(x, y, z).transpose * world))
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
        case .carton: .generateBox(size: SIMD3(0.07, 0.20, 0.07))  // a 1 L carton
        case .bag: .generateBox(size: SIMD3(0.12, 0.20, 0.07))     // a 1 kg bag of sugar
        }
    }
}
#endif
