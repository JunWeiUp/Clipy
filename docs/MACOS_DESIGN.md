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

- The primary entry is a nonactivating `NSPanel` with SwiftUI content (`MenuBarPanel/`), opened by left-clicking the status item. The panel uses an opaque semantic content surface and 12 pt corners. The home view prefers 520 × 640 pt; Tools keeps that same size with scrolling content, and detail pages use smaller heights, with the Devices page sized to its device count. `MenuBarPanelPolicy` clamps each size to the current screen’s visible frame, and the controller resizes on navigation or device changes without creating a polling task. It can be pinned; otherwise outside clicks dismiss it.
- On the home view, keep one top row with search plus pin/settings controls, then hidden icons, Clipboard / Snippets / Devices / Tools tabs, scrolling content and bottom status controls. On detail pages, replace those home controls with a compact Back/title row and contextual content. Do not leave an unselected home tab bar on a detail page. The Devices tab starts with a Refresh Devices button and gives each device direct Send Text / Send File buttons (no Send menu). Under each device name, show the same endpoint label as Settings: IP and port for direct connections, or localized “Internet relay” for relay connections. Tools is the fourth home tab: one capture surface with direct Region / Window / Screen buttons, then Lookup / Vocabulary and a Password action. Its header retains the shared hidden-icons strip without moving the tabs. The footer has named Keep Awake and Notifications controls, the installed version and More; banner preferences move into More. Keep Awake uses distinct on/off symbols, accent state and an accessible state label; global search can still find all tools. Do not turn every row into a card.
- Show six recent clipboard entries initially. Full-history searches run off the main thread, debounce input, bound results to 40, and cancel old queries on edit/close. The complete history window remains available. Global search ignores old folder/type filters. Clear old executable results while loading.
- History-row clicks reuse copying and auto-paste for text/HTML/RTF; Copy is an explicit keep-open action. File rows copy files without synthesizing paste. Context menus expose file names, Finder and plain-text actions. Keep full persisted `textPath` data; never copy a list preview as full content.
- Closing before paste must release panel key focus. Validate the originating frontmost PID, clipboard change count, presentation generation and absence of another Clipy key window immediately before deferred paste. Reopen/new clipboard/other app cancels the paste. External feature windows and original status menus receive their action only after the panel is hidden.
- Wrap multi-child detail content in one `VStack` before giving it flexible height. The back/title header must keep its intrinsic height; only the list uses the remaining space. Notification titles and bodies wrap fully inside that scroll area instead of being capped at two/three lines.
- Plain-style buttons must apply `contentShape(Rectangle())` inside the label after its final frame/padding. Tabs, filter pills, quick actions and full-width links must respond across their whole visible bounds, not only their text.
- Search supports ⌘F, arrows and Return, without stealing input-method composition. ⌘1–6 invokes visible history. Escape clears search, returns from a detail page, then closes. Use accessible labels on icon controls and semantic colors in both appearances.
- Hidden icons occupy the same horizontal strip below search on Clipboard / Snippets / Devices / Tools. When more than three items exist, show a labeled scroll control so a clipped item is not the only overflow clue. Use original previews when available, otherwise app icons/names; keep unsupported items disabled with a reason. Empty, disabled, permission and unavailable-display states stay compact. This remains opt-in and reads every connected display's menu bar; matched hosted-window geometry and AX source identity remain mandatory. No icon moving or blind coordinate clicks. An unconfirmed AX result must never trigger a retry or modal alert over a possibly open native menu.
- The existing `NSMenu` remains on right-click and folder hotkeys. Use `AppMenuStyle`, native key equivalents and disabled states there; never embed the new panel as an NSMenu row. Defer panel data refreshes while its context/action menus track, and keep the panel out of menu key-window negotiation. Release query results, thumbnails/view tree and menu memory on dismissal.
- Screenshot selection still uses the existing capture engine. Region selection exposes scrolling capture and recording in its toolbar; do not create a second recording implementation inside the panel.

Settings use a single scrollable document: scrolling reaches the next category without clicking. Sidebar selection follows the visible section; clicking a category jumps to its heading. Use the shared navigation implementation for both general and screenshot settings.

## Content windows

- All focused content windows close with unmodified Escape, including while a text field is focused. Use `EscapeClosingWindow` / `EscapeClosingPanel` (inherited by `HostingWindow`) so normal close delegates, draft saves and unsaved-change prompts run. Sheets, input-method composition and shortcut recording keep their own cancellation first. Borderless panels override `cancelOperation` to use their existing teardown action. Capture overlays retain their session cancellation logic.
- Search: a prominent input, secondary filter rows, quiet category pills, list and preview. Give content the most column width; file locations appear as secondary text under the filename with the full path in a tooltip.
- Word lookup: accept Chinese and English, with explicit submission for online bilingual suggestions and spelling corrections. Chinese translations are selectable English candidates; only opened complete English entries enter vocabulary. Keep candidates readable (20 pt terms, 16 pt explanations) and usable alongside the entry. Preserve local candidates on network failure and open saved candidates offline. Retain single-word clipboard-prefill behavior. Explicit input also accepts phrases and sentences (500 characters, punctuation and numbers); unlisted text shows a separate machine translation with 20–22 pt original/translated text, copy and English read-aloud actions. Keep machine translations out of vocabulary; clear them on new lookup and close. The query field expands to four lines; the button and Command-Return submit longer text.
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

The home menu-bar panel shows the installed bundle version and build number in
a small secondary label at the bottom right, in the footer beside More. It shares
the version formatter with About settings and adds no timer or background work.

## Relay invitation progress

Scanning a device-group QR code submits the request. While this page is open, requests appear automatically above the invitation QR; manual mode requires the inviter to compare the pairing code and explicitly approve. Approval automatically completes enrollment on the requesting device. Do not require “Check join request” or “Finish joining” buttons. Keep discard/cancel controls and inline network/expiry feedback.

Relay invitations default to automatic joining after scanning, with manual pairing-code approval available by turning the option off. Automatic admission verifies a time-limited manager-signed delegation and grants ordinary membership; the inviter need not remain online. QR codes and copied invitations use encrypted short links, while legacy invitations remain supported. Existing members must upgrade to the delegation-aware SDK; the server must support automatic admission and invitation-link endpoints.
