# Metrics Service

Collects **API telemetry, access logs**, and provides performance analytics.

**Base Path**: `/api/metrics/`  
**Port**: 8005 (internal)

::: warning Admin Only
All Metrics endpoints require `super_admin` role.
:::

## Access Logs

```http
GET /api/metrics/logs?limit=100&offset=0
Authorization: Bearer <token>
```

**Query Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `limit` | integer | Max entries (default: 100) |
| `offset` | integer | Pagination offset |
| `start_date` | string | ISO-8601 start date filter |
| `end_date` | string | ISO-8601 end date filter |
| `user_id` | string | Filter by user ID |
| `method` | string | Filter by HTTP method |

**Response:**
```json
{
  "logs": [
    {
      "id": "log_001",
      "timestamp": "2026-04-12T10:00:00Z",
      "method": "GET",
      "path": "/api/orgs/org-12345/events",
      "status_code": 200,
      "duration_ms": 45,
      "user_id": "u_abc123",
      "org_id": "org-12345"
    }
  ],
  "total": 1532,
  "limit": 100,
  "offset": 0
}
```

::: info Full Endpoint List
For all Metrics endpoints, see the [API Explorer](/api/explorer) and filter by **Metrics Service**.
:::
