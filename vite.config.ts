import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { fileURLToPath, URL } from 'node:url';

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },
  optimizeDeps: {
    exclude: ['lucide-react'],
  },
  build: {
    chunkSizeWarningLimit: 1000,
    rollupOptions: {
      output: {
        manualChunks(id) {
          if (!id.includes('node_modules')) return;

          if (id.includes('/react/') || id.includes('/react-dom/')) {
            return 'vendor-react';
          }

          if (id.includes('react-router-dom') || id.includes('@remix-run/router') || id.includes('/react-router/')) {
            return 'vendor-router';
          }

          if (
            id.includes('lucide-react') ||
            id.includes('react-hot-toast') ||
            id.includes('@hcaptcha/react-hcaptcha')
          ) {
            return 'vendor-ui';
          }

          if (id.includes('@supabase/supabase-js') || id.includes('zustand')) {
            return 'vendor-data';
          }

          if (id.includes('@ffmpeg/') || id.includes('pdfkit') || id.includes('resend')) {
            return 'vendor-heavy';
          }
        },
      },
    },
  },
});
