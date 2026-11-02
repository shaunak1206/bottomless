# Bottomless — design

A personal photo library. Every original lives in cheap cloud storage, the phone keeps small copies for browsing
(including offline), and old photos can be removed from the phone once they are safely backed up.

## Pieces

```
iPhone app (SwiftUI, iOS 17+)
   │  backup · browse · offline cache · share · free up space
   ▼
Cloudflare Worker  (backend/)  ── D1 "bottomless-catalog"   one row per photo/video, change feed (seq)
   │                           ── R2 "bottomless-derived"    thumbnails (t/<id>) and previews (p/<id>)
   └─ presigned URLs ────────────► Google Cloud Storage, ARCHIVE class   originals (o/<id>, o/<id>.pair)
```

| Copy | Size | Where | Used for |
|---|---|---|---|
| thumbnail | ~40 KB, 360 px | R2 + every phone (all of them) | grid, offline browsing of the whole library |
| preview | ~400 KB, 2048 px | R2 + phone cache (recent 250 + favorites + recently viewed) | full-screen viewing, sharing |
| original | full file (HEIC/RAW/MOV) | GCS Archive (~$1.2/TB-month) | "Get original", export, video playback |

## Flows

- **Backup** (app → Worker): the app reads new photos with PhotoKit (persistent change tokens), exports each original,
  hashes it (SHA-256 for identity, MD5 for upload verification), makes the thumbnail and preview with ImageIO, then
  `POST /v1/assets/prepare`. If the hash is already known nothing is uploaded. Otherwise the Worker returns a presigned
  PUT for the original (straight to GCS, so big videos never pass through the Worker); the thumbnail and preview go
  through the Worker into R2. `POST /v1/assets/:id/commit` makes the Worker check the original's size and MD5 in GCS
  before the asset becomes `ready`.
- **Catalog sync** (Worker → app): every change bumps a global sequence number; the app pulls `GET /v1/changes?since=`
  and mirrors rows into a local SQLite catalog. Favorites, trash and restores sync this way.
- **Offline**: the local catalog and every thumbnail are on the phone, so the whole library can be scrolled offline.
  Previews are pinned for the most recent N (default 250) and all favorites; other previews are an LRU cache.
- **Originals**: `GET /v1/assets/:id/original` returns a short-lived presigned GET.
- **Free up space**: photos that are backed up (`ready`), older than the keep window (default 30 days) and not
  favorites are offered for deletion from the phone in one batch. iOS always asks for confirmation and keeps them in
  Recently Deleted for 30 days. iCloud Photos must be off first (otherwise deleting also deletes from iCloud).
- **Sharing**: the iOS share sheet (Messages, WhatsApp, AirDrop…) with the preview or the original; or an expiring
  web link (`POST /v1/shares` → `/s/<token>`), a small gallery page the Worker serves.
- **Background**: nightly `BGProcessingTask` (charging + network) and a Shortcuts action ("Sync Photos") for a
  dependable daily run; opening the app also syncs.
- **Trash**: deleting in the app trashes the asset; a daily cron purges trash older than 30 days from R2 and GCS.

## Decisions and trade-offs

- **GCS Archive over S3 Glacier Deep Archive**: ~$1.44 vs ~$1.19 per 100 GB-year, but GCS Archive reads are instant
  (Deep Archive restores take 12–48 h). Costs: $0.05/GB to read back, 365-day minimum per object.
- **Derivatives made on the phone**: free CPU, works offline; a server-side image pipeline would cost money.
- **Originals upload direct to GCS**: avoids the Worker's 100 MB request limit (videos).
- **Thumbnails/previews through the Worker + R2 binding**: no extra storage keys on the phone, free egress.
- **Auth**: one long random bearer token (Worker secret + app build setting). Single user; Sign in with Apple needs a
  paid developer account.
- **No end-to-end encryption in v1**: data is encrypted at rest by Google/Cloudflare; E2E would break share links and a
  lost key would lose every photo.
- **Free Apple Personal Team**: the app is installed from Xcode and re-signed every 7 days (SideStore can automate it).
  No push notifications (local notifications instead), no App Groups (no widgets/Files extension in v1).
- **Fallback**: `ORIGINALS_MODE=r2` keeps originals in an R2 bucket through the Worker (used for local tests and if GCS
  is unavailable).

## Not in v1

Search by place, albums, Live Photo motion playback (both halves are stored), widgets, Files extension, face grouping.
