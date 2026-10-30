import { expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import config from '../../vitest.config';

it('explicitly confines Vitest to source TypeScript tests and retains the five-second timeout',()=>{
  expect(config.test?.include).toEqual(['src/**/__tests__/**/*.test.{ts,tsx}']);
  expect(config.test?.testTimeout).toBe(5000);
});
it('runs deployment socket tests only under node:test, independently of Vitest',()=>{
  const pkg=JSON.parse(readFileSync('package.json','utf8'));
  expect(pkg.scripts['test:deployment']).toBe('node --test tool/deploy/deployment.checks.mjs');
  const source=readFileSync('tool/deploy/deployment.checks.mjs','utf8');
  expect(source).toContain("from 'node:test'");expect(source).not.toMatch(/from ['"]vitest/);
});
