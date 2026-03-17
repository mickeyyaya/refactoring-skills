---
name: file-upload-media-patterns
description: Use when designing or reviewing file upload and media processing systems — covers presigned URL direct-to-storage uploads, resumable uploads (tus/S3 multipart), upload security pipeline (MIME magic bytes, virus scanning, quarantine), async media processing (thumbnails, transcoding, webhooks), image optimization (WebP/AVIF, responsive images, CDN transforms), storage abstraction layer, content-addressable storage with hash-based dedup, and upload anti-patterns across TypeScript and Go
---

# File Upload and Media Processing Patterns

## Overview

File upload systems fail silently when storage is bypassed through the API server, when uploads lack size limits, when MIME types are trusted from the client, or when media processing blocks the request thread.

**When to use:** Designing direct-to-storage upload flows; reviewing upload endpoints for security gaps; evaluating media processing pipelines; assessing image optimization strategies; auditing storage abstraction layers.

## Quick Reference

| Pattern | Core Idea | Primary Red Flag |
|---------|-----------|-----------------|
| Presigned URL / Direct-to-Storage | Client uploads directly to S3/GCS/Azure via short-lived URL; API never handles bytes | Streaming large files through the API server; no expiry on upload URLs |
| Resumable Uploads (tus / S3 Multipart) | Large uploads broken into chunks; interrupted uploads resume from last chunk | Single-shot uploads of large files with no resume capability |
| Upload Security Pipeline | Validate MIME magic bytes, virus scan in quarantine bucket before promoting | Trusting Content-Type header; skipping ClamAV scan; no quarantine stage |
| Async Media Processing | Thumbnails/transcoding enqueued as jobs; webhook fires on completion | Blocking the HTTP response while FFmpeg runs; sync thumbnail generation |
| Image Optimization | Convert to WebP/AVIF at ingest; generate responsive srcset; CDN transforms | Serving raw JPEG/PNG; no responsive variants; no CDN transform layer |
| Storage Abstraction | Provider-agnostic interface wraps S3/GCS/Azure/local; swap without code change | Hardcoded `s3.PutObject` calls scattered through business logic |
| Content-Addressable Storage | SHA-256 hash is the key; identical files stored once; dedup is automatic | UUID-named files; duplicate content stored multiple times |
| Upload Anti-Patterns | base64 in JSON, no size limits, sync processing, storing blobs in DB | Any of these present in production upload code |

---

## Patterns in Detail

### 1. Direct-to-Storage Presigned URL

API server generates a short-lived presigned URL; client POSTs bytes directly to the storage bucket. The API server never handles file bytes, preserving bandwidth and compute.

**Red Flags:**
- API server streams upload bytes from client to S3 — double bandwidth usage
- Presigned URL has no expiry or a multi-day expiry — window for abuse
- `Content-Type` and size not constrained in presigned URL conditions
- No follow-up webhook or polling to confirm upload completion
- Client-supplied filename written directly to storage key — path traversal risk

**TypeScript — generate presigned URL (AWS SDK v3):**
```typescript
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";

async function createUploadUrl(
  userId: string,
  contentType: string,
  maxBytes = 10 * 1024 * 1024
): Promise<{ uploadUrl: string; objectKey: string; expiresAt: Date }> {
  const allowedTypes = ["image/jpeg", "image/png", "image/gif", "video/mp4"];
  if (!allowedTypes.includes(contentType)) throw new Error(`Unsupported: ${contentType}`);

  const objectKey = `quarantine/${userId}/${crypto.randomUUID()}`; // server-assigned key
  const command = new PutObjectCommand({
    Bucket: process.env.UPLOAD_BUCKET,
    Key: objectKey,
    ContentType: contentType,
  });

  const uploadUrl = await getSignedUrl(s3Client, command, { expiresIn: 300 });
  return { uploadUrl, objectKey, expiresAt: new Date(Date.now() + 300_000) };
}
```

Cross-reference: `security-patterns-code-review` — Input Validation: never trust client-supplied filenames or MIME types.

---

### 2. Resumable Uploads — tus Protocol and S3 Multipart

Large file uploads need resume capability. Without this, a 2 GB video upload that fails at 95% must restart from zero.

**Red Flags:**
- Single PUT/POST for files over 5 MB with no retry on network failure
- Multipart upload initiated but never completed or aborted — dangling parts accumulate
- Chunk size below 5 MB for S3 multipart — S3 rejects parts under 5 MB (except last)
- No expiry on incomplete multipart uploads — stale parts linger indefinitely
- No client-side progress reporting — user sees no feedback on large uploads

**TypeScript — S3 multipart upload:**
```typescript
import {
  CreateMultipartUploadCommand, UploadPartCommand,
  CompleteMultipartUploadCommand, AbortMultipartUploadCommand,
} from "@aws-sdk/client-s3";

const CHUNK_SIZE = 10 * 1024 * 1024; // above S3's 5 MB minimum

async function multipartUpload(
  bucket: string, key: string, fileBuffer: Buffer,
  onProgress?: (pct: number) => void
): Promise<string> {
  const { UploadId } = await s3.send(new CreateMultipartUploadCommand({ Bucket: bucket, Key: key }));
  if (!UploadId) throw new Error("Failed to initiate multipart upload");

  const parts: { PartNumber: number; ETag: string }[] = [];
  try {
    const totalChunks = Math.ceil(fileBuffer.length / CHUNK_SIZE);
    for (let i = 0; i < totalChunks; i++) {
      const chunk = fileBuffer.subarray(i * CHUNK_SIZE, (i + 1) * CHUNK_SIZE);
      const { ETag } = await s3.send(new UploadPartCommand({
        Bucket: bucket, Key: key, UploadId, PartNumber: i + 1, Body: chunk,
      }));
      parts.push({ PartNumber: i + 1, ETag: ETag! });
      onProgress?.((((i + 1) / totalChunks) * 100) | 0);
    }
    const { Location } = await s3.send(new CompleteMultipartUploadCommand({
      Bucket: bucket, Key: key, UploadId, MultipartUpload: { Parts: parts },
    }));
    return Location!;
  } catch (err) {
    await s3.send(new AbortMultipartUploadCommand({ Bucket: bucket, Key: key, UploadId }));
    throw new Error(`Multipart upload failed: ${(err as Error).message}`);
  }
}
```

**tus server (Node.js — @tus-node-server):**
```typescript
import { Server, FileStore } from "@tus-node-server";

const tusServer = new Server({
  path: "/uploads",
  datastore: new FileStore({ directory: "/tmp/tus-uploads" }), // use S3Store in production
});

tusServer.on("POST_FINISH", async (req, res, upload) => {
  await enqueueMediaProcessing(upload.id, upload.metadata);
});
```

---

### 3. Upload Security Pipeline — MIME Validation, Virus Scan, Quarantine

Never promote an uploaded file to the public bucket without validating its actual content. MIME headers are client-supplied and trivially spoofed.

**Pipeline stages:**
1. File lands in **quarantine bucket** (not publicly accessible)
2. Lambda/worker: read magic bytes, validate against allowed types
3. ClamAV scan (async); on detection, delete and alert
4. On clean: compute SHA-256, check dedup, copy to **production bucket**, delete quarantine object
5. Emit `file.ready` event; downstream services use production bucket only

**Red Flags:**
- Trusting `Content-Type` header — clients send `image/jpeg` for `.exe` files
- Reading only the file extension — rename `malware.exe` to `photo.jpg`
- Serving uploads directly from the upload bucket without scan
- No quarantine bucket — infected files land with clean files
- Virus scan runs synchronously in the upload request — adds seconds to response time

**TypeScript — MIME magic bytes validation:**
```typescript
const MAGIC_BYTES: Record<string, number[][]> = {
  "image/jpeg": [[0xff, 0xd8, 0xff]],
  "image/png":  [[0x89, 0x50, 0x4e, 0x47]],
  "image/gif":  [[0x47, 0x49, 0x46, 0x38]],
  "image/webp": [[0x52, 0x49, 0x46, 0x46]],
  "video/mp4":  [[0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70]],
  "application/pdf": [[0x25, 0x50, 0x44, 0x46]],
};

function validateMagicBytes(buffer: Buffer, declaredType: string): boolean {
  const signatures = MAGIC_BYTES[declaredType];
  if (!signatures) return false;
  return signatures.some(sig => sig.every((byte, i) => buffer[i] === byte));
}

async function processQuarantinedFile(objectKey: string): Promise<void> {
  const { Body, ContentLength } = await s3.send(
    new GetObjectCommand({ Bucket: QUARANTINE_BUCKET, Key: objectKey })
  );
  if ((ContentLength ?? 0) > MAX_FILE_SIZE_BYTES) {
    await deleteQuarantineObject(objectKey);
    throw new Error(`File exceeds size limit: ${objectKey}`);
  }
  const header = await readFirstBytes(Body, 16);
  const declaredType = objectKey.split(".").pop() ?? "";
  if (!validateMagicBytes(header, `image/${declaredType}`)) {
    await deleteQuarantineObject(objectKey);
    throw new Error(`MIME magic bytes mismatch: ${objectKey}`);
  }
  await enqueueVirusScan(objectKey); // async — do not block here
}
```

**Go — invoke ClamAV via clamd socket:**
```go
import "github.com/dutchcoders/go-clamd"

func scanFile(ctx context.Context, filePath string) error {
    clam := clamd.NewClamd("tcp://clamav:3310")
    if err := clam.Ping(); err != nil {
        return fmt.Errorf("ClamAV unreachable: %w", err)
    }
    f, err := os.Open(filePath)
    if err != nil { return fmt.Errorf("scanFile open: %w", err) }
    defer f.Close()

    ch, err := clam.ScanStream(f, make(chan bool))
    if err != nil { return fmt.Errorf("scanFile scan: %w", err) }
    for result := range ch {
        if result.Status == clamd.RES_FOUND {
            return fmt.Errorf("virus detected: %s in %s", result.Description, filePath)
        }
    }
    return nil
}
```

Cross-reference: `security-patterns-code-review` — File Upload Security: SSRF via SVG, polyglot files.

---

### 4. Async Media Processing Pipeline — Thumbnails, Transcoding, Webhooks

Media processing is CPU-intensive and can take seconds to minutes. Never run it synchronously inside the HTTP request.

**Pipeline:**
```
Upload complete → [file.uploaded event] → message queue
  → [media-worker pool]
      ├── thumbnail generator (sharp)
      ├── video transcoder (FFmpeg)
      └── metadata extractor (exiftool)
  → [file.ready event] → webhook delivery → client callback URL
```

**Red Flags:**
- Calling `sharp()` or `ffmpeg` synchronously inside the POST /upload handler
- Processing blocks the event loop — Node.js unresponsive for all requests
- No job queue — media processing scales with API servers instead of dedicated workers
- Webhook fired before processing is confirmed complete
- No retry for failed transcoding jobs
- Output files written before job marked complete — partial files served

**TypeScript — enqueue and process:**
```typescript
interface MediaJob {
  jobId: string; objectKey: string; userId: string;
  operations: ("thumbnail" | "transcode" | "extractMetadata")[];
  webhookUrl?: string;
}

async function enqueueMediaProcessing(objectKey: string, userId: string, webhookUrl?: string): Promise<string> {
  const job: MediaJob = { jobId: crypto.randomUUID(), objectKey, userId, operations: ["thumbnail", "extractMetadata"], webhookUrl };
  await sqs.send(new SendMessageCommand({
    QueueUrl: process.env.MEDIA_JOBS_QUEUE_URL,
    MessageBody: JSON.stringify(job),
    MessageGroupId: userId,
  }));
  return job.jobId;
}

async function processThumbnail(job: MediaJob): Promise<void> {
  const SIZES = [{ w: 150, h: 150, suffix: "thumb" }, { w: 800, h: 600, suffix: "medium" }];
  const inputBuffer = await downloadFromS3(job.objectKey);
  const outputs = await Promise.all(
    SIZES.map(({ w, h, suffix }) =>
      sharp(inputBuffer)
        .resize(w, h, { fit: "cover", withoutEnlargement: true })
        .webp({ quality: 80 }).toBuffer()
        .then(buf => uploadToS3(`processed/${job.userId}/${suffix}-${job.jobId}.webp`, buf))
    )
  );
  if (job.webhookUrl) await deliverWebhook(job.webhookUrl, { jobId: job.jobId, status: "complete", outputs });
}
```

**Go — FFmpeg transcoding worker:**
```go
func transcodeVideo(ctx context.Context, job MediaJob) error {
    inputPath := filepath.Join(os.TempDir(), job.JobID+"-input")
    outputPath := filepath.Join(os.TempDir(), job.JobID+"-output.mp4")

    if err := downloadFromS3(ctx, job.ObjectKey, inputPath); err != nil {
        return fmt.Errorf("transcodeVideo download: %w", err)
    }
    defer os.Remove(inputPath)
    defer os.Remove(outputPath)

    cmd := exec.CommandContext(ctx, "ffmpeg",
        "-i", inputPath,
        "-c:v", "libx264", "-crf", "23", "-preset", "fast",
        "-c:a", "aac", "-b:a", "128k",
        "-movflags", "+faststart",
        outputPath,
    )
    if out, err := cmd.CombinedOutput(); err != nil {
        return fmt.Errorf("ffmpeg failed: %w\noutput: %s", err, out)
    }

    outputKey := fmt.Sprintf("processed/%s/%s-720p.mp4", job.UserID, job.JobID)
    if err := uploadToS3(ctx, outputKey, outputPath); err != nil {
        return fmt.Errorf("transcodeVideo upload: %w", err)
    }
    return deliverWebhook(ctx, job.WebhookURL, WebhookPayload{JobID: job.JobID, Status: "complete", Key: outputKey})
}
```

Cross-reference: `message-queue-patterns` — DLQ for failed transcoding jobs; `error-handling-patterns` — Retry with Backoff.

---

### 5. Image Optimization — WebP/AVIF, Responsive Images, CDN Transforms

Serving unoptimized images is the single largest avoidable performance drain. Convert at ingest, generate responsive variants, and use CDN-level transforms for on-the-fly resizing.

**Red Flags:**
- Serving original JPEG/PNG without WebP/AVIF — 30-60% larger than necessary
- No responsive variants — mobile clients download desktop-sized images
- Resizing in the API on every request — repeated CPU work, no caching
- CDN not configured for image transforms — raw files served from origin on every request
- No `srcset` or `<picture>` element in frontend — browser always fetches largest image

**TypeScript — generate responsive WebP/AVIF variants at ingest:**
```typescript
import sharp from "sharp";

const RESPONSIVE_WIDTHS = [320, 640, 1024, 1920];

async function generateResponsiveImages(sourceBuffer: Buffer, baseKey: string) {
  const variants = [];
  for (const width of RESPONSIVE_WIDTHS) {
    for (const format of ["webp", "avif"] as const) {
      const key = `optimized/${baseKey}-${width}w.${format}`;
      const options = format === "avif" ? { quality: 70, effort: 5 } : { quality: 80 };
      const buf = await sharp(sourceBuffer)
        .resize(width, undefined, { withoutEnlargement: true, fit: "inside" })
        [format](options).toBuffer();
      const url = await uploadToS3(key, buf, { ContentType: `image/${format}` });
      variants.push({ key, width, format, url });
    }
  }
  return variants;
}

// CDN transform URL (Cloudflare Images / imgix)
function cdnImageUrl(key: string, { width, height, format = "auto" }: { width: number; height?: number; format?: string }): string {
  const params = new URLSearchParams({ w: String(width), fmt: format, q: "80", fit: "cover", ...(height ? { h: String(height) } : {}) });
  return `https://images.example.com/${key}?${params}`;
}
```

---

### 6. Storage Abstraction Layer — Provider-Agnostic Interface

Hardcoded S3 SDK calls spread through business logic make it impossible to run locally, switch providers, or test without cloud credentials.

**Red Flags:**
- `s3.PutObject(...)` called directly from service or controller layers
- Tests require real AWS credentials or localstack
- Switching from S3 to GCS requires changes in dozens of files
- No interface — the storage implementation is the only implementation

**TypeScript — storage interface + implementations:**
```typescript
export interface FileStorage {
  put(key: string, body: Buffer | ReadableStream, options?: PutOptions): Promise<string>;
  get(key: string): Promise<Buffer>;
  delete(key: string): Promise<void>;
  exists(key: string): Promise<boolean>;
  stat(key: string): Promise<StorageObject>;
  getDownloadUrl(key: string, expiresInSeconds?: number): Promise<string>;
  copy(sourceKey: string, destKey: string): Promise<void>;
}

export class S3Storage implements FileStorage {
  constructor(private readonly bucket: string, private readonly client: S3Client) {}
  async put(key: string, body: Buffer, options?: PutOptions): Promise<string> {
    await this.client.send(new PutObjectCommand({ Bucket: this.bucket, Key: key, Body: body, ContentType: options?.contentType }));
    return key;
  }
  async getDownloadUrl(key: string, expiresInSeconds = 3600): Promise<string> {
    return getSignedUrl(this.client, new GetObjectCommand({ Bucket: this.bucket, Key: key }), { expiresIn: expiresInSeconds });
  }
  // ... remaining methods
}

// In-memory implementation for tests — no cloud credentials needed
export class MemoryStorage implements FileStorage {
  private readonly store = new Map<string, { body: Buffer; options?: PutOptions }>();
  async put(key: string, body: Buffer, options?: PutOptions): Promise<string> {
    this.store.set(key, { body: Buffer.from(body), options }); return key;
  }
  async get(key: string): Promise<Buffer> {
    const entry = this.store.get(key);
    if (!entry) throw new Error(`Key not found: ${key}`);
    return Buffer.from(entry.body);
  }
  async exists(key: string): Promise<boolean> { return this.store.has(key); }
  // ... remaining methods
}
```

**Go — storage interface (all providers implement; business logic depends only on the interface):**
```go
type Storage interface {
    Put(ctx context.Context, key string, body io.Reader, opts PutOptions) error
    Get(ctx context.Context, key string) (io.ReadCloser, error)
    Delete(ctx context.Context, key string) error
    Exists(ctx context.Context, key string) (bool, error)
    DownloadURL(ctx context.Context, key string, ttl time.Duration) (string, error)
    Copy(ctx context.Context, src, dst string) error
}

type MediaService struct {
    storage Storage // S3Storage, GCSStorage, LocalStorage all implement Storage
    db      *sql.DB
}
```

Cross-reference: `dependency-injection-module-patterns` — Constructor injection: inject `Storage` interface, not concrete `S3Storage`.

---

### 7. Content-Addressable Storage and Hash-Based Deduplication

SHA-256 hash as storage key: identical content maps to the same key, deduplication is automatic. UUID keys waste space when users upload duplicate files.

**Red Flags:**
- UUID-keyed storage with no dedup — 1,000 users upload same stock photo → 1,000 copies
- Hash computed on the client — client can supply false hash to collide with another user's file
- Hash computed after upload — concurrent uploads of same file race before dedup check
- Content hash not stored in app DB — cannot query by content or verify integrity
- Missing per-user reference counting — deleting one user's file deletes shared content

**TypeScript — server-side SHA-256 content-addressable storage:**
```typescript
import { createHash } from "crypto";

async function storeWithDedup(fileBuffer: Buffer, contentType: string) {
  const sha256 = createHash("sha256").update(fileBuffer).digest("hex"); // always hash server-side
  const objectKey = `content/${sha256.substring(0, 2)}/${sha256}`;

  const exists = await storage.exists(objectKey);
  if (!exists) await storage.put(objectKey, fileBuffer, { contentType });

  return { sha256, objectKey, sizeBytes: fileBuffer.length, alreadyExisted: exists };
}

// Reference counting — safe multi-user dedup
// CREATE TABLE file_refs (sha256 TEXT, user_id UUID, created_at TIMESTAMPTZ);
async function deleteUserFile(userId: string, sha256: string): Promise<void> {
  const refCount = await db.deleteFileRef(userId, sha256);
  if (refCount === 0) {
    await storage.delete(`content/${sha256.substring(0, 2)}/${sha256}`);
  }
}
```

---

### 8. Upload Anti-Patterns

| Anti-Pattern | Why It Fails | Fix |
|-------------|-------------|-----|
| **base64 in JSON** | Inflates payload 33%; entire file held in memory; no streaming | Use multipart/form-data or presigned URL for direct-to-storage |
| **No size limits** | OOM crash; disk exhaustion; DoS vector | Set `Content-Length` limit at gateway; validate in app layer |
| **Sync media processing** | Blocks HTTP thread; times out on large files; cannot scale | Enqueue to message queue; return job ID; webhook on completion |
| **Storing blobs in DB** | Bloats DB size; no CDN integration; expensive queries | Store reference (key/URL) in DB; bytes in object storage |
| **Trusting client MIME type** | Trivially spoofed; polyglot files bypass extension checks | Validate magic bytes server-side |
| **UUID-only filenames** | Original filename lost; no dedup; no integrity check | Store original name in metadata; use SHA-256 content-addressable key |
| **Public bucket by default** | All uploaded files publicly accessible without auth | Default to private; generate short-lived presigned download URLs |
| **No upload expiry** | Presigned URLs usable indefinitely after compromise | Set 5-15 minute expiry on presigned upload URLs |

**base64 WRONG vs CORRECT:**
```typescript
// WRONG: 10 MB file becomes ~13.3 MB JSON; entire file held in memory
app.post("/upload", express.json({ limit: "50mb" }), async (req, res) => {
  const fileBytes = Buffer.from(req.body.fileBase64, "base64");
  await s3.putObject(fileBytes);
});

// CORRECT: API only issues the URL; client uploads bytes directly to S3
app.post("/upload/init", async (req, res) => {
  const { uploadUrl, objectKey } = await createUploadUrl(req.user.id, req.body.contentType);
  res.json({ uploadUrl, objectKey, expiresIn: 300 });
});
```

---

## Cross-References

- `security-patterns-code-review` — File Upload Security: SSRF via SVG, polyglot files, zip bombs, path traversal via filename
- `message-queue-patterns` — Async job queues for media processing workers; DLQ for failed transcoding jobs
- `caching-strategies` — CDN cache headers for processed images; cache-busting on content update
- `observability-patterns` — Instrument upload duration, processing queue depth, virus scan results, and dedup hit rate
- `error-handling-patterns` — Retry with backoff for failed S3 operations; dead letter queue for unprocessable media jobs
