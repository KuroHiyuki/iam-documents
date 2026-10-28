# Quy ước triển khai xuyên suốt giáo trình

Đây là hợp đồng chung của các chương. Khi thay tên route, bảng hoặc field, cập nhật tài liệu này và các bài liên quan trong cùng thay đổi. Toàn bộ địa chỉ dưới đây là **môi trường lab**, không phải dịch vụ đã được triển khai.

## 1. Hai lớp repository

Repository được bàn giao là **giáo trình**. Người học tạo ứng dụng tại `lab/` ở chương 03. Các đường dẫn bắt đầu bằng `lab/` trong sách là file cần tạo khi thực hành; chúng không được ngầm coi là đã có trong repository tài liệu.

```text
IAM/
  README.md
  docs/chapters/                  # 20 chương
  docs/reference/                 # hợp đồng, SQL, checklist, runbook
  tools/                         # kiểm tra tài liệu
  lab/                           # người học tạo tại chương 03
    services/identity/src/
    services/authorization/src/
    services/audit/src/
    services/governance/src/
    services/invoice-api/src/
    apps/web-a/src/
    apps/web-b/src/
    packages/contracts/src/
    infra/compose/
    infra/kind/
    infra/helm/iam/
    infra/gitops/
    scripts/ci/
    load/
```

Lệnh trong sách chạy tại **workspace `IAM`**, trừ khi khối lệnh có `Set-Location lab` hoặc phần mô tả nêu rõ thư mục. Từ chương 03, lệnh pnpm cho ứng dụng dùng `pnpm -C lab ...`. Không chạy lệnh tạo workspace ứng dụng tại root giáo trình.

## 2. Ports và TLS local

| Thành phần | URL người dùng | HTTP backend local | pnpm package |
|---|---|---|---|
| Identity | `https://iam.local.test:8443` | `127.0.0.1:3000` | `@iam/identity` |
| Web A | `https://app-a.local.test:8444` | `127.0.0.1:3101` | `@iam/web-a` |
| Web B | `https://app-b.local.test:8445` | `127.0.0.1:3102` | `@iam/web-b` |
| Invoice API | `https://api.local.test:8446` | `127.0.0.1:3200` | `@iam/invoice-api` |
| Authorization | chỉ nội bộ | `127.0.0.1:3300` | `@iam/authorization` |
| Audit | chỉ nội bộ | `127.0.0.1:3400` | `@iam/audit` |
| Governance | chỉ nội bộ | `127.0.0.1:3500` | `@iam/governance` |

Local dùng Caddy 2 reverse proxy TLS với chứng chỉ mkcert; chương 03 hướng dẫn đầy đủ. Production chuyển sang Envoy Gateway + cert-manager, các backend nằm trong mạng riêng. `ISSUER` là URL HTTPS cố định theo **môi trường**, không được suy ra từ `Host`/`X-Forwarded-Host`. Local, staging và production có issuer riêng; không mang token giữa môi trường.

## 3. Fixture bất biến

| Tên | ID |
|---|---|
| Alice | `00000000-0000-4000-8000-000000000001` |
| Bob | `00000000-0000-4000-8000-000000000002` |
| Acme | `10000000-0000-4000-8000-000000000001` |
| Beta | `10000000-0000-4000-8000-000000000002` |

Alice là thành viên active của Acme và Beta. Bob chỉ là thành viên active của Beta. Account global không có role global mặc định. Email demo thuộc miền `example.test`; secret được sinh ngẫu nhiên tại máy người học, không dùng chuỗi trong sách làm credential thật.

Client: `web-a`, `web-b` là confidential BFF; `invoice-api` là resource-server client; `iam-policy-api` là client của Authorization service. Audience API nghiệp vụ là `invoice-api`; audience gọi PDP là `iam-policy-api`. Mỗi client có allowlist scope/audience/introspection audience riêng.

## 4. Routes

| Method | Route | Ý nghĩa |
|---|---|---|
| GET | `/.well-known/openid-configuration` | metadata OIDC |
| GET | `/oauth2/authorize` | bắt đầu Code Flow + PKCE |
| POST | `/oauth2/token` | code, refresh, client credentials; form-urlencoded |
| GET, POST | `/oauth2/userinfo` | thông tin user trong phạm vi scope |
| GET | `/oauth2/jwks` | chỉ khóa công khai |
| POST | `/oauth2/introspect` | resource service xác thực bằng client credential |
| POST | `/oauth2/revoke` | revoke token, xác thực/binding client |
| GET, POST | `/oauth2/logout` | RP-initiated logout; chống logout CSRF |
| GET | `/health/live` | process còn sống |
| GET | `/health/ready` | dependency bắt buộc còn dùng được |
| POST | Authorization `/v1/decisions` | quyết định quyền trực tuyến |
| PUT | Identity `/internal/v1/orgs/:orgId/memberships/:userId/status` | lệnh owner đổi trạng thái membership |
| POST | Authorization `/internal/v1/grants` | owner tạo role assignment |
| DELETE | Authorization `/internal/v1/grants/:id` | owner revoke assignment |

API quản trị khác dùng `/v1/...`. `/internal/...` vẫn xác thực và phân quyền; tên route không thay cho security boundary. Introspection không gọi PDP nên không có vòng lặp Identity → Policy → Identity.

## 5. Token và danh tính

- Authorization code, opaque access/refresh token, session cookie và challenge là giá trị ngẫu nhiên ít nhất 32 byte từ CSPRNG; lưu hash SHA-256 `bytea` nếu server chỉ cần so khớp.
- Password dùng Argon2id, không dùng SHA-256. Secret cần đọc lại như TOTP seed phải mã hóa và quản lý khóa riêng.
- ID token là JWT RS256. API không chấp nhận ID token làm access token.
- Token user gắn một `org_id`; token platform/account chỉ dùng audience riêng. Organization không được thay bởi header client.
- Client credentials token có `sub = client:<client_id>` và organization được bind từ cấu hình service principal, không từ organization tùy ý trong body.
- Mặc định lab: code 60 giây, access token 5 phút, grant/refresh tối đa 30 ngày, IAM session tối đa 12 giờ. BFF session có idle timeout 30 phút riêng; IAM không ghi last-seen cho mỗi introspection. Refresh phải kiểm tra session/membership/policy đăng nhập hiện hành. TTL ngắn không thay online checking.
- Refresh family chính là một `oauth_grants.id`. Reuse refresh token đã consume revoke cả grant. **Commit revoke rồi mới trả `invalid_grant`**; throw trong transaction sẽ rollback việc revoke.

## 6. Bảng SQL và helper chung

SQL tham chiếu có tại [identity.sql](sql/identity.sql), [authorization.sql](sql/authorization.sql), [audit.sql](sql/audit.sql), [governance.sql](sql/governance.sql). Mỗi file chạy vào database riêng, dưới quyền migration owner. Application role không sở hữu bảng, không superuser, không BYPASSRLS.

Identity: `users`, `organizations`, `memberships`, `groups`, `group_members`, `clients`, `app_assignments`, `sessions`, `challenges`, `authenticators`, `consents`, `oauth_authorization_requests`, `oauth_codes`, `oauth_grants`, `oauth_tokens`, `signing_keys`, `outbox`, `idempotency_records`.

Các bảng OAuth dùng `org_id`, `scope text[]`, `audience text`, `client_id text`. `oauth_tokens.kind` là `access` hoặc `refresh`; `token_hash` là primary key; `parent_hash` unique dành cho refresh successor; `consumed_at` đánh dấu refresh đã dùng. `oauth_grants.revoked_at`/`absolute_expires_at` là ranh giới family. Code bind `client_id`, redirect URI, PKCE, user, organization, session, scope và audience.

Helper do người học tạo theo chương:

| File trong `lab/services/identity/src` | Export | Nơi định nghĩa |
|---|---|---|
| `config.ts` | `config` (port, issuer, databaseUrl, cookie settings) | chương 03 |
| `errors.ts` | `AppError`, Express error handler | chương 03 |
| `db.ts` | `pool`, `withTransaction<T>(fn)` dùng cùng một `PoolClient` | chương 04 |
| `security.ts` | `newOpaqueToken(): string`, `hashToken(raw): Buffer` | chương 05 |
| các module protocol | `ProtocolError`, client auth, session/interaction helpers | chương 06–08 |

Schema hoàn chỉnh là **đích của Identity Core**; chương 04 giải thích phần dữ liệu nền, chương 06–10 giải thích và sử dụng phần protocol. Có thể áp dụng toàn bộ schema trong lab để tập trung học luồng xử lý; production dùng migration thêm dần và expand/contract ở chương 19.

## 7. Introspection và phân quyền

Introspection ban đầu dùng `client_secret_basic` với secret ngẫu nhiên lưu hash; chương 17 thêm `private_key_jwt`. Caller chỉ thấy token có audience trong `clients.introspection_audiences` của chính caller. Unknown, inactive hoặc ngoài quyền introspect trả `200 {"active":false}`. Credential của caller không hợp lệ trả lỗi giao thức phù hợp; resource service coi đó là lỗi cấu hình/dependency và trả 503 cho request nghiệp vụ.

Response active tối thiểu:

```json
{"active":true,"sub":"00000000-0000-4000-8000-000000000001","client_id":"web-a","org_id":"10000000-0000-4000-8000-000000000001","scope":"openid profile invoice.read","aud":"invoice-api","iss":"https://iam.local.test:8443","token_type":"Bearer","sid":"session-id","groups":[],"iat":1793149200,"exp":1793149500}
```

Đây là payload minh họa, không phải token đã phát hành. `groups` lấy từ membership hiện hành. Phiên user, trạng thái organization, app assignment và client phải còn active; machine token kiểm tra trạng thái client/service principal tương ứng. Query ngắn vào primary; không giữ snapshot cũ qua request. Không cache positive response hoặc policy allow xuyên request. Protected responses dùng `Cache-Control: no-store`; conditional response cũng phải qua kiểm tra trước.

Invoice API lấy access token của chính nó (audience `iam-policy-api`) để gọi PDP. PDP xác thực caller online, rồi introspect `subject_token` gốc bằng credential được phép kiểm tra audience `invoice-api`. Caller `client:invoice-api` chỉ được khai báo resource type do nó sở hữu. Owner load attributes từ DB ứng dụng, không chuyển attributes do browser gửi thành dữ kiện đáng tin.

```json
{"subject_token":"OPAQUE_VALUE_NOT_LOGGED","action":"invoice.read","resource":{"type":"invoice","id":"inv-001","org_id":"10000000-0000-4000-8000-000000000001","attributes":{"owner_id":"00000000-0000-4000-8000-000000000001","status":"draft"}}}
```

```json
{"allow":false,"reason_code":"NO_MATCHING_ALLOW","policy_version":3,"decision_id":"generated-uuid"}
```

Raw token chỉ đi qua TLS và không nằm trong audit/log. Decision API không nhận `sub`, group hay role từ browser làm principal đã xác thực. Identity và Policy không tạo một distributed transaction cho toàn bộ business request; request đã vượt một check có thể đang chạy khi revoke commit.

## 8. Lệnh owner, event và delivery

Lệnh membership có body `{status, operation_id}`. Lệnh cấp quyền có `{operation_id,org_id,subject_type,subject_id,role_id,scope:{type,resource_type,resource_id?},valid_until}`; `scope.type` là `organization` hoặc `resource`; owner map tới `role_assignments`. Owner trả `id` và `revision`. Lệnh revoke có `{operation_id,expected_revision}` để review không thu hồi nhầm assignment đã thay đổi. Một operation ID không được áp cho payload khác. Owner ghi mutation, receipt idempotency và outbox cùng transaction; Governance chỉ điều phối qua API. Scope máy gọi PDP là `authz:check`, scope ghi grant là `authz:grant`.

Các cột outbox `id`, `type`, `version`, `aggregate_id`, `aggregate_version`, `org_id`, `actor`, `correlation_id`, `data` được publisher chuyển thành [wire envelope v1](events.md): `schema_version`, `aggregate`, `actor_id`, `source` và metadata audit. Không serialize nguyên database row thành transport payload. At-least-once delivery; consumer có inbox/dedup và chiến lược version/reconciliation. Không đặt raw token, password, code, seed hay full secret vào event.

## 9. Error và security invariant

| Kết quả | HTTP ở ứng dụng |
|---|---|
| Không có / inactive access token | 401 |
| Token active, policy deny | 403 (hoặc 404 khi API công bố chính sách che tài nguyên) |
| Identity/Policy timeout, response sai schema, machine credential lỗi | 503 |
| Input quản trị sai | 400 theo management error contract |
| Resource service quá tải chủ động | 503 có giới hạn concurrency |

Mọi kiểm tra bắt đầu sau committed revoke phải thấy trạng thái mới; không bao gồm request đã được phép trước commit. Database failover không được phục hồi trạng thái cũ đã revoke: cần synchronous durability hoặc chặn lưu lượng khi không chứng minh được. Backup restore bắt buộc invalidate grant/session/challenge và xử lý credential thay đổi sau backup trước mở lại traffic.

## 10. Bằng chứng

Output ghi “minh họa/kỳ vọng” chưa phải kết quả đã chạy. Người học lưu bằng chứng dưới `lab/evidence/chXX/`: command, phiên bản, timestamp, cấu hình, kết quả và cách tái hiện; redaction mọi secret. Repository tài liệu có báo cáo kiểm tra riêng, không tự nhận đã chạy production/conformance chỉ vì có code block.
