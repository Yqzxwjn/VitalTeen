import { fileURLToPath, URL } from 'node:url'

import vue from '@vitejs/plugin-vue'
import { defineConfig } from 'vitest/config'

export default defineConfig({
  plugins: [vue()],

  // 相对路径：答辩现场用本地静态服务器打开 dist/，若配成绝对路径，
  // 从子目录访问时资源会 404。离线演示不该被部署路径绊住。
  base: './',

  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },

  build: {
    // 大屏是本地离线打开，不追求首屏体积；ECharts 一整包就是 1MB 量级，
    // 默认 500KB 的警告会一直刷屏，反而把真正的警告淹没。
    chunkSizeWarningLimit: 2000,
  },

  test: {
    environment: 'jsdom',
    include: ['src/**/*.spec.ts'],
  },
})
