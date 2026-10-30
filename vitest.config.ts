import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    // node:test deployment.checks.mjs belongs exclusively to test:deployment.
    include: ['src/**/__tests__/**/*.test.{ts,tsx}'],
    testTimeout: 5000,
  },
});
