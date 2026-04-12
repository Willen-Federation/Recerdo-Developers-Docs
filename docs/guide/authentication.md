# Authentication

Recuerdo uses **AWS Cognito** as the identity provider, with JWT access tokens for API authorization.

## Overview

```
Client App
    │
    ├─── 1. Login ─────────────► Auth Service (/api/auth/)
    │                                    │
    │                              AWS Cognito
    │
    ├─── 2. Use Token ─────────► Core / Storage / Album Services
```

## Login Flow

### Request

```http
POST /api/auth/login
Content-Type: application/json

{
  "email": "user@example.com",
  "password": "your-password"
}
```

### Response

```json
{
  "access_token": "eyJhbGciOiJSUzI1NiIs...",
  "id_token": "eyJhbGciOiJSUzI1NiIs...",
  "refresh_token": "eyJjdHkiOiJKV1Qi...",
  "expires_in": 3600,
  "token_type": "Bearer"
}
```

## Using Access Tokens

Include the `access_token` in the `Authorization` header:

```http
GET /api/users/me
Authorization: Bearer eyJhbGciOiJSUzI1NiIs...
```

::: warning Token Expiry
Access tokens expire after **1 hour**. Use the refresh token to obtain a new one before expiry.
:::

## Token Refresh

```http
POST /api/auth/refresh
Content-Type: application/json

{
  "refresh_token": "eyJjdHkiOiJKV1Qi..."
}
```

## AWS Cognito (Production)

In production, tokens are issued directly by **AWS Cognito**. The `Auth Service` acts as a synchronization layer:

1. The client authenticates with Cognito directly (via Amplify SDK or similar)
2. The Cognito `accessToken` is sent to the backend as a Bearer token
3. The Auth Service validates the token against Cognito's JWKS endpoint

### Web / Mobile Clients (Amplify)

```typescript
import { fetchAuthSession } from 'aws-amplify/auth'

const session = await fetchAuthSession()
const token = session.tokens?.accessToken?.toString()

// Use in fetch:
fetch('/api/users/me', {
  headers: { Authorization: `Bearer ${token}` }
})
```

## Error Responses

| Status | Error | Description |
|--------|-------|-------------|
| `401` | `UNAUTHORIZED` | Missing or invalid token |
| `403` | `FORBIDDEN` | Valid token but insufficient permissions |
| `401` | `TOKEN_EXPIRED` | Token has expired; refresh and retry |

## User Roles

| Role | Description |
|------|-------------|
| `super_admin` | Full access across all organizations |
| `org_admin` | Admin within a specific organization |
| `member` | Standard user within an organization |
| `guest` | Limited read-only access |
