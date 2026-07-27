/// <reference types="vite/client" />

interface ImportMetaEnv {
  /**
   * Prefixed to every API path. Empty (the default) means same-origin, which is
   * what the dev proxy in `vite.config.ts` arranges. Setting it to another
   * origin needs CORS on the Phoenix endpoint, which does not exist.
   */
  readonly VITE_API_BASE_URL?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
