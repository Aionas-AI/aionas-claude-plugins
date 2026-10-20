// A local stand-in for the Anthropic Messages API, for the scripted Claude Code run.
// Answers every /v1/messages call with "ok" and a fixed context size, and appends
// one line per call to $MOCK_LOG: "<n> <instruction seen: 0|1> <stream: 0|1>".
// It never forwards anything; there is no real model behind it.
const http = require('http');
const fs = require('fs');
const tokens = parseInt(process.env.MOCK_CONTEXT_TOKENS || '30000', 10);
const log = process.env.MOCK_LOG;
let n = 0;
const srv = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const body = Buffer.concat(chunks).toString('utf8');
    if (req.method === 'POST' && /^\/v1\/messages(\?|$)/.test(req.url)) {
      n += 1;
      if (process.env.MOCK_DUMP) fs.writeFileSync(`${process.env.MOCK_DUMP}.${n}.json`, body);
      let stream = false;
      try { stream = !!JSON.parse(body).stream; } catch (e) { /* not json */ }
      fs.appendFileSync(log, `${n} ${body.includes('[aionas-handoff]') ? 1 : 0} ${stream ? 1 : 0}\n`);
      const usage = { input_tokens: tokens, cache_creation_input_tokens: 0, cache_read_input_tokens: 0, output_tokens: 3 };
      const msg = { id: `msg_mock${n}`, type: 'message', role: 'assistant', model: 'claude-mock', content: [], stop_reason: null, stop_sequence: null, usage };
      if (!stream) {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ ...msg, content: [{ type: 'text', text: 'ok' }], stop_reason: 'end_turn' }));
        return;
      }
      res.writeHead(200, { 'content-type': 'text/event-stream' });
      const ev = (e, d) => res.write(`event: ${e}\ndata: ${JSON.stringify(d)}\n\n`);
      ev('message_start', { type: 'message_start', message: msg });
      ev('content_block_start', { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } });
      ev('content_block_delta', { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'ok' } });
      ev('content_block_stop', { type: 'content_block_stop', index: 0 });
      ev('message_delta', { type: 'message_delta', delta: { stop_reason: 'end_turn', stop_sequence: null }, usage: { output_tokens: 3 } });
      ev('message_stop', { type: 'message_stop' });
      res.end();
      return;
    }
    res.writeHead(404, { 'content-type': 'application/json' });
    res.end('{}');
  });
});
srv.listen(0, '127.0.0.1', () => { fs.writeFileSync(process.env.MOCK_PORT_FILE, String(srv.address().port)); });
