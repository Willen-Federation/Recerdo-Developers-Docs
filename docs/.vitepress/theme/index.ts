import type { Theme } from 'vitepress'
import DefaultTheme from 'vitepress/theme'
import { defineAsyncComponent } from 'vue'
import './custom.css'
// Import Swagger UI styles globally (only affects .swagger-ui scoped elements)
import 'swagger-ui-dist/swagger-ui.css'

export default {
  extends: DefaultTheme,
  enhanceApp({ app }) {
    // Register SwaggerExplorer as an async component (deferred until used)
    app.component(
      'SwaggerExplorer',
      defineAsyncComponent(() => import('./SwaggerExplorer.vue'))
    )
  },
} satisfies Theme
