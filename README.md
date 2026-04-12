# Recuerdo Developer Docs

[![Netlify Status](https://api.netlify.com/api/v1/badges/27ce33ac-e298-4d62-a01b-d10319734e49/deploy-status)](https://app.netlify.com/projects/recerdo-developers-docs/deploys)

Official API reference, integration guides, and CLI documentation for the **Recuerdo** platform — a multi-tenant media management system built with Go microservices.

**Live site**: https://recerdo-developers-docs.netlify.app/

## Tech Stack

- **Static Site Generator**: [Hugo](https://gohugo.io/) (Extended)
- **Theme**: [DocuAPI v2](https://github.com/bep/docuapi) (Slate-based single-page API docs)
- **Hosting**: [Netlify](https://www.netlify.com/)
- **CSS Processing**: PostCSS + Autoprefixer

## Documentation Structure

| Section | Description |
|---------|-------------|
| **Getting Started** | Base URL, first API call, request headers |
| **Authentication** | AWS Cognito, JWT tokens, token refresh, user roles |
| **Media Upload** | Standard and chunked upload, HEIC conversion, delivery |
| **API Overview** | Microservices architecture, service ports, tech stack |
| **Auth Service** | Login, logout, token refresh, Cognito sync |
| **Core Service** | Users, organizations, events, invitations |
| **Storage Service** | Media upload, delivery, processing pipeline |
| **Album Service** | Albums, event albums, highlights |
| **Metrics Service** | Access logs, API telemetry (admin only) |
| **API Explorer** | Swagger UI usage guide |
| **Admin CLI** | `recuerdo-admin` commands and registry management |
| **RSP v1 Protocol** | Service manifest schema, health check, registry format |

## Local Development

### Prerequisites

- [Hugo Extended](https://gohugo.io/installation/) v0.147.0+
- [Go](https://go.dev/) 1.21+
- [Node.js](https://nodejs.org/) 20+

### Setup

```bash
# Install dependencies
npm install

# Fetch Hugo modules
hugo mod tidy

# Start development server
hugo server
```

The site will be available at `http://localhost:1313/`.

### Build

```bash
hugo
```

Output is generated in the `public/` directory.

## Project Structure

```
.
├── content/              # Hugo content (Markdown)
├── assets/scss/slate/    # SCSS overrides (brand colors, accessibility)
├── layouts/partials/     # Hugo template overrides (sidebar logo)
├── static/               # Static assets (hero.svg, llms.txt)
├── manual-docs/          # Original VitePress documentation (reference)
├── design-docs/          # Internal design documents (not published)
├── hugo.toml             # Hugo site configuration
├── go.mod                # Hugo module dependencies
├── netlify.toml          # Netlify build and deploy settings
└── package.json          # PostCSS dependencies
```

## Deployment

Netlify builds and deploys automatically on push to `main`. The build configuration is defined in `netlify.toml`:

- **Build command**: `npm install && hugo`
- **Publish directory**: `public/`
- **Hugo version**: 0.147.0
- **Node version**: 20

## License

Copyright &copy; 2026 Willen-Federation. All rights reserved.
