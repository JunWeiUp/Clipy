# Security policy and limitations

## Reporting a vulnerability

Do not post pairing secrets, clipboard history, notification contents, passwords,
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
- Payloads use AES-256-GCM. A non-empty user pairing secret is derived with HKDF;
  configure the same strong, private secret on every participating device.
- **An empty pairing secret uses a public, hard-coded compatibility key.** Anyone
  who knows the source can derive it. That mode does not provide confidentiality
  against an attacker with access to the traffic.
- Device IDs and the authorized-devices list are not cryptographic proof of
  identity. The current protocol has no authenticated key exchange; all devices
  sharing a secret belong to the same trust group, not isolated per-device pairs.
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
including the unresolved [third-party license review](THIRD_PARTY_NOTICES.md).
