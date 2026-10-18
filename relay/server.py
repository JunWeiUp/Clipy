"""Authenticated, bounded WSS rendezvous. No payload persistence or logging."""
import asyncio
import hashlib
import json
import os
import re
from http import HTTPStatus
from websockets.asyncio.server import serve
from websockets.exceptions import ConnectionClosed

ID = re.compile(r"[A-Za-z0-9_-]{1,80}\Z")
MAX_DEVICES = 8


class Relay:
    def __init__(self, token_hashes):
        self.tokens = set(token_hashes)
        self.controls = {}  # (group hash, device) -> (socket, metadata)
        self.pairs = {}     # (group hash, sorted device ids) -> side sockets

    def authenticate(self, connection, request):
        if request.path not in ('/clipy-relay/control', '/clipy-relay/tunnel'):
            return connection.respond(HTTPStatus.NOT_FOUND, 'Not found\n')
        authorization = request.headers.get('Authorization', '')
        digest = hashlib.sha256(authorization.removeprefix('Bearer ').encode()).hexdigest()
        device = request.headers.get('X-Clipy-Device', '')
        if not authorization.startswith('Bearer ') or digest not in self.tokens or not ID.fullmatch(device):
            return connection.respond(HTTPStatus.UNAUTHORIZED, 'Unauthorized\n')
        connection.clipy_identity = (digest, device)

    async def publish(self, group):
        entries = [(identity, value) for identity, value in self.controls.items() if identity[0] == group]
        data = json.dumps({'type': 'peers', 'peers': [meta for _, (_, meta) in entries]})
        # At most 8 small control writes, each deadline bounded.
        for _, (ws, _) in entries:
            try:
                await asyncio.wait_for(ws.send(data), 3)
            except (ConnectionClosed, TimeoutError):
                await ws.close()

    async def control(self, ws, group, device):
        key = (group, device)
        if key in self.controls or sum(g == group for g, _ in self.controls) >= MAX_DEVICES:
            await ws.close(4409, 'Device already online or group full')
            return
        try:
            message = await asyncio.wait_for(ws.recv(), 10)
            if not isinstance(message, str) or len(message) > 4096:
                raise ValueError()
            meta = json.loads(message)
            if not isinstance(meta, dict):
                raise ValueError()
            addresses = meta.get('addresses', [])
            if not isinstance(addresses, list) or len(addresses) > 8:
                raise ValueError()
            import ipaddress
            addresses = [str(ipaddress.IPv4Address(a)) for a in addresses]
            port = meta.get('port')
            if type(port) is not int or not 1 <= port <= 65535:
                raise ValueError()
            name = str(meta.get('name', device))[:100]
            # Recheck after recv: duplicate registrations must not race.
            if key in self.controls or sum(g == group for g, _ in self.controls) >= MAX_DEVICES:
                await ws.close(4409, 'Device already online or group full')
                return
            self.controls[key] = (ws, dict(id=device, name=name, addresses=addresses, port=port))
            await self.publish(group)
            async for message in ws:
                if message != 'peers':
                    await ws.close(4400, 'Invalid control message')
                    break
                await self.publish(group)
                await asyncio.sleep(1)  # Bound authenticated control flooding.
        except (ValueError, TypeError, TimeoutError, ConnectionClosed):
            await ws.close(4400, 'Invalid registration')
        finally:
            if self.controls.get(key, (None,))[0] is ws:
                del self.controls[key]
                for pair_key, sides in list(self.pairs.items()):
                    if pair_key[0] == group and device in pair_key[1:]:
                        for socket, _ in list(sides.values()):
                            await socket.close(4410, 'Device offline')
                await self.publish(group)

    async def tunnel(self, ws, group, device):
        target = ws.request.headers.get('X-Clipy-Target', '')
        if not ID.fullmatch(target) or target == device or (group, device) not in self.controls or (group, target) not in self.controls:
            await ws.close(4404, 'Peer offline')
            return
        key = (group, *sorted([device, target]))
        sides = self.pairs.setdefault(key, {})
        if device in sides:
            await ws.close(4409, 'Tunnel exists')
            return
        ready = asyncio.Event()
        sides[device] = (ws, ready)
        try:
            if len(sides) == 2:
                # Ready must precede binary bytes on BOTH sockets.
                for socket, _ in sides.values():
                    await socket.send('ready')
                for _, event in sides.values():
                    event.set()
            await asyncio.wait_for(ready.wait(), 40)
            remote = sides[target][0]
            async for message in ws:
                if not isinstance(message, bytes) or not message:
                    await ws.close(4400, 'Binary bytes required')
                    break
                await asyncio.wait_for(remote.send(message), 30)
        except (ConnectionClosed, TimeoutError, KeyError):
            pass
        finally:
            if sides.get(device, (None,))[0] is ws:
                sides.pop(device, None)
                if target in sides:
                    await sides[target][0].close(4410, 'Tunnel ended')
                if not sides and self.pairs.get(key) is sides:
                    del self.pairs[key]

    async def handler(self, ws):
        group, device = ws.clipy_identity
        if ws.request.path.endswith('/control'):
            await self.control(ws, group, device)
        else:
            await self.tunnel(ws, group, device)

    async def serve(self, host='127.0.0.1', port=47804):
        return await serve(self.handler, host, port, process_request=self.authenticate,
                           max_size=65536, max_queue=2, write_limit=65536,
                           compression=None, ping_interval=20, ping_timeout=20,
                           close_timeout=3, open_timeout=10, server_header=None)


async def main():
    with open(os.environ.get('CLIPY_RELAY_TOKENS', '/etc/clipy-relay/tokens.json')) as f:
        tokens = json.load(f)
    if not tokens or any(not re.fullmatch('[0-9a-f]{64}', t) for t in tokens):
        raise ValueError('Expected nonempty list of SHA-256 token hashes')
    server = await Relay(tokens).serve(port=int(os.environ.get('CLIPY_RELAY_PORT', '47804')))
    async with server:
        await server.serve_forever()


if __name__ == '__main__':
    asyncio.run(main())
