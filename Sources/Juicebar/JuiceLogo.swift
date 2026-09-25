import SwiftUI

/// Shared app artwork, also used by the app icon and website favicon.
struct JuiceLogo: View {
    private static let artwork: NSImage? = Bundle.module.url(forResource: "juicebar", withExtension: "png").flatMap(NSImage.init(contentsOf:))

    var body: some View {
        if let artwork = Self.artwork {
            Image(nsImage: artwork).resizable().scaledToFit().accessibilityHidden(true)
        }
    }
}
