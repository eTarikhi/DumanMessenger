/** Static staging only: no APIs, directory listing, SPA fallback or secrets. */
import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import { join, extname } from 'node:path';
import { pathToFileURL } from 'node:url';
import { verifyPackage } from './verify.mjs';

export function createStagingServer(root, { allowEmbed = false } = {}) {
  const verified = verifyPackage(root);
  // Snapshot only verified web bytes. Subsequent file/symlink replacement cannot
  // make a running server serve arbitrary bytes outside its verified package.
  const files = new Map([...verified.paths].filter(p => p.startsWith('web/')).map(p => [p.slice(4), readFileSync(join(verified.root, p))]));
  const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png', '.ico': 'image/x-icon', '.woff2': 'font/woff2' };
  return createServer((req, res) => {
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('Permissions-Policy', 'camera=(), microphone=(), geolocation=(), bluetooth=()');
    res.setHeader('Content-Security-Policy', "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; form-action 'none';" + (allowEmbed ? '' : " frame-ancestors 'self';"));
    res.setHeader('Cache-Control', 'no-store');
    if (!['GET', 'HEAD'].includes(req.method)) { res.setHeader('Allow', 'GET, HEAD'); res.writeHead(405); res.end(); return; }
    let path;
    try { path = decodeURIComponent((req.url ?? '/').split('?')[0]); } catch { res.writeHead(400); res.end(); return; }
    if (!path.startsWith('/') || /[\\\x00]/.test(path) || path.split('/').some(s => s === '..' || s === '.')) { res.writeHead(400); res.end(); return; }
    const name = path === '/' ? 'index.html' : path.slice(1), bytes = files.get(name);
    if (!bytes) { res.writeHead(404); res.end(); return; }
    res.setHeader('Content-Type', types[extname(name)] ?? 'application/octet-stream');
    res.setHeader('Content-Length', bytes.length); res.writeHead(200);
    res.end(req.method === 'HEAD' ? undefined : bytes);
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const port = Number(process.env.PORT ?? 4173);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw Error('PORT must be 1..65535');
  const server = createStagingServer(process.argv[2] ?? 'artifacts/package', { allowEmbed: process.env.ALLOW_PREVIEW_EMBED === '1' });
  server.requestTimeout = 10000; server.headersTimeout = 10000;
  server.listen(port, process.env.HOST ?? '127.0.0.1', () => console.log(`Simulator staging port ${port}; not a messenger service`));
  for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => server.close());
}
