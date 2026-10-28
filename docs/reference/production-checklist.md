# Cổng đánh giá production

Checklist này dùng cùng [chương 20](../chapters/20-sre-production.md), [runbooks](runbooks.md), [protocol support](protocol-support.md) và [OIDC conformance](oidc-conformance.md). **Tất cả mặc định pending**. Có đoạn code, một bài viết hoặc một output minh họa không làm mục đó passed. Mỗi hàng cần evidence link, thời điểm, source commit/image digest, môi trường, người thực hiện và reviewer; ghi N/A phải có lý do/scope được duyệt.

Không cộng điểm trung bình để bù một security gate thất bại. Có thể hoàn thành lab trước production; học xong sách không tự cấp chứng nhận an toàn cho authorization server tự xây.

## 1. Ownership, phạm vi và compatibility

- [ ] Có owner/on-call cho Identity, Authorization, data, platform và incident; recovery operator identity độc lập IAM.
- [ ] Capability matrix phân biệt implemented/tested/deferred; không quảng cáo implicit/password grant/Bulk SCIM hoặc profile chưa xây.
- [ ] Fixed issuer riêng từng environment, redirect/client/audience inventory và quy trình onboarding ứng dụng ngoài đã kiểm chứng.
- [ ] API/contracts/events có versioning và compatibility tests; mọi client biết 401/403/503 và retry semantics.
- [ ] Threat model cập nhật các trust boundaries, browser/BFF, machine caller, federation, provisioning và supply chain.
- [ ] Security review độc lập có findings được sửa hoặc ngoại lệ có owner/expiry; review không chỉ dùng dependency scanner.

## 2. Protocol và credential lifecycle

- [ ] Authorization Code + PKCE S256, state/nonce, exact redirect, code binding và replay/concurrency negative tests passed.
- [ ] OIDC discovery/JWKS/userinfo/ID token validation/conformance profile có report của implementation thực; ghi rõ certification status nếu có.
- [ ] Opaque tokens có entropy đủ, SHA-256 bytea; passwords Argon2id; raw token/code/password không có trong logs/events/artifacts.
- [ ] Refresh rotation/reuse revoke commit trước error response; family/session/client/org checks cùng fixtures đồng thời.
- [ ] Reset/verify/invite/MFA/recovery challenges single-use có expiry, chống enumeration, abuse/rate limits và recovery ownership.
- [ ] MFA/passkey và step-up context có tests; clock/counter/recovery failure không bypass authentication.
- [ ] Client auth/private_key_jwt algorithm/aud/iss/sub/exp/jti và replay database có test; DB lỗi 503, không inactive giả.
- [ ] Signing keys được KMS/Vault giữ private, runtime least privilege; rotation/compromise/custody/renewal và version→kid mapping đã diễn tập.

## 3. Mỗi request và tenant boundary

- [ ] Từng protected resource request online introspect; không positive cache, stale fallback, cross-request coalescing hoặc gateway-only enforcement.
- [ ] Protected CDN/browser/BFF/conditional responses không bypass checks; ID token và local app cookie không tự thay access-token state check.
- [ ] Introspection caller authenticated và audience allowlisted; unknown/inactive/wrong audience chỉ active:false; status hiện hành từ primary.
- [ ] Current user/org/membership/session/client/app assignment/group state có mutation→next-check tests sau committed transaction.
- [ ] Global account/multi-org semantics đúng: org-bound token, org switch lấy token mới, SCIM deprovision không xóa account ở org khác.
- [ ] Tenant tests bao gồm IDs, list/filter, pagination, jobs, audit queries, policy admin và direct backend access.
- [ ] PDP tenant boundary, explicit deny, constraints, allow/default deny và condition-error fail-closed có tests; current assignments/relations không dựa audit projection.
- [ ] Resource owner nạp thuộc tính từ DB; caller org/resource ownership registry được check; browser không giả sub/group/resource attrs.
- [ ] Policy checks không tạo dependency cycle Identity→Policy→Identity; failure/deadline và errors rõ ràng.
- [ ] Streaming/background jobs có authorization checkpoints đã định nghĩa; không hứa hủy request đã qua check trước revoke.

## 4. Enterprise governance và workloads

- [ ] Request/approval/activation không self-approve, có step-up, role change re-review, expiry enforced trong PDP dù scheduler dừng.
- [ ] Owner API mutations idempotent với payload conflict, outbox cùng transaction; Governance không dùng cross-database credentials.
- [ ] Access review snapshot/revision/CAS không revoke nhầm assignment mới; stale queue replay không tái cấp quyền.
- [ ] SCIM capability thật, pagination/filter/ETag/errors, org-bound integration và account-linking ownership tests.
- [ ] Workload principal tách user, per-org client credential và least-privilege scopes/audiences; disable client chặn token đang giữ.
- [ ] Delegation giữ subject/actor, downscope, audience edges, parent revoke; profile unsupported bị reject.

## 5. Data, durability và recovery

- [ ] Mỗi owner có database/app role riêng, không SUPERUSER/table owner/BYPASSRLS; RLS/pool context và transaction semantics đã test.
- [ ] DB TLS/CA/primary routing và connection budget được xác minh trong cluster; không truy vấn security state từ async replica.
- [ ] Acknowledged revocations đạt RPO=0 qua failover, có synchronous durability + fencing + candidate validation; không chứng minh được thì recovery gate giữ closed.
- [ ] Backup encrypted, retention/PITR/key custody rõ; restore vào môi trường cô lập đã chạy và đo RTO/RPO.
- [ ] Restore drill trước revoke/password change chứng minh token/session/challenge/recovery/factor/client credential/quyền cũ không sống lại.
- [ ] Reconciliation policy/ABAC/ReBAC, governance queue/outbox và audit sau restore hoàn tất trước mở tenant.
- [ ] Migration expand/contract hai phiên bản, checksum/lock/deadline và rollback digest có bằng chứng; runtime không có DDL privilege.

## 6. Platform và supply chain

- [ ] Kubernetes/control-plane/cloud IAM hardening, failure domains và data topology phù hợp; không gọi kind nhiều containers là multi-AZ HA.
- [ ] Envoy Gateway/Gateway API/cert-manager versions hỗ trợ nhau, backend TLS/SAN/CA đúng; không skip verification.
- [ ] Default deny NetworkPolicy được packet-test positive/negative; service accounts/RBAC/non-root/read-only FS/secrets tách riêng.
- [ ] Pod disruption/rolling update/graceful shutdown/pool budget/HPA có workload tests.
- [ ] CI protected branch và fork isolation đã thử; actions/base/dependencies/infra images pin và có quy trình update CVE.
- [ ] GHCR digest/SBOM/provenance/attestation verify đúng repository+workflow; promotion không rebuild; admission chặn unsigned/disallowed artifacts.
- [ ] Runtime secret từ custody được quản lý, không Git/image/CI artifacts; rotation và secret-leak response đã diễn tập.
- [ ] GitOps AppProject/repo/controller quyền tối thiểu; emergency mutation có audit và reconciliation về Git.

## 7. SRE và sign-off

- [ ] Benchmark data/profile/env/versions đầy đủ; 100 RPS/15 phút, introspection p95≤50 ms, API p95≤150 ms có kết quả thực hoặc target được review lại với lý do.
- [ ] Refresh expiry, fan-out và dependency hops được tính; không load health/no-op rồi suy ra toàn login/OAuth throughput.
- [ ] Latency/error saturation bounded, không cạn memory/connections; outage trả 503 trong budget, không cached allow.
- [ ] SLO end-to-end 99,9%, SLI semantics, synthetic SSO/revoke và burn alerts có owner/runbook; không chỉ đo health uptime.
- [ ] Audit/trace/metric redaction và cardinality được kiểm tra; incident investigation nối request/decision/operation mà không lộ credential.
- [ ] Drills pod/DB/Redis/broker/Vault/key rotation/primary failover/restore/rollback có timestamp và observed results.
- [ ] Dữ liệu cá nhân, retention/deletion/export và nghĩa vụ theo jurisdiction được người có trách nhiệm đánh giá; không tự suy ra compliance từ checklist kỹ thuật.
- [ ] Pilot theo nhóm tenant, rollback/maintenance switch, support/onboarding docs và review sau rollout có lịch/owner.

### Biên bản một gate

```text
Gate: online membership revoke after commit
Status: pending | passed | failed | N/A
Environment / date UTC:
Source SHA / artifact digest / schema version:
Command/test file and redacted result link:
Expected vs observed:
Limitations / exception expiry:
Operator / reviewer / decision:
```

Release owner chỉ mở production khi mọi gate áp dụng passed hoặc ngoại lệ đã được chủ thể chịu trách nhiệm chấp thuận bằng văn bản. Nếu chưa đạt, giữ môi trường học/staging hoạt động và tiếp tục sửa; không đổi định nghĩa passed để tránh phần việc còn thiếu.
