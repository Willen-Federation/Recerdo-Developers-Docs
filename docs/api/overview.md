# API Architecture Overview

Recuerdo is a **microservices-based** platform. All services are exposed through a single nginx API gateway.

## Architecture

```
                     ┌──────────────────────────────┐
                     │   Client Application           │
                     │  (Web / iOS / Android)        │
                     └─────────┬───────────────────┘
                                │
                    ▼
              ┌──────────────────────┐
              │  nginx API Gateway :8080  │
              │  (single Base URL)        │
              └┬──────┬──────┬─────┬┘
               │      │      │     │
    ▼          ▼      ▼      ▼     ▼
┌───────┐ ┌──────┐ ┌────────┐ ┌──────┐ ┌────────┐
│ Auth   │ │ Core  │ │ Storage │ │Album │ │Metrics │
│ :8001  │ │ :8003 │ │ :8004   │ │:8006 │ │:8005   │
└───────┘ └──────┘ └────────┘ └──────┘ └────────┘
```

## Services Summary

| Service | Port | Path Prefix | Description |
|---------|------|-------------|-------------|
| [Auth Service](/api/auth) | 8001 | `/api/auth/` | Authentication & Cognito integration |
| [Core Service](/api/core) | 8003 | `/api/users/`, `/api/orgs/`, `/api/core/` | Users, orgs, events, timeline |
| [Storage Service](/api/storage) | 8004 | `/api/media/` | Media upload, delivery, processing |
| [Album Service](/api/album) | 8006 | `/api/album/`, `/api/orgs/:id/albums` | Albums, highlights, access |
| [Metrics Service](/api/metrics) | 8005 | `/api/metrics/` | API telemetry, access logs |

## Multi-Tenancy

All user data is isolated by **organization** (`org_id`). Most API paths include `{org_id}`:

```http
GET /api/orgs/{org_id}/events
GET /api/media/{org_id}/{media_id}
GET /api/orgs/{org_id}/albums
```

## OpenAPI Specification

The unified OpenAPI 3.0 specification is available at:

- **Local**: `http://localhost:8080/api/docs/openapi.yaml`
- **Production**: `https://api.yourdomain.com/api/docs/openapi.yaml`

## Service Communication

- **Client → Gateway**: HTTP/HTTPS via nginx
- **Service → Service**: gRPC (Protocol Buffers)
- **Async processing**: Redis + Asynq job queue (image optimization, HEIC conversion)

## Tech Stack

| Layer | Technology |
|-------|------------|
| Language | Go 1.22+ |
| Web framework | Gin |
| Database | MySQL + GORM |
| Auth | AWS Cognito + JWT |
| Async | Asynq + Redis |
| Inter-service | gRPC / Protocol Buffers |
| Gateway | nginx |
