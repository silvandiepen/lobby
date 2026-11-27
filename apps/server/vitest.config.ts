// SPDX-License-Identifier: MPL-2.0
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // Tests make real video files with ffmpeg and read them with ffprobe; that is slow on a busy machine.
    testTimeout: 60_000,
    hookTimeout: 60_000,
  },
});
