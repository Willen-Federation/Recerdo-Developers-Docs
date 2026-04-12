---
title: "RSP v1 Protocol"
weight: 13
---

# Recuerdo Service Protocol (RSP) v1

> **Status**: Draft | **Version**: 1.0.0 | **Updated**: 2026-04-12

RSP defines how Recuerdo microservices register with and are discovered by the Admin Hub.

## Overview

A service implementing RSP v1 can:

- Be registered with `recuerdo-admin add` in one command
- Show health status in the Admin Hub automatically
- Appear in the Service Hub with metadata and quick-links

## Service Manifest (`recuerdo-service.json`)

### Placement

| Location | Path |
|----------|------|
| Repository root | `./recuerdo-service.json` |
| Well-Known URI | `https://{admin-domain}/.well-known/recuerdo-service.json` |
| npm package | `"recuerdo"` field in `package.json` |

### Schema

```json
{
  "$schema": "https://recuerdo.example.com/schemas/service-manifest.v1.json",
  "rsp": "1",
  "id": "timeline",
  "name": "Timeline Service",
  "description": "...",
  "version": "1.2.3",
  "adminUrl": "https://timeline-admin.example.com",
  "healthEndpoint": "/api/timeline/health",
  "icon": "🎞️",
  "category": "media",
  "status": "active",
  "apiPrefix": "/api/timeline",
  "routes": [
    { "label": "Timelines", "path": "/timelines" },
    { "label": "Settings",  "path": "/settings" }
  ],
  "requires": {
    "services": ["core", "auth"],
    "minAdminVersion": "1.0.0"
  }
}
```

### Field Constraints

| Field | Type | Constraint |
|-------|------|------------|
| `rsp` | string | Must be `"1"` |
| `id` | string | `^[a-z][a-z0-9-]{1,62}$` |
| `version` | string | SemVer format |
| `adminUrl` | string | Must start with `https://` |
| `healthEndpoint` | string | Starts with `/` (relative) or `https://` (absolute) |
| `category` | enum | `core` \| `media` \| `system` \| `developer` \| `custom` |
| `status` | enum | `active` \| `maintenance` \| `planned` \| `deprecated` |

## Health Check

The Admin Hub polls each service's `healthEndpoint` every 30 seconds.

### Request

```http
GET {healthEndpoint}
Authorization: Bearer {token}  (optional)
```

### Response

**Healthy (200):**

```json
{ "status": "ok", "version": "1.2.3", "uptime_seconds": 3600 }
```

**Degraded (503):**

```json
{ "status": "degraded", "reason": "Database connection lost" }
```

<aside class="warning">
<strong>Timeout</strong> — Respond within <strong>1 second</strong>. The Hub times out after <strong>4 seconds</strong> and marks the service as <code>unreachable</code>.
</aside>

## Registry Format (`registry.json`)

```json
{
  "version": "1",
  "updatedAt": "2026-04-12T10:00:00Z",
  "services": [
    {
      "rsp": "1",
      "id": "timeline",
      "name": "Timeline Service",
      "version": "1.2.3",
      "adminUrl": "https://timeline-admin.example.com",
      "healthEndpoint": "/api/timeline/health",
      "icon": "🎞️",
      "category": "media",
      "status": "active",
      "builtIn": false,
      "registeredAt": "2026-04-12T10:00:00Z"
    }
  ]
}
```

## Source Resolution

When running `recuerdo-admin add <source>`:

| Source format | Resolution |
|--------------|------------|
| `https://example.com` | Fetch `{url}/.well-known/recuerdo-service.json` |
| `https://example.com/file.json` | Fetch directly |
| `@scope/package` | `npm info` → read `"recuerdo"` field |
| `./path/to/dir` | Read `{dir}/recuerdo-service.json` |
| `./path/to/file.json` | Read directly |

## Versioning

| RSP Version | Changes |
|-------------|--------|
| `1` (current) | Initial: Manifest / Registry / Health / CLI |

The `rsp` field ensures backward compatibility. CLI will auto-migrate on major version bumps.

## Security

1. `adminUrl` must use `https://` in production
2. Manifests are validated against the JSON Schema before registration
3. Built-in service IDs cannot be overridden by external registrations
4. 4-second timeout applies to both health checks and manifest fetches
