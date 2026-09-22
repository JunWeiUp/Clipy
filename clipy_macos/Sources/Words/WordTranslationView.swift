import SwiftUI

struct WordTranslationView: View {
  @ObservedObject var viewModel: WordLookupViewModel
  let translation: WordTranslation
  @State private var copied = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 10) {
          Text(L10n.t(.wordOriginal)).font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.secondary)
          Text(translation.original).font(.system(size: 20)).lineSpacing(8)
        }
        Divider()
        VStack(alignment: .leading, spacing: 12) {
          Text(L10n.t(translation.direction == .chineseToEnglish ? .wordEnglishTranslation : .wordChineseTranslation))
            .font(.system(size: 24, weight: .semibold))
          Text(translation.text).font(.system(size: 22)).lineSpacing(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("wordTranslationText")
        }
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 16) { actions }
          VStack(alignment: .leading, spacing: 12) { actions }
        }
        if let status = viewModel.audioStatus {
          Text(L10n.t(status)).font(.system(size: 14)).foregroundStyle(.secondary)
        }
        Text(L10n.t(.wordMachineTranslation)).font(.system(size: 14)).foregroundStyle(.secondary)
        Link(L10n.t(.wordSource), destination: translation.sourceURL).font(.system(size: 14))
      }
      .textSelection(.enabled)
      .frame(maxWidth: 680, alignment: .leading)
      .padding(AppSpacing.xl)
      .frame(maxWidth: .infinity)
    }
  }

  @ViewBuilder private var actions: some View {
    Button {
      NSPasteboard.general.clearContents()
      copied = NSPasteboard.general.setString(translation.text, forType: .string)
    } label: {
      Label(L10n.t(copied ? .snippetCopied : .wordCopyTranslation), systemImage: copied ? "checkmark" : "doc.on.doc")
    }
    .accessibilityIdentifier("wordCopyTranslation")
    .buttonStyle(AppToolbarButtonStyle())
    .font(.system(size: 16))
    Button { viewModel.pronounce() } label: {
      Label(L10n.t(viewModel.isSpeaking ? .wordStopAudio : .wordReadEnglish),
            systemImage: viewModel.isSpeaking ? "stop.fill" : "speaker.wave.2.fill")
    }
    .accessibilityIdentifier("wordPronounce")
    .buttonStyle(AppToolbarButtonStyle())
    .font(.system(size: 16))
  }
}
