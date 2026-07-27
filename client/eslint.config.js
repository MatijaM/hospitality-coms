import js from "@eslint/js";
import { defineConfig, globalIgnores } from "eslint/config";
import reactHooks from "eslint-plugin-react-hooks";
import globals from "globals";
import tseslint from "typescript-eslint";

export default defineConfig([
  globalIgnores(["dist/**", "coverage/**", "node_modules/**"]),
  js.configs.recommended,
  tseslint.configs.strictTypeChecked,
  tseslint.configs.stylisticTypeChecked,
  // `configs["recommended-latest"]` is still the eslintrc shape in v7; the flat
  // namespace is the one this config can spread.
  reactHooks.configs.flat["recommended-latest"],
  {
    languageOptions: {
      globals: globals.browser,
      parserOptions: {
        projectService: {
          // This file is JavaScript and no tsconfig can own it.
          allowDefaultProject: ["eslint.config.js"],
        },
        tsconfigRootDir: import.meta.dirname,
      },
    },
    rules: {
      // `AGENTS.md` bans `{:error, term()}` in favour of enumerated atoms. The
      // TypeScript analogue is a discriminated union, and `any` is the hole
      // every such union leaks through, so it is an error rather than a warning.
      "@typescript-eslint/no-explicit-any": "error",
      "@typescript-eslint/no-unsafe-assignment": "error",
      "@typescript-eslint/consistent-type-imports": "error",
      // A `switch` over a discriminated union is how this client enumerates
      // failure cases. Without this rule a new case added to a union compiles
      // and silently falls through every existing switch.
      "@typescript-eslint/switch-exhaustiveness-check": "error",
      // Every object shape in this client is either a member of a discriminated
      // union or a config record, and unions have to be `type` anyway. One
      // keyword for all of them beats a rule that splits them by shape.
      "@typescript-eslint/consistent-type-definitions": "off",
      // An HTTP status in a message is a number and reads as one.
      "@typescript-eslint/restrict-template-expressions": [
        "error",
        { allowNumber: true },
      ],
    },
  },
  {
    files: ["**/*.test.ts", "**/*.test.tsx"],
    rules: {
      // Test doubles stand in for `phoenix`'s and the DOM's own loose types;
      // insisting a fake socket satisfies every overload buys nothing.
      "@typescript-eslint/no-unsafe-argument": "off",
    },
  },
  {
    files: ["vite.config.ts", "eslint.config.js"],
    languageOptions: { globals: globals.node },
  },
]);
