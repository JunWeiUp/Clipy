import SwiftUI

struct WordLookupView: View {
  @EnvironmentObject private var languageObserver: AppLanguageObserver
  @ObservedObject var viewModel: WordLookupViewModel
  @ObservedObject var wordBook: WordBookStore

  init(viewModel: WordLookupViewModel) {
    self.viewModel = viewModel
    self.wordBook = viewModel.wordBook
  }
  @FocusState private var queryFocused: Bool

  private var trimmedQueryIsEmpty: Bool {
    viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    let _ = languageObserver.revision
    VStack(spacing: 0) {
      header
      Rectangle().fill(WordsV3Style.line).frame(height: 0.5)
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      if let error = wordBook.errorKey {
        Text(L10n.t(error)).foregroundStyle(.red).padding(AppSpacing.sm)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      Rectangle().fill(WordsV3Style.line).frame(height: 0.5)
      Text(viewModel.usesModelTranslation ? ModelTranslationText.t("提交后发送至配置的模型接口 · 译文不保存 · 朗读使用系统语音", "Submission sends text to your configured API · Translations are not saved · Read-aloud uses system speech") : L10n.t(.wordPrivacy))
        .font(.system(size: 14)).foregroundStyle(WordsV3Style.text3).lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(WordsV3Style.secondaryContent)
    }
    .background(WordsV3Style.content)
    .onAppear { queryFocused = true }
    .onChange(of: viewModel.focusRequest) { _ in queryFocused = true }
    .onExitCommand { NSApp.keyWindow?.close() }
    .background(
      Button("") { queryFocused = true }.keyboardShortcut("l", modifiers: .command).hidden())
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Picker("", selection: $viewModel.usesModelTranslation) {
          Text(L10n.t(.wordSearch)).tag(false)
          Text(ModelTranslationText.t("模型翻译", "Model translation")).tag(true)
        }
        .labelsHidden().pickerStyle(.segmented).fixedSize()
        if viewModel.usesModelTranslation {
          Picker(ModelTranslationText.t("翻译为", "Translate into"), selection: $viewModel.translationToEnglish) {
            Text(ModelTranslationText.t("中文", "Chinese")).tag(false)
            Text(ModelTranslationText.t("英文", "English")).tag(true)
          }
          .pickerStyle(.menu).fixedSize()
        }
        Spacer()
        Text(ModelTranslationText.t("⌘L 聚焦输入 · ⌘↩ 提交", "⌘L Focus input · ⌘↩ Submit"))
          .font(.system(size: 11.5)).foregroundStyle(WordsV3Style.text3)
      }
      HStack(alignment: .top, spacing: 10) {
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: "magnifyingglass").font(.system(size: 15))
            .foregroundStyle(WordsV3Style.text3).padding(.top, 5)
          if viewModel.usesModelTranslation {
            TextEditor(text: $viewModel.query)
              .font(.system(size: 20))
              .scrollContentBackground(.hidden)
              .frame(maxWidth: .infinity).frame(height: 76)
              .focused($queryFocused)
              .accessibilityLabel(ModelTranslationText.t("待翻译文本", "Text to translate"))
              .accessibilityIdentifier("wordQuery")
          } else {
            TextField(L10n.t(.wordPlaceholder), text: $viewModel.query, axis: .vertical)
              .lineLimit(1...4)
              .frame(maxWidth: .infinity)
              .font(.system(size: 20))
              .textFieldStyle(.plain)
              .focused($queryFocused)
              .onSubmit { viewModel.search() }
              .accessibilityIdentifier("wordQuery")
          }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(minHeight: viewModel.usesModelTranslation ? 96 : 44, alignment: .topLeading)
        .background(WordsV3Style.content, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
          .strokeBorder(queryFocused ? AppColor.accent : WordsV3Style.line, lineWidth: 1))
        .background(RoundedRectangle(cornerRadius: 10.5)
          .stroke(AppColor.accent.opacity(queryFocused ? 0.22 : 0), lineWidth: 5)
          .padding(-0.5))
        .contentShape(Rectangle())
        .onTapGesture { queryFocused = true }
        Button(viewModel.usesModelTranslation ? ModelTranslationText.t("翻译", "Translate") : L10n.t(.wordSearch)) { viewModel.search() }
          .buttonStyle(WordPrimaryButtonStyle())
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(trimmedQueryIsEmpty)
          .accessibilityIdentifier("wordSearch")
      }
    }
    .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 12)
    .background(WordsV3Style.content)
  }

  @ViewBuilder private var content: some View {
    VStack(spacing: 0) {
      if !viewModel.suggestions.isEmpty {
        candidateList
          .frame(maxHeight: viewModel.entry == nil && viewModel.translation == nil ? .infinity : 180)
        Rectangle().fill(WordsV3Style.line).frame(height: 0.5)
      }
      if viewModel.isLoading {
        ProgressView(L10n.t(.wordLoading)).padding(24)
        if viewModel.suggestions.isEmpty { Spacer() }
      } else if let error = viewModel.modelError {
        placeholder(symbol: "exclamationmark.bubble", title: error,
                    detail: ModelTranslationText.t("可在 API 设置中检查配置后重新翻译。", "Check API settings and retry."))
      } else if let error = viewModel.errorKey {
        if viewModel.suggestions.isEmpty {
          placeholder(
            symbol: "magnifyingglass", title: L10n.t(error), detail: L10n.t(.wordTryAgain))
        } else {
          Text(L10n.t(error)).font(.system(size: 16)).foregroundStyle(.secondary).padding(16)
        }
      } else if let entry = viewModel.entry {
        HStack(spacing: 0) {
          WordEntryDetailView(viewModel: viewModel, entry: entry, showsInlineExtras: false)
          WordsV3Style.line.frame(width: 1)
          WordEntryInspector(viewModel: viewModel, store: wordBook, entry: entry)
            .frame(width: 300)
        }
      } else if let translation = viewModel.translation {
        WordTranslationView(viewModel: viewModel, translation: translation)
          .id(translation.original)
      } else if viewModel.suggestions.isEmpty {
        placeholder(
          symbol: "character.book.closed", title: L10n.t(.wordWelcome),
          detail: viewModel.usesModelTranslation
            ? ModelTranslationText.t("先在 API 设置中填写接口和模型，再输入句子并点击翻译。⌘ 回车也可提交。", "Configure your API endpoint and model, then enter a sentence and click Translate or press ⌘ Return.")
            : L10n.t(.wordWelcomeDetail))
      }
    }
  }

  private var candidateList: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(L10n.t(.wordCandidates)).font(.system(size: 18, weight: .semibold))
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(viewModel.suggestions) { suggestion in
            Button { viewModel.selectSuggestion(suggestion) } label: {
              HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                  Text(suggestion.word).font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.primary)
                  if !suggestion.detail.isEmpty {
                    Text(suggestion.detail).font(.system(size: 16)).foregroundStyle(.secondary)
                      .lineLimit(2).lineSpacing(4)
                  }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
              }
              .multilineTextAlignment(.leading)
              .padding(.vertical, 12).padding(.horizontal, 8)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.t(.wordLookupPhrase))
            Divider()
          }
        }
      }
    }
    .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 12)
    .accessibilityIdentifier("wordCandidates")
  }

  private func placeholder(symbol: String, title: String, detail: String) -> some View {
    VStack(spacing: 14) {
      Spacer()
      Image(systemName: symbol).font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
      Text(title).font(.system(size: 24, weight: .medium))
      Text(detail).font(.system(size: 18)).lineSpacing(6).foregroundStyle(.secondary).multilineTextAlignment(.center)
      Spacer()
    }
    .padding(28)
    .frame(maxWidth: .infinity)
  }
}

/// Prominent 44pt submit button from the V3 word workspace.
struct WordPrimaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 16, weight: .medium))
      .foregroundStyle(.white)
      .padding(.horizontal, 20)
      .frame(height: 44)
      .background(AppColor.accent.opacity(configuration.isPressed ? 0.82 : 1),
                  in: RoundedRectangle(cornerRadius: 9))
      .shadow(color: AppColor.accent.opacity(0.35), radius: 1, y: 1)
      .opacity(isEnabled ? 1 : 0.45)
      .contentShape(Rectangle())
  }
}
