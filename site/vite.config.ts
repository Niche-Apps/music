import { defineConfig } from 'vite'

const allowedHosts = ['macbookserver.tail13bd39.ts.net']

export default defineConfig({
  base: './',
  server: { allowedHosts },
  preview: { allowedHosts },
})
