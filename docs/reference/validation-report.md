# Báo cáo kiểm tra giáo trình

Ngày cập nhật: 29/10/2026, Asia/Saigon. Phạm vi: repository **tài liệu**, gồm 20 chương IAM và 8 bài quy trình P01–P08. Chưa có ứng dụng IAM production được triển khai bởi quá trình biên soạn.

## Kiểm tra có thể tái hiện

Chạy tại root `iam-documents`:

```powershell
pnpm install --frozen-lockfile
pnpm check:docs
pnpm check:powershell
```

Checker tài liệu kiểm tra đủ số bài, liên kết local, fences, JSON/YAML, cú pháp TypeScript và NFR template. Checker PowerShell dùng parser, **không chạy** lệnh trong bài; vì vậy không tạo cloud resources, không chỉnh GitHub rulesets và không thực thi SQL/deployment. Có Terraform 1.13.5 trên PATH thì chạy thêm `pnpm check:hcl`; checker này chỉ dùng formatter parse file tạm với `-write=false`, không init provider hoặc truy cập AWS.

## Trạng thái

Đã chạy kiểm tra trên repository hiện tại ngày 29/10/2026:

| Kiểm tra | Kết quả quan sát |
|---|---|
| Cài dependency tài liệu từ lockfile | PASS, exact TypeScript 5.9.3 và yaml 2.8.1; khôi phục links pnpm sau khi di chuyển repository |
| Document checker trên Node 24.22.1 | PASS: 45 Markdown documents, 20 chương IAM, 8 bài delivery, 265 liên kết local, 310 fences |
| Nội dung JSON/YAML/TypeScript | PASS: 13 JSON blocks, 20 YAML blocks, 79 TypeScript syntax blocks |
| PowerShell parser 5.1.26100.9711 | PASS: 111 code blocks, không parse error |
| HCL bằng Terraform 1.13.5 | PASS: 8 code blocks được parser formatter đọc, không parse error; CLI tải từ distribution chính thức và đối chiếu SHA-256 |
| NFR register | PASS: NFR-01–NFR-08 duy nhất, đủ field target/workload/verification/evidence/owner/status |
| Whitespace Git diff | PASS với `git diff --check` |

Số đếm trên là snapshot của lần kiểm tra; thêm nội dung sẽ làm số đếm thay đổi. Không coi một code block hoặc source upstream là bằng chứng ứng dụng/cloud đã chạy thành công.

## Review nội dung và các điểm đã sửa

- Nối 10 nhóm yêu cầu với artifact/gate qua coverage map, không chỉ thêm tên công cụ.
- Thống nhất entrypoint Docker qua `start:prod` của từng package; cài root tooling cho integration/browser tests; đồng bộ required checks và tránh path-filter làm check treo.
- Phân biệt canary public Gateway với internal service traffic; giữ cùng authority state/keys/issuer, route/config render theo environment và no-data không pass.
- Giữ CMK cần cho retained database snapshot khi destroy application stack; budget là alert, không hard cap.
- Scrape theo từng pod/replica để không trộn counters qua ClusterIP; tách self-managed pgBackRest với RDS-native PITR.
- Phân biệt request-based error budget với time-based availability và security durability với backup RPO.
- Giữ nguyên phần thực hành ở thư mục sibling `iam-experiement`; không triển khai hoặc publish tài nguyên từ quá trình viết tài liệu.

## Giới hạn của kết quả

- TypeScript parse không là typecheck toàn chương và không là runtime/integration test.
- YAML parse không là Kubernetes server-side validation; HCL trong bài cần `terraform fmt/validate/plan` dưới environment của người học.
- PowerShell parse không kiểm tra permission, CLI installed, DNS, certificate, cloud account hoặc kết quả command.
- Giá/compatibility/phiên bản tham chiếu có source trong từng bài; cần đối chiếu lại trước apply/upgrade.
- Chưa chạy EKS/RDS/Terraform apply, GitHub workflow/ruleset, Helm cluster, canary/PITR hoặc conformance/security review cho app người học. Các gate này giữ pending tới khi có evidence thật.

Người học lưu bằng chứng deployment/application ở `lab/evidence`, theo [coverage map](delivery-coverage.md), [capstone](../delivery/08-capstone-lifecycle.md) và [production checklist](production-checklist.md).
