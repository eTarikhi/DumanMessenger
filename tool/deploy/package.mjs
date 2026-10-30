import { cpSync, existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { resolve, join, extname } from 'node:path';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { verifyPackage } from './verify.mjs';

export function packageSimulator(source, destination, metadata) {
  source = resolve(source); destination = resolve(destination);
  if (existsSync(destination)) throw Error('Output exists: use a new package directory (never overwrite an installed package)');
  const files = [];
  function scan(dir, prefix = '') {
    for (const name of readdirSync(dir).sort()) {
      const p = join(dir, name), rel = prefix + name, stat = lstatSync(p);
      if (stat.isSymbolicLink()) throw Error('Build symlink rejected');
      if (stat.isDirectory()) { if (rel !== 'assets') throw Error(`Unexpected build directory: ${rel}`); scan(p, rel + '/'); }
      else {
        if (rel !== 'index.html' && !(rel.startsWith('assets/') && /^[A-Za-z0-9_.-]+$/.test(name) && ['.js','.css','.svg','.png','.ico','.woff2'].includes(extname(name)))) throw Error(`Unexpected build file: ${rel}`);
        files.push(rel);
      }
    }
  }
  scan(source);
  if (!files.includes('index.html') || !files.some(f => f.endsWith('.js'))) throw Error('Build the simulator first');
  mkdirSync(destination, { recursive: true });
  for (const file of files) { mkdirSync(join(destination, 'web', file, '..'), { recursive: true }); cpSync(join(source, file), join(destination, 'web', file)); }
  for (const name of ['serve.mjs','verify.mjs']) cpSync(new URL(name, import.meta.url), join(destination, name));
  cpSync('LICENSE', join(destination, 'LICENSE'));
  writeFileSync(join(destination, 'README.txt'), 'Duman Mesh Simulator staging package. Synthetic/plaintext/in-memory only. Not a secure phone messenger.\nNode22+: node serve.mjs .\nDefault loopback:4173. HOST/PORT explicit for private staging; TLS/access control at operator-managed proxy.\nVerify archive SHA256 via a trusted channel. Internal manifest is integrity, not authenticity. No secrets or persistence.\nRollback: stop process and restart previous immutable package. Do not overlay versions.\n');
  const entries = [...files.map(f => 'web/' + f), 'serve.mjs', 'verify.mjs', 'LICENSE', 'README.txt'].sort().map(path => {
    const bytes = readFileSync(join(destination, path));
    return { path, bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') };
  });
  writeFileSync(join(destination, 'manifest.json'), JSON.stringify({ schema: 1, kind: 'duman-simulator-staging', routingProfile: 'baseline', ...metadata, files: entries }, null, 2) + '\n');
  verifyPackage(destination);
  return destination;
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const sourceSha = execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
  const dirty = !!execFileSync('git', ['status', '--porcelain', '--untracked-files=no'], { encoding: 'utf8' }).trim();
  console.log(packageSimulator('dist', process.argv[2] ?? 'artifacts/package', { sourceSha, dirty, node: process.version, version: JSON.parse(readFileSync('package.json')).version }));
}
