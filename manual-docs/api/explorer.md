---
title: API Explorer
description: Interactive Swagger UI for the Recuerdo Backend API
---

# API Explorer

Browse all Recuerdo API endpoints and view request/response schemas using the embedded Swagger UI.

::: info Read-only public explorer
The explorer fetches the API definition from the **production backend** at `https://api.yourdomain.com`. This public view is read-only — "Try it out" is disabled to prevent unintended requests to production.
:::

<ClientOnly>
  <SwaggerExplorer />
</ClientOnly>

## Filtering by Service

Use the tabs above the Swagger UI to filter endpoints by service:

| Tab | Shows |
|-----|-------|
| All Services | Every endpoint |
| Auth Service | Login, logout, token refresh, Cognito sync |
| Core Service | Users, organizations, events, timeline, invitations |
| Storage Service | Media upload, delivery, chunked upload |
| Album Service | Albums, event albums, highlights |
| Metrics Service | Access logs, API telemetry |

## Local Development

For local testing with full try-it-out support, use the Swagger UI served by the backend:

```
http://localhost:8080/swagger/
```

This connects directly to your local services and supports all HTTP methods.

To authenticate:
1. Click the **Authorize** button (🔓 icon)
2. Enter `Bearer <your-access-token>` in the `OAuth2Implicit` field
3. Click **Authorize**

To get a token: call `POST /api/auth/login` first, then copy the `access_token` from the response.
