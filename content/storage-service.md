---
title: "Storage Service"
weight: 8
---

# Storage Service

Handles **media upload, delivery, HEIC conversion, thumbnail generation**, and access control.

**Base Path**: `/api/media/`
**Port**: 8004 (internal)

## Upload

### Standard Upload

```http
POST /api/media/{org_id}/single
Authorization: Bearer <token>
Content-Type: multipart/form-data

file=<binary>
```

### Chunked Upload

```http
# Upload chunk
POST /api/media/{org_id}/upload

# Merge chunks
POST /api/media/{org_id}/merge
```

See the **Media Upload** section above for full details.

## Delivery

```http
GET /api/media/{org_id}/{media_id}?type=original|optimized|thumb
Authorization: Bearer <token>
```

| Type | Description |
|------|-------------|
| `original` | Original file as uploaded |
| `optimized` | Converted (HEIC→PNG) and compressed |
| `thumb` | Thumbnail up to 1280px |
| *(auto)* | Selected by `User-Agent` |

## Processing Pipeline

```
Upload → Storage (raw) → Job Queue (asynq)
                                │
              ├─────────────────────┬──────────────────┘
              ▼                    ▼
        HEIC conversion      Thumbnail gen
              ▼                    ▼
          optimized/            thumb/
          {media_id}.png    {media_id}.jpg
```

<aside class="notice">
<strong>Full Endpoint List</strong> — For all Storage endpoints with schemas, see the Swagger UI at <code>http://localhost:8080/swagger/</code> and filter by <strong>Storage Service</strong>.
</aside>
