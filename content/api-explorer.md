---
title: "API Explorer"
weight: 11
---

# API Explorer

Browse all Recuerdo API endpoints and view request/response schemas using the Swagger UI.

<aside class="notice">
The interactive Swagger UI is available at your backend server. For local development, visit <code>http://localhost:8080/swagger/</code>.
</aside>

## Filtering by Service

Use the Swagger UI tabs to filter endpoints by service:

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

```shell
# Open in your browser
open http://localhost:8080/swagger/
```

This connects directly to your local services and supports all HTTP methods.

To authenticate:

1. Click the **Authorize** button
2. Enter `Bearer <your-access-token>` in the `OAuth2Implicit` field
3. Click **Authorize**

To get a token: call `POST /api/auth/login` first, then copy the `access_token` from the response.
