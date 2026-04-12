---
title: "Getting Started"
weight: 2
---

# Getting Started

This guide helps frontend and mobile developers integrate with the Recuerdo backend API.

## Base URL

All API requests go through the **nginx API Gateway**. Never call individual service ports directly — always use the single Base URL.

| Environment | Base URL |
|-------------|----------|
| **Local development** | `http://localhost:8080` |
| **Production** | `https://api.yourdomain.com` |

<aside class="success">
Update the production URL when your domain is finalized.
</aside>

## Swagger UI (Interactive API Explorer)

The fastest way to explore the API is via the interactive Swagger UI:

- **Local**: `http://localhost:8080/swagger/`

In the Swagger UI dropdown, select the API group you want:

- `Auth API` — Login, registration, token refresh
- `Core API` — Users, organizations, events, timeline
- `Storage API` — Media upload and delivery
- `Album API` — Albums, media linking, highlights

## Making Your First Request

### 1. Authenticate

Call the Auth API to obtain a JWT access token:

```shell
curl -X POST http://localhost:8080/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email": "user@example.com", "password": "your-password"}'
```

The response includes an `access_token`.

### 2. Use the Token

Include the token in all subsequent requests:

```shell
curl http://localhost:8080/api/users/me \
  -H "Authorization: Bearer <ACCESS_TOKEN>"
```

### 3. Specify Your Organization

Most data APIs require an `org_id` in the URL path (multi-tenant isolation):

```shell
curl http://localhost:8080/api/orgs/org-12345/events \
  -H "Authorization: Bearer <ACCESS_TOKEN>"
```

<aside class="success">
<strong>Finding your org_id</strong> — Fetch your organizations after login:
<code>curl http://localhost:8080/api/users/me -H "Authorization: Bearer &lt;ACCESS_TOKEN&gt;"</code>
The response includes an <code>organizations</code> array with org_id values.
</aside>

## Request Headers Reference

| Header | Required | Description |
|--------|----------|-------------|
| `Authorization` | Yes (most endpoints) | `Bearer <ACCESS_TOKEN>` |
| `Content-Type` | For POST/PUT | `application/json` or `multipart/form-data` |
| `X-Impersonate-User` | Admin only | Impersonate a user (requires admin role) |

## Identification Codes

Organizations and events have human-readable codes in addition to UUIDs:

| Type | Code Example | Description |
|------|-------------|-------------|
| Organization | `MY-COMPANY-01` | Stable identifier, set at creation |
| Event | `SUMMER-PARTY-2026` | Stable identifier, set at creation |

Always use these codes for filtering and display. Use UUIDs for API path parameters.

## Next Steps

- **Authentication Guide** — JWT, Cognito, token refresh
- **Media Upload Guide** — Chunked upload, HEIC conversion
- **API Reference** — Full endpoint documentation
