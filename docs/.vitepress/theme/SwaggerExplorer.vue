<template>
  <div class="swagger-explorer-page">
    <!-- Service filter tabs -->
    <div class="swagger-service-tabs">
      <button
        v-for="tab in tabs"
        :key="tab.id"
        class="swagger-tab-btn"
        :class="{ active: activeTab === tab.id }"
        @click="setTab(tab.id)"
      >
        <span>{{ tab.icon }}</span>
        <span>{{ tab.label }}</span>
      </button>
    </div>

    <!-- Error state -->
    <div v-if="specError" class="spec-error" style="padding:1rem;background:#fff3cd;border:1px solid #ffc107;border-radius:6px;margin-bottom:1rem;">
      <strong>\u26A0\uFE0F Could not load OpenAPI spec.</strong>
      Check that the API is accessible and has CORS enabled for this origin.
      Spec URL: <code>{{ specUrl }}</code>
    </div>

    <!-- Swagger UI mount point -->
    <div ref="swaggerMount" class="swagger-ui-container" />
  </div>
</template>

<script setup lang="ts">
import { ref, onMounted, watch } from 'vue'

// Injected at build time via vite.define in .vitepress/config.ts
declare const __API_BASE_URL__: string

const apiBaseUrl = (() => {
  try {
    return __API_BASE_URL__ || 'https://api.yourdomain.com'
  } catch {
    return 'https://api.yourdomain.com'
  }
})()

const specUrl = `${apiBaseUrl}/api/docs/openapi.yaml`

const tabs = [
  { id: 'all',     label: 'All Services',   icon: '\uD83D\uDD0D', filterTag: '' },
  { id: 'auth',    label: 'Auth Service',    icon: '\uD83D\uDD10', filterTag: 'Auth Service' },
  { id: 'core',    label: 'Core Service',    icon: '\uD83C\uDFD7\uFE0F', filterTag: 'Core Service' },
  { id: 'storage', label: 'Storage Service', icon: '\uD83D\uDCF8', filterTag: 'Storage Service' },
  { id: 'album',   label: 'Album Service',   icon: '\uD83D\uDDBC\uFE0F', filterTag: 'Album Service' },
  { id: 'metrics', label: 'Metrics Service', icon: '\uD83D\uDCCA', filterTag: 'Metrics Service' },
]

const activeTab  = ref('all')
const specError  = ref(false)
const swaggerMount = ref<HTMLElement | null>(null)
let   ui: any = null

async function initSwagger() {
  if (!swaggerMount.value) return
  specError.value = false

  try {
    // Dynamic import: runs only in the browser (ClientOnly wrapper ensures this)
    const [{ default: SwaggerUIBundle }, { default: SwaggerUIStandalonePreset }] = await Promise.all([
      import('swagger-ui-dist/swagger-ui-bundle.js'),
      import('swagger-ui-dist/swagger-ui-standalone-preset.js'),
    ])

    // Inject Swagger UI CSS dynamically
    if (!document.querySelector('link[data-swagger-ui-css]')) {
      const link = document.createElement('link')
      link.rel = 'stylesheet'
      link.href = new URL('swagger-ui-dist/swagger-ui.css', import.meta.url).href
      link.setAttribute('data-swagger-ui-css', '')
      document.head.appendChild(link)
    }

    const currentFilter = tabs.find(t => t.id === activeTab.value)?.filterTag ?? ''

    ui = SwaggerUIBundle({
      url: specUrl,
      domNode: swaggerMount.value,
      presets: [
        SwaggerUIBundle.presets.apis,
        SwaggerUIStandalonePreset,
      ],
      plugins: [SwaggerUIBundle.plugins.DownloadUrl],
      layout: 'StandaloneLayout',
      docExpansion: 'list',
      defaultModelsExpandDepth: -1,
      filter: currentFilter || false,
      tryItOutEnabled: false, // Disabled for public docs (CORS)
      onComplete: () => { specError.value = false },
      onFailure: () => { specError.value = true },
    })
  } catch (e) {
    console.error('[SwaggerExplorer] Failed to initialize:', e)
    specError.value = true
  }
}

function setTab(id: string) {
  activeTab.value = id
}

watch(activeTab, (newTab) => {
  if (!ui) return
  const filterTag = tabs.find(t => t.id === newTab)?.filterTag ?? ''
  // Re-initialize with new filter (simpler than using internal Swagger UI actions)
  initSwagger()
})

onMounted(() => {
  initSwagger()
})
</script>
