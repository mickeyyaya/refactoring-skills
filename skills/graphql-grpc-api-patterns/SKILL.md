---
name: graphql-grpc-api-patterns
description: Use when reviewing or designing GraphQL and gRPC APIs — covers schema design and evolution, N+1/DataLoader batching, subscriptions, Protobuf field numbering, gRPC streaming modes, breaking-change detection, anti-patterns, and code review signals across TypeScript, Go, and Java
---

# GraphQL and gRPC API Patterns for Code Review

## Overview

GraphQL and gRPC each solve different API design problems but share a common failure mode: schema or contract changes that break callers without warning. GraphQL's flexibility makes it easy to over-fetch, under-batch, and leak implementation details. gRPC's strict Protobuf contracts are powerful but unforgiving when field numbers or types are changed carelessly.

**When to use:** Reviewing GraphQL resolvers, schema migrations, Protobuf `.proto` files, gRPC service definitions, or any code that consumes or exposes these APIs; evaluating batching strategies, subscription implementations, or streaming service designs.

## Quick Reference

| Pattern | Core Idea | Primary Red Flag |
|---------|-----------|-----------------|
| GraphQL Schema Design | Types, fields, nullability as API contract | Nullable fields everywhere; exposing DB columns directly |
| Schema Evolution (GraphQL) | Deprecate over version; never remove live fields | Removing fields without `@deprecated`; adding breaking nullability changes |
| N+1 / DataLoader | Batch per-field DB lookups into one query | Per-resolver DB call inside a list type; no DataLoader |
| GraphQL Subscriptions | Real-time push via WebSocket/SSE | Subscriptions without auth checks; no connection cleanup |
| Protobuf Design | Field numbering and naming are the wire contract | Reusing field numbers; renaming fields without alias |
| gRPC Streaming | Four modes: unary, server, client, bidirectional | Streaming without deadline/cancel propagation |
| Schema Evolution (gRPC) | Backward-compatible field additions only | Removing/renumbering fields; changing field types |
| Breaking Change Detection | Automate with buf or protoc-gen-compat | Manual review only; no CI check on `.proto` changes |

---

## Patterns in Detail

### 1. GraphQL Schema Design and Nullability

**Red Flags:**
- Every field is nullable — callers must null-check every level, and errors are invisible
- Schema mirrors DB tables — leaks storage concerns into the API contract
- Input types reused as output types — different validation needs collide
- `ID` fields typed as `String` or `Int` inconsistently — prevents global object identification

**TypeScript (schema-first with `graphql-tag`):**
```typescript
// BEFORE — nullable everywhere; DB table exposed directly
type User {
  id: String
  name: String
  email: String
  internal_account_id: String  # storage detail leaked
}

// AFTER — nullable only where absence is meaningful; IDs use scalar ID
type User {
  id: ID!
  name: String!
  email: String!
  # internal_account_id removed — not a public concern
  createdAt: DateTime!
  avatarUrl: String          # nullable: user may not have set one
}

type Query {
  user(id: ID!): User        # nullable return: user may not exist
  me: User!                  # non-nullable: if authed, always present
}
```

**TypeScript (code-first with type-graphql):**
```typescript
@ObjectType()
class User {
  @Field(() => ID)
  id: string;

  @Field()
  name: string;  // non-null by default in type-graphql

  @Field({ nullable: true })
  avatarUrl?: string;
}
```

**Java (DGS framework):**
```java
@DgsComponent
public class UserDataFetcher {
    @DgsQuery
    public User user(@InputArgument String id) {
        return userService.findById(id)
            .orElseThrow(() -> new DgsEntityNotFoundException("User not found: " + id));
    }
}
```

---

### 2. GraphQL Schema Evolution — Deprecation Over Versioning

**Red Flags:**
- Field removed without `@deprecated` directive and a migration period
- New required (non-null) argument added to existing field — breaks existing queries
- `schema.design` changed by renaming a field — old queries fail silently
- Breaking nullability change: field changed from `String` to `String!` without client audit

**Schema deprecation — TypeScript:**
```typescript
// WRONG: just delete the field
type User {
  id: ID!
  name: String!
  # username removed — breaks all existing clients
}

// CORRECT: mark deprecated first; remove only after all callers migrate
type User {
  id: ID!
  name: String!
  username: String @deprecated(reason: "Use `name` instead. Removed after 2026-06-01.")
}
```

**Adding arguments safely (TypeScript):**
```typescript
// WRONG — adding required arg breaks existing callers
users(limit: Int!, offset: Int!): [User!]!

// CORRECT — new arguments must have defaults so old queries still work
users(limit: Int = 20, offset: Int = 0): [User!]!
```

**Evolut schema with interface extension — Go (gqlgen):**
```go
// schema.graphqls
extend type Query {
  # New field added — non-breaking; old queries unaffected
  usersByOrg(orgId: ID!, limit: Int = 20): [User!]!
}
```

Cross-reference: `review-api-contract` — API versioning strategies and backward compatibility rules.

---

### 3. GraphQL N+1 Problem and DataLoader Batching

**Red Flags:**
- A resolver for a field on a list type makes a database call per item — N+1 queries
- `DataLoader` created inside the resolver function (not per-request) — defeats batching
- No DataLoader for any has-many or belongs-to relationship
- `Promise.all` used correctly but still bypasses batching — parallel but not coalesced

**TypeScript — N+1 before/after:**
```typescript
// BEFORE — N+1: 1 query for posts + N queries for each author
const PostResolver = {
  author: async (post: Post) => {
    return db.users.findById(post.authorId);  // called once per post in list
  },
};

// AFTER — DataLoader coalesces all author IDs into a single batch query
import DataLoader from 'dataloader';

function createLoaders() {
  return {
    userLoader: new DataLoader<string, User>(async (ids) => {
      const users = await db.users.findByIds([...ids]);
      const userMap = new Map(users.map(u => [u.id, u]));
      return ids.map(id => userMap.get(id) ?? new Error(`User not found: ${id}`));
    }),
  };
}

// Loader attached to request context — one instance per request, not per field
const PostResolver = {
  author: (post: Post, _args: unknown, ctx: Context) => {
    return ctx.loaders.userLoader.load(post.authorId);
  },
};
```

**Go (gqlgen + dataloaden):**
```go
// generated UserLoader batches by []string IDs
func (r *queryResolver) Posts(ctx context.Context) ([]*model.Post, error) {
    posts, err := r.db.AllPosts(ctx)
    if err != nil { return nil, err }
    return posts, nil
}

// Per-field resolver uses the loader — no direct DB call
func (r *postResolver) Author(ctx context.Context, post *model.Post) (*model.User, error) {
    return getLoaders(ctx).UserLoader.Load(post.AuthorID)
}
```

**Java (Spring GraphQL + @BatchMapping):**
```java
@BatchMapping(typeName = "Post", field = "author")
public Flux<User> authors(List<Post> posts) {
    List<String> ids = posts.stream().map(Post::getAuthorId).toList();
    return userService.findAllByIds(ids);  // single DB call for all posts
}
```

---

### 4. GraphQL Subscriptions and Real-Time Patterns

**Red Flags:**
- Subscription resolvers without authentication checks — open WebSocket endpoints
- No connection cleanup (unsubscribe / complete) — memory leaks under load
- Publishing to all subscribers from a single resolver — fan-out bottleneck
- Subscriptions sharing mutable state across connections — race conditions
- Missing heartbeat/keep-alive — stale connections accumulate

**TypeScript (Apollo Server + graphql-ws):**
```typescript
// schema
type Subscription {
  messageAdded(channelId: ID!): Message!
}

// resolver — subscription with auth guard and cleanup
const resolvers = {
  Subscription: {
    messageAdded: {
      subscribe: async function* (_, { channelId }, ctx) {
        if (!ctx.userId) throw new GraphQLError('Unauthorized', {
          extensions: { code: 'UNAUTHORIZED' },
        });
        const channel = await validateChannelAccess(ctx.userId, channelId);
        const iter = pubsub.asyncIterator(`MESSAGE_ADDED:${channel.id}`);
        try {
          for await (const payload of iter) {
            yield payload;
          }
        } finally {
          // cleanup runs when client disconnects
          iter.return?.();
        }
      },
    },
  },
};
```

**Go (gqlgen subscriptions):**
```go
func (r *subscriptionResolver) MessageAdded(ctx context.Context, channelID string) (<-chan *model.Message, error) {
    if !auth.IsAuthorized(ctx) {
        return nil, fmt.Errorf("unauthorized")
    }
    ch := make(chan *model.Message, 1)
    go func() {
        defer close(ch)
        sub := r.broker.Subscribe(channelID)
        defer r.broker.Unsubscribe(sub)  // cleanup on context cancel
        for {
            select {
            case msg := <-sub.C:
                ch <- msg
            case <-ctx.Done():
                return
            }
        }
    }()
    return ch, nil
}
```

Cross-reference: `architectural-patterns` — event-driven patterns and pub/sub models.

---

### 5. Protobuf Design — Field Numbering and Naming

**Red Flags:**
- Field numbers reused after removing a field — wire format corruption for old clients
- Field renamed without `json_name` alias — breaks JSON transcoding
- `required` keyword used (proto2) — prevents adding optional fields later
- `enum` value 0 not defined or used as a meaningful state — proto default is 0
- Nested messages reused across unrelated services — tight coupling between services

**Proto file — TypeScript generated client:**
```proto
// WRONG — number 2 reused, breaks backward compat
message User {
  int32 id = 1;
  // string name = 2;  // removed
  string email = 2;    // REUSED — old clients read email as name
}

// CORRECT — reserve removed field numbers and names
message User {
  int32 id = 1;
  reserved 2;
  reserved "name";
  string email = 3;
  string display_name = 4;  // new field — safe addition
}
```

**Enum zero value — always define UNKNOWN:**
```proto
// WRONG — 0 is the default; using it as a real state is ambiguous
enum OrderStatus {
  PENDING = 0;   // proto default — unset looks like PENDING
  COMPLETED = 1;
}

// CORRECT — 0 reserved for unset/unknown
enum OrderStatus {
  ORDER_STATUS_UNSPECIFIED = 0;
  ORDER_STATUS_PENDING = 1;
  ORDER_STATUS_COMPLETED = 2;
}
```

**Go — safe Protobuf field access:**
```go
// WRONG — nil pointer if optional field not set
name := req.GetUser().Name

// CORRECT — check presence before dereferencing
if u := req.GetUser(); u != nil {
    name = u.GetName()  // GetName() returns "" if nil — safe
}
```

Cross-reference: `review-api-contract` — backward compatibility, field deprecation strategy.

---

### 6. gRPC Streaming Modes

**Red Flags:**
- Streaming without deadline propagation — streams run indefinitely
- No cancellation handling in server-side stream loop — goroutine/thread leak
- Client streaming without flow control — unbounded memory growth
- Bidirectional stream that ignores half-close — client cannot signal end-of-stream

**TypeScript — server streaming with deadline:**
```typescript
// proto: rpc ListOrders (ListOrdersRequest) returns (stream Order);

async function listOrders(
  call: grpc.ServerWritableStream<ListOrdersRequest, Order>
): Promise<void> {
  const cursor = db.orders.cursor({ userId: call.request.userId });
  try {
    for await (const order of cursor) {
      if (call.cancelled) break;  // respect client cancel
      call.write(orderToProto(order));
    }
    call.end();
  } catch (err) {
    call.destroy(err as Error);
  }
}
```

**Go — bidirectional streaming with context propagation:**
```go
// proto: rpc Chat (stream ChatMessage) returns (stream ChatMessage);

func (s *ChatServer) Chat(stream pb.Chat_ChatServer) error {
    ctx := stream.Context()
    for {
        msg, err := stream.Recv()
        if err == io.EOF {
            return nil  // client signalled half-close
        }
        if err != nil {
            return status.Errorf(codes.Internal, "recv: %v", err)
        }
        select {
        case <-ctx.Done():
            return status.Error(codes.Canceled, "client disconnected")
        default:
        }
        reply := process(msg)
        if err := stream.Send(reply); err != nil {
            return err
        }
    }
}
```

**Java — client streaming with StreamObserver:**
```java
// proto: rpc UploadMetrics (stream MetricPoint) returns (SummaryResponse);

@Override
public StreamObserver<MetricPoint> uploadMetrics(StreamObserver<SummaryResponse> responseObserver) {
    List<MetricPoint> buffer = new ArrayList<>();
    return new StreamObserver<>() {
        @Override public void onNext(MetricPoint point) { buffer.add(point); }
        @Override public void onError(Throwable t) {
            log.error("Upload stream error", t);
            responseObserver.onError(t);
        }
        @Override public void onCompleted() {
            SummaryResponse summary = metricsService.summarize(buffer);
            responseObserver.onNext(summary);
            responseObserver.onCompleted();
        }
    };
}
```

---

### 7. Schema Evolution and Breaking Change Detection

**Red Flags:**
- No `buf` or `protoc-gen-compat` check in CI — breaking changes merged silently
- GraphQL schema changes deployed without `graphql-inspector` diff in PR
- Field type changed (e.g., `int32` to `int64`) — wire incompatible even if value fits
- New non-null field added to input type without default — breaks existing callers
- `oneof` field added to existing message without backward-compat analysis

**buf.yaml — CI breaking change detection:**
```yaml
version: v1
breaking:
  use:
    - FILE
lint:
  use:
    - DEFAULT
```

**CI workflow snippet (GitHub Actions):**
```yaml
- name: Check Protobuf breaking changes
  run: |
    buf breaking --against '.git#branch=main'
```

**GraphQL Inspector in CI — TypeScript project:**
```bash
# Compare current schema against main branch schema
npx graphql-inspector diff \
  'git:origin/main:schema.graphql' \
  './schema.graphql' \
  --onUsage breaking
```

**Go — safe proto message evolution:**
```go
// BEFORE (v1)
message SearchRequest {
  string query = 1;
}

// AFTER (v2) — backward compatible additions
message SearchRequest {
  string query = 1;
  int32 max_results = 2;   // new optional field — old clients send 0 (proto default)
  repeated string filters = 3;  // new repeated — old clients send empty list
}
```

Cross-reference: `error-handling-patterns` — fail-fast validation at schema boundaries.

---

### 8. Anti-Patterns and Code Review Signals

| Anti-Pattern | Description | Fix |
|-------------|-------------|-----|
| **Resolver N+1** | Per-item DB call inside list resolver | Introduce DataLoader; batch by parent IDs |
| **God Query** | Single GraphQL query fetches entire object graph | Paginate lists; use `@defer` for non-critical fields |
| **Schema Versioning** | `/graphql/v2` endpoint instead of deprecating fields | Add `@deprecated`; version at field level, not endpoint |
| **Nullable Everything** | All fields nullable to "be safe" | Make fields non-null unless absence is meaningful; document why nullable |
| **Field Number Reuse** | Deleted proto field number reassigned | Always `reserve` deleted field numbers and names |
| **Missing Deadline** | gRPC call or stream without deadline/timeout | Set `WithDeadline` or `WithTimeout` on every outgoing call |
| **Streaming Without Cancel** | Server stream ignores `context.Done()` | Select on `ctx.Done()` in every stream loop iteration |
| **Open Subscription** | Subscription endpoint lacks auth guard | Check credentials in `subscribe` function before yielding |
| **Input = Output Type** | Same GraphQL type used for mutations and queries | Separate `UserInput` for writes; `User` for reads |
| **proto `required` Fields** | Using `required` in proto2 locks schema forever | Use `optional` (proto3 default); validate in application layer |

**God Query — TypeScript fix with `@defer`:**
```typescript
// BEFORE — fetches entire social graph in one round-trip
query UserPage($id: ID!) {
  user(id: $id) {
    id name email
    posts { id title body comments { id text author { name } } }
    followers { id name avatarUrl }
  }
}

// AFTER — critical data first; deferred sections stream in after
query UserPage($id: ID!) {
  user(id: $id) {
    id name email
    ... on User @defer(label: "posts") {
      posts { id title }
    }
    ... on User @defer(label: "followers") {
      followers { id name }
    }
  }
}
```

**Missing deadline — Go:**
```go
// WRONG — no deadline; server stream runs forever on slow response
conn, _ := grpc.Dial(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
client := pb.NewOrderServiceClient(conn)
stream, _ := client.ListOrders(context.Background(), req)

// CORRECT — deadline propagated; stream cancelled if server is slow
ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
defer cancel()
stream, err := client.ListOrders(ctx, req)
if err != nil {
    return fmt.Errorf("ListOrders: %w", err)
}
```

**Auth guard on subscription — Java (Spring GraphQL):**
```java
@SubscriptionMapping
public Flux<Message> messageAdded(@Argument String channelId,
                                   @AuthenticationPrincipal UserDetails user) {
    if (user == null) throw new AccessDeniedException("Authentication required");
    return messagingService.subscribe(channelId, user.getUsername())
        .doOnCancel(() -> messagingService.unsubscribe(channelId, user.getUsername()));
}
```

---

## Cross-References

- `review-api-contract` — API backward compatibility rules, versioning strategy, and contract testing
- `architectural-patterns` — Event-driven architecture and pub/sub models that underpin subscriptions and streaming
- `error-handling-patterns` — Fail-fast validation at schema and Protobuf message boundaries; error propagation in streaming contexts
- `security-patterns-code-review` — Authentication on WebSocket/subscription endpoints; authorization in resolver context
- `observability-patterns` — Tracing across gRPC boundaries; subscription connection metrics and DataLoader cache hit rates
