process.argv = [
  process.argv[0],
  'mcp-remote',
  'http://127.0.0.1:19789/mcp',
  '--allow-http',
  '--transport',
  'http-only'
];
require('mcp-remote/dist/proxy.js');
