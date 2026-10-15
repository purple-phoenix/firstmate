#!/usr/bin/env node
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

const dir = process.argv[2];
if (!dir) process.exit(2);
const controlFile = path.join(dir, 'control.json');
const logFile = path.join(dir, 'requests.jsonl');
const postedFile = path.join(dir, 'posted.json');
const portFile = path.join(dir, 'port');
const ids = {
  guild: '100000000000000001', channel: '100000000000000002', owner: '100000000000000003',
  bot: '100000000000000004', outsider: '100000000000000005', botRole: '100000000000000006', adminRole: '100000000000000007',
  channel2: '100000000000000008', unknownRole: '100000000000000009'
};

function readJson(file, fallback) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; } }
function writeJson(file, value) { fs.writeFileSync(file, `${JSON.stringify(value)}\n`, { mode: 0o600 }); }
function control() { return readJson(controlFile, {}); }
function posted() { return readJson(postedFile, []); }
function respond(res, status, body, headers = {}) {
  res.writeHead(status, { 'content-type': 'application/json', ...headers });
  res.end(JSON.stringify(body));
}
function messagesFor(cfg) {
  return Array.isArray(cfg.messages) ? cfg.messages : [];
}

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (chunk) => chunks.push(chunk));
  req.on('end', () => {
    const cfg = control();
    let body = null;
    try { body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : null; } catch {}
    fs.appendFileSync(logFile, `${JSON.stringify({ method: req.method, url: req.url, body })}\n`);
    if (cfg.auth_invalid || req.headers.authorization !== `Bot ${cfg.token}`) return respond(res, 401, { message: '401: Unauthorized' });
    const once = Array.isArray(cfg.rate_once) ? cfg.rate_once.find((prefix) => req.url.startsWith(prefix)) : null;
    if (once) {
      cfg.rate_once.splice(cfg.rate_once.indexOf(once), 1);
      writeJson(controlFile, cfg);
      return respond(res, 429, { message: 'rate limited', retry_after: cfg.retry_after || 2, global: false }, { 'retry-after': String(cfg.retry_after || 2) });
    }
    if (req.url === '/users/@me') return respond(res, 200, { id: ids.bot, username: 'Firstmate Test', bot: true });
    if ([`/channels/${ids.channel}`, `/channels/${ids.channel2}`].includes(req.url)) {
      const channelId = req.url.slice('/channels/'.length);
      const channel = {
        id: channelId, guild_id: ids.guild, type: cfg.channel_type ?? 0,
        permission_overwrites: cfg.omit_overwrites ? undefined : [
          { id: ids.guild, type: 0, allow: '0', deny: '1024' },
          { id: ids.owner, type: 1, allow: '1024', deny: '0' },
          { id: ids.bot, type: 1, allow: '68608', deny: '0' },
          ...(cfg.extra_viewer && !cfg.extra_admin ? [{ id: ids.outsider, type: 1, allow: '1024', deny: '0' }] : [])
        ]
      };
      if (cfg.omit_overwrites) delete channel.permission_overwrites;
      return respond(res, 200, channel);
    }
    if (req.url === `/guilds/${ids.guild}?with_counts=true`) {
      return respond(res, 200, {
        id: ids.guild, owner_id: ids.owner, approximate_member_count: cfg.extra_viewer ? 3 : 2,
        roles: [
          { id: ids.guild, permissions: '0' },
          ...(cfg.omit_bot_role ? [] : [{ id: ids.botRole, permissions: '68608' }]),
          { id: ids.adminRole, permissions: '8' }
        ]
      });
    }
    if (req.url.startsWith(`/guilds/${ids.guild}/members?`)) {
      if (cfg.members_status) return respond(res, cfg.members_status, { message: 'members unavailable' });
      const members = [
        { user: { id: ids.owner, bot: false }, roles: [] },
        { user: { id: ids.bot, bot: true }, roles: [cfg.member_unknown_role ? ids.unknownRole : ids.botRole] }
      ];
      if (cfg.extra_viewer) members.push({ user: { id: ids.outsider, bot: false }, roles: cfg.extra_admin ? [ids.adminRole] : [] });
      return respond(res, 200, members);
    }
    const messageChannel = [ids.channel, ids.channel2].find((id) => req.url.startsWith(`/channels/${id}/messages?`));
    if (req.method === 'GET' && messageChannel) {
      const url = new URL(req.url, 'http://localhost');
      let messages = messagesFor(cfg).filter((message) => message.channel_id === messageChannel || cfg.include_wrong_channel);
      const after = url.searchParams.get('after');
      const before = url.searchParams.get('before');
      if (after) messages = messages.filter((message) => BigInt(message.id) > BigInt(after));
      if (before) messages = messages.filter((message) => BigInt(message.id) < BigInt(before));
      messages.sort((a, b) => BigInt(a.id) > BigInt(b.id) ? -1 : 1);
      return respond(res, 200, messages.slice(0, Number(url.searchParams.get('limit') || 50)));
    }
    const postChannel = [ids.channel, ids.channel2].find((id) => req.url === `/channels/${id}/messages`);
    if (req.method === 'POST' && postChannel) {
      const existing = posted().find((message) => message.nonce === body?.nonce);
      if (body?.enforce_nonce && existing) return respond(res, 200, existing);
      const list = posted();
      const message = {
        id: String(900000000000000000n + BigInt(list.length + 1)), channel_id: postChannel,
        author: { id: ids.bot, bot: true }, content: body?.content, nonce: body?.nonce
      };
      list.push(message);
      writeJson(postedFile, list);
      if (cfg.uncertain_post) return req.socket.destroy();
      return respond(res, 200, message);
    }
    respond(res, 404, { message: 'not found' });
  });
});

server.listen(0, '127.0.0.1', () => {
  fs.writeFileSync(portFile, `${server.address().port}\n`, { mode: 0o600 });
});
