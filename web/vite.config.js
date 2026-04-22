import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
export default defineConfig({
    plugins: [react()],
    build: {
        outDir: '../server/web/dist',
        emptyOutDir: true
    },
    server: {
        port: 5173,
        proxy: {
            '/api': {
                target: 'http://localhost:9999',
                changeOrigin: true
            },
            '/sync': {
                target: 'http://localhost:9999',
                changeOrigin: true
            }
        }
    }
});
