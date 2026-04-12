---
title: "Album Service"
weight: 9
---

# Album Service

Manages **albums, media associations, highlight videos**, and event album access control.

**Base Paths**: `/api/orgs/{org_id}/albums`, `/api/orgs/{org_id}/events/{event_id}/album`, `/api/album/`
**Port**: 8006 (internal)

## List Albums

```http
GET /api/orgs/{org_id}/albums
Authorization: Bearer <token>
```

Returns all albums in the organization that the authenticated user can access, including their role per album.

**Response:**

```json
{
  "albums": [
    {
      "album_id": "alb_abc123",
      "event_id": "evt_xyz789",
      "title": "Summer Party 2026",
      "cover_media_id": "m_cover001",
      "media_count": 142,
      "user_role": "viewer"
    }
  ]
}
```

## Get Event Album

```http
GET /api/orgs/{org_id}/events/{event_id}/album
Authorization: Bearer <token>
```

Returns the full album for an event: metadata, cover image, highlight video, and all media.

**Response:**

```json
{
  "album_id": "alb_abc123",
  "event": {
    "event_id": "evt_xyz789",
    "title": "Summer Party 2026",
    "event_code": "SUMMER-PARTY-2026"
  },
  "cover_image": "/api/media/org-12345/m_cover001?type=thumb",
  "highlight_video": "/api/media/org-12345/m_video001?type=original",
  "media": [
    {
      "media_id": "m_abc001",
      "url": "/api/media/org-12345/m_abc001",
      "type": "image"
    }
  ]
}
```

<aside class="notice">
<strong>Full Endpoint List</strong> — For all Album endpoints with schemas, see the Swagger UI at <code>http://localhost:8080/swagger/</code> and filter by <strong>Album Service</strong>.
</aside>
