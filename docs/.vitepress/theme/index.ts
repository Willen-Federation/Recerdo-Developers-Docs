import type { Theme } from 'vitepress'
import DefaultTheme from 'vitepress/theme'
import SwaggerExplorer from './SwaggerExplorer.vue'
import './custom.css'

export default {
  extends: DefaultTheme,
  enhanceApp({ app }) {
    // Register the SwaggerExplorer component globally
    // Usage: <SwaggerExplorer /> in any .md file
    app.component('SwaggerExplorer', SwaggerExplorer)
  },
} satisfies Theme
