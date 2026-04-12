import { defineConfig } from 'vitepress'

// Public production API base URL
// Update this when the production domain is finalized
const API_BASE_URL = process.env.VITE_API_BASE_URL || 'https://api.yourdomain.com'

export default defineConfig({
  title: 'Recuerdo Developer Docs',
  description:
    'Official API reference, integration guides, and CLI documentation for the Recuerdo platform — a multi-tenant media management system.',
  lang: 'ja',

  // Make the API base URL available to the theme
  vite: {
    define: {
      __API_BASE_URL__: JSON.stringify(API_BASE_URL),
    },
  },

  // Sitemap for SEO and AI discoverability
  sitemap: {
    hostname: 'https://recuerdo-developers-docs.netlify.app',
  },

  // Head tags
  head: [
    ['meta', { name: 'theme-color', content: '#6366F1' }],
    ['meta', { property: 'og:type', content: 'website' }],
    ['meta', { property: 'og:site_name', content: 'Recuerdo Developer Docs' }],
    ['meta', { name: 'robots', content: 'index, follow' }],
    // llms.txt link for AI discovery
    ['link', { rel: 'alternate', type: 'text/plain', href: '/llms.txt', title: 'LLM Index' }],
  ],

  themeConfig: {
    logo: '\uD83D\uDCF8',

    // Top navigation
    nav: [
      { text: 'Guide', link: '/guide/getting-started' },
      { text: 'API Reference', link: '/api/overview' },
      {
        text: 'API Explorer',
        link: '/api/explorer',
        activeMatch: '/api/explorer',
      },
      { text: 'CLI', link: '/cli/overview' },
      {
        text: 'GitHub',
        link: 'https://github.com/willen-federation',
        target: '_blank',
      },
    ],

    // Sidebar
    sidebar: [
      {
        text: 'Getting Started',
        collapsed: false,
        items: [
          { text: 'Introduction', link: '/guide/getting-started' },
          { text: 'Authentication', link: '/guide/authentication' },
          { text: 'Media Upload', link: '/guide/media-upload' },
        ],
      },
      {
        text: 'API Reference',
        collapsed: false,
        items: [
          { text: 'Overview & Architecture', link: '/api/overview' },
          { text: 'Auth Service', link: '/api/auth' },
          { text: 'Core Service', link: '/api/core' },
          { text: 'Storage Service', link: '/api/storage' },
          { text: 'Album Service', link: '/api/album' },
          { text: 'Metrics Service', link: '/api/metrics' },
        ],
      },
      {
        text: '\uD83D\uDD0D Interactive Explorer',
        collapsed: false,
        items: [{ text: 'API Explorer (Swagger UI)', link: '/api/explorer' }],
      },
      {
        text: 'Admin CLI',
        collapsed: false,
        items: [
          { text: 'CLI Overview', link: '/cli/overview' },
          { text: 'RSP v1 Protocol', link: '/cli/rsp-protocol' },
        ],
      },
    ],

    // Search
    search: {
      provider: 'local',
      options: {
        locales: {
          root: {
            translations: {
              button: { buttonText: 'Search docs', buttonAriaLabel: 'Search' },
              modal: {
                noResultsText: 'No results for',
                resetButtonTitle: 'Clear',
                footer: { selectText: 'to select', navigateText: 'to navigate' },
              },
            },
          },
        },
      },
    },

    // Footer
    footer: {
      message: 'Released under the MIT License.',
      copyright: 'Copyright \u00A9 2026 Willen-Federation',
    },

    // Edit link
    editLink: {
      pattern:
        'https://github.com/willen-federation/recerdo-developers-docs/edit/main/docs/:path',
      text: 'Edit this page on GitHub',
    },

    // Social links
    socialLinks: [
      { icon: 'github', link: 'https://github.com/willen-federation' },
    ],

    // Last updated
    lastUpdated: {
      text: 'Last updated',
      formatOptions: { dateStyle: 'short' },
    },
  },

  // Markdown config
  markdown: {
    theme: { light: 'github-light', dark: 'github-dark' },
    lineNumbers: true,
  },
})
