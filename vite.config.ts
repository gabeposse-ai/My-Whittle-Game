import { defineConfig } from 'vite';

// Relative base so the build works on GitHub Pages (served from /my-whittle-game/) and anywhere else.
export default defineConfig({
  base: './',
  build: { target: 'es2022', chunkSizeWarningLimit: 1500 },
});
