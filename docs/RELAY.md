# Legacy Internet relay (retired)

The current app uses Common Relay device enrollment, separate device ID / Internet Key fields, and encrypted streams. See [current configuration and SDK behavior](COMMON-RELAY-SDK.md). The deployment and shared-key instructions below document the retired service; do not use them for current builds.

macOS and the Flutter app (Android, Windows and foreground iOS) can use a
self-hosted WSS relay when a direct LAN connection is unavailable. Configure
**Internet relay** under macOS Settings → LAN devices or Flutter Devices.
Enable sync, enter `wss://your-server/clipy-relay`, enter the same private access
key on each device, and save. A key must contain 32–256 characters; generate at
least 32 random bytes. This is opt-in and no deployment credentials are shipped
in the app. Existing clipboard/notification sharing choices still apply.

A key identifies a private group of at most eight online devices. Members can
see device names and private LAN addresses, and explicitly send text/files to
one another. A stolen key grants group access; replace its hash on the server
and update every group member to revoke it. macOS stores the key in Keychain;
Flutter stores it in application-private preferences (not an encrypted vault).
Do not distribute backups containing those preferences.

## Connection and lifecycle

- One authenticated control WebSocket advertises device ID, name, port and at
  most eight LAN addresses. Only peers in the same group are announced.
- Before opening a tunnel, clients try at most two private LAN addresses with
  800 ms connection deadlines. A working direct session takes priority.
- A tunnel consists of two authenticated WebSockets rendezvousing by group and
  device IDs. Both receive `ready` before any bytes. A socketpair on macOS and
  a temporary loopback socket pair in Dart adapt the stream to existing v3
  framing, identity validation, ACKs, history persistence and file SHA-256 checks.
- Relay endpoints are labelled **Internet relay** and never persisted as LAN
  endpoints. LAN connections can replace relay sessions while no file transfer
  is active. An active relay isn't repeatedly replaced merely to probe LAN.
- Presence requests every 30 seconds also retry absent sessions. Presence loss
  cancels tunnels; control reconnect backs off from 1 to 30 seconds. The server
  pings every 20 seconds. Mobile network transitions may need old sockets to
  time out before the device can register again. There is no offline server queue.
- Stop/disable/settings change shuts down presence, reconnect timers, bridges
  and sockets. Generation checks reject late completions. iOS foreground-only
  lifetime remains unchanged. Android OEM battery restrictions still apply.
- The native iOS Share Extension remains LAN-only; use the main iOS app for
  relay transfers. Transfers interrupted by route loss must be retried; there
  is no resume. Stored reliable history keeps its existing ACK retry behavior.

## Bounds and trust

Relay WebSocket messages are binary chunks of at most 64 KiB; v3 frames may span
multiple chunks. Each bridge keeps one outbound send and one inbound write in
flight. The server uses two queued receive frames, 64 KiB write watermarks,
40-second rendezvous and 30-second blocked-write deadlines. It disables
compression and stores no payloads. The dedicated systemd service is capped at
160 MiB / 32 tasks / 256 file descriptors. The production listener binds only
`127.0.0.1:47804`; Nginx supplies TLS on port 443.

**This does not upgrade v3 into end-to-end encryption against the relay operator.**
The built-in v3 AES-GCM key is public. WSS protects each client/server connection,
and private group credentials prevent anonymous Internet access, but the relay
operator can inspect traffic. Use a trusted server. Never expose raw LAN TCP
port 5566 publicly. Keys are sent in Authorization headers, never query strings;
the relay does not log request headers or message content.

## Deploy

Python 3.11+ and Nginx with an existing valid TLS certificate are required.
`relay/requirements.txt` pins websockets; its [server API](https://websockets.readthedocs.io/en/15.0/reference/asyncio/server.html)
provides the queue, write-watermark and ping controls.

Create a private local key file and a JSON array of its SHA-256 hashes. The server
receives only hashes. Protect both files and keep them outside the repository.

```sh
bash relay/deploy.sh user@host /private/path/token-hashes.json nginx-site-name
```

The deployment helper installs `/opt/clipy-relay`, `/etc/clipy-relay/tokens.json`,
`clipy-relay.service`, and `/etc/nginx/snippets/clipy-relay.conf`. It adds one
include next to an existing `wifiadb.conf` WSS include in the specified TLS site;
if that exact anchor is absent or ambiguous, it refuses to choose a server block.
For another host, install the supplied service and include the supplied Nginx
snippet inside the intended TLS server block manually. It tests Nginx before
reload and does not change existing WSS paths. Re-deployment supplies the full
hash list; preserve other groups when adding a new one.

```sh
sudo systemctl status clipy-relay --no-pager
sudo systemctl show clipy-relay -p MemoryCurrent
sudo journalctl -u clipy-relay --no-pager -n 30
```

Rollback: disable the clients, stop/disable `clipy-relay`, remove only its Nginx
include, run `nginx -t` and reload Nginx. Do not restore an old entire site file
on top of unrelated configuration changes. Source replacement retains
`/opt/clipy-relay/server.py.previous` for code rollback.

## Verification

```sh
python3 -m venv /tmp/clipy-relay-tests
/tmp/clipy-relay-tests/bin/pip install -r relay/requirements.txt
/tmp/clipy-relay-tests/bin/python -m unittest discover -s relay -v
```

Server tests cover unauthorized access, group isolation, duplicate presence,
bidirectional 8 MiB streams, oversized/text payload rejection, and disconnect
cleanup. Flutter `relay_client_test.dart` covers configuration and cancellation
while the WebSocket sink is streaming.

For a real TLS route, set `CLIPY_RELAY_TEST_URL` and
`CLIPY_RELAY_TEST_KEY_FILE` to a private test group, then run both
`relay/tests/dart_relay_smoke.dart` and a Swift executable compiled from
`SyncRelayClient.swift`, `SyncSocketWriter.swift` and
`relay/tests/SwiftRelaySmoke.swift`. They force the relay by advertising no LAN
addresses and verify an 8 MiB Swift → Dart → Swift round trip byte for byte.
These test the real transport implementations, not device background survival.
