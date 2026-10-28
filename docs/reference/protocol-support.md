# Phạm vi giao thức và hợp đồng tích hợp

Đọc cùng [implementation map](implementation-map.md), [chương OAuth](../chapters/06-oauth-authorization-code.md) và [cổng kiểm tra tương thích](oidc-conformance.md). Đây là **profile mục tiêu của giáo trình**, không phải tuyên bố server đã được triển khai, kiểm thử hay chứng nhận. Người học tự viết runtime trong `lab/`; repository hiện cung cấp tài liệu.

## Quyết định cố định

| Hạng mục | Profile của bài lab |
|---|---|
| Runtime | Node.js 24 LTS, TypeScript strict, ESM, Express 5 |
| Issuer | `https://iam.local.test:8443` — không có dấu `/` cuối |
| Browser clients | `web-a`, `web-b`; confidential BFF; redirect URI đăng ký chính xác |
| Human login | Authorization Code + PKCE `S256` + state + OIDC nonce |
| OAuth code | Opaque, ngẫu nhiên 32 byte; SHA-256 `bytea` ở DB; một lần; TTL 60 giây |
| Access token | Opaque, ngẫu nhiên 32 byte; TTL 5 phút |
| Refresh token | Opaque, rotation mỗi lần; grant tối đa 30 ngày, còn bị chặn bởi session/context |
| ID token | JWS JWT, `RS256`, TTL 5 phút; `kid` bắt buộc trong profile |
| API audience | `invoice-api` |
| API validation | Introspection trực tuyến trên **mỗi** protected HTTP request; đọc primary |
| Tenant | Shared issuer, account toàn cục, membership nhiều tổ chức; grant gắn một tenant |
| Client authentication | `client_secret_basic`; public client `none` chỉ dành test interoperability có đăng ký |
| Registration | Admin tạo client, không mở public dynamic registration |
| Machine calls | `client_credentials`, subject là service principal; không impersonate user |
| Errors API | `401` credential invalid; `403` đủ danh tính nhưng bị từ chối; `503` dependency không khả dụng |

Đây là các mặc định triển khai của khóa học. Session IAM có hạn tuyệt đối 12 giờ; idle 30 phút áp dụng session BFF. RFC không quy định chung rằng access token phải sống đúng 5 phút hoặc grant đúng 30 ngày. Trước production, kiểm tra tải hash mật khẩu, clock skew, recovery, mật độ traffic và threat model để điều chỉnh bằng ADR; không tự đổi TTL giữa các chương.

## Endpoint và dữ liệu

| Endpoint | Method | Input / output chính | Chương |
|---|---|---|---|
| `/.well-known/openid-configuration` | GET | JSON metadata chỉ quảng bá feature đã làm | [07](../chapters/07-openid-connect.md) |
| `/.well-known/oauth-authorization-server` | GET | Authorization Server Metadata; cùng issuer | [07](../chapters/07-openid-connect.md) |
| `/oauth2/authorize` | GET | `response_type=code`, client, redirect, scope, state, challenge; browser redirect | [06](../chapters/06-oauth-authorization-code.md) |
| `/oauth2/token` | POST form | `authorization_code`, `refresh_token`, `client_credentials` | [06](../chapters/06-oauth-authorization-code.md), [08](../chapters/08-token-lifecycle-introspection.md) |
| `/oauth2/userinfo` | GET/POST | Bearer access token; JSON `sub`, permitted profile claims | [07](../chapters/07-openid-connect.md) |
| `/oauth2/jwks` | GET | Public JWK Set, tuyệt đối không có private parameters | [07](../chapters/07-openid-connect.md), [10](../chapters/10-mfa-key-management.md) |
| `/oauth2/introspect` | POST form | Authenticated resource server, `token`; `active` + authorized metadata | [08](../chapters/08-token-lifecycle-introspection.md) |
| `/oauth2/revoke` | POST form | Authenticated owning client, `token`; `200` với token không tồn tại | [08](../chapters/08-token-lifecycle-introspection.md) |
| `/oauth2/logout` | GET/POST | RP-initiated request, confirmation khi cần, exact post-logout URI | [09](../chapters/09-sso-integration.md) |

Token/revocation/introspection nhận `application/x-www-form-urlencoded`; không silently chấp nhận JSON thay cho wire format chuẩn. Dùng `Cache-Control: no-store` cho token response, `Pragma: no-cache` để tương thích. Token không xuất hiện trong URL, application log, trace attribute hoặc error body. Discovery/JWKS là public metadata và có thể cache theo chính sách riêng; đó không phải positive authentication cache.

Introspection active trả `sub`, `client_id`, `org_id`, scope chuỗi, `aud`, `iss`, `sid`, `groups`, `iat`, `exp` và bằng chứng phiên hiện hành `amr`, `acr`, `auth_time`. Machine token không có phiên user nên các field evidence lần lượt là `[]`, `null`, `null`. Authorization ABAC dùng evidence này, không tin evidence do browser tự khai.

## Authorization profile

`invoice.read` và `invoice.write` là OAuth scope giới hạn ủy quyền của client. Chúng **không thay thế** kiểm tra role, resource tenant, ownership hay điều kiện của Authorization service. Seed BFF chỉ cấp `invoice.read`; bài tập write cần thay registration có kiểm soát. `openid`, `profile`, `email`, `offline_access` là các scope liên quan OIDC/lifecycle. Chỉ cấp refresh token khi có `offline_access`, client được phép và có consent tường minh. Profile học tập vẫn gắn grant với session và vô hiệu hóa grant khi session bị thu hồi: ở đây `offline_access` cho phép refresh trong cửa sổ đã cấp, không phải lời hứa sống mãi sau logout.

Một token access của API có audience `invoice-api`; cột `audience` là text đơn. UserInfo của cùng issuer chấp nhận user-bound token của flow BFF này khi có scope `openid`, theo policy được mô tả ở [chương 07](../chapters/07-openid-connect.md). Không coi một token dành API khác là hợp lệ vì nó cùng issuer. Code flow BFF lấy audience từ registration; machine grant dùng extension parameter `audience` với allowlist. Không quảng bá RFC 8707 nếu chỉ hỗ trợ profile nội bộ này.

Organization context `org_id` được lưu trên authorization request và grant. Giá trị `org_id` trong query chỉ là **yêu cầu lựa chọn**, phải được IAM xác minh sau login; không phải bằng chứng membership. Refresh không nhận đổi organization; cần một authorization flow mới. Identity không gọi Policy để xác thực password hay phát hiện token hợp lệ; API gọi Authorization sau khi có identity context đã kiểm tra.

## Những feature chưa thuộc baseline

Không hỗ trợ implicit/password grant, wildcard redirect, shared-secret JWT signing, URL bearer token hoặc bỏ xác minh TLS. Các mục sau là phần mở rộng có cổng kiểm tra riêng: upstream OIDC federation, SAML, SCIM, device authorization, token exchange, private-key JWT, mTLS, DPoP, PAR/JAR, dynamic registration, pairwise subject, back-channel logout. Không liệt kê endpoint hoặc metadata cho một feature chỉ mới có trong backlog.

`oidc-provider` có thể chạy như hệ thống đối chứng trong test sandbox để so sánh wire behavior; nó **không nằm trong runtime Authorization Server** của bài học. `jose`, `argon2`, SimpleWebAuthn và OIDC **client** library được phép dùng: chúng cung cấp primitive/serialization/verification hoặc phía client; logic state machine, transactions, grants và protocol endpoints vẫn do người học triển khai.

## Chuẩn tham chiếu và trạng thái

Ngày tra cứu: **28/10/2026**. OAuth 2.1 vẫn là Internet-Draft; baseline dựa OAuth 2.0 cộng các RFC đã xuất bản. [IETF OAuth 2.1 status](https://datatracker.ietf.org/doc/draft-ietf-oauth-v2-1/).

- OAuth framework và bearer usage: [RFC 6749](https://www.rfc-editor.org/rfc/rfc6749.html), [RFC 6750](https://www.rfc-editor.org/rfc/rfc6750.html).
- PKCE, bảo vệ grant và refresh token: [RFC 7636](https://www.rfc-editor.org/rfc/rfc7636.html), [RFC 9700](https://www.rfc-editor.org/rfc/rfc9700.html).
- OIDC Core/Discovery và logout: [OIDC Core](https://openid.net/specs/openid-connect-core-1_0.html), [Discovery](https://openid.net/specs/openid-connect-discovery-1_0.html), [RP-Initiated Logout](https://openid.net/specs/openid-connect-rpinitiated-1_0.html).
- Online token status và revocation: [RFC 7662](https://www.rfc-editor.org/rfc/rfc7662.html), [RFC 7009](https://www.rfc-editor.org/rfc/rfc7009.html).
- Browser architecture: [RFC 10017](https://www.rfc-editor.org/rfc/rfc10017.html), BCP tháng 8/2026. Metadata/JWKS bảo vệ thuật toán theo [JWT BCP RFC 8725](https://www.rfc-editor.org/rfc/rfc8725.html).

