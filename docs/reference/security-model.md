# Threat model và security defaults

Đọc [kiến trúc](architecture.md), [ADR](decisions.md), [support matrix](protocol-support.md) và [production checklist](production-checklist.md). Đây là mô hình thiết kế/threat cases; không thay security review của implementation thật.

## Assets và adversaries

Assets: credential, account recovery, user identity, organization membership, application trust, session/grant, machine identity, policy, signing key, confidential business data và audit evidence.

Adversaries gồm attacker Internet chưa login, user đã login của tenant khác, client app độc hại, account bị chiếm, workload bị compromise và người vận hành có quyền quá rộng. Việc bảo vệ trước user chưa login chưa đủ cho SaaS B2B.

## Trust boundary và mitigation

| Boundary / attack | Mitigation | Bài và test |
|---|---|---|
| Browser→IAM: credential stuffing | IP/account limiter, blocklist, KDF slots, phishing-resistant admin MFA | 05/10, burst + outage tests |
| Browser form: CSRF/fixation | Origin, CSRF token, `__Host-` Secure HttpOnly cookie, session rotation | 05/06/09 |
| Redirect và callback mix-up | Exact redirect registration, code/client binding, state/nonce/issuer, PKCE S256 | 06/07/09 |
| Auth code / refresh replay | Hash artifacts, atomic row locks, one-time consume, family revoke after reuse | 06/08, two-replica race |
| Token substitution | API accepts only opaque access token, audience+scope+live state | 07–11 |
| Tenant escape/BOLA | Verified org context, resource owner query, PDP boundary, RLS where designed | 04/11/13 |
| Service impersonation | Per-org confidential client, short-lived token, owner/audience/scope allowlist | 11/17 |
| Policy injection | Typed AST allowlist, no eval/JS/SQL expressions, bounded recursion | 13 |
| Federation account takeover | Issuer/subject binding, explicit linking proof, signature/replay/audience/recipient checks | 14 |
| SCIM overreach | Connector credential bound organization, owner API, idempotency, no global disable by tenant connector | 15/16 |
| Stale revoke | Primary current-state query, no positive cache, sync durability/fail-closed failover | 08/20 |
| Event spoof/duplicate | Producer ACL/source binding, schema validation, inbox hash/dedup, ACK after commit | 12 |
| Key/secret exfiltration | Secret manager, non-exportable signing key, workload policy, redaction, rotation | 10/17–20 |
| Insider audit tampering | Separate credentials, append privileges, export integrity/WORM, audit ops | 12/20 |
| Supply-chain compromise | Frozen deps, pinned images/actions, scan/SBOM/signature/provenance | 19 |

BOLA: Broken Object Level Authorization, thường xuất hiện khi API nhận một ID hợp lệ nhưng không kiểm tra tenant/permission của object đó.

## Dữ liệu nào được tin?

- `sub`, `org_id`, groups, authentication evidence đến từ live Identity check, không từ header do browser tạo.
- Resource attributes đến từ service sở hữu resource. PDP xác thực và giới hạn caller được khai báo resource types nào.
- `actor_id` audit được server suy từ credential đã xác thực. `subject_id` có thể khác actor khi delegation, nhưng phải có trust/delegation chain.
- Issuer/token/JWKS/upstream URL đến từ cấu hình quản trị, không từ `jku`, `x5u`, header Host hoặc URL tùy ý trong token.
- External webhook/SCIM/SAML/OIDC input là input không đáng tin tới khi qua validation và replay protection.

## Default token/session policy

| Đối tượng | Default lab | Invariant |
|---|---|---|
| Authorization request | 5 phút | bind interaction cookie/session, single-use |
| Code | 60 giây | bind client, redirect, PKCE, session/org/grant |
| Access token | 5 phút | 256-bit opaque, hash indexed, live check mỗi request |
| Refresh grant | tối đa 30 ngày | không vượt session 12 giờ trong baseline, rotation, reuse revoke |
| IAM session | tối đa 12 giờ | revoke/credential change/state check |
| BFF session | idle 30 phút | token encrypted server-side, online check protected requests |
| Verify/reset challenge | 15 phút | single-use, account/version binding |
| Admin sensitive action | recent step-up theo policy (lab 5 phút) | MFA evidence không được giả mới khi refresh |

TTL không làm revocation tức thời. Online checks và durability mới bảo đảm contract đã chọn. Grant có `offline_access` vẫn chịu baseline session policy; muốn offline delegation lâu hơn phải có policy riêng, không đổi âm thầm.

## Mật mã và secret storage

Password dùng Argon2id với salt do library sinh. Token/secret ngẫu nhiên entropy cao dùng SHA-256 để so khớp; không dùng password KDF trên mỗi introspection. TOTP seed/mail delivery token cần đọc lại thì dùng authenticated encryption; AAD bind owner/context và key version. KMS/Vault signing adapter chỉ nhận signing input đã có alg/kid allowlist; không tự viết RSA hoặc JOSE verification.

Public JWKS không có `d`, RSA primes, symmetric `k`, private certificate hoặc provider credential. Private signing material không có trong container image, Git, public endpoint hay database export thường. Local private key và root CA private key không đi cùng evidence.

## Protocol input/error handling

Reject duplicate protocol parameters, unsupported grant/response mode, bad body/content-type, over-size, redirect khác và ambiguous client authentication. Dùng một token dispatcher, không nhiều handler cạnh tranh ở cùng path. Token success/error no-store; không log request bodies hoặc query chứa code/state/assertion. Error description không phản chiếu credential.

Management JSON strict schema; unknown field nhạy cảm không được mass-assign. `is_admin`, status, role và org context không được lấy từ public register payload. SQL values parameterized; dynamic sort/filter map qua allowlist.

## Federation và recovery

Email verification chỉ chứng minh quyền kiểm soát mailbox trong luồng đó. Không tự merge accounts hoặc bind corporate subject theo email. Upstream identity khóa bởi `(issuer,sub)` hoặc SAML persistent identity mapping đã provision; linking cần login/reauth hai phía và policy organization.

Reset password không reset MFA hoặc bỏ corporate SSO. Factor replacement và account recovery là luồng nhạy cảm, có notification/audit/revocation. Break-glass thuộc control plane có lưu giữ và diễn tập riêng, không là một password “master” được hardcode trong app.

## Availability và abuse limits

Resource APIs fail closed với 503 khi không thể xác minh live state; circuit breaker không tái dùng allow cũ. Giới hạn pool, request body, outstanding requests, retry, recursion, query time và export size. Machine credential lỗi là operational/security event, không biến thành user login loop.

Rate limit keys tránh email/token raw; proxy IP đúng allowlist. Khi làm việc với tenant headers, sửa trusted proxy setting không được mở quyền nhận `X-Forwarded-For` từ Internet tùy ý.

## Review trước production

Với từng mutation, ghi: ai gọi, credential gì, scope/tenant nào, invariant gì, lock thứ tự nào, response sau commit hay trước, audit event nào, retry có duplicate không, failover/restore có đảo ngược security state không. Chứng minh bằng test âm tính và failure drill; lưu test case→requirement→evidence.

Nguồn: [OAuth BCP](https://www.rfc-editor.org/rfc/rfc9700.html), [JWT BCP](https://www.rfc-editor.org/rfc/rfc8725.html), [RFC 7662 security](https://www.rfc-editor.org/rfc/rfc7662.html#section-4), [OWASP ASVS](https://owasp.org/www-project-application-security-verification-standard/), [OWASP microservices security](https://cheatsheetseries.owasp.org/cheatsheets/Microservices_Security_Cheat_Sheet.html).
