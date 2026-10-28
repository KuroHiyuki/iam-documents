# Tham chiếu Azure, AWS, Google đúng phạm vi

Tài liệu tham khảo được đối chiếu ngày 28/10/2026. Giáo trình xây một identity platform B2B phục vụ các ứng dụng của bạn. Không tuyên bố có feature parity, API compatibility, chứng nhận hay SLA như cloud providers. Mỗi cloud dùng nhiều sản phẩm phối hợp; tên “IAM” không đồng nghĩa một dịch vụ login.

| Năng lực | Microsoft | AWS | Google | Đầu ra giáo trình |
|---|---|---|---|---|
| Workforce directory và SSO | Entra ID | IAM Identity Center | Cloud Identity; Workforce Identity Federation | Global user, membership đa org, app assignment, SSO |
| Login ứng dụng khách hàng | Entra External ID | Cognito user pools | Identity Platform | Authorization server/OIDC provider tự triển khai |
| Quyền tài nguyên | Azure RBAC | IAM và Organizations guardrails | Cloud IAM | Permission, role, scope, policy, PDP/PEP |
| Machine identity | Service principals, managed identities | IAM roles/STS | Service accounts, Workload Identity Federation | Confidential clients, short-lived tokens, workload federation |
| Điều kiện truy cập | Entra Conditional Access; Azure ABAC theo dịch vụ | Policy conditions | IAM Conditions | ABAC với attributes có nguồn đáng tin |
| Governance | Entra ID Governance, PIM | Nhiều dịch vụ IAM/Organizations/analysis | Nhiều dịch vụ IAM/analysis | JIT, approval, expiry, review và lifecycle |
| Quan hệ chia sẻ object | Thiết kế ứng dụng và dịch vụ liên quan | Thiết kế ứng dụng/dịch vụ authorization | Zanzibar là nghiên cứu tham khảo riêng | ReBAC hữu hạn theo org |

Entra roles quản trị Entra resources khác Azure RBAC quản trị Azure resources. Với hệ thống tự xây, tách platform administration, tenant administration và business resource permissions để tránh tenant admin trở thành platform admin. [Microsoft giải thích resource management](https://learn.microsoft.com/en-us/entra/architecture/secure-resource-management).

Identity Center hướng tới workforce access nhiều AWS accounts/apps; Cognito phục vụ ứng dụng web/mobile. Dự án cần học cả centralized authentication lẫn policy management. [AWS federation product mapping](https://docs.aws.amazon.com/en_en/IAM/latest/UserGuide/id_roles_providers.html).

Cloud Identity là directory workforce; Cloud IAM quyết định quyền Google Cloud resources; Identity Platform cung cấp CIAM cho ứng dụng. Chúng không phải ba tên của cùng một sản phẩm. [Google identity products](https://docs.cloud.google.com/docs/authentication/identity-products).

## Những ý tưởng đưa vào từng mốc

1. **Core:** account lifecycle, tenant memberships, client registry, sessions, strong authentication và OIDC. App A/B cùng delegate login về Identity.
2. **Resource authorization:** roles, permissions, scope và deny mặc định. Invoice API thực thi quyết định ngay tại tài nguyên; gateway không phải nơi kiểm tra duy nhất.
3. **Policy nâng cao:** explicit deny, mandatory constraints, ABAC và relations; tenant boundary luôn cứng. Có policy tests, version, simulation trước apply.
4. **Enterprise:** upstream OIDC/SAML federation, SCIM Users/Groups, suspend/deprovision, app assignment. Authentication thành công không tự cấp membership mới.
5. **Governance:** access request/review, eligible role, activation TTL, approval separation, periodic reconciliation và break-glass.
6. **Operations:** backup/restore, secret/key rotation, metrics, DR, load/failure tests, security review; sau đó mới xem active-active multi-region.

## Không sao chép policy semantics nửa vời

AWS evaluation có nhiều loại policies và khác biệt identity/resource/session/cross-account. Lab dùng mô hình nhỏ hơn: tenant → deny → constraints → allow → default deny. Không gọi mô hình này là AWS compatible. [AWS policy evaluation](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html).

Azure deny assignments không được người dùng tạo trực tiếp giống role assignments. Google Principal Access Boundaries có danh sách permissions hỗ trợ và enforcement version. Chúng gợi ý guardrails cho giáo trình nhưng không chứng minh mọi engine có cùng semantics. [Azure deny assignments](https://learn.microsoft.com/azure/role-based-access-control/deny-assignments), [Google policy types](https://docs.cloud.google.com/iam/docs/policy-types).

RBAC phù hợp quyền chức năng; ABAC thêm điều kiện từ principal/resource/environment; ReBAC diễn tả chia sẻ theo quan hệ. Không gắn graph database vào MVP chỉ vì Google đã có Zanzibar. Bài ReBAC dùng graph hữu hạn trong PostgreSQL, kiểm tra cycle/depth và live tuple reads. [Zanzibar research](https://research.google/pubs/zanzibar-googles-consistent-global-authorization-system/).

## Isolation và identity dùng chung

Lab chọn global identity, organizations/membership riêng; mỗi user access token có một org context. Đây là lựa chọn cho B2B SaaS của giáo trình. Cloud có cả silo và shared approaches. Một user thuộc hai org không có nghĩa policy/password/IdP của org A được thay thế policy của org B. [Google tenant isolation](https://docs.cloud.google.com/identity-platform/docs/multi-tenancy), [Cognito user-pool isolation tradeoff](https://docs.aws.amazon.com/cognito/latest/developerguide/bp_user-pool-based-multi-tenancy.html).

## Tiêu chí học thay cho đếm features

Bạn phải giải thích được ai sở hữu dữ liệu, trust boundary ở đâu, thao tác nào atomic, revoke có hiệu lực khi nào, dependency down trả gì, và cách chứng minh tenant B không thấy dữ liệu tenant A. Đầu ra là code bạn tự viết cùng tests và evidence. Triển khai được lên Kubernetes chưa đủ để gắn nhãn production-grade. Khi self-implement protocols, cần đối chiếu normative specs, interoperability/conformance tests và independent review trước phục vụ người dùng thật.
