#!/usr/bin/env python3
"""Independent synthetic portal and attacker peers on a private bus."""
import asyncio
import json
import os
import sys
from dbus_next import Message, Variant, MessageType
from dbus_next.aio import MessageBus

NAME = 'org.freedesktop.portal.Desktop'
PATH = '/org/freedesktop/portal/desktop'
REMOTE = 'org.freedesktop.portal.RemoteDesktop'
CLIP = 'org.freedesktop.portal.Clipboard'
SHORT = 'org.freedesktop.portal.GlobalShortcuts'
CONTROL = 'net.praxient.vizier.Mock'


class Mock:
    def __init__(self, bus, attacker):
        self.bus = bus
        self.attacker = attacker
        self.old_buses = []
        self.peers = {}
        self.transfers = {}
        self.serial = 0

    def peer(self, sender):
        return self.peers.setdefault(sender, dict(events=[], keys=[], key_methods=[], held=[], close_held=[],
                                                  closed=[], clipboard='', done=False, ownerships=0, forged=0, forged_responses=0,
                                                  config={}, registered=False, remote='', shortcut=''))

    def reply(self, msg, signature='', body=None, fds=None):
        return self.bus.send(Message.new_method_return(msg, signature, body or [], unix_fds=fds or []))

    def signal(self, path, interface, member, signature, body, destination=None, bus=None):
        return (bus or self.bus).send(Message(path=path, interface=interface, member=member,
                                            message_type=MessageType.SIGNAL, signature=signature,
                                            body=body, destination=destination))

    def request(self, msg, results, code=0):
        p = self.peer(msg.sender)
        opts = msg.body[-1]
        sender = msg.sender[1:].replace('.', '_')
        request = f'{PATH}/request/{sender}/{opts["handle_token"].value}'
        p['request'] = request
        if p['config'].get('different_request'):
            request += '_legacy'
        if msg.member == 'Start' and p['config'].get('forge_start_response'):
            async def forged_first():
                fake = {'devices': Variant('u', 1), 'clipboard_enabled': Variant('b', True)}
                await self.signal(request, 'org.freedesktop.portal.Request', 'Response', 'ua{sv}',
                                  [0, fake], msg.sender, bus=self.attacker)
                p['forged_responses'] += 1
                await asyncio.sleep(0.05)
                self.signal(request, 'org.freedesktop.portal.Request', 'Response', 'ua{sv}', [code, results], msg.sender)
            asyncio.create_task(forged_first())
        else:
            # An early response independently tests subscription ordering.
            self.signal(request, 'org.freedesktop.portal.Request', 'Response', 'ua{sv}', [code, results], msg.sender)
        self.reply(msg, 'o', [request])

    async def acknowledge(self, sender, handle):
        p = self.peer(sender)
        await asyncio.sleep(p['config'].get('ownership_delay_ms', 100) / 1000)
        if p['config'].get('no_ownership'):
            return
        p['ownerships'] += 1
        opts = {'session_is_owner': Variant('b', not p['config'].get('false_ownership', False))}
        if p['config'].get('unknown_options'):
            opts['future_bytes'] = Variant('ay', b'\x01\x02')
            opts['future_double'] = Variant('d', 1.5)
            opts['future_signature'] = Variant('g', 'ay')
        self.signal(PATH, CLIP, 'SelectionOwnerChanged', 'oa{sv}', [handle, opts], sender)

    def transfer(self, sender, handle=None, mime=None):
        p = self.peer(sender)
        handle = handle or p['remote']
        mime = mime or p.get('mime_types', ['text/plain'])[0]
        self.serial += 1
        self.transfers[self.serial] = {'owner': sender, 'session': handle, 'content': bytearray()}
        self.signal(PATH, CLIP, 'SelectionTransfer', 'osu', [handle, mime, self.serial], sender)

    async def forge(self, sender):
        p = self.peer(sender)
        if p['shortcut']:
            await self.signal(PATH, SHORT, 'Activated', 'osta{sv}', [p['shortcut'], 'toggle', 42, {}], sender, bus=self.attacker)
            p['forged'] += 1
        for handle in (p['remote'], p['shortcut']):
            if handle:
                await self.signal(handle, 'org.freedesktop.portal.Session', 'Closed', 'a{sv}', [{}], sender, bus=self.attacker)
                p['forged'] += 1
        await self.signal('/org/freedesktop/DBus', 'org.freedesktop.DBus', 'NameOwnerChanged', 'sss',
                          [NAME, self.bus.unique_name, ''], sender, bus=self.attacker)
        p['forged'] += 1
        if p.get('remote'):
            await self.signal(PATH, CLIP, 'SelectionOwnerChanged', 'oa{sv}',
                              [p['remote'], {'session_is_owner': Variant('b', True)}], sender, bus=self.attacker)
            p['forged'] += 1

    def handle(self, msg):
        if msg.message_type != MessageType.METHOD_CALL:
            return False
        p = self.peer(msg.sender)
        iface, method, b = msg.interface, msg.member, msg.body
        if iface == CONTROL:
            if method == 'Configure':
                p['config'].update({k: v.value for k, v in b[0].items()})
                self.reply(msg)
            elif method == 'Snapshot':
                self.reply(msg, 's', [json.dumps(p)])
            elif method == 'Activate':
                self.signal(PATH, SHORT, 'Activated', 'osta{sv}', [p['shortcut'], b[0], 42, {}], msg.sender)
                self.reply(msg)
            elif method == 'ReadClipboard':
                self.transfer(msg.sender, mime=b[0] if b else None)
                self.reply(msg)
            elif method == 'StaleTransfer':
                self.transfer(msg.sender, handle=PATH + '/session/stale', mime='text/plain')
                self.reply(msg)
            elif method == 'Forge':
                asyncio.create_task(self.forge(msg.sender))
                self.reply(msg)
            elif method == 'CloseSessions':
                for handle in (p['remote'], p['shortcut']):
                    if handle:
                        self.signal(handle, 'org.freedesktop.portal.Session', 'Closed', 'a{sv}', [{}], msg.sender)
                self.reply(msg)
            elif method == 'Restart':
                self.reply(msg)
                asyncio.create_task(self.restart())
            elif method == 'FD':
                fd = os.memfd_create('synthetic-portal-fd', os.MFD_CLOEXEC)
                self.reply(msg, 'h', [0], [fd]).add_done_callback(lambda _: os.close(fd))
            elif method == 'Echo':
                self.reply(msg, 'a{sv}', b)
            else:
                self.bus.send(Message.new_error(msg, 'org.freedesktop.DBus.Error.UnknownMethod', 'Unknown mock method'))
            return True
        p['events'].append(method)
        if iface == 'org.freedesktop.host.portal.Registry' and method == 'Register':
            async def register():
                await asyncio.sleep(p['config'].get('register_delay_ms', 0) / 1000)
                if p['registered'] or p['config'].get('no_registry'):
                    self.bus.send(Message.new_error(msg, 'org.freedesktop.DBus.Error.UnknownInterface', 'Registry unavailable'))
                elif b != ['net.praxient.vizier', {}] or any(x in p['events'][:-1] for x in ('Get', 'CreateSession')):
                    self.bus.send(Message.new_error(msg, 'org.freedesktop.DBus.Error.InvalidArgs', 'Registration must be first'))
                else:
                    p['registered'] = True
                    self.reply(msg)
            asyncio.create_task(register())
        elif iface == 'org.freedesktop.DBus.Properties' and method == 'Get':
            versions = {REMOTE: 2, CLIP: 1, SHORT: 2}
            if b[0] in versions and not p['config'].get('missing_interface'):
                self.reply(msg, 'v', [Variant('u', versions[b[0]])])
            else:
                self.bus.send(Message.new_error(msg, 'org.freedesktop.DBus.Error.UnknownInterface', 'Interface absent'))
        elif iface in (REMOTE, SHORT) and method == 'CreateSession':
            handle = f'{PATH}/session/{msg.sender[1:].replace(".", "_")}/{b[0]["session_handle_token"].value}'
            p['remote' if iface == REMOTE else 'shortcut'] = handle
            self.request(msg, {'session_handle': Variant('s', handle)})
        elif iface == REMOTE and method == 'SelectDevices':
            opts = b[1]
            p['select'] = {k: v.value for k, v in opts.items() if k != 'handle_token'}
            self.request(msg, {}, 0 if opts['types'].value == 1 and opts['persist_mode'].value == 2 else 2)
        elif iface == CLIP and method == 'RequestClipboard':
            p['requested_clipboard'] = b[0]
            self.reply(msg)
        elif iface == REMOTE and method == 'Start':
            if p['config'].get('deny_start'):
                self.request(msg, {}, 1)
            elif p.get('requested_clipboard') != b[0]:
                self.request(msg, {}, 2)
            else:
                self.request(msg, {'devices': Variant('u', 1),
                                   'clipboard_enabled': Variant('b', not p['config'].get('deny_clipboard', False)),
                                   'restore_token': Variant('s', 'synthetic-restore-token')})
        elif iface == REMOTE and method in ('NotifyKeyboardKeycode', 'NotifyKeyboardKeysym'):
            if method == 'NotifyKeyboardKeysym' and p['config'].get('refuse_keysym'):
                self.bus.send(Message.new_error(msg, 'org.freedesktop.DBus.Error.UnknownMethod', 'Keysym unsupported'))
            else:
                p['keys'].append([b[2], b[3]])
                p['key_methods'].append(method)
                if b[3] == 1:
                    p['held'].append(b[2])
                else:
                    p['held'] = [key for key in p['held'] if key != b[2]]
                if p['config'].get('fail_key') == len(p['keys']):
                    self.bus.send(Message.new_error(msg, 'org.freedesktop.DBus.Error.Failed', 'Synthetic ambiguous key failure'))
                else:
                    self.reply(msg)
        elif iface == CLIP and method == 'SetSelection':
            p['mime_types'] = b[1]['mime_types'].value
            self.reply(msg)  # success says nothing about clipboard ownership
            asyncio.create_task(self.acknowledge(msg.sender, b[0]))
        elif iface == CLIP and method == 'SelectionWrite':
            transfer = self.transfers[b[1]]
            readfd, writefd = os.pipe()
            os.set_blocking(readfd, False)
            transfer.update(readfd=readfd)
            sent = self.reply(msg, 'h', [0], [writefd])
            asyncio.get_running_loop().add_reader(readfd, self.read_transfer, b[1])
            sent.add_done_callback(lambda _: os.close(writefd))
        elif iface == CLIP and method == 'SelectionWriteDone':
            transfer = self.transfers[b[1]]
            self.read_transfer(b[1])
            p['done'] = b[2]
            p['clipboard'] = transfer['content'].decode('utf-8')
            self.reply(msg)
        elif iface == SHORT and method == 'BindShortcuts':
            p['bindings'] = [[id_, {k: v.value for k, v in opts.items()}] for id_, opts in b[1]]
            ids = ['toggle'] if p['config'].get('toggle_only') else ['toggle', 'cancel']
            self.request(msg, {'shortcuts': Variant('a(sa{sv})', [[id_, {'description': Variant('s', opts['description'].value),
                                                                   'trigger_description': Variant('s', opts['preferred_trigger'].value)}]
                                                                  for id_, opts in b[1] if id_ in ids])})
        elif iface in ('org.freedesktop.portal.Session', 'org.freedesktop.portal.Request') and method == 'Close':
            p['closed'].append(msg.path)
            if iface == 'org.freedesktop.portal.Session':
                p['close_held'] = p['held'].copy()
                self.signal(msg.path, iface, 'Closed', 'a{sv}', [{}], msg.sender)
            self.reply(msg)
        else:
            self.bus.send(Message.new_error(msg, 'org.freedesktop.DBus.Error.UnknownMethod', 'Unsupported synthetic portal call'))
        return True

    def read_transfer(self, serial):
        transfer = self.transfers[serial]
        fd = transfer.get('readfd')
        if fd is None:
            return
        while True:
            try:
                data = os.read(fd, 65536)
            except BlockingIOError:
                break
            if not data:
                asyncio.get_running_loop().remove_reader(fd)
                os.close(fd)
                transfer['readfd'] = None
                break
            transfer['content'].extend(data)

    async def restart(self):
        old = self.bus
        await old.release_name(NAME)
        self.old_buses.append(old)
        for p in self.peers.values():
            p['registered'] = False
            p['events'] = []
        await asyncio.sleep(0.1)
        self.bus = await MessageBus(negotiate_unix_fd=True).connect()
        self.bus.add_message_handler(self.handle)
        await self.bus.request_name(NAME)


async def main():
    bus = await MessageBus(negotiate_unix_fd=True).connect()
    attacker = await MessageBus(negotiate_unix_fd=True).connect()
    mock = Mock(bus, attacker)
    bus.add_message_handler(mock.handle)
    await bus.request_name(NAME)
    with open(sys.argv[1], 'w') as ready:
        ready.write('ready\n')
    await asyncio.Future()


if __name__ == '__main__':
    asyncio.run(main())
