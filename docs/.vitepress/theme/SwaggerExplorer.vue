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

    <!-- API Base URL notice -->
    <div v-if="specError" class="spec-error">
      <strong>\u26A0\uFE0F Could not load OpenAPI spec.</strong>
      Make sure the backend is running and accessible at
      <code>{{ apiBaseUrl }}</code>
    </div>

    <!-- Swagger UI mount point -->
    <div
      ref="swaggerContainer"
      class="swagger-ui-container"
      style="min-height: 600px"
    />
  </div>
</template>

<script setup lang="ts">
import { ref, onMounted, watch } from 'vue'

declare const __API_BASE_URL__: string

const apiBaseUrl = typeof __API_BASE_URL__ !== 'undefined'
  ? __API_BASE_URL__
  : 'https://api.yourdomain.com'

const specUrl = `${apiBaseUrl}/api/docs/openapi.yaml`

// Service tabs definition
const tabs = [
  { id: 'all',     label: 'All Services',    icon: '\uD83D\uDD0D', filterTag: undefined },
  { id: 'auth',    label: 'Auth Service',     icon: '\uD83D\uDD10', filterTag: 'Auth Service' },
  { id: 'core',    label: 'Core Service',     icon: '\uD83C\uDFD7\uFE0F', filterTag: 'Core Service' },
  { id: 'storage', label: 'Storage Service',  icon: '\uD83D\uDCF8', filterTag: 'Storage Service' },
  { id: 'album',   label: 'Album Service',    icon: '\uD83D\uDDBC\uFE0F', filterTag: 'Album Service' },
  { id: 'metrics', label: 'Metrics Service',  icon: '\uD83D\uDCCA', filterTag: 'Metrics Service' },
]

const activeTab    = ref('all')
const specError    = ref(false)
const swaggerContainer = ref<HTMLElement | null>(null)
let   swaggerUiInstance: any = null

function setTab(id: string) {
  activeTab.value = id
}

async function initSwagger() {
  if (!swaggerContainer.value) return

  try {
    // Dynamically import swagger-ui-dist (client-side only)
    const SwaggerUIBundle = (await import('swagger-ui-dist/swagger-ui-bundle.js' as any)).default
    await import('swagger-ui-dist/swagger-ui.css' as any)

    const currentTab = tabs.find(t => t.id === activeTab.value)
    const filterTag  = currentTab?.filterTag

    swaggerUiInstance = SwaggerUIBundle({
      url: specUrl,
      dom_id: '#swagger-mount',
      presets: [SwaggerUIBundle.presets.apis, SwaggerUIBundle.SwaggerUIStandalonePreset],
      layout: 'BaseLayout',
      docExpansion: 'list',
      defaultModelsExpandDepth: -1,
      filter: filterTag ?? false,
      onComplete: () => {
        specError.value = false
      },
      onFailure: () => {
        specError.value = true
      },
    })

    // Mount into the ref element
    const mountEl = document.createElement('div')
    mountEl.id = 'swagger-mount'
    swaggerContainer.value.innerHTML = ''
    swaggerContainer.value.appendChild(mountEl)

    swaggerUiInstance = SwaggerUIBundle({
      url: specUrl,
      dom_id: '#swagger-mount',
      presets: [SwaggerUIBundle.presets.apis],
      layout: 'BaseLayout',
      docExpansion: 'list',
      defaultModelsExpandDepth: -1,
      filter: filterTag ?? false,
    })
  } catch (e) {
    console.error('Failed to init Swagger UI', e)
    specError.value = true
  }
}

function reloadSwagger() {
  if (!swaggerContainer.value) return
  if (!swaggerUiInstance) { initSwagger(); return }

  const currentTab = tabs.find(t => t.id === activeTab.value)
  const filterTag  = currentTab?.filterTag
  swaggerUiInstance.getSystem().filterActions.updateFilter(filterTag ?? '')
}

onMounted(() => {
  initSwagger()
})

watch(activeTab, () => {
  reloadSwagger()
})
</script>
