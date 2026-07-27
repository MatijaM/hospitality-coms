/// <reference types="vite/client" />

interface ImportMetaEnv {
  /**
   * Prefixed to every API path. Empty (the default) means same-origin, which is
   * what the dev proxy in `vite.config.ts` arranges. Setting it to another
   * origin needs CORS on the Phoenix endpoint, which does not exist.
   */
  readonly VITE_API_BASE_URL?: string;

  /**
   * Where the Phoenix socket is mounted. U7 chooses it; nothing connects yet.
   */
  readonly VITE_SOCKET_ENDPOINT?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
