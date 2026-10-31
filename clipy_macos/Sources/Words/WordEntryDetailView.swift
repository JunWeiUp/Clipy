import SwiftUI

/// The same complete dictionary entry is available live and from the saved book.
/// Live lookup moves inflections and phrases to `WordEntryInspector` (V3 right column);
/// the word book keeps them inline because it has no inspector column.
struct WordEntryDetailView: View {
  @ObservedObject var viewModel: WordLookupViewModel
  let entry: WordEntry
  var onLookupPhrase: ((String) -> Void)? = nil
  var showChineseMeanings = true
  var showsInlineExtras = true

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        wordHeader(entry)
        section(.wordMeanings) {
          if showChineseMeanings {
            ForEach(Array(entry.meanings.enumerated()), id: \.offset) { _, meaning in
              HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(meaning.partOfSpeech).font(.system(size: 16, weight: .medium))
                  .foregroundStyle(WordsV3Style.text2).frame(width: 44, alignment: .leading)
                Text(meaning.definition).lineSpacing(5).frame(
                  maxWidth: .infinity, alignment: .leading)
              }
              .padding(.vertical, 6)
            }
          } else {
            Text(L10n.t(.wordChineseHidden)).font(.system(size: 14)).foregroundStyle(WordsV3Style.text3)
          }
        }
        if showsInlineExtras {
          if !entry.inflections.isEmpty {
            section(.wordInflections) {
              ForEach(Array(entry.inflections.enumerated()), id: \.offset) { _, form in
                HStack {
                  Text(form.name).foregroundStyle(WordsV3Style.text2).frame(width: 110, alignment: .leading)
                  Text(form.value)
                }
              }
            }
          }
          section(.wordPhrases) {
            if entry.phrases.isEmpty {
              Text(L10n.t(.wordNoPhrases)).foregroundStyle(WordsV3Style.text2)
            }
            LazyVGrid(
              columns: [GridItem(.adaptive(minimum: 220), alignment: .topLeading)],
              alignment: .leading, spacing: AppSpacing.md
            ) {
              ForEach(Array(entry.phrases.enumerated()), id: \.offset) { _, phrase in
                WordPhraseButton(phrase: phrase, showTranslation: showChineseMeanings,
                                 size: 18, translationSize: 16) { lookup(phrase.text) }
              }
            }
          }
        }
        section(.wordExamples) {
          if entry.examples.isEmpty {
            Text(L10n.t(.wordNoExamples)).foregroundStyle(WordsV3Style.text2)
          }
          ForEach(Array(entry.examples.enumerated()), id: \.offset) { index, example in
            HStack(alignment: .top, spacing: 12) {
              Text(String(index + 1)).font(.system(size: 14).monospacedDigit())
                .foregroundStyle(WordsV3Style.text3)
                .padding(.top, 4)
              VStack(alignment: .leading, spacing: 2) {
                Text(example.text).font(.system(size: 18)).lineSpacing(4)
                if showChineseMeanings {
                  Text(example.translation).font(.system(size: 16))
                    .foregroundStyle(WordsV3Style.text2).lineSpacing(3)
                }
                if !example.source.isEmpty {
                  Text(example.source).font(.system(size: 14)).foregroundStyle(WordsV3Style.text3)
                }
              }
            }
            .padding(.vertical, 6)
          }
        }
        Link(destination: entry.sourceURL) {
          Label(L10n.t(.wordSource), systemImage: "arrow.up.right.square")
            .font(.system(size: 14))
            .foregroundStyle(AppColor.accent)
        }
        .padding(.top, -2)
      }
      .font(.system(size: 18))
      .textSelection(.enabled)
      .frame(maxWidth: 680, alignment: .leading)
      .padding(.horizontal, 36).padding(.top, 24).padding(.bottom, 20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .id(entry.word)
  }

  private func lookup(_ text: String) {
    if let onLookupPhrase { onLookupPhrase(text) }
    else {
      viewModel.query = text
      viewModel.search()
    }
  }

  private func wordHeader(_ entry: WordEntry) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(entry.word).font(.system(size: 30, weight: .semibold)).tracking(-0.6)
      Text(entry.americanIPA.map { "\(L10n.t(.wordAmerican)) /\($0)/" } ?? L10n.t(.wordNoIPA))
        .foregroundStyle(WordsV3Style.text2)
        .padding(.top, 8)
      WordPronounceButton(viewModel: viewModel)
        .padding(.top, 10)
      if let status = viewModel.audioStatus {
        Text(L10n.t(status)).font(.system(size: 14)).foregroundStyle(WordsV3Style.text2)
          .padding(.top, 6)
      }
    }
  }

  private func section<Content: View>(_ title: L10nKey, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 6) {
      Text(L10n.t(title)).font(.system(size: 18, weight: .semibold))
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(WordsV3Style.line).frame(height: 0.5) }
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Pill-shaped American pronunciation control (V3 `.pbtn`).
struct WordPronounceButton: View {
  @ObservedObject var viewModel: WordLookupViewModel

  var body: some View {
    Button { viewModel.pronounce() } label: {
      HStack(spacing: 7) {
        Image(systemName: viewModel.isSpeaking ? "stop.fill" : "speaker.wave.2.fill")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 20, height: 20)
          .background(AppColor.accent, in: Circle())
        Text(L10n.t(viewModel.isSpeaking ? .wordStopAudio : .wordPlayAudio))
          .font(.system(size: 14))
          .foregroundStyle(viewModel.isSpeaking ? AppColor.accent : WordsV3Style.text2)
      }
      .padding(.leading, 6).padding(.trailing, 12)
      .frame(height: 30)
      .background(viewModel.isSpeaking ? WordsV3Style.selection : WordsV3Style.fill, in: Capsule())
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("wordPronounce")
  }
}

struct WordPhraseButton: View {
  let phrase: WordEntry.Phrase
  var showTranslation = true
  var size: CGFloat = 16
  var translationSize: CGFloat = 14
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 1) {
        Text(phrase.text).font(.system(size: size, weight: .medium))
          .foregroundStyle(AppColor.accent).multilineTextAlignment(.leading)
        if showTranslation && !phrase.translation.isEmpty {
          Text(phrase.translation).font(.system(size: translationSize))
            .foregroundStyle(WordsV3Style.text2).multilineTextAlignment(.leading)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(L10n.t(.wordLookupPhrase))
  }
}

/// V3 right column: inflections, phrases and the word-book record for the entry.
struct WordEntryInspector: View {
  @ObservedObject var viewModel: WordLookupViewModel
  @ObservedObject var store: WordBookStore
  let entry: WordEntry

  private func t(_ zh: String, _ en: String) -> String { ModelTranslationText.t(zh, en) }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        card(L10n.t(.wordInflections), symbol: "list.bullet.indent") {
          if entry.inflections.isEmpty {
            Text(t("无", "None")).font(.system(size: 14)).foregroundStyle(WordsV3Style.text3)
          }
          ForEach(Array(entry.inflections.enumerated()), id: \.offset) { _, form in
            HStack(alignment: .firstTextBaseline, spacing: 0) {
              Text(form.name).foregroundStyle(WordsV3Style.text2).frame(width: 92, alignment: .leading)
              Text(form.value).textSelection(.enabled)
            }
            .font(.system(size: 16)).padding(.vertical, 3)
          }
        }
        card(L10n.t(.wordPhrases), symbol: "list.bullet") {
          if entry.phrases.isEmpty {
            Text(L10n.t(.wordNoPhrases)).font(.system(size: 14)).foregroundStyle(WordsV3Style.text3)
          }
          VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(entry.phrases.enumerated()), id: \.offset) { _, phrase in
              WordPhraseButton(phrase: phrase) {
                viewModel.query = phrase.text
                viewModel.search()
              }
            }
          }
        }
        if let saved = store.words.first(where: { $0.id == entry.word.lowercased() }) {
          bookCard(saved)
        }
      }
      .padding(18)
    }
    .background(WordsV3Style.secondaryContent)
  }

  private func bookCard(_ saved: SavedWord) -> some View {
    card(L10n.t(.wordBook), symbol: "books.vertical", trailing: {
      Text(L10n.t(saved.isFamiliar ? .wordFamiliar : .wordUnfamiliar))
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(saved.isFamiliar ? WordsV3Style.ok : WordsV3Style.warn)
        .padding(.horizontal, 7).frame(height: 20)
        .background((saved.isFamiliar ? WordsV3Style.ok : WordsV3Style.warn).opacity(0.13),
                    in: RoundedRectangle(cornerRadius: 5))
    }) {
      Toggle(L10n.t(.wordFamiliar), isOn: Binding(
        get: { saved.isFamiliar },
        set: { store.setFamiliar($0, id: saved.id) }))
        .toggleStyle(.checkbox)
        .font(.system(size: 14))
        .help(L10n.t(.wordBookCheckHelp))
        .accessibilityIdentifier("wordInspectorFamiliar")
      HStack(alignment: .top, spacing: 14) {
        stat("\(saved.lookupCount)", L10n.t(.wordBookLookups))
        stat(Self.shortDate(saved.lastLookedUpAt), L10n.t(.wordBookLastLookup))
        stat(Self.shortDate(saved.firstLookedUpAt), t("首次查询", "First lookup"))
      }
      .padding(.top, 12)
      Text(L10n.t(.wordBookHint)).font(.system(size: 12)).foregroundStyle(WordsV3Style.text3)
        .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        .padding(.top, 14)
    }
  }

  private func stat(_ value: String, _ label: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(value).font(.system(size: 15, weight: .semibold).monospacedDigit()).lineLimit(1)
      Text(label).font(.system(size: 12)).foregroundStyle(WordsV3Style.text3).lineLimit(1)
    }
    .fixedSize()
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  static func shortDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: PreferencesManager.shared.appLanguage == .zh ? "zh_CN" : "en_US")
    formatter.setLocalizedDateFormatFromTemplate("MMMd")
    return formatter.string(from: date)
  }

  private func card<Content: View>(_ title: String, symbol: String,
                                   @ViewBuilder content: () -> Content) -> some View {
    card(title, symbol: symbol, trailing: { EmptyView() }, content: content)
  }

  private func card<Trailing: View, Content: View>(_ title: String, symbol: String,
                                                   @ViewBuilder trailing: () -> Trailing,
                                                   @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 7) {
        Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(AppColor.accent)
        Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(WordsV3Style.text2)
        Spacer(minLength: 4)
        trailing()
      }
      .padding(.bottom, 10)
      content()
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WordsV3Style.card, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(WordsV3Style.line, lineWidth: 0.5))
  }
}
