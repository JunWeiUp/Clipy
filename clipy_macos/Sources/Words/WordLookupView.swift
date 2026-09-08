import SwiftUI

struct WordLookupView: View {
  @EnvironmentObject private var languageObserver: AppLanguageObserver
  @ObservedObject var viewModel: WordLookupViewModel
  @FocusState private var queryFocused: Bool

  var body: some View {
    let _ = languageObserver.revision
    AppListWindowLayout {
      AppWindowHeader {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
          HStack(spacing: 10) {
            HStack {
              Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
              TextField(L10n.t(.wordPlaceholder), text: $viewModel.query)
                .textFieldStyle(.plain)
                .focused($queryFocused)
                .onSubmit { viewModel.search() }
                .accessibilityIdentifier("wordQuery")
            }
            .modifier(AppInputSurface())
            Button(L10n.t(.wordSearch)) { viewModel.search() }
              .buttonStyle(.borderedProminent)
              .controlSize(.large)
              .disabled(viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
              .accessibilityIdentifier("wordSearch")
          }
        }
      }
    } content: {
      VStack(spacing: 0) {
        if viewModel.isLoading {
          Spacer()
          ProgressView(L10n.t(.wordLoading))
          Spacer()
        } else if let error = viewModel.errorKey {
          placeholder(
            symbol: "magnifyingglass", title: L10n.t(error), detail: L10n.t(.wordTryAgain))
        } else if let entry = viewModel.entry {
          ScrollView {
            VStack(alignment: .leading, spacing: 24) {
              wordHeader(entry)
              section(.wordMeanings) {
                ForEach(Array(entry.meanings.enumerated()), id: \.offset) { _, meaning in
                  HStack(alignment: .firstTextBaseline, spacing: 12) {
                    if !meaning.partOfSpeech.isEmpty {
                      Text(meaning.partOfSpeech).font(AppFont.section)
                        .foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                    }
                    Text(meaning.definition).lineSpacing(5).frame(
                      maxWidth: .infinity, alignment: .leading)
                  }
                  .padding(.vertical, 6)
                }
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
                        viewModel.query = phrase.text
                        viewModel.search()
                      } label: {
                        Text(phrase.text).fontWeight(.medium).multilineTextAlignment(.leading)
                      }
                      .buttonStyle(.link)
                      .help(L10n.t(.wordLookupPhrase))
                      Text(phrase.translation).foregroundStyle(.secondary)
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
                    Text(String(index + 1)).font(.caption.monospacedDigit()).foregroundStyle(
                      .tertiary
                    )
                    .padding(.top, 3)
                    VStack(alignment: .leading, spacing: 5) {
                      Text(example.text).font(.system(size: 14)).lineSpacing(4)
                      Text(example.translation).foregroundStyle(.secondary).lineSpacing(3)
                      if !example.source.isEmpty {
                        Text(example.source).font(.caption).foregroundStyle(.tertiary)
                      }
                    }
                  }
                  .padding(.vertical, 5)
                }
              }
              Link(L10n.t(.wordSource), destination: entry.sourceURL).font(.caption)
            }
            .textSelection(.enabled)
            .frame(maxWidth: 680, alignment: .leading)
            .padding(AppSpacing.xl)
            .frame(maxWidth: .infinity, alignment: .center)
          }
          .id(entry.word)
        } else {
          placeholder(
            symbol: "character.book.closed", title: L10n.t(.wordWelcome),
            detail: L10n.t(.wordWelcomeDetail))
        }
        Divider()
        Text(L10n.t(.wordPrivacy)).font(.caption).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading).padding(AppSpacing.sm)
          .background(AppColor.groupedBackground)
      }
    }
    .onAppear { queryFocused = true }
    .onChange(of: viewModel.focusRequest) { _ in queryFocused = true }
    .onExitCommand { NSApp.keyWindow?.close() }
    .background(
      Button("") { queryFocused = true }.keyboardShortcut("l", modifiers: .command).hidden())
  }

  private func wordHeader(_ entry: WordEntry) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(entry.word).font(.system(size: 30, weight: .semibold))
      HStack(spacing: 12) {
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
        Text(L10n.t(status)).font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func section<Content: View>(_ title: L10nKey, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 10) {
      Text(L10n.t(title)).font(AppFont.section)
      Divider()
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func placeholder(symbol: String, title: String, detail: String) -> some View {
    VStack(spacing: 14) {
      Spacer()
      Image(systemName: symbol).font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
      Text(title).font(.title3.weight(.medium))
      Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
      Spacer()
    }
    .padding(28)
    .frame(maxWidth: .infinity)
  }
}
