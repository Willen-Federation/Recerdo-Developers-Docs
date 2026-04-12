---
title: "Recuerdo Developer Docs"
weight: 1
---

# Introduction

Welcome to the **Recuerdo Developer Documentation**. Recuerdo is a multi-tenant media management platform providing API reference, integration guides, and CLI tools for developers.

## Platform Services

Recuerdo is built on a microservices architecture with the following core services:

- **Auth Service** — AWS Cognito integration, JWT authentication, user sessions, and device tracking. Secure multi-tenant access control.
- **Core Service** — User management, organizations, roles, events, timeline, and invitation workflows.
- **Storage Service** — Media upload with chunked support, HEIC to PNG auto-conversion, thumbnail generation, and optimized delivery.
- **Album Service** — Album creation, media and comment linking, highlight video management, and access control.
- **Metrics Service** — API telemetry, access logs, and performance analytics.
- **Admin CLI** — Register and manage microservice admin panels using the `recuerdo-admin` CLI and the RSP v1 protocol.

## Quick Links

- **Getting Started** — Set up your environment and make your first API call
- **Authentication** — JWT, Cognito, token refresh
- **Media Upload** — Chunked upload, HEIC conversion
- **API Reference** — Full endpoint documentation for all services
