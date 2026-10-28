# Thuật ngữ

| Thuật ngữ | Giải thích trong giáo trình |
|---|---|
| IAM | Identity and Access Management: danh tính, xác thực, phân quyền, lifecycle và governance |
| Principal | Thực thể có danh tính: user hoặc workload/service |
| Subject | Danh tính mà một token/authorization đang đại diện |
| Actor | Thực thể thực hiện hành động, có thể thay mặt subject |
| AuthN | Xác thực bằng chứng danh tính |
| AuthZ | Quyết định quyền cho action/resource/context |
| IdP / OP | Identity Provider / OpenID Provider, issuer phục vụ đăng nhập |
| AS | OAuth Authorization Server, phát token theo grant |
| RP / client | Ứng dụng sử dụng kết quả đăng nhập/quyền được cấp |
| Resource server | API nhận access token và bảo vệ tài nguyên |
| Issuer | Định danh URL của bên phát assertion/token; phải khớp trust config |
| Audience | Bên được phép nhận/sử dụng token, không phải tên user |
| Scope | Giới hạn quyền token/client được yêu cầu; không tự thay resource policy |
| Claim | Một phát biểu trong token/response, chỉ tin sau validation |
| ID token | OIDC assertion cho client về lần đăng nhập, không là bearer token API |
| Opaque token | Secret không chứa payload để client tự giải mã, cần hỏi trạng thái server |
| JWT / JWS / JWK | Định dạng claim, chữ ký JOSE, biểu diễn key |
| JWKS / kid | Tập public keys / key identifier để hỗ trợ verification và rotation |
| PKCE | Bind code exchange với secret verifier của authorization transaction |
| State | Client correlation/CSRF value round-trip qua authorization callback |
| Nonce | Bind ID token với OIDC login request của client |
| Consent | User chấp thuận scope/client; khác organization app assignment |
| Grant | Server-side authorization context sinh ra token family |
| Introspection | API hỏi trạng thái và metadata token theo RFC 7662 |
| Revocation | Thu hồi khả năng dùng token/grant/session theo policy |
| Refresh rotation | Mỗi lần refresh tạo successor, đánh dấu token cũ consumed |
| Reuse detection | Phát hiện token consumed được trình lại và revoke family theo policy |
| BFF | Backend For Frontend, giữ OAuth tokens phía server cho web app |
| Tenant / organization | Ranh giới dữ liệu/quản trị của khách hàng B2B |
| Membership | Quan hệ user thuộc organization với state riêng |
| PEP / PDP | Nơi thực thi / nơi quyết định authorization |
| RBAC | Role-Based Access Control, role gom permission và được gán theo scope |
| ABAC | Attribute-Based Access Control, điều kiện theo attributes đã kiểm chứng |
| ReBAC | Relationship-Based Access Control, quyền theo quan hệ object/user/group |
| Explicit deny | Quy tắc cấm thắng allow trong semantics của hệ thống này |
| Step-up | Yêu cầu bằng chứng mạnh/gần đây hơn trước thao tác nhạy cảm |
| MFA / passkey | Nhiều yếu tố / credential public-key WebAuthn chống phishing khi dùng đúng |
| Federation | Chấp nhận authentication từ issuer/identity system khác qua trust rõ ràng |
| SCIM | Giao thức provisioning user/group, không là giao thức login |
| JIT | Just-In-Time; trong governance là activation quyền có thời hạn; phân biệt JIT provisioning |
| JML | Joiner/Mover/Leaver: vào tổ chức, chuyển vai trò, rời tổ chức |
| Outbox / inbox | Event ghi cùng mutation / record consumer xử lý để chống duplicate |
| Idempotency | Retry cùng operation không tạo thêm hiệu ứng nghiệp vụ |
| Correlation / causation | Liên kết chuỗi request / chỉ sự kiện/lệnh trực tiếp gây ra bước sau |
| DLQ | Dead-letter queue lưu message cần điều tra/replay |
| RLS | Row-Level Security trong PostgreSQL |
| RPO / RTO | Mất dữ liệu tối đa chấp nhận / thời gian phục hồi mục tiêu |
| SLI / SLO | Chỉ số đo / mục tiêu tin cậy cho chỉ số đó |
| PITR | Point-In-Time Recovery từ backup và WAL |
| Expand/contract | Thêm schema tương thích trước, chuyển code/data, loại bỏ cũ sau |
| Conformance | Kiểm tra implementation đáp ứng profile chuẩn; khác certification đã được công nhận |
| Failure domain | Miền lỗi độc lập như host/zone; nhiều container cùng laptop chưa độc lập |

Các thuật ngữ có semantics cụ thể trong [implementation map](implementation-map.md), [authorization contract](authorization-contract.md), [event contract](events.md) và [protocol support](protocol-support.md).
