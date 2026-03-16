---
name: search-indexing-patterns
description: Use when reviewing or designing search and indexing systems — covers Elasticsearch/OpenSearch mapping design, index lifecycle management, query patterns, aggregation patterns, pagination strategies, bulk indexing, PostgreSQL full-text search, and search anti-patterns with red flags and fix strategies across JSON, TypeScript, and SQL
---

# Search and Indexing Patterns for Code Review

## Overview

Poor mapping design causes mapping explosions, wrong query types bypass the index, unbounded aggregations exhaust heap, and deep pagination scans millions of documents. Use this guide when reviewing or designing any system that indexes or queries data — Elasticsearch, OpenSearch, or PostgreSQL full-text search.

**When to use:** Reviewing Elasticsearch/OpenSearch index mappings, query builders, aggregation pipelines, pagination code, bulk indexing pipelines, or PostgreSQL full-text search schemas.

## Quick Reference

| Pattern | Core Idea | Primary Red Flag |
|---------|-----------|-----------------|
| Explicit Mapping | Define field types upfront; disable dynamic mapping | `"dynamic": true` on unbounded fields; mapping explosion |
| Index Lifecycle / Aliases | Aliases as stable endpoints; reindex behind the alias | Querying the real index name; no alias on write path |
| Bool Query | `must/should/filter/must_not` compose queries safely | Mixing filters into `must`; no `filter` clause for exact matches |
| Boosting | `boost` or `function_score` tunes relevance | Static score multipliers that are never revisited |
| Aggregations | `terms`, `date_histogram`, `nested` aggregation patterns | Unbounded `terms` `size`; `size: 0` missing on agg-only queries |
| Pagination | `search_after` for deep pages; PIT for stable snapshots | `from + size > 10000`; scroll held open indefinitely |
| Bulk Indexing | `_bulk` API batches writes; tune `refresh_interval` | Per-document indexing in a loop; refresh after every doc |
| PostgreSQL FTS | `tsvector` + GIN index + `pg_trgm` for fuzzy | `LIKE '%term%'` instead of `@@`; no GIN index on tsvector column |

---

## Patterns in Detail

### 1. Mapping Design — Explicit vs Dynamic

Elasticsearch and OpenSearch infer field types on first document. Uncontrolled dynamic mapping creates thousands of fields, exhausts cluster state memory, and makes schema changes impossible without reindex.

**Red Flags:**
- `"dynamic": true` (or absent, which defaults to `true`) on an index that receives user-controlled field names
- `"type": "text"` on a field also used for sorting or aggregation (use `keyword` sub-field)
- No `"index": false` on large blobs that are stored but never queried
- Mapping explosion: field count grows with each unique user-supplied key

**Explicit mapping example (JSON):**
```json
{
  "settings": {
    "number_of_shards": 3,
    "number_of_replicas": 1,
    "refresh_interval": "30s"
  },
  "mappings": {
    "dynamic": "strict",
    "_source": { "enabled": true },
    "properties": {
      "id":          { "type": "keyword" },
      "title":       { "type": "text", "fields": { "keyword": { "type": "keyword", "ignore_above": 256 } } },
      "body":        { "type": "text", "index_options": "offsets" },
      "tags":        { "type": "keyword" },
      "created_at":  { "type": "date", "format": "strict_date_optional_time" },
      "view_count":  { "type": "integer" },
      "metadata":    { "type": "object", "dynamic": false, "enabled": false }
    }
  }
}
```

Key decisions:
- `"dynamic": "strict"` — rejects documents with unknown fields (fail-fast)
- `metadata` uses `"enabled": false` — stored in `_source` but not indexed, preventing field explosion from arbitrary user metadata
- `title` has a `keyword` sub-field for sorting/aggregation while remaining full-text searchable

**TypeScript — mapping bootstrap with type safety:**
```typescript
import { MappingProperty } from '@elastic/elasticsearch/lib/api/types';

const PRODUCT_MAPPING: Record<string, MappingProperty> = {
  id:         { type: 'keyword' },
  name:       { type: 'text', fields: { keyword: { type: 'keyword', ignore_above: 256 } } },
  price:      { type: 'scaled_float', scaling_factor: 100 },
  category:   { type: 'keyword' },
  updated_at: { type: 'date' },
};

async function ensureIndex(client: Client, indexName: string): Promise<void> {
  const exists = await client.indices.exists({ index: indexName });
  if (!exists) {
    await client.indices.create({
      index: indexName,
      body: {
        settings: { number_of_shards: 3, number_of_replicas: 1 },
        mappings: { dynamic: 'strict', properties: PRODUCT_MAPPING },
      },
    });
  }
}
```

---

### 2. Index Lifecycle Management — Aliases, Zero-Downtime Reindex, Rollover

Directly referencing an index name in application code makes schema changes and reindexing impossible without downtime. Aliases decouple the application from the physical index.

**Red Flags:**
- Application code referencing `products_v1` directly — hardcoded index name requires code deploy to switch
- No write alias — reindex cannot atomically cut over
- `forcemerge` or `close` called on a live write index
- No rollover policy on time-series indices — shards grow unbounded

**Alias + zero-downtime reindex pattern (TypeScript):**
```typescript
const READ_ALIAS  = 'products';
const WRITE_ALIAS = 'products_write';

async function reindexZeroDowntime(
  client: Client,
  oldIndex: string,
  newIndex: string,
): Promise<void> {
  // 1. Create the new index with updated mapping
  await client.indices.create({ index: newIndex, body: { mappings: { dynamic: 'strict', properties: PRODUCT_MAPPING } } });

  // 2. Reindex data from old to new (runs in background; old index still serves reads)
  await client.reindex({
    body: {
      source: { index: oldIndex },
      dest:   { index: newIndex, op_type: 'create' },
    },
    wait_for_completion: true,
    requests_per_second: 500, // throttle to avoid saturating cluster
  });

  // 3. Atomic alias swap — zero gap, zero overlap
  await client.indices.updateAliases({
    body: {
      actions: [
        { remove: { index: oldIndex, alias: READ_ALIAS } },
        { remove: { index: oldIndex, alias: WRITE_ALIAS } },
        { add:    { index: newIndex, alias: READ_ALIAS } },
        { add:    { index: newIndex, alias: WRITE_ALIAS, is_write_index: true } },
      ],
    },
  });

  // 4. Delete old index only after alias swap is confirmed
  await client.indices.delete({ index: oldIndex });
}
```

**ILM rollover policy (JSON) — for time-series logs:**
```json
{
  "policy": {
    "phases": {
      "hot":    { "actions": { "rollover": { "max_size": "50gb", "max_age": "30d" } } },
      "warm":   { "min_age": "30d", "actions": { "shrink": { "number_of_shards": 1 }, "forcemerge": { "max_num_segments": 1 } } },
      "delete": { "min_age": "90d", "actions": { "delete": {} } }
    }
  }
}
```

---

### 3. Search Query Patterns — Bool Queries, Boosting, Fuzzy, Filters vs Queries

Every query clause either contributes to the relevance score (`must`, `should`) or filters without scoring (`filter`, `must_not`). Filter clauses are cached; query clauses are not.

**Red Flags:**
- Exact-match conditions (status, category, date range) placed in `must` instead of `filter` — scores every doc, bypasses filter cache
- `wildcard` with a leading wildcard: `{ "wildcard": { "title": "*phone" } }` — full index scan
- `fuzzy` without `max_expansions` — can expand to thousands of terms
- `match_all` with a `sort` but no `filter` — scores and sorts the entire index

**Bool query with filter optimization (JSON):**
```json
{
  "query": {
    "bool": {
      "must": [
        { "multi_match": { "query": "noise cancelling", "fields": ["title^3", "description", "tags^2"], "type": "best_fields" } }
      ],
      "filter": [
        { "term":  { "status":   "active" } },
        { "term":  { "category": "headphones" } },
        { "range": { "price":    { "gte": 50, "lte": 500 } } }
      ],
      "must_not": [
        { "term": { "is_deleted": true } }
      ]
    }
  }
}
```

**TypeScript — type-safe query builder:**
```typescript
interface SearchFilters {
  category?: string;
  status?:   string;
  priceMin?: number;
  priceMax?: number;
}

function buildProductQuery(q: string, filters: SearchFilters) {
  const filterClauses = [];
  if (filters.category) filterClauses.push({ term: { category: filters.category } });
  if (filters.status)   filterClauses.push({ term: { status:   filters.status   } });
  if (filters.priceMin !== undefined || filters.priceMax !== undefined) {
    filterClauses.push({ range: { price: { gte: filters.priceMin, lte: filters.priceMax } } });
  }

  return {
    query: {
      bool: {
        must:   [{ multi_match: { query: q, fields: ['name^3', 'description'], fuzziness: 'AUTO', max_expansions: 50 } }],
        filter: filterClauses,
      },
    },
  };
}
```

**Boosting with `function_score` (JSON):**
```json
{
  "query": {
    "function_score": {
      "query": { "match": { "title": "headphones" } },
      "functions": [
        { "filter": { "term": { "is_sponsored": true } }, "weight": 2.0 },
        { "field_value_factor": { "field": "rating", "factor": 1.2, "missing": 1.0, "modifier": "log1p" } }
      ],
      "score_mode": "sum",
      "boost_mode": "multiply"
    }
  }
}
```

---

### 4. Aggregation Patterns — Terms, Date Histogram, OOM Risk

Aggregations run in-memory on the coordinating node. Unbounded `terms` aggregations or high-cardinality fields can exhaust heap.

**Red Flags:**
- `terms` aggregation with `size: 0` (Elasticsearch 1.x default) — returns all buckets, OOM risk on high-cardinality fields
- `terms` on a `text` field instead of its `.keyword` sub-field — uses fielddata heap, triggers deprecation warning
- `date_histogram` on a `text` or `keyword` field instead of `date`
- Nested aggregation inside `terms` on a high-cardinality field — multiplicative memory usage
- Running aggregation-only queries without `"size": 0` — fetches hits AND runs agg, double the work

**Safe aggregation (JSON):**
```json
{
  "size": 0,
  "query": {
    "bool": {
      "filter": [
        { "range": { "created_at": { "gte": "now-30d/d", "lte": "now/d" } } }
      ]
    }
  },
  "aggs": {
    "by_category": {
      "terms": {
        "field": "category",
        "size": 20,
        "order": { "_count": "desc" },
        "shard_size": 100
      },
      "aggs": {
        "avg_price": { "avg": { "field": "price" } }
      }
    },
    "orders_over_time": {
      "date_histogram": {
        "field":              "created_at",
        "calendar_interval":  "day",
        "min_doc_count":      1,
        "extended_bounds": { "min": "now-30d/d", "max": "now/d" }
      }
    }
  }
}
```

Key decisions:
- `"size": 0` on the top query — no hits returned, only aggregation results
- `terms.size: 20` — bounded bucket count
- `shard_size: 100` — larger per-shard sample improves accuracy of top-N without returning all buckets

**TypeScript — aggregation result typing:**
```typescript
interface CategoryBucket { key: string; doc_count: number; avg_price: { value: number | null } }
interface AggResult {
  by_category:     { buckets: CategoryBucket[] };
  orders_over_time: { buckets: Array<{ key_as_string: string; doc_count: number }> };
}

const { aggregations } = await client.search<never, AggResult>({
  index: READ_ALIAS,
  body: buildAggQuery(filters),
});
const topCategories = aggregations?.by_category.buckets ?? [];
```

---

### 5. Pagination — from+size Limits, search_after, Scroll / PIT

Elasticsearch limits `from + size` to 10,000 by default (`index.max_result_window`). Deep pagination with `from` scans and discards millions of documents.

**Red Flags:**
- `from + size > 10000` — hits `index.max_result_window` limit, throws 400
- `"from": 0, "size": 10000` to export all documents — use scroll or PIT instead
- Scroll context held open for hours — uses significant heap per open context
- No `sort` on `search_after` — results are non-deterministic across pages

**from+size (acceptable for shallow pages only):**
```typescript
function shallowPage(page: number, pageSize: number) {
  if ((page - 1) * pageSize + pageSize > 10_000) {
    throw new RangeError('Page too deep — use search_after for deep pagination');
  }
  return { from: (page - 1) * pageSize, size: pageSize };
}
```

**search_after with PIT (correct deep pagination):**
```typescript
interface SearchPage<T> { hits: T[]; nextCursor: unknown[] | null }

async function fetchPage<T>(
  client: Client,
  pitId: string,
  sort: unknown[],
  searchAfter?: unknown[],
  pageSize = 20,
): Promise<SearchPage<T>> {
  const body: Record<string, unknown> = {
    size: pageSize,
    sort,
    pit:  { id: pitId, keep_alive: '1m' },
    track_total_hits: false,
  };
  if (searchAfter) body.search_after = searchAfter;

  const res = await client.search<T>({ body });
  const hits = res.hits.hits;
  const lastHit = hits[hits.length - 1];
  return {
    hits:       hits.map(h => h._source as T),
    nextCursor: hits.length === pageSize && lastHit?.sort ? lastHit.sort : null,
  };
}

// Caller creates PIT once and passes cursor across requests
async function openPit(client: Client): Promise<string> {
  const { id } = await client.openPointInTime({ index: READ_ALIAS, keep_alive: '1m' });
  return id;
}
async function closePit(client: Client, pitId: string): Promise<void> {
  await client.closePointInTime({ body: { id: pitId } });
}
```

**Scroll for bulk export (not for real-time pagination):**
```typescript
async function* scrollAll<T>(client: Client, query: unknown): AsyncGenerator<T[]> {
  let res = await client.search<T>({ index: READ_ALIAS, scroll: '2m', size: 500, body: query });
  while (res.hits.hits.length > 0) {
    yield res.hits.hits.map(h => h._source as T);
    res = await client.scroll<T>({ scroll_id: res._scroll_id, scroll: '2m' });
  }
  if (res._scroll_id) {
    await client.clearScroll({ body: { scroll_id: res._scroll_id } });
  }
}
```

---

### 6. Bulk Indexing vs Single-Document Write Optimization

The `_bulk` API amortizes per-request overhead across many operations. Indexing documents one at a time in a loop is the single most common performance problem in ingestion pipelines.

**Red Flags:**
- `client.index(...)` inside a `for` loop — N round trips for N documents
- `refresh: 'true'` on every document — forces a Lucene commit after each write, kills throughput
- Bulk batch size set by document count alone — should be tuned by payload size (5–15 MB per batch is typical)
- No error check on bulk response — partial failures are 200 OK with per-action errors in `items`

**Bulk indexing with error handling (TypeScript):**
```typescript
const BULK_BATCH_BYTES = 10 * 1024 * 1024; // 10 MB per batch

async function bulkIndex<T extends { id: string }>(
  client: Client,
  index: string,
  documents: T[],
): Promise<{ indexed: number; failed: number }> {
  let indexed = 0;
  let failed  = 0;
  let batch: unknown[] = [];
  let batchBytes = 0;

  const flush = async () => {
    if (batch.length === 0) return;
    const res = await client.bulk({ body: batch, refresh: false });
    for (const item of res.items) {
      const op = item.index ?? item.create ?? item.update ?? item.delete;
      if (op?.error) { failed++; console.error('Bulk item error', op.error); }
      else indexed++;
    }
    batch = [];
    batchBytes = 0;
  };

  for (const doc of documents) {
    const action = JSON.stringify({ index: { _index: index, _id: doc.id } });
    const source = JSON.stringify(doc);
    const rowBytes = action.length + source.length + 2; // +2 for newlines
    if (batchBytes + rowBytes > BULK_BATCH_BYTES) await flush();
    batch.push({ index: { _index: index, _id: doc.id } }, doc);
    batchBytes += rowBytes;
  }
  await flush();

  // Force one refresh at the end rather than per-document
  await client.indices.refresh({ index });
  return { indexed, failed };
}
```

**Settings to tune during bulk load (JSON):**
```json
{
  "index": {
    "refresh_interval": "-1",
    "number_of_replicas": "0"
  }
}
```
Restore after bulk load:
```json
{
  "index": {
    "refresh_interval": "30s",
    "number_of_replicas": "1"
  }
}
```

---

### 7. PostgreSQL Full-Text Search — tsvector, GIN, pg_trgm

PostgreSQL has a capable full-text search engine built in. `LIKE '%term%'` bypasses all indexes and performs a full table scan.

**Red Flags:**
- `WHERE body LIKE '%search%'` on a large table — sequential scan, no index
- `tsvector` column not indexed with GIN — `@@` operator falls back to sequential scan
- `to_tsvector` called inline in `WHERE` clause — recomputed for every row, not using the stored column
- `pg_trgm` extension not installed before using `%` similarity operator
- `setweight` not used — all fields have equal relevance weight

**Schema with tsvector + GIN index (SQL):**
```sql
-- Enable pg_trgm for fuzzy/trigram search
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TABLE products (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT        NOT NULL,
  description TEXT,
  tags        TEXT[],
  status      TEXT        NOT NULL DEFAULT 'active',
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- Stored tsvector for efficient FTS
  search_vector TSVECTOR
    GENERATED ALWAYS AS (
      setweight(to_tsvector('english', coalesce(name, '')),        'A') ||
      setweight(to_tsvector('english', coalesce(description, '')), 'B') ||
      setweight(to_tsvector('english', array_to_string(tags, ' ')), 'C')
    ) STORED
);

-- GIN index for FTS
CREATE INDEX products_search_gin ON products USING GIN (search_vector);

-- GIN index for trigram fuzzy search
CREATE INDEX products_name_trgm ON products USING GIN (name gin_trgm_ops);
```

**Query patterns (SQL):**
```sql
-- Full-text search using stored tsvector (uses GIN index)
SELECT id, name, ts_rank(search_vector, query) AS rank
FROM products, to_tsquery('english', 'noise & cancelling') query
WHERE search_vector @@ query
  AND status = 'active'
ORDER BY rank DESC
LIMIT 20;

-- Phrase search
SELECT id, name
FROM products
WHERE search_vector @@ phraseto_tsquery('english', 'noise cancelling headphones');

-- Fuzzy trigram search (pg_trgm) — catches typos
SELECT id, name, similarity(name, 'headfones') AS sim
FROM products
WHERE name % 'headfones'    -- uses gin_trgm_ops index
ORDER BY sim DESC
LIMIT 10;

-- Highlight matching terms in result
SELECT id, name,
  ts_headline('english', description, to_tsquery('english', 'noise & cancelling'),
    'MaxFragments=2, MinWords=10, MaxWords=20') AS snippet
FROM products
WHERE search_vector @@ to_tsquery('english', 'noise & cancelling');
```

**TypeScript — parameterized FTS query:**
```typescript
async function searchProducts(db: Pool, rawQuery: string, limit = 20): Promise<Product[]> {
  // Convert user input to a safe tsquery (websearch_to_tsquery handles operators naturally)
  const { rows } = await db.query<Product>(
    `SELECT id, name, description,
            ts_rank(search_vector, query) AS rank
     FROM products, websearch_to_tsquery('english', $1) query
     WHERE search_vector @@ query
       AND status = 'active'
     ORDER BY rank DESC
     LIMIT $2`,
    [rawQuery, limit],
  );
  return rows;
}
```

Cross-reference: `database-review-patterns` — Index design and query plan analysis.

---

## Search Anti-Patterns

| Anti-Pattern | Description | Fix |
|-------------|-------------|-----|
| **Mapping Explosion** | Dynamic mapping on user-supplied keys; field count grows unbounded | Set `"dynamic": "strict"`; use `"enabled": false` for free-form metadata objects |
| **Deep Pagination with from+size** | `from: 9980, size: 20` scans 10,000 docs to return 20 | Use `search_after` with a PIT for pages beyond page ~10 |
| **Leading Wildcard** | `{ "wildcard": { "name": "*phone" } }` — full shard scan | Use `edge_ngram` tokenizer at index time or a `match` query |
| **No Alias on Write Path** | App writes directly to `products_v1`; reindex requires downtime | Always write and read through aliases; alias swap is atomic |
| **Unbounded Terms Aggregation** | `"terms": { "field": "user_id", "size": 0 }` — all buckets in memory | Set a reasonable `size`; for exact counts use `cardinality` agg |
| **Scroll for Pagination** | Scroll kept open per user session — heap leak under concurrent load | Use `search_after` + PIT for user-facing pagination; scroll only for batch export |
| **Per-Document Refresh** | `client.index(..., refresh: 'true')` in a loop | Batch with `_bulk`, set `refresh_interval: -1` during load, then restore |
| **Text Field Aggregation** | `terms` agg on a `text` field — loads fielddata into heap | Aggregate on the `.keyword` sub-field; avoid `fielddata: true` on `text` |
| **LIKE with Leading %** | `WHERE name LIKE '%term%'` in PostgreSQL — seq scan | Use `tsvector @@ tsquery` with a GIN index or `pg_trgm` with trigram index |
| **Inline to_tsvector in WHERE** | `WHERE to_tsvector('english', name) @@ query` — recomputed per row | Store a `GENERATED ALWAYS AS` `tsvector` column and index it |

---

## Cross-References

- `database-review-patterns` — Index design, query plans (`EXPLAIN ANALYZE`), and N+1 query detection
- `performance-anti-patterns` — N+1 queries, missing indexes, and database hotspot patterns
- `caching-strategies` — Cache search results at the query level to reduce Elasticsearch load; cache PIT cursors for pagination sessions
- `data-pipeline-patterns` — Bulk ingest pipelines, backpressure, and dead-letter patterns for failed index operations
- `api-rate-limiting-throttling` — Rate-limit search endpoints; aggregation-heavy queries are expensive
