import SwiftUI

enum ControlStyle {
    static let accent = Color(red: 0.34, green: 0.88, blue: 0.94)
    static let background = Color(red: 0.075, green: 0.105, blue: 0.15)
    static let surface = Color.white.opacity(0.065)
    static let border = Color.white.opacity(0.09)
}

struct CardSection<Content: View>: View {
    let header: String?
    let content: Content

    init(_ header: String? = nil, @ViewBuilder content: () -> Content) {
        self.header = header
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let header {
                Text(header)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(ControlStyle.accent.opacity(0.8))
                    .textCase(.uppercase)
                    .padding(.leading, 2)
            }
            VStack(alignment: .leading, spacing: 11) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ControlStyle.surface, in: .rect(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(ControlStyle.border, lineWidth: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
