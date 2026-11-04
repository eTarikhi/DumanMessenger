import { createHash } from 'node:crypto';
import { readFileSync, realpathSync, lstatSync, readdirSync } from 'node:fs';
import { join, relative, sep } from 'node:path';

export function verifyPackage(root) {
  root = realpathSync(root);
  const manifest = JSON.parse(readFileSync(join(root, 'manifest.json'), 'utf8'));
  if (manifest.schema !== 1 || manifest.kind !== 'duman-simulator-staging' || manifest.routingProfile !== 'baseline' ||
      !Array.isArray(manifest.files) || !manifest.files.length) throw Error('Invalid package manifest');
  const paths = new Set();
  for (const file of manifest.files) {
    if (typeof file.path !== 'string' || !/^[A-Za-z0-9_.\/-]+$/.test(file.path) ||
        file.path.startsWith('/') || file.path.split('/').some(s => !s || s === '.' || s === '..') ||
        paths.has(file.path)) throw Error('Unsafe/duplicate manifest path');
    paths.add(file.path);
    const path = join(root, file.path);
    if (!lstatSync(path).isFile() || lstatSync(path).isSymbolicLink() ||
        relative(root, realpathSync(path)).startsWith(`..${sep}`)) throw Error('Unsafe package file');
    const bytes = readFileSync(path);
    if (bytes.length !== file.bytes || createHash('sha256').update(bytes).digest('hex') !== file.sha256)
      throw Error(`Integrity mismatch: ${file.path}`);
  }
  // Reject unlisted files and directory symlinks, not just listed paths.
  function walk(dir, prefix = '') {
    for (const name of readdirSync(dir)) {
      const path = join(dir, name), rel = prefix + name, info = lstatSync(path);
      if (info.isSymbolicLink()) throw Error('Symlink in package');
      if (info.isDirectory()) walk(path, rel + '/');
      else if (rel !== 'manifest.json' && !paths.has(rel)) throw Error(`Unlisted package file: ${rel}`);
    }
  }
  walk(root);
  if (!paths.has('web/index.html')) throw Error('Missing simulator entry');
  return { root, manifest, paths };
}
