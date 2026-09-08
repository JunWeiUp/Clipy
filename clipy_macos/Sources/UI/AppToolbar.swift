import SwiftUI

struct AppToolbarButton: Identifiable {
  let id = UUID()
  let title: String
  let systemImage: String?
  let action: () -> Void
}

struct AppToolbar: View {
  let leading: [AppToolbarButton]
  var trailing: [AppToolbarButton] = []

  var body: some View {
    AppWindowHeader {
      HStack(spacing: AppSpacing.xs) {
        ForEach(leading) { button in
          toolbarButton(button)
        }
        Spacer(minLength: 0)
        ForEach(trailing) { button in
          toolbarButton(button)
        }
      }
    }
  }

  @ViewBuilder
  private func toolbarButton(_ button: AppToolbarButton) -> some View {
    if let systemImage = button.systemImage {
      Button(action: button.action) {
        Label(button.title, systemImage: systemImage)
      }
      .buttonStyle(AppToolbarButtonStyle())
      .help(button.title)
    } else {
      Button(button.title, action: button.action)
        .buttonStyle(AppToolbarButtonStyle())
    }
  }
}

struct AppToolbarButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(AppFont.body)
      .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
      .padding(.horizontal, 9)
      .frame(minHeight: 30)
      .background {
        RoundedRectangle(cornerRadius: AppCornerRadius.small)
          .fill(
            Color.primary.opacity(
              configuration.isPressed ? 0.12 : (isHovered && isEnabled ? 0.06 : 0)))
      }
      .contentShape(RoundedRectangle(cornerRadius: AppCornerRadius.small))
      .onHover { isHovered = $0 }
  }
}
