import SwiftUI

struct LockScreenSiteTitleView: View {
    let title: String

    var body: some View {
        HStack(spacing: 2) {
            Image(.iconJetpack)
                .resizable()
                .frame(width: 11, height: 11)
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.system(size: 11))
                .lineLimit(1)
                .allowsTightening(true)
        }

    }
}
