---
title: API Explorer
description: Interactive Swagger UI for the Recuerdo Backend API
---

# API Explorer

Use the interactive Swagger UI below to browse and test all Recuerdo API endpoints.

::: info Production API
The explorer connects to the **production backend** at `https://api.yourdomain.com`. You need a valid JWT token to test authenticated endpoints.
:::

::: tip How to authenticate in Swagger UI
1. Click the **Authorize** button (\uD83D\uDD13 icon) in the Swagger UI
2. Enter `Bearer <your-access-token>` in the `OAuth2Implicit` field
3. Click **Authorize**

To get a token: call `POST /api/auth/login` first, then copy the `access_token` from the response.
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
