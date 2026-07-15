import js from "@eslint/js"
import {defineConfig} from "eslint/config"
import globals from "globals"

export default defineConfig(
  {
    files: ["js/**/*.js"],
    extends: [js.configs.recommended],
    languageOptions: {
      ecmaVersion: "latest",
      sourceType: "module",
      globals: {
        ...globals.browser,
        process: "readonly",
      },
    },
    rules: {
      "no-unused-vars": ["error", {argsIgnorePattern: "^_", caughtErrorsIgnorePattern: "^_"}],
    },
  },
)
