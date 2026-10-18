import asyncio
import hashlib
import json
import unittest
from websockets.asyncio.client import connect
from websockets.exceptions import InvalidStatus, ConnectionClosed
from server import Relay

TOKEN = 'test-only-' + 'a' * 40
OTHER = 'test-only-' + 'b' * 40

class RelayTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.relay = Relay([hashlib.sha256(t.encode()).hexdigest() for t in (TOKEN, OTHER)])
        self.server = await self.relay.serve(port=0)
        self.url = f'ws://127.0.0.1:{self.server.sockets[0].getsockname()[1]}/clipy-relay'
        self.clients = []

    async def asyncTearDown(self):
        await asyncio.gather(*(c.close() for c in self.clients))
        self.server.close()
        await self.server.wait_closed()

    async def socket(self, device, path='control', target=None, token=TOKEN):
        headers = {'Authorization': 'Bearer '+token, 'X-Clipy-Device': device}
        if target: headers['X-Clipy-Target'] = target
        ws = await connect(self.url+'/'+path, additional_headers=headers, proxy=None, compression=None)
        self.clients.append(ws)
        return ws

    async def control(self, device, token=TOKEN):
        ws = await self.socket(device, token=token)
        await ws.send(json.dumps(dict(name=device, port=5566, addresses=[])))
        await ws.recv()
        return ws

    async def pair(self):
        await self.control('a'); await self.control('b')
        a = await self.socket('a', 'tunnel', 'b')
        b = await self.socket('b', 'tunnel', 'a')
        self.assertEqual(await a.recv(), 'ready')
        self.assertEqual(await b.recv(), 'ready')
        return a, b

    async def test_unauthorized(self):
        with self.assertRaises(InvalidStatus): await self.socket('a', token='wrong')
        self.assertFalse(self.relay.controls)

    async def test_group_isolation(self):
        await self.control('a'); b = await self.control('b', OTHER)
        await b.send('peers')
        self.assertEqual([p['id'] for p in json.loads(await b.recv())['peers']], ['b'])
        tunnel = await self.socket('a', 'tunnel', 'b')
        with self.assertRaises(ConnectionClosed): await tunnel.recv()

    async def test_duplicate_presence(self):
        await self.control('a')
        duplicate = await self.socket('a')
        with self.assertRaises(ConnectionClosed): await duplicate.recv()
        self.assertEqual(len(self.relay.controls), 1)

    async def test_bidirectional_large_stream_and_cleanup(self):
        a, b = await self.pair()
        async def stream(src, dst, byte):
            chunk = byte * 65536
            async def upload():
                for _ in range(128): await src.send(chunk)
            async def download():
                for _ in range(128): self.assertEqual(await dst.recv(), chunk)
            await asyncio.gather(upload(), download())
        await asyncio.wait_for(asyncio.gather(stream(a, b, b'a'), stream(b, a, b'b')), 10)
        await a.close()
        with self.assertRaises(ConnectionClosed): await b.recv()
        await asyncio.sleep(.05)
        self.assertFalse(self.relay.pairs)

    async def test_text_payload_rejected(self):
        a, b = await self.pair()
        await a.send('not binary')
        with self.assertRaises(ConnectionClosed): await b.recv()

    async def test_oversized_payload_rejected(self):
        a, b = await self.pair()
        await a.send(b'x'*65537)
        with self.assertRaises(ConnectionClosed): await b.recv()

    async def test_presence_loss_closes_tunnels(self):
        a, b = await self.pair()
        await self.clients[0].close()
        with self.assertRaises(ConnectionClosed): await b.recv()

if __name__ == '__main__': unittest.main()
