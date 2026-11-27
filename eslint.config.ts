// SPDX-License-Identifier: MPL-2.0
import js from "@eslint/js";
import { defineConfig } from "eslint/config";
import tseslint from "typescript-eslint";

export default defineConfig(
  {
    ignores: [
      "**/node_modules/**",
      "apps/server/data/**",
      "apps/apple/**",
      "packages/**",
      "eslint.config.ts",
    ],
  },
  js.configs.recommended,
  tseslint.configs.strictTypeChecked,
  {
    languageOptions: {
      parserOptions: {
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },
    rules: {
      "@typescript-eslint/consistent-type-definitions": ["error", "interface"],
      "@typescript-eslint/restrict-template-expressions": ["error", { allowNumber: true }],
      // The database helpers take the row type as a type argument: `db.get<Row>(sql)`.
      "@typescript-eslint/no-unnecessary-type-parameters": "off",
    },
  },
);
