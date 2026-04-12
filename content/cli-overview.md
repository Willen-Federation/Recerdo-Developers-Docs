---
title: "Admin CLI Overview"
weight: 12
---

# Admin CLI Overview

The `recuerdo-admin` CLI tool manages microservice registrations in the Admin Panel.

## Installation

```shell
npm install -g recuerdo-admin-cli
```

Or use locally within the `adminpanel_recerdo` project:

```shell
npx recuerdo-admin <command>
```

## Commands

### `init`

Scaffold a new microservice admin panel:

```shell
recuerdo-admin init <service-id>
```

Creates a new project with:

- `recuerdo-service.json` manifest
- Basic admin UI structure
- RSP v1 compliance

### `add`

Register a service with the Admin Hub:

```shell
# From a URL
recuerdo-admin add https://my-service.example.com

# From an npm package
recuerdo-admin add @my-org/timeline-admin

# From a local directory
recuerdo-admin add ./path/to/service

# From a direct manifest URL
recuerdo-admin add https://my-service.example.com/manifest.json
```

The CLI resolves the manifest automatically:

1. URL without path → tries `{url}/.well-known/recuerdo-service.json`
2. URL with `.json` extension → fetches directly
3. npm package → reads `"recuerdo"` field from `package.json`
4. Local path → reads `recuerdo-service.json` from directory

### `remove`

Deregister a service:

```shell
recuerdo-admin remove <service-id>
```

### `list`

List all registered services:

```shell
recuerdo-admin list
```

### `status`

Check health of all registered services:

```shell
recuerdo-admin status
```

### `validate`

Validate a manifest without registering:

```shell
recuerdo-admin validate https://my-service.example.com
recuerdo-admin validate ./recuerdo-service.json
```

## Registry File

The CLI manages `src/config/registry.json` in the admin panel repository. This file is committed to git and built into the admin panel bundle.

```json
{
  "version": "1",
  "updatedAt": "2026-04-12T10:00:00Z",
  "services": [
    {
      "id": "timeline",
      "name": "Timeline Service",
      "adminUrl": "https://timeline-admin.example.com",
      "healthEndpoint": "/api/timeline/health",
      "registeredAt": "2026-04-12T10:00:00Z"
    }
  ]
}
```

## Service Priority

When the same service ID exists in multiple sources, the highest priority wins:

```
localStorage (UI-added)
    > registry.json (CLI-managed)
        > BUILT_IN_SERVICES (code-defined)
```

## Publishing a Service Package

To publish your service admin panel as an npm package:

```json
{
  "name": "@my-org/timeline-admin",
  "version": "1.0.0",
  "recuerdo": {
    "rsp": "1",
    "id": "timeline",
    "name": "Timeline Service",
    "adminUrl": "https://timeline-admin.example.com",
    "healthEndpoint": "/api/timeline/health",
    "icon": "🎞️",
    "category": "media"
  },
  "publishConfig": { "access": "public" }
}
```

Then install via:

```shell
recuerdo-admin add @my-org/timeline-admin
```

## Related

- **RSP v1 Protocol** — Full protocol specification (see next section)
