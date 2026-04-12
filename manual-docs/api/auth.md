# Auth Service

Handles authentication via **AWS Cognito**, JWT token management, user sessions, and device tracking.

**Base Path**: `/api/auth/`  
**Port**: 8001 (internal)

## Key Endpoints

### Login

```http
POST /api/auth/login
```

Authenticate a user and receive JWT tokens.

**Request Body:**
```json
{
  "email": "user@example.com",
  "password": "password"
}
```

**Response:**
```json
{
  "access_token": "eyJhbGci...",
  "id_token": "eyJhbGci...",
  "refresh_token": "eyJjdHki...",
  "expires_in": 3600,
  "token_type": "Bearer"
}
```

### Refresh Token

```http
POST /api/auth/refresh
```

**Request Body:**
```json
{
  "refresh_token": "eyJjdHki..."
}
```

### Cognito Sync

```http
POST /api/auth/sync
```

Synchronizes Cognito user state with the local database. Called automatically on login.

### Logout

```http
POST /api/auth/logout
Authorization: Bearer <token>
```

## Security

- All tokens are **RS256 signed JWTs** issued by AWS Cognito
- Token validation uses Cognito's JWKS endpoint
- Access tokens expire after **1 hour**
- Refresh tokens expire after **30 days**

::: info Full Endpoint List
For the complete list of Auth endpoints with request/response schemas, see the [API Explorer](/api/explorer) and filter by **Auth Service**.
:::
