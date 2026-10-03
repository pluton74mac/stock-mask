import StockMaskAR
import SwiftUI

/// The thin app target: everything else is in app/Packages (StockMaskAR, StockMaskCounting,
/// StockMaskCore). StockMaskRootView checks for LiDAR, asks who counts which zone, then opens the
/// counting screen.
@main
struct StockMaskApp: App {
    var body: some Scene {
        WindowGroup {
            StockMaskRootView()
        }
    }
}
