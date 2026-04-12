---
title: "Media Upload"
weight: 4
---

# Media Upload

The Storage Service handles all media (images, videos) with automatic optimization.

## Upload Methods

### Standard Upload (Small to Medium Files)

For files under ~100 MB:

```http
POST /api/media/{org_id}/single
Authorization: Bearer <token>
Content-Type: multipart/form-data

file=<binary>
```

```shell
curl -X POST http://localhost:8080/api/media/org-12345/single \
  -H "Authorization: Bearer <token>" \
  -F "file=@photo.jpg"
```

**Response:**

```json
{
  "media_id": "m_abc123",
  "status": "processing",
  "original_url": "/api/media/org-12345/m_abc123?type=original"
}
```

### Chunked Upload (Large Files)

For large files, split into chunks and upload sequentially:

#### Step 1: Upload chunks

```http
POST /api/media/{org_id}/upload
Authorization: Bearer <token>
Content-Type: multipart/form-data

file=<chunk_binary>
upload_id=<session_id>
chunk_index=0
total_chunks=5
```

#### Step 2: Merge chunks

```http
POST /api/media/{org_id}/merge
Authorization: Bearer <token>
Content-Type: application/json

{
  "upload_id": "<session_id>",
  "total_chunks": 5,
  "filename": "video.mp4"
}
```

## Media Delivery

Fetch uploaded media with optional format selection:

```http
GET /api/media/{org_id}/{media_id}?type=<format>
Authorization: Bearer <token>
```

| `type` parameter | Description |
|-----------------|-------------|
| `original` | Original uploaded file |
| `optimized` | Converted/compressed version (PNG for HEIC, MP4 for video) |
| `thumb` | Thumbnail (max 1280px) for fast preview |
| *(omitted)* | Auto-selects based on client `User-Agent` |

## Automatic Processing

All uploaded media is automatically:

1. **HEIC to PNG conversion** — for compatibility with Windows/Android clients
2. **Thumbnail generation** — up to 1280px, stored as `thumb`
3. **Optimization** — compression for faster delivery
4. **Multi-tenant isolation** — each `org_id` has isolated storage

<aside class="notice">
<strong>Processing time</strong> — Processing happens asynchronously via the job queue. Poll the media status endpoint or use webhooks to know when processing is complete.
</aside>

## HEIC Auto-Detection

If the `type` query parameter is omitted, the Storage Service inspects the `User-Agent` header:

- iOS / macOS Safari → delivers HEIC original
- Windows / Android / other → delivers optimized PNG automatically

## Media Object Reference

```json
{
  "media_id": "m_abc123",
  "org_id": "org-12345",
  "filename": "photo.heic",
  "mime_type": "image/heic",
  "size_bytes": 4200000,
  "status": "ready",
  "versions": {
    "original": "/api/media/org-12345/m_abc123?type=original",
    "optimized": "/api/media/org-12345/m_abc123?type=optimized",
    "thumb": "/api/media/org-12345/m_abc123?type=thumb"
  },
  "created_at": "2026-04-12T10:00:00Z"
}
```
