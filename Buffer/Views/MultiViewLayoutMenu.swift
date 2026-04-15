import SwiftUI

struct MultiViewLayoutMenu: View {
    let session: PlayerSession

    var body: some View {
        Menu {
            ForEach(availableLayouts, id: \.self) { option in
                Button {
                    session.setLayout(option)
                } label: {
                    HStack {
                        Image(systemName: option.symbol)
                        Text(option.label)
                        if session.layout == option {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: session.layout.symbol)
                .font(.callout)
                .frame(width: 20, height: 20)
                .frame(width: 30, height: 30)
                .background(
                    Color.black.opacity(0.42),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.white.opacity(0.1), lineWidth: 1)
                }
                .foregroundStyle(.white)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Change layout")
    }

    private var availableLayouts: [MultiViewLayout] {
        let count = session.slots.count
        return MultiViewLayout.allCases.filter { $0.capacity >= count }
    }
}
