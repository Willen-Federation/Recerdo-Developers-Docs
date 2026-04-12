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

    <!-- Error notice -->
    <div
      v-if="specError"
      style="
        padding: 0.75rem 1rem;
        margin-bottom: 1rem;
        background: #fff3cd;
        border: 1px solid #f59e0b;
        border-radius: 6px;
        font-size: 0.9rem;
      "
    >
      <strong>\u26A0\uFE0F OpenAPI spec could not be loaded.</strong>
      The production API (<code>{{ apiBaseUrl }}</code>) may be unavailable or
      CORS may not be configured for this origin. For local testing, use
      <a href="http://localhost:8080/swagger/" target="_blank">localhost:8080/swagger/</a>.
    </div>

    <!-- Loading state -->
    <div v-if="loading" style="padding: 2rem; text-align: center; color: var(--vp-c-text-2);">
      Loading API Explorer\u2026
    </div>

    <!-- Swagger UI mount point -->
    <div ref="swaggerMount" class="swagger-ui-container" :style="loading ? 'display:none' : ''" />
  </div>
</template>

<script setup lang="ts">
import { ref, onMounted, watch } from 'vue'

declare const __API_BASE_URL__: string

const apiBaseUrl = (() => {
  try { return __API_BASE_URL__ || 'https://api.yourdomain.com' }
  catch { return 'https://api.yourdomain.com' }
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

const activeTab    = ref('all')
const specError    = ref(false)
const loading      = ref(true)
const swaggerMount = ref<HTMLElement | null>(null)

async function initSwagger() {
  if (!swaggerMount.value) return
  loading.value = true
  specError.value = false

  // Clear previous content
  swaggerMount.value.innerHTML = ''

  try {
    const SwaggerUIBundle = (await import('swagger-ui-dist/swagger-ui-bundle.js')).default
    const SwaggerUIStandalonePreset = (await import('swagger-ui-dist/swagger-ui-standalone-preset.js')).default

    const currentFilter = tabs.find(t => t.id === activeTab.value)?.filterTag ?? ''

    SwaggerUIBundle({
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
      // Disable try-it-out for public docs (CORS)
      supportedSubmitMethods: [],
      onComplete: () => {
        loading.value = false
        specError.value = false
      },
      onFailure: () => {
        loading.value = false
        specError.value = true
      },
    })
  } catch (e) {
    console.error('[SwaggerExplorer] Init failed:', e)
    loading.value = false
    specError.value = true
  }
}

function setTab(id: string) {
  activeTab.value = id
}

watch(activeTab, () => {
  initSwagger()
})

onMounted(() => {
  initSwagger()
})
</script>
