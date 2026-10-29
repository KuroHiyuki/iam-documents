# P01 — Từ ý tưởng đến yêu cầu và thiết kế có thể nghiệm thu

[Lộ trình toàn vòng đời](../reference/delivery-coverage.md) · [Tiếp: Git và security workflow](02-git-security-workflow.md) · [Kiến trúc IAM](../reference/architecture.md)

## 1. Mục tiêu và điều kiện đầu vào

Đây là bài bắt đầu của tuyến Solution Architect + DevOps, trước khi viết code chức năng. Đọc chương IAM [01](../chapters/01-domain-overview.md) để biết principal, organization và ranh giới service. Bạn chưa cần cloud account. Kết quả là một bộ yêu cầu có mã, các lựa chọn có lý do, cost/risk register và plan kiểm chứng. Việc chọn Kubernetes chỉ diễn ra sau yêu cầu; deployment xanh chưa phải dấu hiệu thiết kế phù hợp.

Các ví dụ là sản phẩm giả định phục vụ học. Target trong bài không phải cam kết với khách hàng thật. Bạn dùng nhiều vai trò khi tự học; khi production cần reviewer/owner độc lập cho các quyết định nhạy cảm.

## 2. Discovery: hỏi câu hỏi dẫn đến thiết kế

Giả sử Acme và Beta thuê Web A/Web B. Product owner muốn chung login, thu hồi quyền ngay khi nhân viên nghỉ, SSO doanh nghiệp và mở API cho service khác. Trước khi chọn database/broker, ghi các câu trả lời:

| Câu hỏi | Default của case study | Hệ quả thiết kế |
|---|---|---|
| Ai dùng, ai quản trị? | User, org admin, operator, workload, approver | Tách quyền platform/org/business |
| Một người thuộc nhiều tổ chức? | Có | Global account + membership riêng |
| API chấp nhận token tới lúc hết hạn sau revoke? | Không; check tiếp theo sau commit phải thấy revoke | Opaque token + online introspection, primary durability |
| Nếu IAM lỗi có cho qua? | Không | Protected API trả 503, capacity/SLO tính dependency |
| Ứng dụng tích hợp nào trước? | Hai BFF + Invoice API + machine caller | OIDC Code/PKCE + client credentials |
| Quy mô cần chứng minh? | Dataset và workload NFR bên dưới | Seed/load test đúng đường auth |
| Ai được chấp nhận rủi ro/cost? | Product/release owner được chỉ định | Có approval/evidence, không tự giảm yêu cầu để pass |
| Phải triển khai ở đâu? | Local trước, AWS reference cho cloud | Core không phụ thuộc AWS APIs |

Nếu chưa biết câu trả lời, ghi `assumption`, owner và thời hạn xác nhận. Không biến giả định thành fact. Ví dụ nhu cầu “thu hồi ngay” phải được chuyển thành ranh giới đo được: các check bắt đầu sau commit thấy inactive; request đã được cho phép trước đó có thể hoàn tất.

## 3. Viết yêu cầu chức năng có acceptance

Dùng `Given / When / Then`, chỉ rõ actor, resource, tenant, effect và lỗi. Một requirement nên test được độc lập.

| ID | Yêu cầu | Acceptance tối thiểu |
|---|---|---|
| FR-01 | Central login/SSO cho hai app | Web A login, Web B dùng lại IAM session khi policy cho phép, app sessions riêng |
| FR-02 | Một account, nhiều org | Alice ở Acme/Beta; token Acme không đọc object Beta |
| FR-03 | Phân quyền resource | Scope hợp lệ nhưng thiếu role/constraint vẫn deny |
| FR-04 | Online revocation | Suspend membership/phiên rồi check mới inactive; không chờ event/cache |
| FR-05 | Account recovery/MFA | Challenge one-time, reset không bỏ MFA hoặc corporate SSO |
| FR-06 | Workload identity | Client credentials riêng, audience/scope/org bind server-side |
| FR-07 | Enterprise lifecycle | SCIM deprovision Acme không khóa global user ở Beta |
| FR-08 | Audit bền vững | Mutation commit tạo outbox; broker retry không mất/nhân đôi hiệu ứng audit |

Ví dụ ticket đầu tiên:

```text
ID: FR-04 / ticket IAM-104
Actor: organization admin Acme
Action: suspend membership Alice/Acme
Given: Alice có session/grant active cho Acme và Beta
When: owner mutation trả success sau commit tại thời điểm C
Then: mọi introspection bắt đầu sau C cho token Acme trả active:false
And: token Beta được xét theo trạng thái Beta, không bị revoke nhầm
And: audit event có actor, org, operation ID; không có raw token
Failure: Identity DB unavailable -> 503, không success giả
Evidence: mutation log/barrier + request timestamps + DB side effects đã redact
```

Đây là ranh giới business → implementation → test. “Có endpoint suspend” chưa đủ nếu handler update nhầm global account hoặc ACK trước commit.

## 4. NFR: viết số đo, phạm vi và phương pháp

Tạo NFR register từ [mẫu CSV](../templates/nfr-register.csv). Các số sau là default học, phải review bằng kết quả thực:

| ID | Target và phạm vi | Đo/kiểm chứng |
|---|---|---|
| NFR-01 | 99,9% valid protected requests thành công trong cửa sổ 30 ngày | SLI edge + synthetic valid login/API; không loại mọi 401 để giấu lỗi |
| NFR-02 | 100 RPS 15 phút; introspection p95≤50 ms, API có live policy p95≤150 ms | k6 trên dataset 10k users/100 org/20k memberships; giữ raw results |
| NFR-03 | Acknowledged security mutations không mất qua failover, hoặc quarantine | Revoke→barrier→promote→check, synchronous durability/fencing |
| NFR-04 | Disaster backup target RPO≤5 phút, RTO≤60 phút cho data profile | PITR vào môi trường cô lập, đo mốc backup/recovery/open-traffic riêng |
| NFR-05 | Không có single app pod là điểm lỗi; failure domains thực cho production | Kill replica, node/zone drill; kind chỉ mô phỏng process/node |
| NFR-06 | Resource cost có forecast/owner/expiry trước apply | Calculator + Terraform inventory + budget alert + cleanup evidence |
| NFR-07 | Secrets/PII không xuất vào Git/log/metric; TLS kiểm chứng hai đầu | Gitleaks, redaction tests, packet/TLS checks và access review |
| NFR-08 | Mỗi critical alert có owner/runbook; đã diễn tập restore/rollback | Game day, incident timeline, postmortem/action tracking |

NFR-03 và NFR-04 khác nhau. Backup có thể mất vài phút dữ liệu, nhưng mở traffic với một session đã revoke “sống lại” là lỗi bảo mật. Recovery phải invalidate/reconcile security state trước mở traffic; không dùng target RPO backup để hợp thức hóa stale authorization.

**Request-based availability:** số request tốt / request hợp lệ trong window. `43 phút 12 giây/30 ngày` chỉ là cách quy đổi **time-based** 99,9%; không lấy số phút đó làm chính xác error budget của request-based SLI. Các 401/403 đúng chính sách không là lỗi dịch vụ; synthetic credential hợp lệ phát hiện việc app vô tình trả 401 cho tất cả user.

## 5. Capacity và availability trước khi sizing

Vẽ đường đi từ [architecture](../reference/architecture.md): API introspect user → PDP introspect caller và subject → current policy. Ví dụ workload 100 external RPS có thể tạo khoảng 300 introspections/s, chưa có refresh/admin/fan-out. Đây là phép tính topology, không kết quả benchmark.

```text
introspection_RPS = Σ(request_RPS_for_path × introspection_calls_on_that_path)
DB_connections_max = Σ(replicas_i × pool_max_i) + workers + migration + operator_margin
KDF_RAM ≈ concurrent_password_jobs × configured_memory_cost
```

Ví dụ ba service phụ thuộc nối tiếp, mỗi service đạt 99,9% và giả sử lỗi độc lập, availability đường đi xấp xỉ `0,999^3 = 99,7003%`. Đây là mô hình sơ bộ; common-cause failures, retry và synthetic behavior có thể khác. Không nhân các SLA marketing rồi tuyên bố end-to-end đạt target. Đo toàn đường và phân bổ budget cho dependency.

Chốt deadline tổng, concurrency/pool và retry policy trước HPA. Tăng replicas có thể làm cạn DB connections nhanh hơn, không tự tăng throughput. Tách workload login KDF, introspection, policy và async queue để biết bottleneck nào cần scale.

## 6. Chọn phương án bằng trade-off

| Quyết định | Phương án đã chọn | Lợi ích | Giá phải trả / khi xem lại |
|---|---|---|---|
| Token | Opaque + check mọi request | Revocation contract rõ | IAM/DB hot path, outage fail closed |
| Service boundary | Identity atomic, tách Policy/Audit/Governance dần | Ít distributed transaction ở protocol | Identity có nhiều module; cần profiling và ownership |
| DB | PostgreSQL, SQL/transactions | Lock/constraint/durability kiểm chứng được | HA/backup/pool cần vận hành |
| Messaging | Outbox + RabbitMQ | Mutation/event không bị xé | Duplicate/replay/DLQ và broker cost |
| Platform | Compose → kind → Kubernetes | Học local trước, deployment chuẩn hóa | Kubernetes operational overhead |
| Cloud reference | AWS một region, ≥2 AZ cho profile production | Có bài VPC/EKS/RDS cụ thể | Chi phí EKS/NAT/RDS; cloud account không cần cho local |

Chấm điểm tùy mục tiêu có trọng số (correctness/security trước convenience). Đừng tạo ma trận sau khi đã chọn công nghệ chỉ để biện minh. Lưu alternatives bị loại và trigger xem lại trong ADR; [ADR hiện có](../reference/decisions.md) là baseline của case study.

## 7. Architecture package để review

Tạo các file dưới `lab/docs/design/` khi đã có workspace chương 03:

```powershell
New-Item -ItemType Directory -Force lab/docs/design,lab/evidence/delivery/p01 | Out-Null
Copy-Item docs/templates/project-charter.md lab/docs/design/charter.md
Copy-Item docs/templates/nfr-register.csv lab/docs/design/nfr-register.csv
```

Điền charter với references đến FR/NFR, sơ đồ context/container, data ownership và sequence. Tối thiểu có:

- Data classification: password/keys/token secrets; email/user IDs PII; invoice business confidential; metric aggregate.
- Trust model: browser untrusted, BFF/resource/PDP có credential riêng; issuer/key endpoints admin-registered; operator recovery độc lập chính IAM.
- Topology local/staging/prod, DNS/issuer, backup location, failure domains và external dependencies.
- Forecast theo component và thời gian chạy; lab cloud timebox, production capacity, owner trả chi phí.
- Risk register: likelihood/impact, mitigation, owner, remaining risk và ngày review.
- Acceptance/test strategy, release gate, rollout/rollback và cách hủy môi trường lab.

Một risk record mẫu:

```text
Risk R-03: async DB promotion mất acknowledged revoke
Impact: token đã thu hồi active trở lại -> security breach
Mitigation: synchronous replication/fencing; recovery quarantine; failover drill
Evidence: NFR-03 test; runbook recovery approval
Owner: Data owner + Identity owner
Residual risk: multi-region disaster restore cần invalidate/reconcile riêng
Status: pending verification; chưa được coi là accepted vì chỉ có sơ đồ
```

## 8. Review kiến trúc và quyết định đi tiếp

Thực hiện một phiên review với bốn câu hỏi cho từng đường dữ liệu: ai gọi, ai tin dữ liệu gì, khi dependency lỗi làm gì, ai chịu chi phí/khôi phục. Người học tự ghi bốn góc nhìn:

- **Solution Architect:** yêu cầu đo được chưa; lựa chọn có phù hợp cost/risk/constraints; data/trust/compatibility rõ chưa?
- **Developer:** module/interface/transaction nào phải viết; business invariants nằm đâu?
- **DevOps/Platform:** hạ tầng nào tái tạo được; secrets/deployment/rollback/observability/runbook ra sao?
- **SRE/Security/Data owner:** chứng minh độ tin cậy, recovery, threat model và security gates như thế nào?

Các vai trò cộng tác, không bàn giao kiểu “architect vẽ xong hết trách nhiệm”. Một ADR đổi revocation policy phải có product/security review và sửa load/SLO/runbook tương ứng.

Output review là `accepted`, `changes_required` hoặc `accepted_with_time_bounded_exception`. Chưa có người review độc lập thì ghi `self_reviewed_lab`; không giả sign-off doanh nghiệp.

## 9. Kiểm thử thiết kế và failure lab

Chạy tabletop (không cần cloud):

1. Identity unavailable: app trả 503; ai bị ảnh hưởng; budget có tính hop này không?
2. Zone mất: app replica còn sống nhưng DB primary ở đó thì sao? NAT/LB/egress có phụ thuộc một AZ không?
3. RDS restore về 10 phút trước: làm sao token và privilege đã revoke không active trở lại?
4. Tải 100→500 RPS: pool ceiling/KDF/queue là gì, khi nào reject thay vì OOM?
5. Cost forecast vượt lab budget: giữ local, giảm thời gian hoặc đổi profile; không gọi single-AZ là multi-AZ để báo đạt.

Sửa sơ đồ/NFR/ADR sau mỗi phát hiện. Đây là bằng chứng review, không bằng chứng runtime. Negative test thật được viết dần ở core 04–20 và P06/P08.

## 10. Troubleshooting và Definition of Done

| Vấn đề | Sửa |
|---|---|
| “Nhanh, an toàn, scale tốt” | Thêm metric, workload, window, expected behavior và owner |
| Chỉ có sơ đồ service | Thêm data/trust/sequence và failure paths |
| Có RPO/RTO nhưng chưa restore | Giữ pending; thêm drill và đồng hồ đo |
| NFR mâu thuẫn ngân sách | Đổi scope/target qua review hoặc đổi phương án; ghi trade-off |
| Mọi quyết định thuộc một người không rõ vai | Ghi role/RACI và self-review limitation |

- [ ] FR/NFR có ID, target, test/evidence và owner.
- [ ] Có context/container/sequence, tenant/data ownership và threat boundaries.
- [ ] Có capacity/cost assumptions và alternatives/ADR.
- [ ] RPO security failover khác backup disaster profile.
- [ ] Tabletop ghi được action, risk owner và gate đi tiếp.
- [ ] Có charter/NFR register; tiếp tục P02 và core 02–05.

Nguồn: [AWS Well-Architected](https://docs.aws.amazon.com/wellarchitected/latest/framework/welcome.html), [Google SRE: implementing SLOs](https://sre.google/workbook/implementing-slos/), [Google SRE: large system design](https://sre.google/workbook/non-abstract-design/), [OWASP threat modeling](https://owasp.org/www-community/Threat_Modeling).
