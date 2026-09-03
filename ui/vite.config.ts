import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// The intent-tier chat surface. VITE_* values are baked in at build time;
// docker/ui-build-and-serve.sh regenerates the runtime .env from pod
// environment before the production build so the ui-env ConfigMap (Service
// DNS URLs) wins over any build-time defaults.
export default defineConfig({
  plugins: [react()],
  server: { port: 3000 },
  preview: { port: 3000, host: true },
})
