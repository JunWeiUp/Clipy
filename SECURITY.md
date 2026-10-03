# Security policy and limitations

## Reporting a vulnerability

Do not post credentials, clipboard history, notification contents, passwords,
private files, or unredacted crash logs in a public issue.

Use GitHub's **Report a vulnerability** option on this repository's Security tab
if the maintainer has enabled it. If it is unavailable, open a minimal issue
asking for a private reporting channel, without exploit details or sensitive data.
Include the affected commit/version, platform, impact and sanitized reproduction
steps through the private channel. There is no guaranteed response-time SLA.

Security fixes target the current development branch; old releases do not have a
separate long-term-support commitment. This project has not undergone a full
independent security audit.

## Current sync threat model

- The protocol is intended for **trusted local networks**, not Internet exposure.
  Do not port-forward the sync listener or expose it on public Wi-Fi/VPNs.
- Current source uses AES-256-GCM with a built-in default key, derived as
  `SHA256("ClipySyncSecret2026")`. There is no pairing code, QR import or shared
  secret configuration. Older saved pairing codes do not affect current traffic.
- This key is public. Any LAN participant with the application/source can decrypt
  or construct payloads; default encryption is not authenticated device identity
  or a confidentiality boundary against those participants.
- Protocol v3 deliberately rejects v2 clients. Upgrade both endpoints together.
  Versions through v1.0.25 use v2; source and packages from v1.0.26 use
  pairing-free v3.
- Device IDs and outgoing sharing switches express user choices, not identity.
- Envelope metadata is not encrypted/authenticated as a whole. Do not equate
  payload encryption with authenticated transport or comprehensive replay protection.
- Allow-lists primarily control outgoing automatic sync and history replay.
  Incoming history can be accepted without reciprocal authorization; one-shot
  `history.direct` and file transfers also do not require mutual authorization.
  See [the protocol](docs/PROTOCOL.md).
  Disable sync when receiving unsolicited LAN data would be unacceptable.

## Local data

- Clipboard history, snippets, search/OCR text, notifications and logs can contain
  sensitive information. OS account/device access is part of the trust boundary.
- macOS offers optional at-rest encryption for history media. This is **not** a
  promise that every database column, snippet, log or exported file is encrypted.
- Received files may be written to `Downloads/Clipy` (Android uses private storage
  as a fallback). They are ordinary files and are not automatically safe to open.
- Exclude password managers and other sensitive apps from clipboard collection.
  A generated password copied to the clipboard may enter history and sync.
- Redact diagnostics before sharing. The repository hygiene check only detects
  a few obvious patterns in the current tree; it does not scan Git history or
  certify that no secrets exist. Rotate any real credential exposed in history.

## Build and release integrity

Normal builds must not install/start applications or select a private signing
identity implicitly. Android release builds require explicit signing configuration;
debug-signed builds are for local validation only. The macOS build is ad-hoc signed
unless a signing identity is supplied and is **not notarized** by this workflow.

Before publishing, complete the [release checklist](docs/DEVELOPMENT.md#release-checklist),
including the [macOS GPLv3 license and source checks](THIRD_PARTY_NOTICES.md).
