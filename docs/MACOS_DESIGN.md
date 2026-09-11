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
- Word lookup: accept Chinese and English, with explicit submission for online bilingual suggestions and spelling corrections. Chinese translations are selectable English candidates; only opened complete English entries enter vocabulary. Keep candidates readable (20 pt terms, 16 pt explanations) and usable alongside the entry. Preserve local candidates on network failure and open saved candidates offline. Retain clipboard-prefill behavior.
- Vocabulary: a searchable word list with Unfamiliar / Familiar filters and checkboxes, plus the same complete detail view as lookup. Checking moves a word to Familiar; unchecking moves it back. Share bilingual fuzzy matching with lookup candidates: exact/prefix/substring first, then bounded subsequences and English typo tolerance; search definitions, phrases, examples and inflections too. Preserve familiarity on repeat lookup. Saved definitions are available offline; pronunciation reuses the lookup audio path. Use readable 18 pt detail text, 20 pt list headwords and 16 pt summaries.
- Snippets: three panes — 180 pt folder navigation, 260 pt snippet list with search/excerpts, and a flexible document editor. New/copy actions are visible; library actions live in an overflow menu. Folder settings open beside the folder navigation. Edits save to a captured snippet ID, including pending content when switching selection or closing; Copy always uses the current editor text. Native tables preserve keyboard navigation and drag reordering; disable reordering while filtering to avoid ambiguous positions.
- Notifications: search and application groups, neutral count badges, compact actions; secondary/clear commands belong in the overflow menu.
- Logs: monospace only for timestamps and log content; readable semantic level badges.
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
