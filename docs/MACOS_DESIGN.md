# macOS design standard

Clipy is a native, frequently used desktop utility. Its interface prioritizes readable content, predictable controls and quick access. Use this standard for new windows and when changing existing macOS UI.

## Shared foundation

| Area | Standard | Implementation |
| --- | --- | --- |
| Window | Native visible title and traffic-light buttons; opaque content | `HostingWindow` |
| Color | System semantic colors; one system accent; light and dark appearances | `AppColor` |
| Typography | System font: 13 pt body, 12 pt secondary, 11 pt metadata, 20 pt page title | `AppFont` |
| Spacing | 4, 8, 12, 16, 20, 24 pt; 28 pt between major content groups | `AppSpacing` |
| Corners | 6 pt small controls, 8 pt input surfaces, 12 pt large containers | `AppCornerRadius` |
| Toolbar | 16 pt horizontal / 12 pt vertical padding; subdued secondary actions | `AppWindowHeader`, `AppToolbarButtonStyle` |
| Input | Consistent padding, semantic control background and fine border | `AppInputSurface` |
| Settings | 168 pt native sidebar, continuous grouped document, scroll-following selection | `AppSettingsLayout` |
| Empty state | One relevant SF Symbol and a concise, readable explanation | `EmptyStateView` |
| Counts | Muted capsule and tabular digits; reserve accent for actions/selection | `CountBadge` |

Do not add manual title-bar padding inside normal windows. `HostingWindow` places the content below the native title bar. Do not stack full-window transparency under opaque lists: materials belong to navigation and toolbars. Honor Reduce Transparency and Reduce Motion. Bringing an already visible window forward must not fade it out again.

## Menu bar

- Use native `NSMenu` rows, section headings, selection and keyboard navigation. Avoid custom button views embedded in menu rows.
- Keep search, word lookup and screenshot actions first. Show six recent clipboard items directly; keep older entries in paginated submenus with the existing history limit.
- Put snippets and devices in their own submenus. Keep device addresses out of the top-level menu.
- Use 16 × 16 pt SF Symbols or thumbnails with stable dimensions. Measure long titles in points, so Chinese and English entries have comparable widths. Preserve full content in the underlying data and paths in tooltips.
- Display shortcuts through `keyEquivalent` and `keyEquivalentModifierMask`, never by appending glyphs or numbers to labels.
- Use the shared `AppMenuStyle`. Disabled states must be explicit because its menus do not automatically enable items.
- Never rebuild the menu while it is tracking. Update only device rows inside the device submenu. Release the complete menu tree and loaded summaries when it closes.

Settings use a single scrollable document: scrolling reaches the next category without clicking. Sidebar selection follows the visible section; clicking a category jumps to its heading. Use the shared navigation implementation for both general and screenshot settings.

## Content windows

- All focused content windows close with unmodified Escape, including while a text field is focused. Use `EscapeClosingWindow` / `EscapeClosingPanel` (inherited by `HostingWindow`) so normal close delegates, draft saves and unsaved-change prompts run. Sheets, input-method composition and shortcut recording keep their own cancellation first. Borderless panels override `cancelOperation` to use their existing teardown action. Capture overlays retain their session cancellation logic.
- Search: a prominent input, secondary filter rows, quiet category pills, list and preview. Give content the most column width; file locations appear as secondary text under the filename with the full path in a tooltip.
- Word lookup: accept Chinese and English, with explicit submission for online bilingual suggestions and spelling corrections. Chinese translations are selectable English candidates; only opened complete English entries enter vocabulary. Keep candidates readable (20 pt terms, 16 pt explanations) and usable alongside the entry. Preserve local candidates on network failure and open saved candidates offline. Retain single-word clipboard-prefill behavior. Explicit input also accepts phrases and sentences (500 characters, punctuation and numbers); unlisted text shows a separate machine translation with 20–22 pt original/translated text, copy and English read-aloud actions. Keep machine translations out of vocabulary; clear them on new lookup and close. The query field expands to four lines; the button and Command-Return submit longer text.
- Vocabulary: a searchable word list with Unfamiliar / Familiar filters and checkboxes, plus the same complete detail view as lookup. Checking moves a word to Familiar; unchecking moves it back. Share bilingual fuzzy matching with lookup candidates: exact/prefix/substring first, then bounded subsequences and English typo tolerance; search definitions, phrases, examples and inflections too. Preserve familiarity on repeat lookup. Saved definitions are available offline; pronunciation reuses the lookup audio path. Use readable 18 pt detail text, 20 pt list headwords and 16 pt summaries.
- Snippets: three panes — 180 pt folder navigation, 260 pt snippet list with search/excerpts, and a flexible document editor. New/copy actions are visible; library actions live in an overflow menu. Folder settings open beside the folder navigation. Edits save to a captured snippet ID, including pending content when switching selection or closing; Copy always uses the current editor text. Native tables preserve keyboard navigation and drag reordering; disable reordering while filtering to avoid ambiguous positions.
- Notifications: search and application groups, neutral count badges, compact actions; secondary/clear commands belong in the overflow menu.
- Logs: monospace only for timestamps and log content; readable semantic level badges.
- Smart app switch: use a focused native text editor, explicitly submit on Return, and preserve IME composition handling. Select enabled Doubao on presentation and restore the previous source only when the user has not changed it. After composition handling, Escape captures the latest text, cancels pending resolution, closes the window and pastes into its originating app once activation completes. Preserve exact text, leave empty/ordinary closes without clipboard changes, and cancel deferred paste on a new presentation, different foreground app or clipboard change. A missing original app leaves the copied text available for manual paste. Show ambiguous applications as keyboard-selectable rows. Keep app aliases, descriptions and model configuration in the continuous settings document; never show an API key outside its secure field.
- Smart Switch has six actions: smart intent, configured app launch, projectless ZCode chat with draft prefill, Open Codex, web search and translation. Show all six in a two-row grid with no pagination or overflow menu; settings allow ordering, not hiding. Wheel input cycles selection only; preserve normal input/result scrolling. Explicit app launch still takes priority locally. ZCode must verify projectless mode and prefill the full draft without sending. Removed actions must be rejected by model-response validation; older duplicate ZCode actions merge during configuration migration.
- Smart Switch alone uses a native opaque nonactivating NSPanel, preserving the original frontmost app and peripheral app presets while accepting keyboard input. Check the panel's key window, not NSApp.isActive, for voice readiness. Hide it before external app activation so it releases keyboard focus; errors may restore its retained draft without activating Clipy. Escape paste-back also works when the caller remained frontmost. Ordinary HostingWindow windows retain normal activation.
- A completed voice hold owns a window presentation independently of voice readiness. Early release, incidental peripheral profile events and readiness failure detach the pending voice handoff without closing or reactivating the window. Keep the caller, text and input source until normal dismissal; explicit Escape/Command-W and sleep/reset still cancel preparation.
- ZCode input protection takes priority over automatic entry: a confirmed text input or unresolved ZCode focus preserves dictation; only confirmed non-text focus opens the panel. Enabling AXManualAccessibility must continue to the actual focus read even when Electron keeps reporting false. Use system-wide focus only when its PID matches the inspected app; never log text contents. Other apps retain the existing unknown-focus fallback.
- Automatic voice entry is opt-in and shares Doubao’s configured hold-to-talk key. Read fresh focus metadata on every trigger and again before presenting. Only positive text-input evidence preserves normal dictation; other controls and unknown/unavailable focus open the switcher. Keep unknown distinct in diagnostics. Do not gate a new gesture on a stale cached text-input result or an application/role allowlist. Secure input and missing permissions still prevent interception. Prepare the input client before relaying the trigger. Keep short taps and modifier shortcuts ordered, cancel a release before readiness, and retain explicit Return submission. Inspect Accessibility metadata on events, without text logging or idle polling. Detect Electron’s documented AX support by capability and briefly retry tree warmup within a fixed bound. A writable AXValue alone does not identify a text input: sliders and checkboxes also expose it. Explain the unknown-focus popup fallback and possible false positives for custom inputs in both languages. Dismissal returns focus to the originating app after the input window closes and invalidates the closed editor’s focus snapshot. Successful app activation, navigation to settings, a reopened popup and user-initiated focus changes retain their destination.
- Passwords: monospace for the password itself, normal system typography for controls. Preserve generation and clipboard behavior.

## Screenshots and recording

Canvas overlays and floating capture tools are specialized surfaces. Keep their dark chrome for contrast against arbitrary captured images; use the app's system accent and shared control radii. Preserve user-customized capture colors, tool geometry, hit testing and permission behavior. Annotation colors are document content and must not be recolored to match the app theme.

## Review checklist

1. Build for the existing macOS 13 deployment target.
2. Inspect light and dark appearances, a narrow supported window, long Chinese/English text and empty states.
3. Check menu selection, nested history, file actions and shortcut labels; check that repeated open/close does not reload hidden content.
4. Keep accessibility labels and tooltips for icon-only controls. Never encode state with color alone.
5. Avoid new polling, timers, image effects or persistent data caches for decoration. Verify existing functional regression tests when navigation or menu structure changes.

References: [Apple menus](https://developer.apple.com/design/human-interface-guidelines/menus), [Apple materials](https://developer.apple.com/design/human-interface-guidelines/materials).
