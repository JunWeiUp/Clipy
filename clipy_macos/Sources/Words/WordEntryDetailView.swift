import SwiftUI

/// The same complete dictionary entry is available live and from the saved book.
struct WordEntryDetailView: View {
  @ObservedObject var viewModel: WordLookupViewModel
  let entry: WordEntry
  var onLookupPhrase: ((String) -> Void)? = nil
  var showChineseMeanings = true

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        wordHeader(entry)
        if showChineseMeanings {
          section(.wordMeanings) {
            ForEach(Array(entry.meanings.enumerated()), id: \.offset) { _, meaning in
              HStack(alignment: .firstTextBaseline, spacing: 12) {
                if !meaning.partOfSpeech.isEmpty {
                  Text(meaning.partOfSpeech).font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                }
                Text(meaning.definition).lineSpacing(5).frame(
                  maxWidth: .infinity, alignment: .leading)
              }
              .padding(.vertical, 6)
            }
          }
        } else {
          Text(L10n.t(.wordChineseHidden)).font(.system(size: 14)).foregroundStyle(.secondary)
        }
        if !entry.inflections.isEmpty {
          section(.wordInflections) {
            ForEach(Array(entry.inflections.enumerated()), id: \.offset) { _, form in
              HStack {
                Text(form.name).foregroundStyle(.secondary).frame(
                  width: 110, alignment: .leading)
                Text(form.value)
              }
            }
          }
        }
        section(.wordPhrases) {
          if entry.phrases.isEmpty {
            Text(L10n.t(.wordNoPhrases)).foregroundStyle(.secondary)
          }
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 220), alignment: .topLeading)],
            alignment: .leading, spacing: AppSpacing.md
          ) {
            ForEach(Array(entry.phrases.enumerated()), id: \.offset) { _, phrase in
              VStack(alignment: .leading, spacing: 4) {
                Button {
                  if let onLookupPhrase { onLookupPhrase(phrase.text) }
                  else {
                    viewModel.query = phrase.text
                    viewModel.search()
                  }
                } label: {
                  Text(phrase.text).fontWeight(.medium).multilineTextAlignment(.leading)
                }
                .buttonStyle(.link)
                .help(L10n.t(.wordLookupPhrase))
                if showChineseMeanings {
                  Text(phrase.translation).foregroundStyle(.secondary)
                }
              }
              .padding(.vertical, 3)
              .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
        section(.wordExamples) {
          if entry.examples.isEmpty {
            Text(L10n.t(.wordNoExamples)).foregroundStyle(.secondary)
          }
          ForEach(Array(entry.examples.enumerated()), id: \.offset) { index, example in
            HStack(alignment: .top, spacing: 12) {
              Text(String(index + 1)).font(.system(size: 14).monospacedDigit()).foregroundStyle(
                .tertiary
              )
              .padding(.top, 3)
              VStack(alignment: .leading, spacing: 5) {
                Text(example.text).font(.system(size: 18)).lineSpacing(4)
                if showChineseMeanings {
                  Text(example.translation).foregroundStyle(.secondary).lineSpacing(3)
                }
                if !example.source.isEmpty {
                  Text(example.source).font(.system(size: 14)).foregroundStyle(.tertiary)
                }
              }
            }
            .padding(.vertical, 5)
          }
        }
        Link(L10n.t(.wordSource), destination: entry.sourceURL).font(.system(size: 14))
      }
      .font(.system(size: 18))
      .textSelection(.enabled)
      .frame(maxWidth: 680, alignment: .leading)
      .padding(AppSpacing.xl)
      .frame(maxWidth: .infinity, alignment: .center)
    }
    .id(entry.word)
  }

  private func wordHeader(_ entry: WordEntry) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(entry.word).font(.system(size: 30, weight: .semibold))
      VStack(alignment: .leading, spacing: 12) {
        Text(entry.americanIPA.map { "\(L10n.t(.wordAmerican)) /\($0)/" } ?? L10n.t(.wordNoIPA))
          .foregroundStyle(.secondary)
        Button {
          viewModel.pronounce()
        } label: {
          Label(
            L10n.t(viewModel.isSpeaking ? .wordStopAudio : .wordPlayAudio),
            systemImage: viewModel.isSpeaking ? "stop.fill" : "speaker.wave.2.fill")
        }
        .buttonStyle(AppToolbarButtonStyle())
        .accessibilityIdentifier("wordPronounce")
      }
      if let status = viewModel.audioStatus {
        Text(L10n.t(status)).font(.system(size: 14)).foregroundStyle(.secondary)
      }
    }
  }

  private func section<Content: View>(_ title: L10nKey, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 10) {
      Text(L10n.t(title)).font(.system(size: 18, weight: .semibold))
      Divider()
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

}
