import SwiftUI
import UIKit

/// Full-screen background image with a dark veil for readable foreground content.
/// Replace `Assets.xcassets/AppBackground` with your own image; falls back to a gradient if the asset is missing.
struct AppBackgroundView: View {
    var overlayOpacity: Double = 0.42

    var body: some View {
        Group {
            if UIImage(named: "AppBackground") != nil {
                Image("AppBackground")
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [
                        Color(red: 0.12, green: 0.32, blue: 0.72),
                        Color(red: 0.18, green: 0.48, blue: 0.88).opacity(0.9),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .overlay(Color.black.opacity(overlayOpacity))
        .ignoresSafeArea()
    }
}
