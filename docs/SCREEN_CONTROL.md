# Phone control of the Mac lock screen (experimental)

This optional feature is implemented for the macOS app and Flutter phone clients
(Android/iOS). It has not yet passed a real locked-screen unlock acceptance test.
The native Android alternative does not expose these optional controls.
Desktop Flutter clients (Windows) neither query Mac screen state nor show the
controls; `macScreenControlSupported` limits them to Android and iOS.
Do not describe this opt-in experimental capability as production-validated remote unlock.

## Setup

1. In Mac Settings → LAN devices → Control Mac screen from phone, enter the
   current account's login password and choose Verify and save. OpenDirectory
   verifies it locally. Only a successful verification enables the capability.
2. Connect the phone to this Mac through normal Clipy sync. On the connected Mac
   card, tap Lock or Unlock directly. There is no control key to enter or copy.
3. The Mac card displays Locked / Unlocked / Unknown. Without a saved login
   credential there are no Lock/Unlock buttons. Without Accessibility permission, Unlock is disabled.
4. Lock requires the Mac app's Accessibility permission. Unlock uses a verified writable system secure field and targeted confirmation;
   no additional administrator helper is required. Success is reported only
   after observing the requested actual session state; timeout is unconfirmed.

Saving the login credential enables **every connected sync peer** to control this
Mac, including LAN peers and connected relay peers. This is explicitly the
connection-based access model: no extra pairing, control secret or per-peer grant
is required. The LAN default encryption key is public and is not device
identity/authentication, so LAN connection alone is not proof of a trusted phone.
Disable the feature or turn off sync when connected peers should not control it.
A one-use session nonce prevents accidental duplicates; it does not authenticate
the caller. This feature is intended for a trusted network and connected devices.

The login credential remains in Mac Keychain and is never sent to the phone,
placed in command arguments/environment, or written to logs. Disable deletes it.
Update the saved credential after changing the system login credential. Existing
saved credentials continue to work after upgrading; previous manual control keys
are ignored. Both phone and Mac must be updated to the direct-control version.

## Native unlock path (adapted from VibePier)

The signed Mac app uses its existing Accessibility permission to locate the
frontmost system loginwindow. It verifies the system application path, console
account, a unique secure text field, its owner PID, a writable AX value, its
window and a supported targeted confirmation action. Traversal is complete and
bounded: at most 128 nodes and 0.5 seconds per snapshot. An incomplete snapshot
cannot authorize a write.

It wakes the display, dismisses a screen saver with a non-secret Shift key, and
may select only a unique account button matching the current console account.
The stored login credential is checked against the current system account before
any write. The credential is written with AXUIElementSetAttributeValue only to
the verified secure field; confirmation uses AXPress/AXConfirm. The exact field
and window are revalidated before and after writing. Local unlock, focus/target
changes, failed writes or unsupported controls stop the operation without a
clipboard, script, global credential event or global Return fallback.

The previous root helper is not part of this path and is no longer required.
Previously installed legacy launch daemons/sockets/binaries can be removed separately; the new app never contacts them. The app
does not change authorizationdb, FileVault, TCC or other login mechanisms. Local
Keychain credential storage is retained; VibePier's separate preference-storage
choice is not imported. See LICENSE.VIBEPIER.MIT for adapted code licensing.

## Platform limits and acceptance

Only an already logged-in account's current lock screen is in scope. Cold-boot
FileVault, logged-out sessions, another user, closed-lid sleep, unreachable Macs,
user-selection screens and enterprise authentication challenges are unsupported.
The app must remain running, connected and able to read its Keychain items.
There is no root authentication bypass or automatic retry after failure.

Required before calling this production-ready: existing app Accessibility permission; real
Android and iPhone lock/unlock with the current Mac; password with non-ASCII
characters; invalid login credential; local unlock during a request;
missing Accessibility permission; account switching; sleeping display; app/sync restart; disable/re-enable; independent verification that login Keychain remains usable afterwards.
Do not put real passwords, keys or personal lock-screen screenshots into evidence.
