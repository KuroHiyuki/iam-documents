# Nhật ký quyết định thiết kế

Mỗi ADR gồm quyết định, lý do, hệ quả và điều kiện xem xét lại. Thay đổi ADR phải cập nhật contract và kiểm thử liên quan.

## ADR-001 — Account global, organization là business tenant

**Quyết định:** user ID global; membership theo organization; một issuer cho mỗi môi trường, một organization trong mỗi user access token. **Lý do:** SaaS B2B cần người dùng tham gia nhiều tổ chức và SSO nhiều ứng dụng. **Hệ quả:** IdP evidence và policy organization phải được kiểm tra khi chọn tenant; không tự link theo email. **Xem lại khi:** hợp đồng khách hàng đòi directory/keys/issuer độc lập; cần migration/trust model riêng, không sửa `issuer` theo `Host` trên shared instance.

## ADR-002 — Opaque access token và online check mỗi request

**Quyết định:** access token opaque, trạng thái ở PostgreSQL primary, RFC 7662, không positive cache xuyên request. ID token vẫn là JWT. **Lý do:** yêu cầu thu hồi có hiệu lực ở lần check tiếp theo sau commit. **Hệ quả:** Identity và database nằm trong đường đi mỗi protected call; outage trả 503. Capacity và SLO đo end-to-end. Public key/config cache được phép vì không chứa quyết định user còn quyền. **Xem lại khi:** sản phẩm chấp nhận cửa sổ revocation; cần người sở hữu yêu cầu thay đổi, không tự bật cache để vượt benchmark.

## ADR-003 — Giữ authentication state atomic trong Identity Core

**Quyết định:** credential, code, grant, refresh và session dùng chung service/database; chia module trong code. **Lý do:** single-use và rotation cần transaction đơn giản, kiểm chứng được. **Hệ quả:** không tạo TokenService/PasswordService riêng từ ngày đầu. **Xem lại khi:** có số đo và ranh giới mới rõ; phải chứng minh semantics khi mất transaction chung.

## ADR-004 — Tự triển khai protocol, dùng crypto library

**Quyết định:** tự viết OAuth/OIDC endpoints và state machine; `jose`/Node crypto thực hiện JOSE/CSPRNG; Argon2id xử lý password; SimpleWebAuthn xử lý WebAuthn verification. **Lý do:** mục tiêu học sâu protocol và vận hành. **Hệ quả:** phải có requirements traceability, client độc lập, conformance và review bảo mật trước production. Không tuyên bố certification từ unit tests. **Xem lại khi:** vận hành ưu tiên giảm phần protocol tự bảo trì; thay bằng engine cần đánh giá compatibility và migration.

## ADR-005 — Owner database và owner commands

**Quyết định:** mỗi bounded context sở hữu database/credential/migration; Governance gọi API owner. **Lý do:** service boundary phải tồn tại ở dữ liệu và quyền vận hành. **Hệ quả:** không có FK/SQL join xuyên DB; provisioning cần idempotency, retry và reconciliation. Local có thể cùng một PostgreSQL instance, không có quyền truy vấn chéo. **Xem lại khi:** bounded context được gộp có chủ đích và ADR thay đổi, không qua shared credential tạm thời.

## ADR-006 — Outbox, at-least-once, idempotent consumer

**Quyết định:** mutation và outbox trong cùng transaction; publisher confirm; consumer ACK sau inbox+effect commit. **Lý do:** xử lý crash giữa DB và broker. **Hệ quả:** duplicate là trường hợp dự kiến; phải phát hiện event ID cùng nội dung khác; backlog/DLQ có alarm. **Xem lại khi:** đổi transport, giữ nguyên delivery contract; không quảng cáo exactly-once toàn hệ thống.

## ADR-007 — Resource owner cung cấp sự thật nghiệp vụ

**Quyết định:** PDP sở hữu policy; Invoice API sở hữu organization/owner/amount/status của invoice. Caller được bind với resource type. **Lý do:** IAM không nên lưu bản sao mọi tài nguyên nghiệp vụ. **Hệ quả:** protected mutation kiểm tra resource version/transaction; browser không tự cung cấp trusted attributes. **Xem lại khi:** thêm ReBAC tuple store; object nghiệp vụ vẫn thuộc owner.

## ADR-008 — Progressive microservices, monorepo

**Quyết định:** hoàn tất vertical slice Identity → BFF → API rồi thêm Policy, Audit, Governance. **Lý do:** mỗi bước có thể demo, debug và kiểm thử. **Hệ quả:** monorepo không đồng nghĩa shared database; packages chung chỉ chứa contract/utility không phụ thuộc domain DB. **Xem lại khi:** team/release boundaries cần nhiều repository; wire contracts giữ version rõ ràng.

## ADR-009 — Ưu tiên đúng trạng thái thu hồi qua failover

**Quyết định:** security state đã ack phải tồn tại khi promote; không chứng minh được thì fail closed/quarantine. Restore backup bắt buộc invalidate grants/sessions/challenges và xử lý credential đã thay đổi sau backup. **Lý do:** async failover có thể làm token bị revoke sống lại. **Hệ quả:** synchronous durability có chi phí availability/latency; RPO chung của backup không đồng nghĩa RPO cho acknowledged revoke. **Xem lại khi:** có cơ chế global revocation epoch/durability khác đã chứng minh bằng failure test.

## ADR-010 — Một region trước, production gate là bằng chứng

**Quyết định:** học local rồi Kubernetes một region; HA cần failure domain thực, TLS/secrets/restore/conformance/review là gate. **Lý do:** hoàn thành deployment chưa chứng minh security/recovery. **Hệ quả:** cluster kind nhiều node trên laptop không có SLA production. **Xem lại khi:** SLO/RTO và nhu cầu business đòi multi-region; thiết kế consistency được đánh giá riêng.

## ADR-011 — Errors và telemetry phân biệt security với outage

**Quyết định:** inactive credential → 401; active không quyền → 403; Identity/Policy/config machine credential lỗi → 503 cho user request. **Lý do:** tránh bắt người dùng login lại khi dependency hỏng và tránh che outage thành inactive. **Hệ quả:** metric phân biệt allow/deny/inactive/dependency_error; logs không chứa raw secret. **Xem lại khi:** API dùng 404 để che tồn tại tài nguyên; phải giữ khả năng điều tra nội bộ qua reason code và correlation.
