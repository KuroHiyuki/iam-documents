# P07 — Trực vận hành, xử lý sự cố và kiểm soát chi phí

[Trang đầu](../../README.md) · [Trước: quan sát và phục hồi](06-observability-data-recovery.md) · [Runbooks](../reference/runbooks.md) · [Cổng production](../reference/production-checklist.md)

## 1. Chuyển từ “deploy được” sang “bàn giao được”

Điều kiện đầu vào: staging chạy bằng artifact đã kiểm chứng, dashboard/alert của P06 có dữ liệu, backup có biên bản restore, và chương19–20 đã có release/rollback drill. Bài này tạo hồ sơ vận hành để một người khác có thể tiếp quản hệ thống mà không cần bạn ngồi cạnh. Các thao tác cloud dưới đây là bài thực hành có giới hạn môi trường; tài liệu chưa tạo tài nguyên hoặc gửi thông báo cho ai.

Solution Architect chịu trách nhiệm diễn giải yêu cầu thành kiến trúc phù hợp, ghi rõ chi phí, rủi ro và phương án. DevOps/Platform biến thiết kế đó thành hạ tầng, pipeline, release và vận hành có thể tái lập. Application/Data/Security owners vẫn có trách nhiệm riêng; “DevOps lo production” không chuyển mọi bug, policy hay dữ liệu sang một người.

Tạo `lab/operations/ownership.md`, điền **tên người**, backup và thời gian trực thay cho vai trò trước release. RACI có R là người thực hiện, A là người chịu trách nhiệm cuối cùng, C là người được tham vấn, I là người cần biết. Mỗi công việc chỉ có một A; nhiều người có thể là R.

| Công việc | Product owner | Solution architect | App owner | Platform/DevOps | Data owner | Security owner |
|---|---|---|---|---|---|---|
| Mục tiêu kinh doanh/ngân sách | A/R | C | C | C | C | C |
| NFR, topology, ADR, tradeoff | C | A/R | C | R | C | C |
| OAuth/tenant correctness | I | C | A/R | C | C | R |
| IaC, CI/CD, release/rollback | I | C | R | A/R | C | C |
| Backup, PITR, failover/fencing | I | C | C | R | A/R | C |
| Credential compromise | I | C | R | R | C | A/R |
| Cost review/quota/cleanup | A | R | C | R | C | I |

Incident commander (IC) điều phối, không nhất thiết là người sửa code. Roster chỉ định IC cho mỗi ca và người thay thế; service owner vẫn quyết định kỹ thuật trong phạm vi của mình. Khi tự học một mình, ghi rõ bạn đang đội vai nào, đổi vai trong diễn tập; production cần reviewer độc lập cho security gates.

Tạo `lab/operations/service-catalog.yaml` bằng mẫu sau rồi mở rộng cho Authorization, Audit, Governance và data:

```yaml
services:
  identity:
    owner_team: iam-application
    oncall_rotation: iam-primary
    backup_rotation: platform-secondary
    dashboard_uid: iam-online-checks-v1
    runbook: docs/reference/runbooks.md#rb-01
    dependencies: [postgres-primary, redis, vault]
    critical_paths: [login, token-exchange, refresh, introspection]
    slo:
      protected_request_availability: 0.999
      window_days: 30
    recovery:
      security_acknowledged_mutation_rpo: zero_or_quarantine
      lab_business_rpo_minutes: 5
      lab_rto_minutes: 30
```

Không đặt số điện thoại, private URL, account secret hoặc mã recovery vào repository công khai. Contact directory và break-glass credentials nằm ở nơi người trực truy cập được **khi IAM này đang hỏng**. [Google SRE incident response](https://sre.google/workbook/incident-response/) là nguồn tham khảo cho phân vai và điều phối; các SLA thao tác dưới đây là mặc định học tập do giáo trình chọn.

## 2. Thiết lập trực và diễn tập một incident đến cùng

### 2.1. Severity và escalation

| Mức | Ví dụ IAM | Phản ứng ban đầu | Cập nhật |
|---|---|---|---|
| SEV0 | Nghi ngờ cross-tenant access, credential/key compromise diện rộng | Page security + IC; xác nhận trong5 phút; cô lập có kiểm soát | Bản cập nhật đầu≤15 phút, sau đó mỗi15 phút |
| SEV1 | Protected requests hợp lệ lỗi diện rộng; login hoặc introspection mất hoàn toàn | Page primary + platform/data owner; IC trong5 phút | Mỗi15 phút cho tới ổn định |
| SEV2 | Một tenant/flow suy giảm, còn đường phục vụ an toàn | Owner xác nhận≤30 phút trong ca hỗ trợ đã công bố | Mỗi60 phút hoặc khi đổi tác động |
| SEV3 | Capacity/chi phí lệch dự báo, certificate còn đủ thời gian, lỗi tài liệu | Ticket có owner/due date | Trong buổi triage kế tiếp |

Không tự hạ SEV vì health xanh. Một lỗi policy cho phép sai có thể là SEV0 dù100%HTTP200. Nếu primary không acknowledge sau5 phút, chuyển backup; sau10 phút IC/escalation owner tham gia. Đây là mục tiêu diễn tập, cần điều chỉnh theo khả năng nhân sự và hợp đồng hỗ trợ thực.

### 2.2. Timeline thao tác có bằng chứng

1. **Phát hiện:** ghi alert ID, onset ước lượng, detection time, service/tenant scope. Mở incident ID duy nhất, ví dụ `INC-20261029-LAB-01`.
2. **Phân vai:** IC giữ bảng tình hình, technical lead điều tra, scribe ghi timeline, communications owner soạn cập nhật. Tránh mọi người cùng chạy mutation.
3. **Định phạm vi:** xác minh synthetic hợp lệ,5xx/401/403, trace dependency và release gần nhất. Không yêu cầu user gửi access token cho người trực.
4. **Giảm tác động:** rollback digest tương thích schema hoặc khôi phục dependency theo runbook. Với mất certainty của security state, giữ maintenance/503, không bật cache allow.
5. **Phục hồi:** kiểm tra online revoke, tenant isolation, SSO hai app, dependency latency và audit backlog. Không chỉ gọi readiness một lần.
6. **Theo dõi:** quan sát ít nhất15 phút trong lab và đủ lưu lượng đại diện; đóng incident khi không còn tác động, chuyển việc còn lại thành issue có owner.

Lệnh đầu tiên là read-only; giữ context guard của runbook trước mutation:

```powershell
$ErrorActionPreference = 'Stop'
if ((kubectl config current-context) -ne 'kind-iam') { throw 'Sai cluster lab' }
$incidentId = 'INC-20261029-LAB-01'
New-Item -ItemType Directory -Force "lab/evidence/p07/$incidentId" | Out-Null
[DateTime]::UtcNow.ToString('o')
kubectl -n iam get deployment,pod,service,endpointslice
kubectl -n iam get events --sort-by=.metadata.creationTimestamp
kubectl -n iam rollout history deployment/identity
kubectl -n iam logs deployment/identity --since=10m --tail=100
```

Chỉ lưu log sau khi đã xác nhận redaction; `kubectl describe`/manifest có thể chứa env hoặc annotation nhạy cảm. Không upload toàn bộ support bundle lên issue công khai. Trace ID, operation ID, version và thời điểm thường đủ nối bằng chứng.

Diễn tập SEV1 trong kind: technical lead scale Identity về0 bằng RB-01; scribe giữ timestamp thao tác nhưng người trực chỉ biết alert. Người trực phải phát hiện qua synthetic/burn alert, phân biệt dependency503 với token401, giữ fail-closed, phục hồi2replica, xác minh token revoke vẫn inactive. Sau đó diễn tập trường hợp certificate CA sai; người trực phải sửa trust, không dùng skipTLS. Tính:

```text
MTTD = detection_time - incident_onset
Time to acknowledge = acknowledgement_time - detection_time
Time to mitigate = safe_service_restored_time - incident_onset
User impact = failed eligible requests, affected flows/tenants, interval
```

Tách thời điểm “đã rollback” với “đã an toàn phục vụ”. Nếu chưa kiểm chứng security reset sau restore, incident vẫn chưa phục hồi hoàn toàn.

### 2.3. Mẫu cập nhật và postmortem

Tạo draft cục bộ, không tự gửi email/chat/status page từ bài học này:

```text
Incident ID / severity / last update UTC:
Impact: flow nào, bắt đầu khi nào, phạm vi xác nhận được.
Current state: investigating | mitigating | monitoring | resolved.
What is known: bằng chứng có thể chia sẻ, không suy đoán nguyên nhân.
Mitigation: hành động đang thực hiện, khả năng người dùng vẫn sử dụng được.
Data/security: confirmed impact hoặc đang xác minh; không khẳng định vô căn cứ.
Next update UTC / communications owner:
```

Tạo postmortem trong2 ngày làm việc sau drill, review trong5ngày. Đây là lịch học đề nghị. Dùng [mô hình postmortem của Google SRE](https://sre.google/workbook/postmortem-culture/) để phân tích hệ thống và các điều kiện góp phần, không dừng ở “human error”. Phải trả lời tại sao guardrail cho phép hành động đó và alert nào phát hiện trễ.

```text
Title / incident link / author / reviewers / review date:
Summary and user impact:
Timeline UTC: onset, detection, ack, mitigation, validation, resolution.
Trigger:
Contributing conditions:
What worked / where detection or recovery failed:
Security invariants verified after recovery:
Evidence links, source SHA, artifact digest, schema version:

Action | Type(prevent/detect/recover) | Owner | Due date | Verification test
Pin TLS CA mount and validate SAN | prevent | platform-owner | YYYY-MM-DD | fresh rollout+negative CA test
Add authenticated synthetic      | detect  | app-owner      | YYYY-MM-DD | injected401 pages within target
Automate isolated restore check  | recover | data-owner     | YYYY-MM-DD | old credential remains blocked
```

“Nhắc mọi người cẩn thận” không đủ làm action; action đóng khi test có bằng chứng, không phải khi merge code. IC theo dõi overdue/exception expiry trong buổi vận hành hằng tuần.

## 3. Lịch bảo trì, patch và onboarding

Tạo `lab/operations/calendar.md`; mỗi hàng có owner, lần chạy trước, lần tới, evidence và escalation. Lịch dưới đây là baseline học tập, không giả định mọi hệ thống cần đúng chu kỳ đó.

| Nhịp | Công việc | Bằng chứng hoàn thành |
|---|---|---|
| Mỗi ca/hằng ngày | Synthetic SSO/revoke; burn rate; backup age/WAL; audit lag; thay đổi bất thường; budget anomaly | Dashboard query + backup metadata + change IDs |
| Hằng tuần | CVE/dependency/container scan triage; pool/storage/capacity; dead letters; overdue incident actions | Issue owner/due/risk; capacity trend |
| Hằng tháng | Restore/PITR vào clone; secret/certificate expiry inventory; access review on-call/cloud; cost allocation | RTO/RPO report, negative security tests, cost report |
| Theo đợt thay đổi | Key rotation, patch rollout, Kubernetes minor upgrade, policy migration | Staging evidence, canary, rollback drill, compatibility record |
| Hằng quý | Failover/fencing và DR exercise; break-glass; threat model; review SLO/ngân sách | Ack revoke preserved hoặc quarantine; signed recovery report |

Patch theo rủi ro: critical actively exploited được triage ngay trong ca; đặt mục tiêu sửa24h nếu phù hợp tác động, high trong7ngày là mặc định của lab. Nếu không đạt phải có risk owner, mitigation và expiry; không để bot tự nâng tất cả package production ngoài review. Tra advisory nhà cung cấp, tái tạo artifact/SBOM, chạy protocol/tenant tests, promote cùng digest qua staging rồi production; không SSH vào pod để `npm update`.

Certificate inventory gồm certificate name, DNS/SAN, issuer, owner, renewal method, expiry và ứng dụng có cần reload/restart. cert-manager status Ready không tự chứng minh backend đã load chứng chỉ mới. Lab rotate certificate, restart theo cơ chế ứng dụng, gọi qua Gateway bằng trust đúng, kiểm tra serial/expiry mà không đọc private key. [cert-manager renewal behavior](https://cert-manager.io/docs/usage/certificate/) là nguồn để xác định khi nào controller thay secret.

```powershell
kubectl -n iam get certificates -o custom-columns='NAME:.metadata.name,READY:.status.conditions[0].status,EXPIRES:.status.notAfter'
kubectl -n monitoring get certificates -o custom-columns='NAME:.metadata.name,EXPIRES:.status.notAfter'
kubectl -n iam get pods -o wide
# Xem công khai certificate; không export tls.key.
openssl s_client -connect iam.local.test:8443 -servername iam.local.test `
  -CAfile lab/.secrets/kind-ca.crt -verify_return_error
```

Secret rotation có prepare → deploy trust/credential mới → verify caller → retire cũ → negative test → audit. Thay client secret theo khả năng chuyển đổi an toàn đã công bố; credential compromise không chờ overlap thông thường. Signing key dùng RB-04; rotate key ký không tự revoke opaque token. Không đặt backup decrypt key cùng repository backup, không phụ thuộc login IAM đang sửa để lấy recovery credential.

Onboarding người vận hành mới là bài kiểm chứng tài liệu:

1. Máy sạch checkout đúng tag, cài toolchain theo inventory, nhận quyền tối thiểu qua quy trình riêng.
2. Tự chạy profile local, giải thích issuer/tenant/token audience và trace một protected request.
3. Tự đọc alert/runbook, phân biệt401/403/503; tái hiện lỗi trong kind mà không xem credential của người khác.
4. Tự restore clone và chứng minh token/password trước restore không sống lại; chỉ có read access trên production trước khi đạt drill.
5. Shadow một ca, reverse-shadow một ca; service owner ký quyền trực và xác nhận recovery access hoạt động ngoài IAM.

Nếu người mới cần hỏi tác giả lệnh nào mới đúng thì ghi lại khoảng trống, cập nhật tài liệu và chạy lại. Số câu hỏi chưa giải quyết là tín hiệu chất lượng handoff, không phải lỗi cá nhân người học.

## 4. Tính chi phí từ topology và usage

### 4.1. Tag và dự toán có nguồn

Chọn region thực hành `ap-southeast-1` (Singapore), tài khoản sandbox riêng và USD. Không dùng ví dụ giá của Ohio để tính Singapore. Bảng giá kiểm tra ngày29/10/2026: [EKS pricing](https://aws.amazon.com/eks/pricing/), [EC2 On-Demand/data transfer](https://aws.amazon.com/ec2/pricing/on-demand/), [VPC/NAT/public IPv4](https://aws.amazon.com/vpc/pricing/), [RDS PostgreSQL](https://aws.amazon.com/rds/postgresql/pricing/), [EBS](https://aws.amazon.com/ebs/pricing/), [S3](https://aws.amazon.com/s3/pricing/), [ELB](https://aws.amazon.com/elasticloadbalancing/pricing/). Lưu lựa chọn region/type và export estimate từ [AWS Pricing Calculator](https://calculator.aws/) vào evidence; bảng giá động chưa render được thì để `pending`, không tự điền số.

EKS standard support có control-plane fee công khai0,10USD/cluster-hour;730giờ tương ứng73USD trước workers, storage và mạng. Đây là ví dụ nhân đơn giá, không phải tổng giá hệ thống. Extended support có phí khác; inventory phải có upgrade calendar. RDS Multi-AZ, CPU credit, storage/IOPS, backup và snapshot retention có dòng chi phí riêng; không lấy giá một Single-AZ instance rồi gọi là giá HA.

Tags bắt buộc `Project=iam-learning`, `Environment=dev|staging|prod`, `Owner`, `CostCenter`, `ManagedBy=terraform` theo P03; thêm `Purpose=cloud-lab` và `ExpiresAt` cho lab. Kubernetes labels tương ứng giúp phân bổ bên trong cluster, nhưng không tự thành AWS cost allocation tags. Kích hoạt user-defined cost tags trong billing và chờ dữ liệu xuất hiện theo [AWS cost allocation tags](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/activating-tags.html). Đừng đặt email/user/tenant ID vào label cloud công khai; dùng owner team identifier.

```text
C_month =
  cluster_hours * eks_standard_hour
  + sum(node_hours_by_type * ec2_hour_by_type)
  + nat_gateway_hours * nat_hour_region + nat_processed_GB * nat_GB_region
  + rds_hours * rds_hour_selected_deployment
  + rds_storage_GBmonth * storage_rate + extra_IOPS/throughput + CPU_credits
  + ebs_GBmonth + load_balancer_hours + LCU/NLCU_usage
  + internet_egress_GB * tiered_egress_rate + cross_AZ_transfer
  + backup_GBmonth + object_requests + KMS_requests + retained_snapshots
  + public_IP_hours + telemetry_ingest/storage/query + DNS + support/tax
```

Không đếm double Multi-AZ nếu calculator đã bao gồm cả deployment; lưu rõ quantity semantics.730giờ chỉ dùng dự toán tháng trung bình, invoice thực theo usage. Kết nối online tạo fan-out và cross-AZ traffic; đo requests/hops, bytes và latency rồi tối ưu topology/pool. VPC endpoint có thể tránh một số NAT traffic nhưng interface endpoint có phí; so cả hai phương án bằng usage thật. Công thức là mô hình của giáo trình, không báo giá nhà cung cấp.

Tạo `lab/operations/cost-estimate.csv` với cột `service,region,configuration,quantity,unit,unit_price,currency,source_url,checked_date,monthly_estimate,owner`. Chọn ba scenario: local tiết kiệm, cloud-lab8giờ, production Multi-AZ730giờ. Thêm contingency20% làm giả định dự toán, tách khỏi giá nhà cung cấp. Báo cả USD/tháng và USD/triệu protected requests; không chia chi phí tháng dự toán cho benchmark vài phút rồi gọi là unit economics thực tế.

### 4.2. Budget alert không phải hard cap

Đặt actual thresholds50/80/100% và forecast100% cho ngân sách sandbox đã chọn; owner nhận alert phải có quyền xem hóa đơn và dừng tài nguyên lab. AWS Budgets có độ trễ cập nhật, nên alert không bảo đảm chặn chi tiêu ngay. [AWS Budgets behavior](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html).

P03 đã tạo budget ở bootstrap; điều chỉnh budget đó thay vì tạo hai budget trùng ý nghĩa. Tạo draft JSON local để review giá trị mới, ví dụ cho **tài khoản chỉ chứa sandbox**.50USD là ngân sách học do bạn lựa chọn, không dự báo giá chạy toàn stack:

```json
{
  "BudgetName": "iam-sandbox-monthly",
  "BudgetLimit": {"Amount": "50", "Unit": "USD"},
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST",
  "CostFilters": {},
  "CostTypes": {"IncludeTax": true, "IncludeSupport": true}
}
```

Xác minh account bằng `aws sts get-caller-identity`, dùng Billing console chọn các notification threshold/recipient của chính bạn rồi review trước tạo. Trong tutorial không gửi test notification tới người khác. Production dùng scope/account đúng và approval của budget owner; không áp IAM deny hoặc auto-stop database production chỉ vì budget vừa vượt. Budget action cần thiết kế recovery và exclusions, không đồng nghĩa hard cap tài chính.

Mỗi tuần so estimate với actual amortized/unblended theo cùng định nghĩa; tách shared platform, production và lab, lưu chênh lệch có nguyên nhân. Alert anomaly phải dẫn tới inventory tài nguyên/usage, không chỉ giảm log retention trong khi vẫn để NAT/cluster không dùng chạy suốt tháng.

## 5. Bài cloud lab một ngày và teardown có kiểm chứng

Cloud-lab dùng **root dev của P03 trong tài khoản dev sandbox dành riêng để hủy sau buổi học**; đây không phải dev đang được nhóm khác dùng. Giữ `environment=dev` đúng validation P03, backend key `infrastructure/dev/terraform.tfstate`, account guard và tag canonical. Không copy credentials/state production. Nếu dev là shared/live, tạo sandbox account/root riêng theo cùng module trước khi học teardown. Đặt `ExpiresAt` tám giờ sau khi bắt đầu, chặn lịch họp ở mốc dọn dẹp và đặt hai nhắc việc cục bộ trước mốc30/10phút. TTL tag không tự xóa tài nguyên. Giới hạn node count, database size, telemetry retention và quota; budget alert không thay thời hạn lab.

| Giờ từ khi bắt đầu | Công việc | Điều kiện chuyển bước |
|---|---|---|
| 0–1 | Verify sandbox/region/state, estimate8giờ, tạo inventory | Account/plan đúng; credential và recovery access có kiểm chứng |
| 1–3 | Apply hạ tầng, deploy digest đã qua staging | Không có public DB/metrics; readiness/online checks pass |
| 3–5 | Load nhỏ, xem traces, rollback drill | Không bypass auth; có request/status evidence |
| 5–6 | Backup/restore clone hoặc xác minh managed PITR | Clone cô lập; security reset tests pass |
| 6–7 | Export evidence không chứa secret, đóng traffic lab | Snapshot/key retention đã quyết định và ghi chi phí |
| 7–8 | Cleanup theo dependency, kiểm tra tài nguyên sót | Không còn tài nguyên chạy ngoài danh sách retention |

Lệnh mở đầu PowerShell phải dùng profile, account ID và region ghi trong lab record, không suy ra từ default profile:

```powershell
$env:AWS_PROFILE = 'iam-sandbox'
$env:AWS_REGION = 'ap-southeast-1'
if (-not $env:IAM_SANDBOX_ACCOUNT_ID) { throw 'Chưa cấu hình account ID sandbox ngoài Git' }
$caller = aws sts get-caller-identity --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $caller.Account -ne $env:IAM_SANDBOX_ACCOUNT_ID) {
  throw 'Sai AWS account; dừng cloud lab'
}
terraform -chdir=lab/infra/terraform/environments/dev workspace show
terraform -chdir=lab/infra/terraform/environments/dev state list
aws resourcegroupstaggingapi get-resources `
  --tag-filters Key=Project,Values=iam-learning Key=Environment,Values=dev --output json
```

Đường dẫn Terraform là root `environments/dev` của P03; chỉ chạy khi account/state đó được ghi là disposable sandbox trong lab record. Xác nhận backend bucket/key và đối chiếu state list với inventory trước thao tác; workspace name không tạo account isolation. State list không chứa secret values; không lưu `terraform show -json` nguyên bản vì plan/state có thể chứa sensitive data.

Teardown theo thứ tự, ghi nhận từng nhóm:

1. Chặn traffic và dừng CronJobs/workers/GitOps reconciliation của **lab**. Nếu Argo còn tự sync, nó có thể tạo tài nguyên trở lại.
2. Export evidence, chốt snapshot/backup nào giữ, thời hạn và người trả phí. Backup giữ lại cần decrypt key và quyền recovery; snapshot không có key sử dụng được không đạt mục tiêu.
3. Xóa app/Gateway/Ingress/Service LoadBalancer để cloud controller giải phóng LB/target group/ENI trước khi cluster biến mất. Đợi cloud API xác nhận, không chỉ Kubernetes object đã xóa.
4. Bỏ clone restore và data lab theo plan; xử lý deletion protection và final snapshot một cách có chủ đích. Không tắt protection trên resource không có lab tag.
5. Review Terraform destroy plan cho **dev sandbox state**: node groups/cluster, NAT/routes, endpoints, subnets/network và tài nguyên phụ. Mỗi resource address phải khớp inventory; ARN ngoài sandbox là điều kiện dừng.
6. Sau apply, kiểm tra resource APIs vì tagging API không bao phủ mọi resource. Chốt EIP, unattached EBS, LB, NAT, snapshots, log groups, KMS key và object storage còn giữ; ghi owner/expiry/chi phí từng item.

```powershell
# Chỉ sau guard account ở trên, dev sandbox state đã đối chiếu và review retention.
terraform -chdir=lab/infra/terraform/environments/dev plan -destroy `
  -out=destroy-reviewed.tfplan
if ($LASTEXITCODE -ne 0) { throw 'Không có destroy plan hợp lệ' }
terraform -chdir=lab/infra/terraform/environments/dev show destroy-reviewed.tfplan
# Review trực tiếp; plan có thể chứa dữ liệu nhạy cảm, không upload công khai.
# Khi inventory và review đã hoàn tất mới chạy:
terraform -chdir=lab/infra/terraform/environments/dev apply destroy-reviewed.tfplan
if ($LASTEXITCODE -ne 0) { throw 'Cleanup chưa hoàn tất; giữ theo dõi chi phí' }
aws eks list-clusters
aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier'
aws ec2 describe-nat-gateways --filter Name=state,Values=available,pending
aws ec2 describe-volumes --filters Name=status,Values=available
aws ec2 describe-addresses
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerArn'
```

Các lệnh inventory trả cả sandbox account; **không** pipe danh sách sang lệnh delete hàng loạt. Phân biệt tài nguyên shared, retained và owned trước cleanup. Destroy plan là file nhạy cảm cục bộ; xóa theo custody sau khi đối soát. Không dùng một lệnh `terraform destroy -auto-approve` làm quy trình đóng cloud lab. [Terraform plan destroy mode](https://developer.hashicorp.com/terraform/cli/commands/plan#planning-modes), [EKS deletion prerequisites](https://docs.aws.amazon.com/eks/latest/userguide/delete-cluster.html).

Ngày kế tiếp kiểm tra Billing/Cost Explorer khi dữ liệu usage cập nhật; tài nguyên còn giữ được ghi vào `retained-resources.csv`. Đóng lab khi mọi item có trạng thái `deleted` hoặc `retained-with-owner-and-expiry`; hóa đơn về0 ngay lập tức không phải điều kiện khả thi do billing latency.

## 6. Review kiến trúc, lỗi thường gặp và nghiệm thu

Một cuộc cost/SLO review phải đưa ra lựa chọn có bằng chứng. Ví dụ: giảm từ multi-AZ xuống một máy làm chi phí giảm nhưng mất failure domain; phù hợp cloud lab, không tự đáp ứng production99,9%. Giảm trace sampling/retention có thể giảm storage mà giữ kiểm tra online; dùng cached allow để giảm chi phí làm thay đổi contract bảo mật đã chốt nên không được thực hiện. Managed RDS giảm công việc database nhưng vẫn cần restore test, security reconciliation và người chịu trách nhiệm.

Solution architect viết ADR so sánh ít nhất hai phương án theo availability, latency, RPO/RTO, security, monthly cost và công sức trực. Platform cung cấp số đo/cách triển khai/rollback, app owner xác nhận protocol và tenant invariant, data owner xác nhận durability, budget owner chấp nhận chi phí. ADR ghi assumptions và điều kiện xem xét lại, ví dụ tải vượt ngưỡng hoặc ngân sách lệch20% hai tháng liên tiếp.

| Lỗi gặp khi thực hành | Chẩn đoán và cách sửa |
|---|---|
| Có alert firing nhưng không ai biết | Route/roster chưa thử; diễn tập acknowledge/escalation và lưu timestamp |
| Dashboard xanh nhưng login sai401 | Synthetic thiếu valid credential/expectation; kiểm tra response semantics |
| Rollback xong vẫn lỗi | Kiểm tra digest, schema, secret/cert, dependency; không rollback database snapshot tùy tiện |
| Restore nhanh nhưng chưa mở được app | RTO thiếu credential/policy reconciliation; đo toàn chuỗi rồi cập nhật mục tiêu |
| Cloud lab tắt pod mà vẫn mất tiền | Control plane/NAT/LB/storage/snapshots vẫn chạy; kiểm kê API từng loại |
| Budget không gửi kịp | Billing/notification có độ trễ; dùng TTL process/quota và nhắc cleanup độc lập |
| Người mới cần quyền admin mọi thứ | Tách read-only investigation, scoped mutation và break-glass có audit |

Lưu evidence trong `lab/evidence/p07/`: ownership/roster đã điền, incident timeline, draft update, postmortem, action verification, patch/certificate drill, estimate với nguồn/date, actual comparison, destroy-plan review và resource inventory sau cleanup. Trước chia sẻ loại bỏ account credentials, private addresses và dữ liệu người dùng. Không ghi “đã nhận page/đã restore/đã dọn cloud” từ output minh họa.

- [ ] Mỗi service/alert/budget có owner chính, backup và recovery access độc lập IAM.
- [ ] Drill từ alert tới mitigation, security verification, communication draft và postmortem hoàn tất.
- [ ] Action có owner, due date, verification test; lịch patch/cert/secret/restore đang được theo dõi.
- [ ] Người mới tái hiện bootstrap, incident và recovery dựa trên tài liệu.
- [ ] Dự toán có region/unit/source/date; actual và retention cost được đối chiếu.
- [ ] Cloud lab đúng sandbox/state, teardown có review và tài nguyên còn giữ có owner/expiry.
- [ ] Checkpoint `p07-operations-and-cost`; mang evidence vào [production checklist](../reference/production-checklist.md), không xem việc đọc hết bài là production sign-off.
