// SPDX-License-Identifier: MPL-2.0
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // The integration tests build a real archive and run the real server from it.
    testTimeout: 300_000,
    hookTimeout: 600_000,
  },
});
