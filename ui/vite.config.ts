import react from '@vitejs/plugin-react'
import { defineConfig, loadEnv } from 'vite'

// The browser calls the relative /api path. Vite proxies it to the supervisor
// target loaded from runtime .env, keeping Kubernetes Service DNS inside the
// UI pod rather than leaking it into the browser bundle.
export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, '.', '')
  const target = env.VITE_SUPERVISOR_API_URL || 'http://localhost:9090'
  const proxy = {
    '/api': {
      target,
      changeOrigin: true,
      rewrite: (path: string) => path.replace(/^\/api/, ''),
    },
  }

  return {
    plugins: [react()],
    server: { port: 3000, proxy },
    preview: { port: 3000, host: true, proxy },
  }
})
