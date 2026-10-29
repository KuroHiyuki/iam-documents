# Tự xây IAM: TypeScript, Express và microservices

Giáo trình thực hành bằng tiếng Việt để tự xây một nền tảng quản lý danh tính và truy cập cho nhiều ứng dụng, đồng thời học **toàn vòng đời từ yêu cầu, thiết kế, code/review đến hạ tầng, phát hành, vận hành và chi phí**. Bạn tự viết Authorization Server/OIDC Provider và nghiệp vụ; thư viện chuyên dụng thực hiện mật mã, password hashing và WebAuthn.

**Cách bắt đầu:** mở [lộ trình toàn vòng đời và ma trận 10 nhóm](docs/reference/delivery-coverage.md), đọc [chương 01](docs/chapters/01-domain-overview.md) rồi làm [P01: yêu cầu và thiết kế](docs/delivery/01-requirements-solution-design.md). Tiếp theo là nền tảng/workspace và quy trình Git trước khi viết IAM. Repository hiện tại chứa giáo trình; ứng dụng được chính bạn tạo dần tại `lab/`.

Workspace hiện có `iam-documents` và `iam-experiement`. Tài liệu nằm trong **iam-documents**; phần thực hành hiện có được giữ nguyên. Các lệnh sách dùng root repository chứa README và `lab/`; xem [quy ước thư mục](docs/reference/delivery-coverage.md) nếu tách code sang repository riêng.

## Hệ thống bạn sẽ xây

- SaaS B2B đa tenant: một danh tính, nhiều tổ chức, quyền riêng từng tổ chức.
- Đăng nhập trung tâm bằng OIDC, hai web app có BFF để chứng minh SSO.
- Opaque access token; **mỗi protected HTTP request kiểm tra trực tuyến** trạng thái token/phiên/tài khoản và policy hiện hành.
- Identity Core → Authorization → Audit → Governance/Provisioning, tách theo các checkpoint chạy được.
- MFA/passkeys, federation OIDC/SAML, SCIM, RBAC/ABAC/ReBAC, access review và đặc quyền có thời hạn.
- Docker Compose → Kubernetes, CI/CD, observability, backup/restore, conformance và security review.
- FR/NFR, ADR/capacity/cost/risk, Git/review/security gates, Terraform/VPC/multi-AZ, dev/staging/prod, canary/rollback, incident/postmortem và maintenance.

## Tuyến quy trình: 8 bài từ bắt đầu đến kết thúc

Các bài P01–P08 đan vào 20 chương IAM bên dưới. Mỗi bài có artifact, lệnh/cấu hình, failure lab, troubleshooting và điều kiện hoàn thành.

| Bài | Thực hành | Học khi |
|---|---|---|
| P01 | [FR/NFR, thiết kế, capacity, cost và risk](docs/delivery/01-requirements-solution-design.md) | Ngay sau khi hiểu bài toán IAM, trước implementation |
| P02 | [Git, review, branch rules và security workflow](docs/delivery/02-git-security-workflow.md) | Sau skeleton, trước feature PR đầu tiên |
| P03 | [Terraform, cloud network và hạ tầng](docs/delivery/03-infrastructure-as-code.md) | Sau local app chạy được, trước cloud deployment |
| P04 | [Dev/staging/prod và promotion](docs/delivery/04-environments-promotion.md) | Thiết kế từ đầu; triển khai cùng chương 18–19 |
| P05 | [Canary, release gates và rollback](docs/delivery/05-progressive-delivery.md) | Sau staging và telemetry, trước production rollout |
| P06 | [Logs/metrics/traces, data protection và recovery](docs/delivery/06-observability-data-recovery.md) | Instrument sớm; cài stack/drill trước release |
| P07 | [On-call, postmortem, maintenance và chi phí](docs/delivery/07-operations-cost.md) | Chốt owner/cost sớm, thực hành sau release |
| P08 | [Capstone một thay đổi qua toàn vòng đời](docs/delivery/08-capstone-lifecycle.md) | Nghiệm thu cuối, rồi lặp cho feature tiếp theo |

Ví dụ hạ tầng cloud dùng AWS để có bài Terraform/VPC/EKS/RDS cụ thể; IAM core vẫn độc lập cloud. Local/kind không cần tài khoản AWS. Cloud có tính phí, cần forecast/timebox/owner trước khi người học tự apply. Không có bước tự tạo tài nguyên trong repository giáo trình.

## Lộ trình 20 chương

| Chương | Bài thực hành | Checkpoint |
|---|---|---|
| 01 | [Hiểu IAM và bài toán sản phẩm](docs/chapters/01-domain-overview.md) | Phân biệt identity, authentication, authorization và governance |
| 02 | [Nền tảng TypeScript, HTTP và bảo mật](docs/chapters/02-foundations.md) | Theo được request/cookie/token và xử lý lỗi async |
| 03 | [Dựng workspace chạy được](docs/chapters/03-workspace-bootstrap.md) | Express + CI + health + TLS local |
| 04 | [Dữ liệu và tenant isolation](docs/chapters/04-data-tenancy.md) | Database, transaction, fixture, RLS và migration |
| 05 | [Vòng đời tài khoản](docs/chapters/05-account-lifecycle.md) | Credentials, verification, reset, session và disable |
| 06 | [Tự viết OAuth Authorization Code + PKCE](docs/chapters/06-oauth-authorization-code.md) | Code được bind và đổi đúng một lần |
| 07 | [Bổ sung OpenID Connect](docs/chapters/07-openid-connect.md) | Discovery, ID token, UserInfo, JWKS |
| 08 | [Token lifecycle và introspection](docs/chapters/08-token-lifecycle-introspection.md) | Rotation/reuse và thu hồi trực tuyến |
| 09 | [SSO và tích hợp các hệ thống khác](docs/chapters/09-sso-integration.md) | Hai BFF + API dùng chung IAM |
| 10 | [MFA, recovery và quản lý khóa](docs/chapters/10-mfa-key-management.md) | Xác thực mạnh và rotation có kiểm chứng |
| 11 | [Authorization service](docs/chapters/11-authorization-service.md) | PDP/PEP và RBAC theo scope |
| 12 | [Messaging và Audit](docs/chapters/12-messaging-audit.md) | Outbox, RabbitMQ, inbox, retry/replay |
| 13 | [ABAC, guardrails và ReBAC](docs/chapters/13-advanced-authorization.md) | Giải thích và kiểm thử policy nâng cao |
| 14 | [Federation doanh nghiệp](docs/chapters/14-enterprise-federation.md) | External OIDC, SAML và linking an toàn |
| 15 | [SCIM và provisioning](docs/chapters/15-scim-provisioning.md) | User/group lifecycle qua owner API |
| 16 | [Governance và đặc quyền](docs/chapters/16-governance-privileged-access.md) | Approval, review, expiry, JIT và break-glass |
| 17 | [Workload identity và delegation](docs/chapters/17-workload-delegation.md) | Machine identity, assertion, exchange, native/CLI |
| 18 | [Docker Compose đến Kubernetes](docs/chapters/18-kubernetes.md) | TLS, probes, network, secrets và rollout |
| 19 | [CI/CD và thay đổi an toàn](docs/chapters/19-cicd.md) | Build, supply chain, GitOps và migration |
| 20 | [SRE và nghiệm thu production](docs/chapters/20-sre-production.md) | Load, failure drill, restore và release gate |

## Cách học và lưu bằng chứng

1. Đọc đầu chương để biết checkpoint cần có. Làm theo thứ tự, không bỏ qua kiểm thử âm tính.
2. Tạo code trong `lab/` theo đường dẫn chỉ định. Code block là nội dung để tự thực hiện; những đoạn ghi “trích đoạn” phải ghép vào module đã nêu.
3. Chạy lệnh từ root repository giáo trình (`iam-documents`, nơi có README), trừ khi bài yêu cầu chuyển thư mục. Lệnh local dùng PowerShell; Bash chỉ xuất hiện ở bước Linux/CI có nhãn rõ ràng.
4. So sánh kết quả với phần “kỳ vọng”. Kết quả minh họa trong sách không có nghĩa deployment của bạn đã đạt gate đó.
5. Lưu evidence đã loại secret trong `lab/evidence/chXX/`, đánh dấu Definition of Done và tạo commit cho checkpoint của mình.
6. Khi lỗi, dùng troubleshooting và failure lab để tìm nguyên nhân trước khi tiếp tục.

Các bản mẫu ID/URL thuộc môi trường lab. Secret, password, certificate và service credential phải sinh tại máy của bạn; không đưa chúng vào Git hoặc chat.

## Yêu cầu môi trường

Windows + PowerShell, Git, Node.js 24 LTS, pnpm, Docker Desktop Linux containers. Khuyến nghị RAM 16 GB để học core; 24–32 GB cho Kubernetes cùng observability. Dùng Compose profiles để không chạy mọi thành phần cùng lúc. Chương 03 có hướng dẫn cài và xác nhận; [bảng phiên bản](docs/reference/versions.md) khóa baseline.

Không cần tài khoản cloud để hoàn thành các bài local. Việc cấp máy chủ/domain production được thực hành ở P03–P04 cùng chương 18, sau khi có forecast, cấu hình và checklist cụ thể.

## Các tài liệu tra cứu

| Tài liệu | Dùng khi |
|---|---|
| [Ma trận 10 nhóm và learning path](docs/reference/delivery-coverage.md) | Biết học bước nào trước, artifact và gate nào phải chứng minh |
| [Project charter](docs/templates/project-charter.md) / [NFR register](docs/templates/nfr-register.csv) | Bắt đầu một hệ thống hoặc review yêu cầu |
| [Implementation map](docs/reference/implementation-map.md) | Kiểm tra tên file, bảng, port, fixture, helper và route chung |
| [Kiến trúc và luồng dữ liệu](docs/reference/architecture.md) | Hiểu bounded contexts và đường đi authentication/authorization |
| [Quyết định thiết kế](docs/reference/decisions.md) | Hiểu lý do và hệ quả của từng lựa chọn |
| [Threat model và security defaults](docs/reference/security-model.md) | Thiết kế/đánh giá abuse cases |
| [Ma trận năng lực cloud](docs/reference/cloud-capabilities.md) | Tra chức năng tương ứng và giới hạn tham chiếu |
| [Protocol support matrix](docs/reference/protocol-support.md) | Biết profile được triển khai, chuẩn và test tương ứng |
| [Authorization contract](docs/reference/authorization-contract.md) | Tích hợp policy service và owner commands |
| [Event contract](docs/reference/events.md) | Publish, consume, audit và replay |
| [Conformance](docs/reference/oidc-conformance.md) | Chạy kiểm thử tương tác chuẩn |
| [Runbook](docs/reference/runbooks.md) | Điều tra và phục hồi sự cố |
| [Production checklist](docs/reference/production-checklist.md) | Nghiệm thu trước phát hành |
| [Thuật ngữ](docs/reference/glossary.md) | Tra các thuật ngữ tiếng Anh |
| [Báo cáo kiểm tra giáo trình](docs/reference/validation-report.md) | Phân biệt phần đã kiểm chứng với bài cần người học chạy |

## Kiểm tra repository tài liệu

Các lệnh dưới đây kiểm tra **giáo trình**, không khởi động IAM:

```powershell
pnpm install --frozen-lockfile
pnpm check:docs
pnpm check:powershell
```

Checker xác nhận 20 chương IAM, 8 bài quy trình, liên kết local, code fence, JSON/YAML và cú pháp TypeScript có thể kiểm tra độc lập. Lệnh PowerShell chỉ parse các khối lệnh, không thực thi chúng; cần PowerShell CLI. Các kiểm chứng khác được ghi riêng trong báo cáo. Một checker tài liệu chạy thành công không thay cho protocol conformance, penetration test hoặc vận hành thực tế.

Nếu đã cài Terraform 1.13.5 theo P03, chạy thêm `pnpm check:hcl` để parse HCL bằng `terraform fmt -write=false` trên file tạm. Lệnh này không init provider, không plan/apply và không truy cập AWS.

## Các mốc hoàn thành

- **A — Nền tảng, chương 01–05:** identity model, app skeleton, database và account lifecycle.
- **B — Identity provider, chương 06–10:** Code Flow, OIDC, online token lifecycle, SSO và MFA.
- **C — Microservices IAM, chương 11–15:** policy, messaging, audit, federation và provisioning.
- **D — Enterprise và vận hành, chương 16–20:** governance, workload identity, Kubernetes và production gates.
- **E — Giao sản phẩm, P01–P08:** requirement → design → reviewed code → infrastructure → staging → canary/recovery → production verification → operations/cost/postmortem.

Mục tiêu cuối là nền tảng IAM có phạm vi hỗ trợ công bố rõ và bằng chứng kiểm chứng. Các mô hình cloud là tài liệu tham khảo nghiệp vụ; hệ thống tự xây có semantics và điều kiện phát hành của chính nó.
