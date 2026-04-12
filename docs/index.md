---
layout: home
title: Recuerdo Developer Docs

hero:
  name: "Recuerdo"
  text: "Developer Documentation"
  tagline: Multi-tenant media management platform — API reference, integration guides, and CLI tools.
  image:
    src: /hero.svg
    alt: Recuerdo
  actions:
    - theme: brand
      text: Get Started
      link: /guide/getting-started
    - theme: alt
      text: API Explorer
      link: /api/explorer
    - theme: alt
      text: API Reference
      link: /api/overview

features:
  - icon: 🔐
    title: Auth Service
    details: AWS Cognito integration, JWT authentication, user sessions, and device tracking. Secure multi-tenant access control.
    link: /api/auth
    linkText: Auth API Reference
  - icon: 🏗️
    title: Core Service
    details: User management, organizations, roles, events, timeline, and invitation workflows.
    link: /api/core
    linkText: Core API Reference
  - icon: 📸
    title: Storage Service
    details: Media upload with chunked support, HEIC→PNG auto-conversion, thumbnail generation, and optimized delivery.
    link: /api/storage
    linkText: Storage API Reference
  - icon: 🖼️
    title: Album Service
    details: Album creation, media and comment linking, highlight video management, and access control.
    link: /api/album
    linkText: Album API Reference
  - icon: 🔍
    title: Interactive Explorer
    details: Browse endpoints, request/response schemas, and example payloads in the embedded Swagger UI.
    link: /api/explorer
    linkText: Open API Explorer
  - icon: 🛠️
    title: Admin CLI
    details: Register and manage microservice admin panels using the recuerdo-admin CLI and the RSP v1 protocol.
    link: /cli/overview
    linkText: CLI Documentation
---
