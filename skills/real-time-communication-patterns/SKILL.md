---
name: real-time-communication-patterns
description: Use when designing or reviewing real-time communication — covers WebSocket lifecycle, Server-Sent Events, long polling, protocol selection, connection manager, horizontal scaling with Redis Pub/Sub, auth at upgrade, backpressure, and real-time anti-patterns with TypeScript and Go examples
---

# Real-Time Communication Patterns

## Overview

Real-time communication introduces connection lifecycle complexity, horizontal scaling challenges, and security risks that request/response APIs avoid entirely. A single unbounded connection pool, missing heartbeat, or JWT exposed in a query string can bring down production systems.

**When to use:** Designing live dashboards, chat, collaborative editing, notifications, streaming APIs, IoT device feeds, or any feature where the server must push data to clients unprompted.

## Quick Reference

| Protocol | Direction | Reconnect | Scaling | Best For |
|----------|-----------|-----------|---------|----------|
| WebSocket | Full-duplex | Manual | Redis Pub/Sub or sticky sessions | Chat, games, collaborative editing |
| Server-Sent Events (SSE) | Server → client | Auto (EventSource) | Standard HTTP load balancer | Notifications, live feeds, dashboards |
| Long Polling | Server → client | Per-request | Standard HTTP load balancer | Legacy clients, firewall-constrained envs |
| gRPC Streaming | Full-duplex | Manual | L7 load balancer (Envoy) | Microservice-to-microservice real-time |

---

## Patterns in Detail

### 1. WebSocket Lifecycle

A WebSocket connection passes through distinct phases: HTTP upgrade handshake, open/connected, heartbeat keep-alive, graceful close, and reconnection with backoff.

**Red Flags:**
- No heartbeat — idle connections silently dropped by load balancers or NAT devices
- No reconnection logic — network blips kill the session permanently
- Sending frames after close — race condition on the write path
- Missing `onclose` / `onerror` handlers — uncaught errors crash the page or goroutine

**TypeScript — client lifecycle with reconnect:**
```typescript
interface WsOptions {
  url: string;
  heartbeatIntervalMs?: number;
  maxReconnectDelayMs?: number;
  onMessage: (data: unknown) => void;
}

class ManagedWebSocket {
  private ws: WebSocket | null = null;
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  private reconnectDelay = 1_000;

  constructor(private readonly opts: WsOptions) {
    this.connect();
  }

  private connect(): void {
    this.ws = new WebSocket(this.opts.url);

    this.ws.onopen = () => {
      this.reconnectDelay = 1_000; // reset on successful connect
      this.startHeartbeat();
    };

    this.ws.onmessage = (event) => {
      const msg = JSON.parse(event.data as string) as { type: string; payload: unknown };
      if (msg.type === 'pong') return; // heartbeat response — ignore
      this.opts.onMessage(msg.payload);
    };

    this.ws.onclose = (event) => {
      this.stopHeartbeat();
      if (!event.wasClean) this.scheduleReconnect();
    };

    this.ws.onerror = (err) => {
      console.error('[WS] error', err);
      this.ws?.close();
    };
  }

  private startHeartbeat(): void {
    const interval = this.opts.heartbeatIntervalMs ?? 25_000;
    this.heartbeatTimer = setInterval(() => {
      if (this.ws?.readyState === WebSocket.OPEN) {
        this.ws.send(JSON.stringify({ type: 'ping' }));
      }
    }, interval);
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer) clearInterval(this.heartbeatTimer);
    this.heartbeatTimer = null;
  }

  private scheduleReconnect(): void {
    const maxDelay = this.opts.maxReconnectDelayMs ?? 30_000;
    const jitter = Math.random() * 1_000;
    const delay = Math.min(this.reconnectDelay + jitter, maxDelay);
    this.reconnectDelay = Math.min(this.reconnectDelay * 2, maxDelay);
    setTimeout(() => this.connect(), delay);
  }

  send(payload: unknown): void {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(payload));
    }
  }

  close(): void {
    this.stopHeartbeat();
    this.ws?.close(1000, 'Client closing gracefully');
  }
}
```

**Go — server-side ping/pong with gorilla/websocket:**
```go
import (
    "time"
    "github.com/gorilla/websocket"
)

const (
    writeWait      = 10 * time.Second
    pongWait       = 60 * time.Second
    pingInterval   = (pongWait * 9) / 10
    maxMessageSize = 512 * 1024 // 512 KB
)

func handleConn(conn *websocket.Conn, outbound <-chan []byte) {
    conn.SetReadLimit(maxMessageSize)
    conn.SetReadDeadline(time.Now().Add(pongWait))
    conn.SetPongHandler(func(string) error {
        conn.SetReadDeadline(time.Now().Add(pongWait))
        return nil
    })

    // heartbeat writer
    go func() {
        ticker := time.NewTicker(pingInterval)
        defer ticker.Stop()
        for range ticker.C {
            conn.SetWriteDeadline(time.Now().Add(writeWait))
            if err := conn.WriteMessage(websocket.PingMessage, nil); err != nil {
                return
            }
        }
    }()

    // outbound message writer
    for msg := range outbound {
        conn.SetWriteDeadline(time.Now().Add(writeWait))
        if err := conn.WriteMessage(websocket.TextMessage, msg); err != nil {
            return
        }
    }
}
```

---

### 2. Server-Sent Events (SSE)

SSE uses a plain HTTP response with `Content-Type: text/event-stream`. The browser `EventSource` API handles auto-reconnect and Last-Event-ID resumption natively — no client-side reconnect code required.

**Red Flags:**
- No `Last-Event-ID` header processing — client replays all events from scratch on reconnect
- Missing `event:` field — all messages funnel into the generic `message` event
- No `retry:` field — browser uses its own default (often 3 s) which may be too aggressive
- Buffering middleware (gzip, proxy) compressing the stream — breaks chunked delivery

**TypeScript — Express SSE endpoint:**
```typescript
import { Request, Response } from 'express';
import { EventEmitter } from 'events';

const bus = new EventEmitter();

export function sseHandler(req: Request, res: Response): void {
  const lastId = req.headers['last-event-id'];

  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    'X-Accel-Buffering': 'no', // disable nginx buffering
    Connection: 'keep-alive',
  });

  // send retry hint and any missed events
  res.write(`retry: 5000\n\n`);
  if (lastId) replayMissedEvents(lastId, res);

  const listener = (event: { id: string; type: string; data: unknown }) => {
    res.write(`id: ${event.id}\n`);
    res.write(`event: ${event.type}\n`);
    res.write(`data: ${JSON.stringify(event.data)}\n\n`);
  };

  bus.on('event', listener);
  req.on('close', () => bus.off('event', listener));
}

function replayMissedEvents(afterId: string, res: Response): void {
  // fetch from durable store and stream missed events before live ones
}
```

**Go — net/http SSE endpoint:**
```go
func sseHandler(w http.ResponseWriter, r *http.Request) {
    flusher, ok := w.(http.Flusher)
    if !ok {
        http.Error(w, "SSE not supported", http.StatusInternalServerError)
        return
    }

    w.Header().Set("Content-Type", "text/event-stream")
    w.Header().Set("Cache-Control", "no-cache")
    w.Header().Set("X-Accel-Buffering", "no")

    lastID := r.Header.Get("Last-Event-ID")
    _ = lastID // replay logic goes here

    fmt.Fprintf(w, "retry: 5000\n\n")
    flusher.Flush()

    for {
        select {
        case <-r.Context().Done():
            return
        case event := <-eventsChan():
            fmt.Fprintf(w, "id: %s\nevent: %s\ndata: %s\n\n",
                event.ID, event.Type, event.JSON())
            flusher.Flush()
        }
    }
}
```

---

### 3. Long Polling

Long polling holds the HTTP connection open until an event arrives or a server-side timeout fires. The client immediately re-issues the request after a response. No special browser API is needed, making it compatible with any HTTP client.

**Red Flags:**
- Thundering herd — all clients reconnect simultaneously after a broadcast, overwhelming the server
- Timeout too short — constant empty responses with no events waste server threads
- No `Last-Event-ID` equivalent — duplicate delivery or gaps on reconnect
- Blocking threads without async I/O — one goroutine/thread per waiting client does not scale

**TypeScript — hold-until-event pattern with jittered reconnect:**
```typescript
async function longPoll(endpoint: string, lastSeq: number): Promise<void> {
  while (true) {
    try {
      const res = await fetch(`${endpoint}?after=${lastSeq}`, {
        signal: AbortSignal.timeout(35_000), // server timeout is 30 s
      });
      if (res.status === 204) {
        // timeout with no event — reconnect immediately
        continue;
      }
      const events = await res.json() as Array<{ seq: number; payload: unknown }>;
      for (const ev of events) {
        processEvent(ev.payload);
        lastSeq = ev.seq;
      }
    } catch (err) {
      const jitter = Math.random() * 2_000;
      await new Promise(r => setTimeout(r, 2_000 + jitter));
    }
  }
}
```

**Go — server hold-until-event with context cancellation:**
```go
func longPollHandler(w http.ResponseWriter, r *http.Request) {
    afterSeq, _ := strconv.ParseInt(r.URL.Query().Get("after"), 10, 64)

    ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
    defer cancel()

    events, err := store.WaitForEvents(ctx, afterSeq)
    if err != nil || len(events) == 0 {
        w.WriteHeader(http.StatusNoContent)
        return
    }

    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(events)
}
```

**Thundering herd mitigation — randomized reconnect delay:**
```typescript
// After server restart or broadcast, add per-client jitter
const baseDelay = 500;
const jitter = Math.floor(Math.random() * 4_500); // 0–4.5 s spread
await new Promise(r => setTimeout(r, baseDelay + jitter));
```

---

### 4. Protocol Selection Decision Matrix

| Criterion | WebSocket | SSE | Long Polling | gRPC Streaming |
|-----------|-----------|-----|--------------|----------------|
| Client sends frequently | Yes | No | No | Yes |
| Standard HTTP load balancer | No (requires sticky or L7) | Yes | Yes | No (HTTP/2 required) |
| Browser native support | Yes | Yes | Yes | No (grpc-web) |
| Auto-reconnect built in | No | Yes | Partial | No |
| Binary frames | Yes | No (base64) | No | Yes (protobuf) |
| Firewall/proxy friendly | Sometimes | Yes | Yes | Sometimes |
| Server pushes rarely | Overkill | Good fit | Good fit | Overkill |
| Bidirectional required | Yes | No | No | Yes |

**Decision rules:**
1. If browser client + server-push only → prefer **SSE** (simpler, auto-reconnect, standard LB)
2. If bidirectional or high-frequency client messages → use **WebSocket**
3. If legacy environment, mobile proxy restrictions, or simple notification → use **long polling**
4. If service-to-service streaming with binary payloads → use **gRPC bidirectional streaming**

---

### 5. Connection Manager Pattern

A connection manager maintains a per-user (or per-room/channel) registry of active connections, handles fan-out delivery, and enforces connection limits.

**Red Flags:**
- Global map without mutex — concurrent map writes panic in Go
- No per-user connection limit — one user opens thousands of tabs and exhausts file descriptors
- Fan-out blocks on slow clients — one unresponsive connection delays all others
- No cleanup on disconnect — dead connections accumulate in the registry

**TypeScript — room-based connection manager:**
```typescript
type ConnectionId = string;

interface Connection {
  id: ConnectionId;
  userId: string;
  send: (data: string) => void;
}

class ConnectionManager {
  // room → set of connection IDs
  private rooms = new Map<string, Set<ConnectionId>>();
  // connection ID → connection
  private connections = new Map<ConnectionId, Connection>();
  private readonly maxPerUser: number;

  constructor(maxPerUser = 5) {
    this.maxPerUser = maxPerUser;
  }

  register(conn: Connection): void {
    const userConnCount = [...this.connections.values()]
      .filter(c => c.userId === conn.userId).length;
    if (userConnCount >= this.maxPerUser) {
      throw new Error(`Connection limit reached for user ${conn.userId}`);
    }
    this.connections.set(conn.id, conn);
  }

  unregister(connId: ConnectionId): void {
    this.connections.delete(connId);
    for (const members of this.rooms.values()) members.delete(connId);
  }

  join(connId: ConnectionId, room: string): void {
    if (!this.rooms.has(room)) this.rooms.set(room, new Set());
    this.rooms.get(room)!.add(connId);
  }

  leave(connId: ConnectionId, room: string): void {
    this.rooms.get(room)?.delete(connId);
  }

  // fan-out: deliver to all room members concurrently, skip slow/dead connections
  fanOut(room: string, data: string): void {
    const members = this.rooms.get(room);
    if (!members) return;
    for (const connId of members) {
      const conn = this.connections.get(connId);
      if (!conn) { members.delete(connId); continue; }
      try { conn.send(data); }
      catch (err) { console.warn('[CM] send failed, removing', connId, err); this.unregister(connId); }
    }
  }
}
```

**Go — concurrent-safe connection hub:**
```go
type Hub struct {
    mu      sync.RWMutex
    rooms   map[string]map[string]*Conn // room → connID → Conn
    conns   map[string]*Conn            // connID → Conn
}

func NewHub() *Hub {
    return &Hub{
        rooms: make(map[string]map[string]*Conn),
        conns: make(map[string]*Conn),
    }
}

func (h *Hub) Register(conn *Conn) {
    h.mu.Lock()
    defer h.mu.Unlock()
    h.conns[conn.ID] = conn
}

func (h *Hub) Unregister(connID string) {
    h.mu.Lock()
    defer h.mu.Unlock()
    delete(h.conns, connID)
    for _, members := range h.rooms {
        delete(members, connID)
    }
}

func (h *Hub) FanOut(room string, data []byte) {
    h.mu.RLock()
    members := h.rooms[room]
    h.mu.RUnlock()

    for _, conn := range members {
        select {
        case conn.Send <- data:
        default:
            // bounded channel full — drop or disconnect slow client
        }
    }
}
```

---

### 6. Horizontal Scaling with Redis Pub/Sub

A single WebSocket or SSE server holds connections in local memory. When scaled horizontally, a message published to server A must reach clients connected to server B. Redis Pub/Sub bridges the gap.

**Red Flags:**
- Publishing directly to connection objects across servers — only works on a single instance
- No channel namespace — all servers receive all messages regardless of relevance
- Redis Pub/Sub with very high fan-out (millions of subscribers) — use Redis Streams or a broker instead
- Sticky sessions as the only scaling strategy — single-node failures disconnect all stuck clients

**TypeScript — Redis adapter for fan-out:**
```typescript
import { createClient } from 'redis';

const publisher = createClient({ url: process.env.REDIS_URL });
const subscriber = publisher.duplicate();

await publisher.connect();
await subscriber.connect();

// This server subscribes to events for rooms whose clients it holds
async function subscribeToRoom(room: string, manager: ConnectionManager): Promise<void> {
  await subscriber.subscribe(`room:${room}`, (message) => {
    manager.fanOut(room, message);
  });
}

// Any server instance can publish; Redis broadcasts to all subscribers
async function publishToRoom(room: string, data: unknown): Promise<void> {
  await publisher.publish(`room:${room}`, JSON.stringify(data));
}
```

**Go — Redis Pub/Sub bridge:**
```go
func startRedisBridge(rdb *redis.Client, hub *Hub, room string) {
    pubsub := rdb.Subscribe(context.Background(), "room:"+room)
    ch := pubsub.Channel()
    go func() {
        for msg := range ch {
            hub.FanOut(room, []byte(msg.Payload))
        }
    }()
}
```

**Sticky sessions — when Redis is overkill:**
- Configure the load balancer to hash by `session cookie` or `user ID` so one user always lands on the same pod.
- Acceptable for small deployments; increases blast radius on pod restarts.
- Combine with a Redis adapter for graceful draining: before a pod shuts down, migrate connections to peers.

---

### 7. Auth at Upgrade

WebSocket and SSE connections are established over HTTP, which means standard auth middleware runs exactly once at upgrade/connection time. After that, the long-lived connection is not re-authenticated on every message.

**Red Flags:**
- JWT in query string (`ws://host/chat?token=eyJ...`) — tokens appear in server logs, proxy logs, and browser history
- No expiry check at upgrade — a revoked or expired token keeps its connection alive indefinitely
- Cookie-based auth skipped on the upgrade request — missing `credentials: 'include'` on the client
- No re-auth for long-lived connections — a 24-hour connection carries a 1-hour token with no renewal

**Short-lived ticket pattern (preferred over query param JWT):**
```typescript
// Step 1: client calls a REST endpoint while authenticated to get a one-time ticket
const { ticket } = await fetch('/api/ws-ticket', { method: 'POST' }).then(r => r.json());

// Step 2: use the ticket (not the JWT) in the WebSocket URL — it is short-lived and single-use
const ws = new WebSocket(`wss://host/ws?ticket=${ticket}`);
```

**Go — server-side ticket validation at upgrade:**
```go
var upgrader = websocket.Upgrader{
    CheckOrigin: func(r *http.Request) bool {
        return isAllowedOrigin(r.Header.Get("Origin"))
    },
}

func wsHandler(w http.ResponseWriter, r *http.Request) {
    ticket := r.URL.Query().Get("ticket")
    userID, err := ticketStore.Consume(ticket) // single-use, TTL 30 s
    if err != nil {
        http.Error(w, "Unauthorized", http.StatusUnauthorized)
        return
    }

    conn, err := upgrader.Upgrade(w, r, nil)
    if err != nil {
        return
    }
    defer conn.Close()

    handleConn(conn, userID)
}
```

**Token refresh for long-lived connections:**
```typescript
// Client sends a refresh message before the JWT expires
setInterval(async () => {
  const newToken = await refreshAccessToken();
  ws.send(JSON.stringify({ type: 'auth-refresh', token: newToken }));
}, TOKEN_TTL_MS * 0.8);
```

---

### 8. Backpressure and Flow Control

A fast producer with a slow consumer causes unbounded buffer growth, out-of-memory crashes, or stale data delivery. Backpressure strategies prevent the buffer from growing unchecked.

**Red Flags:**
- Unbounded write buffer — server accumulates millions of unsent messages for a slow client
- No drop strategy — memory grows until the process is OOM-killed
- Blocking fan-out on a slow client — one slow consumer delays all others in the room
- No client acknowledgment for critical messages — no way to detect or recover from drops

**Strategies:**

| Strategy | When to Use | Trade-off |
|----------|-------------|-----------|
| Bounded buffer + drop-oldest | Live telemetry, dashboards | Latest data is kept; historical gaps are acceptable |
| Bounded buffer + drop-newest | Order books, audit trails | No overwrite; client must slow down or disconnect |
| Client acknowledgment | Payment events, critical notifications | Reliable delivery; adds latency and complexity |
| Disconnect slow client | Commodity data streams | Simple; forces client reconnect and re-sync |

**Go — bounded channel with drop-oldest:**
```go
type BoundedSender struct {
    ch chan []byte
}

func NewBoundedSender(capacity int) *BoundedSender {
    return &BoundedSender{ch: make(chan []byte, capacity)}
}

func (s *BoundedSender) Send(data []byte) {
    select {
    case s.ch <- data:
        // sent successfully
    default:
        // buffer full — drop oldest to make room for newest
        select {
        case <-s.ch:
        default:
        }
        s.ch <- data
    }
}
```

**TypeScript — client acknowledgment for critical events:**
```typescript
class AckTracker {
  private pending = new Map<string, { payload: unknown; timer: ReturnType<typeof setTimeout> }>();

  track(id: string, payload: unknown, ws: WebSocket, timeoutMs = 5_000): void {
    const timer = setTimeout(() => {
      console.warn('[AckTracker] no ack for', id, '— retrying');
      ws.send(JSON.stringify({ id, payload }));
    }, timeoutMs);
    this.pending.set(id, { payload, timer });
  }

  acknowledge(id: string): void {
    const entry = this.pending.get(id);
    if (entry) { clearTimeout(entry.timer); this.pending.delete(id); }
  }
}
```

---

### 9. Real-Time Anti-Patterns

| Anti-Pattern | Description | Fix |
|-------------|-------------|-----|
| **No heartbeat** | Idle connections silently dropped by proxies after 60–90 s | Send ping every 25–30 s; reset read deadline on pong |
| **Unbounded connections** | No per-user or total connection cap — file descriptor exhaustion | Enforce `maxPerUser` in connection manager; set OS `ulimit` |
| **Auth in query string** | JWT visible in logs, proxy traces, browser history | Use short-lived ticket pattern or `Authorization` header (SSE) |
| **Synchronous fan-out** | Delivering to N clients in a loop — one slow client blocks all others | Use non-blocking sends; skip or disconnect slow clients |
| **No reconnect jitter** | All clients reconnect simultaneously after outage — thundering herd | Add random jitter (0–N seconds) to reconnect delay |
| **Missing Last-Event-ID** | SSE client loses events during reconnect gap | Store events with sequence ID; replay on reconnect |
| **Single-server connection state** | Works on one instance; breaks when horizontally scaled | Introduce Redis Pub/Sub adapter or sticky session + drain |
| **Long-lived token in connection** | Revoked token keeps connection open until the socket closes | Validate token on a schedule or handle server-sent `auth-expired` event |
| **Blocking read goroutine writes** | Writing to a closed channel or WebSocket from multiple goroutines | Use a single dedicated writer goroutine per connection |

---

## Cross-References

- `message-queue-patterns` — Dead Letter Queue, bounded producer-consumer, and at-least-once delivery for durable event streams behind real-time connections
- `auth-authz-patterns` — JWT validation, token refresh flows, and short-lived ticket issuance referenced in Auth at Upgrade section
- `observability-patterns` — Connection count metrics, fan-out latency histograms, and alerting on DLQ depth or disconnect rate spikes
