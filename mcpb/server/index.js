// Stdio→HTTP shim for Claude Desktop
const http = require('node:http');

const URL_BASE = 'http://127.0.0.1:19789/mcp';
const RETRY_MS_MIN = 500;
const RETRY_MS_MAX = 5000;
const REQUEST_REPLAY_MS = 25000; // fail held requests before Claude Desktop's own 60s timeout

let sessionId = null;
let protocolVersion = '2025-06-18';
let initializeParams = null; // replayed on reconnect
let reconnecting = null;     // shared promise; concurrent failures trigger one loop
let internalId = 0;
let getStreamAbort = null;

const log = (...a) => console.error('[palmier-shim]', ...a);
const writeOut = (msg) => process.stdout.write(JSON.stringify(msg) + '\n');
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

function headers(extra = {}) {
  const h = {
    'Content-Type': 'application/json',
    'Accept': 'application/json, text/event-stream',
    'MCP-Protocol-Version': protocolVersion,
    ...extra,
  };
  if (sessionId) h['Mcp-Session-Id'] = sessionId;
  return h;
}

async function readSSE(body, onMessage) {
  const reader = body.getReader();
  const decoder = new TextDecoder();
  let buf = '';
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    buf += decoder.decode(value, { stream: true });
    let sep;
    while ((sep = buf.indexOf('\n\n')) >= 0) {
      const event = buf.slice(0, sep); buf = buf.slice(sep + 2);
      const data = event.split('\n')
        .filter(l => l.startsWith('data:'))
        .map(l => l.slice(5).trimStart())
        .join('\n');
      if (!data) continue;
      try { onMessage(JSON.parse(data)); } catch { /* priming events */ }
    }
  }
}

// Throws on failure; err.delivered means a response reached onMessage,
// so the request may have executed and must not be replayed.
async function post(message, onMessage) {
  let delivered = false;
  const deliver = (msg) => { delivered = true; onMessage(msg); };
  try {
    const res = await fetch(URL_BASE, {
      method: 'POST',
      headers: headers(),
      body: JSON.stringify(message),
    });
    if (res.status === 404) throw new Error('session expired');
    if (!res.ok && res.status !== 202) throw new Error(`HTTP ${res.status}`);
    const assigned = res.headers.get('mcp-session-id');
    if (assigned) sessionId = assigned;
    const type = (res.headers.get('content-type') || '').split(';')[0];
    if (type === 'text/event-stream') await readSSE(res.body, deliver);
    else if (type === 'application/json') deliver(await res.json());
  } catch (err) {
    err.delivered = delivered;
    throw err;
  }
}

// Standalone GET stream carries server-initiated messages (tools/list_changed).
// Uses node:http, not fetch: undici kills idle response bodies after 300s,
// which would churn a new session (and a client tools refetch) every 5 minutes.
function openGetStream() {
  getStreamAbort?.abort();
  let aborted = false;
  let request = null;
  getStreamAbort = { abort() { aborted = true; request?.destroy(); } };
  const fail = (err) => {
    if (aborted) return;
    aborted = true;
    log('notification stream lost:', err.message);
    reconnect();
  };
  request = http.get(URL_BASE, { headers: headers({ 'Accept': 'text/event-stream' }), timeout: 0 }, (res) => {
    if (res.statusCode !== 200) { res.resume(); return fail(new Error(`GET HTTP ${res.statusCode}`)); }
    let buf = '';
    res.setEncoding('utf8');
    res.on('data', (chunk) => {
      buf += chunk;
      let sep;
      while ((sep = buf.indexOf('\n\n')) >= 0) {
        const event = buf.slice(0, sep); buf = buf.slice(sep + 2);
        const data = event.split('\n')
          .filter(l => l.startsWith('data:'))
          .map(l => l.slice(5).trimStart())
          .join('\n');
        if (!data) continue;
        try {
          const msg = JSON.parse(data);
          if (msg.method) writeOut(msg);
        } catch { /* priming events */ }
      }
    });
    res.on('end', () => fail(new Error('GET stream ended')));
    res.on('error', fail);
  });
  request.on('error', fail);
}

async function establishSession() {
  let delay = RETRY_MS_MIN;
  for (;;) {
    try {
      sessionId = null;
      const id = `shim-init-${++internalId}`;
      let result = null;
      await post({ jsonrpc: '2.0', id, method: 'initialize', params: initializeParams }, (msg) => {
        if (msg.id === id && msg.result) result = msg.result;
      });
      if (!result) throw new Error('no initialize result');
      if (result.protocolVersion) protocolVersion = result.protocolVersion;
      await post({ jsonrpc: '2.0', method: 'notifications/initialized' }, () => {});
      openGetStream();
      log('session established', sessionId);
      return result;
    } catch (err) {
      log(`connect failed (${err.message}); retrying in ${delay}ms`);
      await sleep(delay);
      delay = Math.min(delay * 2, RETRY_MS_MAX);
    }
  }
}

function reconnect() {
  if (!reconnecting) {
    reconnecting = establishSession().finally(() => { reconnecting = null; });
  }
  return reconnecting;
}

async function handleClientMessage(msg) {
  if (msg.method === 'initialize') {
    initializeParams = msg.params;
    const result = await reconnect();
    writeOut({ jsonrpc: '2.0', id: msg.id, result });
    return;
  }
  if (msg.method === 'notifications/initialized') return; // sent internally per session
  const deadline = Date.now() + REQUEST_REPLAY_MS;
  for (;;) {
    if (reconnecting) {
      const timeLeft = deadline - Date.now();
      if (timeLeft <= 0 || !(await Promise.race([
        reconnecting.then(() => true),
        sleep(timeLeft).then(() => false),
      ]))) throw new Error('reconnect pending');
    }
    try {
      await post(msg, (out) => {
        if (out.id !== undefined || out.method) writeOut(out);
      });
      return;
    } catch (err) {
      if (msg.id === undefined) return;
      if (err.delivered || Date.now() > deadline) throw err;
      log(`request ${msg.method} failed (${err.message}); reconnecting`);
      await reconnect();
    }
  }
}

let stdinBuf = '';
process.stdin.on('data', (chunk) => {
  stdinBuf += chunk.toString();
  let nl;
  while ((nl = stdinBuf.indexOf('\n')) >= 0) {
    const line = stdinBuf.slice(0, nl).trim(); stdinBuf = stdinBuf.slice(nl + 1);
    if (!line) continue;
    let msg;
    try { msg = JSON.parse(line); } catch { continue; }
    handleClientMessage(msg).catch((err) => {
      log('unhandled error:', err.message);
      if (msg.id !== undefined) {
        writeOut({ jsonrpc: '2.0', id: msg.id, error: { code: -32603, message: `Palmier Pro unreachable: ${err.message}` } });
      }
    });
  }
});
process.stdin.on('end', () => process.exit(0));
log('started; proxying stdio ↔', URL_BASE);
