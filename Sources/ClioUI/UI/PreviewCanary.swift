#if DEBUG
import SwiftUI

/// A preview with no dependencies at all.
///
/// Diagnostic: if this one renders and the real previews do not, the problem
/// is in what they build on. If this one does not render either, the problem
/// is the Xcode setup — scheme, destination, or the package not being opened
/// through Package.swift — and no amount of changing the views will help.
#Preview("Canary") {
    VStack(spacing: 8) {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 32))
            .foregroundStyle(.green)
        Text("Previews work")
            .font(.headline)
    }
    .padding(40)
}
#endif
