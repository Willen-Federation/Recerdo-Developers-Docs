# Core Service

Manages **users, organizations, roles, events, timeline**, and invitations.

**Base Paths**: `/api/users/`, `/api/orgs/`, `/api/core/`, `/api/system/`, `/api/dashboard/`  
**Port**: 8003 (internal)

## Users

### Get Current User

```http
GET /api/users/me
Authorization: Bearer <token>
```

**Response:**
```json
{
  "uid": "u_abc123",
  "user_name": "John Doe",
  "email": "john@example.com",
  "organizations": [
    {
      "org_id": "org-12345",
      "org_code": "MY-COMPANY-01",
      "role": "org_admin"
    }
  ]
}
```

### List Users

```http
GET /api/users?limit=100&offset=0
Authorization: Bearer <token>
```

## Organizations

### List Organizations

```http
GET /api/orgs
Authorization: Bearer <token>
```

### Get Organization

```http
GET /api/orgs/{org_id}
Authorization: Bearer <token>
```

## Events

### List Events

```http
GET /api/orgs/{org_id}/events
Authorization: Bearer <token>
```

**Query Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `limit` | integer | Max results (default: 20) |
| `offset` | integer | Pagination offset |
| `status` | string | Filter by status: `active`, `archived` |

### Create Event

```http
POST /api/orgs/{org_id}/events
Authorization: Bearer <token>
Content-Type: application/json

{
  "title": "Summer Party 2026",
  "event_code": "SUMMER-PARTY-2026",
  "start_date": "2026-07-15T10:00:00Z",
  "end_date": "2026-07-15T22:00:00Z"
}
```

## Invitations

```http
POST /api/orgs/{org_id}/invitations
Authorization: Bearer <token>
Content-Type: application/json

{
  "email": "newmember@example.com",
  "role": "member"
}
```

::: info Full Endpoint List
For all Core Service endpoints, see the [API Explorer](/api/explorer) and filter by **Core Service**.
:::
