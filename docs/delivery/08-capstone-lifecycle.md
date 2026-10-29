# P08 — Capstone: đưa một thay đổi IAM từ yêu cầu đến vận hành

[Lộ trình và 10 nhóm](../reference/delivery-coverage.md) · [P07: vận hành/chi phí](07-operations-cost.md) · [Production gates](../reference/production-checklist.md)

## 1. Mục tiêu và điều kiện đầu vào

Đã hoàn thành core 01–20 và đọc P01–P07. Có hai app BFF, Invoice API, Identity/Policy và môi trường local/staging chạy đúng contract. Capstone lặp toàn vòng đời bằng **một thay đổi có thể quan sát**. Bạn có thể làm toàn bộ bằng kind/local Git; những bước cần cloud/reviewer độc lập phải ghi đúng limitation, không điền passed giả.

Thay đổi mẫu `IAM-208`: Acme chỉ cho approve invoice có số tiền trong hạn mức đã cấp và authentication evidence đáp ứng recent MFA. Resource owner cung cấp `amount_cents`, `status`, `owner_id`; browser không tự chọn trusted attributes. Luồng cũ đọc invoice vẫn hoạt động, organization Beta không bị đổi policy nhầm.

Để dùng đúng canary Identity ở P05, **code delta của capstone nằm trong Identity**: introspection trả `mfa_time` từ `sessions.mfa_at` hiện hành; refresh giữ nguyên authentication evidence thực, không tự làm mới `auth_time`/`mfa_time`. Evaluator/AST đã được chuẩn bị bằng core 13, còn hạn mức/recent-MFA là policy config versioned bật sau khi toàn bộ internal Identity replicas hỗ trợ field mới. Canary public Identity không được coi là bằng chứng đã canary một phiên bản code PDP khác. Nếu bạn thay evaluator code, phải có rollout/gate riêng cho internal Policy service trước kích hoạt config.

## 2. Giai đoạn 0 — Nhận yêu cầu và chuẩn bị hồ sơ

Tạo mã release `iam-1.1.0` làm ví dụ; nếu repo của bạn đã dùng version khác, dùng version thật và nhất quán. Tạo hồ sơ:

```powershell
New-Item -ItemType Directory -Force lab/evidence/delivery/capstone,lab/docs/releases | Out-Null
git status --short
git switch -c feat/iam-208-approve-constraints
```

Không checkout/reset khi đang có thay đổi chưa lưu. Ghi ticket vào `lab/docs/releases/iam-1.1.0.md` với nội dung:

```text
Problem: role Approver hiện quá rộng so với quy trình phê duyệt Acme
Acceptance:
 A1 active Acme approver + đủ token scope + amount trong hạn mức + recent MFA -> allow
 A2 thiếu role/scope/MFA hoặc amount vượt -> deny
 A3 browser sửa amount/org/owner không ảnh hưởng trusted DB attributes
 A4 disable user/membership/session/client/role -> next check bị chặn sau commit
 A5 Beta policy và existing read flow không đổi
 A6 Identity/Policy lỗi -> 503, không cached allow
Constraints: cùng issuer/schema/keyring/opaque-token semantics với release hiện tại
NFR: giữ p95/API target và no unexpected error; đo trên workload đã chốt
```

Điền reviewer, data/security owner, cost window và rollout/rollback criteria. Reuse NFR register P01, thêm test IDs cho A1–A6. Bằng chứng review hiện tại ghi self-review nếu học một mình.

## 3. Giai đoạn 1 — Thiết kế, review và risk

Vẽ sequence auth như core 11/13. Xác định change ở policy evaluator/condition và resource attributes, không nhét business data vào ID token. Quy định đơn vị tiền `amount_cents` integer, timezone/clock và recent MFA evidence do Identity cung cấp. Không tin `auth_time` mới tự đặt khi refresh.

Quyết định compatibility trước coding:

- Nếu chỉ cấu hình condition đã hỗ trợ, thay policy version và thêm regression test; không tạo schema migration vô ích.
- Nếu thêm field operator, old reader phải reject unknown condition fail closed; rollout data/code theo capability trước kích hoạt policy mới.
- Nếu thêm database column, expand nullable/default tương thích, deploy code dual-read/write, backfill, rồi contract sau rollback window.

Risk mẫu: canary mới hiểu constraint nhưng stable không hiểu. Mitigation: versioned capability gate và chỉ bật condition sau cả stable/canary được chuẩn bị; rollback policy về version tương thích có review, không vô hiệu MFA vô điều kiện. Lưu ADR hoặc design delta gắn ticket.

## 4. Giai đoạn 2 — Code, test và PR

Thực hiện change trong service sở hữu theo core 11/13. Viết tests trước hoặc cùng code; tối thiểu có table-driven scenarios A1–A6 và test đồng thời đổi resource version. Test live policy dùng real PostgreSQL, tránh mock allow mọi request.

```powershell
pnpm -C lab install --frozen-lockfile
pnpm -C lab -r run typecheck
pnpm -C lab -r run test
pnpm -C lab -r run build
git diff --check
git diff --stat
```

Với native command, kiểm tra `$LASTEXITCODE` và dừng khi khác 0 như script CI core 19; một transcript có lệnh sau vẫn chạy không chứng minh lệnh trước pass. Nếu package chưa có `test`, bổ sung test script thật; không thêm passWithNoTests để vượt gate.

PR theo [P02](02-git-security-workflow.md): commit nhỏ, problem/result/validation/risk rõ, CODEOWNERS, review, required checks và security findings. Thử riêng một PR negative làm tenant/security test fail; gate phải chặn merge. Không merge PR negative vào branch release.

CI output cần JUnit/security reports, lockfile, source SHA, image digest, SBOM/provenance. Secret scan phải không upload token/account data trong artifacts. Scan findings critical không được ignored chỉ để có build xanh; có exception thì owner/scope/expiry/reason cụ thể.

## 5. Giai đoạn 3 — Chuẩn bị hạ tầng và môi trường

Theo [P03](03-infrastructure-as-code.md), giữ plan trước apply: đúng account/region/backend key, network routes/SG, least privilege, encryption/backup, estimate. Gate cần review thay đổi tạo/xóa/replace database. Terraform plan có thể chứa dữ liệu nhạy cảm; không publish public artifact.

Local track dùng kind; AWS track dùng topology nhiều AZ. Cả hai phải có DNS/TLS/secret/primary DB endpoints chuẩn. Không gọi kind nodes là multi-AZ production. Ghi option bạn thực sự đã chạy.

Theo [P04](04-environments-promotion.md), xác minh:

| Ranh giới | Kiểm tra |
|---|---|
| Issuer/client/redirect | Staging chỉ chấp nhận staging identity; production token không dùng cho staging và ngược lại |
| DB/secrets/keyring | Môi trường có credentials và dataset riêng; không copy production backup thô để seed staging |
| GitOps config | AppProject và destination namespace/cluster bị giới hạn |
| Artifact | Cùng một digest được promote, không rebuild tại production |
| Migration | Owner job/timeout/lock, compatible với stable và canary |
| Operator | Recovery identity độc lập IAM đang thử nghiệm |

Evidence G2 gồm plan reviewed, config inventory đã redact, packet tests, TLS/SAN checks và cost estimate. Không tạo production resources chỉ để lấp checklist khi chưa có budget/domain/owner.

## 6. Giai đoạn 4 — Staging acceptance và recovery

Deploy digest đã build vào staging bằng workflow/GitOps ở core 19. Chạy E2E với Alice/Acme, Alice/Beta, Bob/Beta, role/scope combinations và corporate/MFA policy nếu bật. Test qua BFF và direct resource API; gateway-only success chưa đủ.

Test revoke có barrier:

```text
1 seed grant/session/member active và xác nhận request allow
2 owner revoke membership/role; chỉ ghi barrier sau response success và commit xác nhận
3 gửi requests có timestamps bắt đầu sau barrier
4 mọi check mới phải inactive/deny; event/audit worker có thể đang dừng
5 reactivate membership không làm grant/session đã revoke trở lại active
```

Đo tải đúng workload core 20, bao gồm refresh sau năm phút và internal fan-out. Theo [P06](06-observability-data-recovery.md), lưu metrics/traces, thử alert, restore backup/PITR vào isolated DB, giữ recovery quarantine và kiểm tra stale credentials. Performance/failure proof phải gắn đúng digest/config của release.

Tối thiểu diễn tập một lỗi app, một lỗi dependency và một restore. Không suy ra NFR-03 failover durability từ một test `pg_dump` restore; mỗi requirement cần evidence riêng.

## 7. Giai đoạn 5 — Release và canary

Theo [P05](05-progressive-delivery.md), giữ stable Deployment/service và tạo canary Identity cùng issuer, keyring, authority state, body/parser/cookie compatibility. Bắt đầu 1% **public Gateway traffic**, không quảng bá đó là 1% toàn bộ internal introspection. Trong giai đoạn này giữ policy cần field mới chưa kích hoạt; dùng test trực tiếp canary để kiểm chứng `mfa_time`/refresh. Sau khi promote internal stable toàn bộ lên digest đã kiểm chứng và capability probe đạt, mới bật policy version mới cho Acme rồi chạy A1–A6. Việc bật config có gate/rollback record riêng.

Ở mỗi bước 1→10→50→100%, kiểm tra:

- Traffic đủ để kết luận; không có dữ liệu thì giữ gate, không pass từ số 0.
- Valid request error rate, latency histogram, saturation và auth synthetic.
- SSO hai app, token/refresh/session/key behavior qua nhiều version.
- Tenant/read/approve/revoke negative cases, failure không trở thành cached allow.
- DB/outbox/credential pressure và budget rollout.

P05 hướng dẫn PromQL và script route weights cụ thể. Capstone record lưu thời điểm, weights thực, digest stable/canary, bằng chứng gate, người quyết định và kết quả. 100% public canary vẫn cần internal service promotion/smoke riêng trước khi xóa stable cũ.

Một production gate failed thì dừng/rollback. Không bỏ required checks, cache introspection hoặc tắt MFA để rollout tiếp. Chờ error budget/môi trường ổn rồi sửa root cause.

## 8. Failure lab — Canary lỗi và rollback

**Chỉ ở lab/staging**, đưa một fault có kiểm soát: canary introspection dependency URL trỏ endpoint không phục vụ, hoặc version evaluator trả lỗi cho condition hợp lệ. Không tạo fault mở quyền. Giữ stable tốt, canary 1–10%.

Expected: valid canary requests có 503, synthetic/gate fail, stable tiếp tục đúng. Thu thập request ID/trace/metric đã redaction; route rollback canary weight về 0 bằng GitOps config và xác nhận resource đã reconcile. Nếu emergency patch trực tiếp, ghi incident và đưa desired state về Git để controller không hoàn tác lệnh của bạn.

Rollback code/config giữ database expand changes nếu backward compatible; không chạy `DROP COLUMN` hoặc restore production DB để rollback một image. Nếu schema đã contract trước hạn thì rollback image có thể không an toàn: kích hoạt runbook change incident, không thử may rủi.

Sau rollback, lặp revoke/tenant/SSO probes và kiểm tra background workflows không replay stale grants. Tạo regression test bảo vệ fault vừa phát hiện, build digest mới và đi lại pipeline.

## 9. Giai đoạn 6 — Incident, postmortem và maintenance

Theo [P07](07-operations-cost.md), ghi incident timeline: detection, triage, containment, recovery, verification và close. Người học mô phỏng Incident Commander/Operator/Communications riêng trong ghi chép, không tự nhận đã có đội on-call 24/7.

Postmortem phải có impact, contributing factors, điều gì giúp/chậm recovery và action. Action mẫu tốt: “CI staging test dependency timeout returns 503 and release gate rejects missing canary metrics; owner X, due date Y, evidence test Z”. Action “cẩn thận hơn” không kiểm chứng được.

Lên calendar patch/dependency/action pin, CA/certificate/secret rotation, restore drill, access review và cost review. Onboard một người khác bằng runbook không đưa họ full cluster/admin DB credential. Nếu học một mình, làm lại runbook ở terminal mới và ghi self-test limitation.

## 10. Giai đoạn 7 — Cost review và kết thúc lab

So actual inventory/bill với forecast: EKS control plane, nodes, RDS/storage/backup, NAT/data processing, LB, logs/traces, egress, snapshots/state. Budget alert là cảnh báo, không phải hard spending cap. Gắn Owner/Environment/Project/ExpiresAt cho tài nguyên hỗ trợ tag; kiểm tra tài nguyên không hỗ trợ tag riêng.

Theo cleanup order P03/P07: bỏ traffic/application resources và LB controller-owned resource trước destroy network; lưu evidence/state/backups cần giữ; review destroy plan đúng sandbox; xác nhận không EKS/NAT/LB/EBS/RDS/snapshot mồ côi. Production decommission cần data retention/owner approval riêng; không dùng lệnh destroy lab cho production.

Ghi `closed_at`, tài nguyên còn giữ có lý do/cost owner/expiry, và lịch kiểm tra bill tiếp theo vì billing data trễ. Giữ Terraform state bucket/lock và backup theo policy riêng, không xóa evidence để có màn hình “zero resources”.

## 11. Hồ sơ bàn giao cuối và troubleshooting

Release record cần đủ các links:

```text
Requirements: FR/NFR + ticket/ADR + risk/cost review
Source: PR/reviews + commit SHA + required-check/security findings
Artifact: image digest + SBOM/signature/provenance
Infrastructure: account/region/backend key + reviewed plan + apply outputs redacted
Environment: issuer/key/DB/secret inventory refs, schema version
Validation: E2E/security/concurrency/load/recovery/protocol results
Rollout: weights/gates/timestamps/operator/reviewer/rollback evidence
Operations: alert routes/runbooks/incident/postmortem/actions/calendar
Cost: forecast/inventory/budget/actuals/cleanup record
Limitations: local-only, self-review, profiles not exercised, pending gates
```

| Triệu chứng | Hành động |
|---|---|
| Không biết đã học đến đâu | Mở gate matrix; thiếu artifact nào làm lại đúng bài đó |
| CI pass nhưng prod lỗi | So digest/config/schema/issuer, không chỉ source code |
| Canary không có traffic | Kiểm tra route weights/selectors/TLS và giữ gate pending |
| Mọi API 401 nhưng 5xx thấp | Synthetic credential hợp lệ, reason code và live introspection |
| Backup có file nhưng restore fail | Sửa key custody/WAL/base backup chain, không ghi NFR passed |
| Cleanup xong còn cost | Kiểm inventory LB/NAT/disks/snapshots/retention và billing delay |

## 12. Definition of Done

- [ ] Một requirement đi được từ ticket → thiết kế → PR/test → artifact → staging → rollout.
- [ ] Cả 10 nhóm có artifact/evidence thật hoặc pending/N/A có lý do.
- [ ] Đã diễn tập canary failure/rollback, online revoke và restore/recovery gate.
- [ ] Có postmortem với action owner/deadline/test và maintenance plan.
- [ ] Có cost forecast/actual/cleanup, không bỏ tài nguyên lab mồ côi.
- [ ] Release record nói rõ phần local/self-review/cloud chưa kiểm chứng; production sign-off chỉ khi gates thật đạt.

Nguồn: [Google SRE canarying](https://sre.google/workbook/canarying-releases/), [postmortem culture](https://sre.google/workbook/postmortem-culture/), [AWS operational excellence](https://docs.aws.amazon.com/wellarchitected/latest/operational-excellence-pillar/welcome.html), [Terraform plan](https://developer.hashicorp.com/terraform/cli/commands/plan).
