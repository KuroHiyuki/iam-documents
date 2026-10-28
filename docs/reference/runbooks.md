# Runbooks vận hành và diễn tập IAM

Các lệnh dưới đây dành **lab trước**, không phải lịch sử thao tác đã chạy. Đọc [chương 18](../chapters/18-kubernetes.md), [chương 20](../chapters/20-sre-production.md) và [implementation map](implementation-map.md). Mỗi runbook cần người thực hiện, incident/change ID, thời điểm UTC và người review. Không lưu bearer token, password, private key hay unseal share trong evidence.

## RB-00 — Chuẩn bị chung và giới hạn môi trường

Prerequisites: PowerShell 7, kubectl/psql đúng versions, namespace/deployment theo chương 18; quyền operator cấp ngoài IAM đang sửa. Chạy tại root giáo trình. Các thao tác mutation mặc định chỉ chấp nhận context kind-iam:

```powershell
$ErrorActionPreference = 'Stop'
function Assert-LabContext {
  $context = kubectl config current-context
  if ($LASTEXITCODE -ne 0 -or $context -ne 'kind-iam') {
    throw 'Runbook lab chỉ chấp nhận context kind-iam'
  }
}
Assert-LabContext
New-Item -ItemType Directory -Force lab/evidence/operations,lab/.secrets | Out-Null
kubectl -n iam get deployment,pod,service,endpointslice
kubectl -n iam get events --sort-by=.metadata.creationTimestamp
```

Production thay guard bằng context ID được change record phê duyệt; không xóa guard chỉ để lệnh chạy. Trước incident cần cấu hình PostgreSQL service file/pgpass có ACL hạn chế và các service names `identity_lab_ops`, `authorization_lab_ops`, `identity_restore_test`. `PGSERVICEFILE`/`PGPASSFILE` trỏ file riêng dưới secret custody; file service có host, dbname, user, sslmode=verify-full và sslrootcert đúng CA. Nhờ đó password không nằm command arguments. Không dùng app role hay SUPERUSER cho mọi việc.

Evidence chỉ chứa status, metadata, IDs và số liệu đã redact. Xem log trước khi redirect ra file: ứng dụng phải có redaction hoạt động, error stack không được mang raw request body. Khi có leak, hạn chế log access, rotate credential và ghi incident; xóa log chưa đủ xử lý credential đã lộ.

## RB-01 — Protected API trả 503 hoặc latency tăng

**Trigger:** synthetic authenticated flow lỗi, burn-rate alert hoặc dependency error tăng. **Mục tiêu:** khôi phục kiểm tra online mà không fallback allow. Trước hết phân biệt client 401, policy 403 và dependency 503 bằng metrics, không yêu cầu mọi user đăng nhập lại.

```powershell
Assert-LabContext
kubectl -n iam get pods -o wide
kubectl -n iam logs deployment/identity --since=10m --tail=200
kubectl -n iam logs deployment/authorization --since=10m --tail=200
kubectl -n iam logs deployment/invoice-api --since=10m --tail=200
kubectl -n iam exec deployment/invoice-api -- node -e `
  "fetch('https://identity.iam.svc.cluster.local:3000/health/ready').then(r=>console.log(r.status)).catch(()=>process.exit(1))"
```

Các health routes chỉ trả capability/status, không connection string. Kiểm tra NetworkPolicy/DNS/CA, pool wait và primary role trước restart. Với DB operations service:

```powershell
$env:PGSERVICE = 'identity_lab_ops'
psql -X -v ON_ERROR_STOP=1 -c 'SELECT pg_is_in_recovery(),clock_timestamp();'
psql -X -v ON_ERROR_STOP=1 -c "SELECT state,wait_event_type,count(*) FROM pg_stat_activity WHERE datname=current_database() GROUP BY state,wait_event_type;"
psql -X -v ON_ERROR_STOP=1 -c "SELECT application_name,state,sync_state,write_lsn,flush_lsn,replay_lsn FROM pg_stat_replication;"
```

Không log query text toàn bộ vì có thể có secret từ thao tác quản trị. Nếu rollout mới gây lỗi, dùng RB-06. Nếu DB unavailable, giữ 503/deadline/bounded queue; không bật cache. Nếu broker unavailable, xem RB-07, không giả định broker làm mất quyền live.

**Failure drill:** trong kind scale Identity xuống 0, gọi một protected invoice bằng token còn hạn, xác nhận 503 trong khoảng một giây; scale lại 2, đợi rollout và test revoked token vẫn inactive. Lệnh mutation:

```powershell
Assert-LabContext
kubectl -n iam scale deployment identity --replicas=0
# Chạy synthetic test có deadline ở terminal khác; không in token.
kubectl -n iam scale deployment identity --replicas=2
kubectl -n iam rollout status deployment/identity --timeout=180s
```

**Exit criteria:** dependency khỏe, error rate/p95 về baseline, synthetic success và revoke negative test pass. Ghi nguyên nhân, không chỉ “restart đã hết”.

## RB-02 — Thu hồi quyền/membership khẩn cấp

Prerequisites: operator token có audience owner, scope đúng org; owner API online, TLS/private routing đã cấu hình. Trong Compose lab, Identity owner URL là HTTP loopback; production dùng private HTTPS endpoint của operator, không expose `/internal` public. Không truyền `org_id` tùy ý vào machine token.

```powershell
$org = '10000000-0000-4000-8000-000000000001'
$user = '00000000-0000-4000-8000-000000000001'
$operation = [guid]::NewGuid().ToString()
if (-not $env:IDENTITY_OWNER_TOKEN) { throw 'Thiếu token operator owner' }
$body = @{ status='suspended'; operation_id=$operation } | ConvertTo-Json
Invoke-RestMethod "http://127.0.0.1:3000/internal/v1/orgs/$org/memberships/$user/status" `
  -Method Put -ContentType application/json -Body $body `
  -Headers @{Authorization="Bearer $env:IDENTITY_OWNER_TOKEN"} | Select-Object operation_id,status
```

Chỉ acknowledge sau commit owner/outbox/idempotency receipt. Sau timeout, retry **cùng operation ID và payload**, không phát request khác để “chắc chắn”. Thu hồi assignment qua Authorization DELETE với `{operation_id,expected_revision}`; conflict revision phải load state hiện hành rồi review, không force revoke nhầm assignment thay thế.

Đánh dấu timestamp acknowledgement, sau đó gọi introspection/decision mới; Alice Acme inactive/deny, Beta không bị vô hiệu hóa account global. Kiểm tra audit operation xuất hiện, broker lag không trì hoãn enforcement. Với credential compromise global, dùng owner operation suspend user/revoke sessions/grants của account và rotate factors theo policy, không chỉ revoke một access token.

**Exit criteria:** tất cả checks bắt đầu sau commit thấy revoke; token exchange child cũng inactive; không khẳng định request đã qua check trước đó bị undo. Credential caller lỗi khiến thao tác chưa được owner nhận phải được incident escalation, không ghi “đã revoke” từ UI local.

## RB-03 — Restore vào môi trường cô lập và security reset

Prerequisites: PostgreSQL 18 client, backup custody, tool `age` đã được tổ chức kiểm chứng, migration owner restore, capacity cô lập và operator identity độc lập. Production phải có PITR/WAL restore theo DB platform đã chọn; các lệnh pg_dump dưới đây tạo logical backup lab, **không thay physical backup/PITR**.

```powershell
$env:PGSERVICE = 'identity_lab_ops'
pg_dump --format=custom --file=lab/.secrets/identity.dump
if ($LASTEXITCODE -ne 0) { throw 'Backup failed' }
if (-not $env:BACKUP_AGE_RECIPIENT) { throw 'Thiếu public encryption recipient' }
age -r $env:BACKUP_AGE_RECIPIENT -o lab/.secrets/identity.dump.age lab/.secrets/identity.dump
if ($LASTEXITCODE -ne 0) { throw 'Backup encryption failed' }
Get-FileHash lab/.secrets/identity.dump.age -Algorithm SHA256
```

Không upload dump plaintext; public recipient khác private decrypt identity. Xóa plaintext theo chính sách bảo mật sau verify encrypted backup, dùng `Remove-Item -LiteralPath` đúng file nếu được phép; không recursive delete directory tính toán. Tạo backup tương tự từng owner database, record consistency window giữa owners; chúng không tự có distributed snapshot.

Restore chỉ tới service `identity_restore_test`, không trỏ vào database sống:

```powershell
$env:PGSERVICE = 'identity_restore_test'
$target = psql -X -At -c 'SELECT current_database();'
if ($target -ne 'identity_restore_test') { throw 'Sai restore target' }
if (-not $env:BACKUP_AGE_IDENTITY_FILE) { throw 'Thiếu decrypt identity path' }
age --decrypt -i $env:BACKUP_AGE_IDENTITY_FILE -o lab/.secrets/identity.restore.dump lab/.secrets/identity.dump.age
if ($LASTEXITCODE -ne 0) { throw 'Decrypt failed' }
pg_restore --exit-on-error --no-owner --no-acl --dbname=service=identity_restore_test lab/.secrets/identity.restore.dump
if ($LASTEXITCODE -ne 0) { throw 'Restore failed' }
```

Đích phải là DB rỗng do migration operator tạo; không dùng `--clean` vào DB tùy ý. Cấp quyền runtime từ migrations sau restore vì `--no-acl` không phục hồi GRANT. So checksum/row counts/schema versions trước khi nối app; public ingress vẫn maintenance/503, workers không được tự replay snapshot queue vào owner sống.

Trước bất kỳ mở traffic nào, chạy security reset dưới owner restore, lưu thành `lab/scripts/recovery/identity-reset.sql` do người học tạo:

```sql
BEGIN;
UPDATE oauth_grants SET revoked_at=clock_timestamp() WHERE revoked_at IS NULL;
UPDATE oauth_tokens SET revoked_at=clock_timestamp() WHERE revoked_at IS NULL;
UPDATE oauth_codes SET consumed_at=clock_timestamp() WHERE consumed_at IS NULL;
UPDATE sessions SET revoked_at=clock_timestamp() WHERE revoked_at IS NULL;
UPDATE challenges SET consumed_at=clock_timestamp() WHERE consumed_at IS NULL;
UPDATE authenticators SET status='revoked',revoked_at=clock_timestamp()
  WHERE status<>'revoked';
UPDATE users SET password_hash=NULL,credential_version=credential_version+1,
  status='suspended',updated_at=clock_timestamp() WHERE status<>'deleted';
UPDATE organizations SET status='suspended' WHERE status<>'deleted';
UPDATE clients SET status='disabled',secret_hash=NULL;
UPDATE signing_keys SET status='retired';
COMMIT;
```

```powershell
psql -X -v ON_ERROR_STOP=1 -f lab/scripts/recovery/identity-reset.sql
if ($LASTEXITCODE -ne 0) { throw 'Security reset failed; giữ maintenance' }
```

Lý do phải xử lý password/MFA/client keys: snapshot cũ có thể khôi phục credential đã đổi hoặc revoke sau backup. Không chỉ revoke JWT/session rồi cho login bằng password cũ. TOTP/WebAuthn/recovery factors phải được enroll lại từ nguồn ownership được xác minh độc lập; email cũ trong snapshot không tự đủ để chứng minh quyền sở hữu. Signing key active mới từ Vault và client registrations mới được dựng sau reconciliation; ID tokens cũ không được trở thành API credential.

Tại Authorization restore database, revoke restored assignments, tăng policy versions và reconcile policy rules/constraints/relationships với change history đáng tin. Giữ tất cả org suspended đến khi reconciliation hoàn tất; chỉ revoke RBAC còn bỏ ABAC/ReBAC cũ có thể làm quyền sống lại. Governance operations/outbox snapshot phải quarantine và đối chiếu owner receipts; không bật worker để replay grant.create cũ trước review.

**Drill bắt buộc:** backup tại T0, revoke token/assignment và đổi password tại T1, restore T0. Credential/token/quyền cũ đều không sử dụng được sau security reset. Record RTO thực tế và những chức năng vẫn pending, không mở toàn bộ tenants chỉ vì health xanh. **Exit criteria:** data validation, new credential enrollment, policy reconciliation, restore negative tests, reviewer ký và mở traffic từng nhóm nhỏ.

## RB-04 — Signing key rotation hoặc compromise

Prerequisites: Vault operator quyền rotate tách runtime signer, current key metadata, max ID-token lifetime, clock skew và JWKS cache policy đã biết. Rotation thường: rotate Transit key, lấy public key version mới, tạo signing_keys row `prepublished`, publish JWKS trước, activate bằng transaction serialized, sau đó giữ key cũ `retiring` đủ overlap. Runtime ký pin `key_version` đúng kid; Vault latest version không tự đổi signer metadata.

```powershell
vault write -f transit/keys/iam-id/rotate
vault read -format=json transit/keys/iam-id
```

Output chứa public key/metadata; không export private key. Administration operation ghi kid/version/private_ref và audit, không ghi signing input có claims nhạy cảm toàn bộ. Verify token mới có kid mới, token cũ còn validate trong overlap, unknown kid khiến RP refresh JWKS có giới hạn rồi fail nếu vẫn unknown. ID token validation tại RP khác API introspection; rotate ID signing key không tự revoke opaque access token.

Compromise: disable signing/mint capability bị ảnh hưởng, revoke grants/sessions theo phạm vi, gỡ compromised key khỏi trust theo incident policy; có thể buộc user đăng nhập lại. Không giữ key compromise chỉ để làm overlap mượt. Recovery cần độc lập credential Vault và IAM; root token Vault không được chuyển cho app để chữa lỗi 403.

## RB-05 — Database failover và kiểm chứng RPO=0

Prerequisites: primary/standby TLS endpoints và operator runbook đã test, synchronous durability, fencing, candidate promotion criteria. Kind một DB pod không đạt prerequisite này. Không cung cấp một lệnh `pg_promote` mặc định cho production khi chưa biết fencing; promotion sai có thể tạo split brain.

Đo baseline trên primary và candidate bằng PGSERVICE tương ứng:

```powershell
$env:PGSERVICE = 'identity_lab_ops'
psql -X -v ON_ERROR_STOP=1 -c 'SHOW synchronous_commit;'
psql -X -v ON_ERROR_STOP=1 -c 'SHOW synchronous_standby_names;'
psql -X -v ON_ERROR_STOP=1 -c 'SELECT pg_current_wal_lsn();'
psql -X -v ON_ERROR_STOP=1 -c 'SELECT application_name,sync_state,flush_lsn,replay_lsn FROM pg_stat_replication;'
```

Commit revoke bằng owner API, lưu receipt operation ID ngoài primary. Đóng ingress/gate, fence old primary bằng DB operator hạ tầng đã chọn, promote **candidate được xác nhận đã giữ acknowledged security state**, đổi primary endpoint, kiểm tra `pg_is_in_recovery()=false` trên đích mới. Chạy RB-02 negative test cùng receipt. Không xác minh được thì giữ recovery gate/503; không mở traffic với lý do “replication lag chỉ vài giây”. Trong lab chưa có standby, đánh dấu drill pending, không ghi passed từ việc restart DB pod.

**Exit criteria:** old primary không còn nhận writes, acknowledged revoke không mất, app tới đúng primary, old credentials vẫn bị chặn. Backup restore thay thế failover phải đi RB-03.

## RB-06 — Release rollback không rollback security state

Prerequisites: GitOps repo, digest trước/sau, schema compatibility record, Argo Application `iam-staging` hoặc tên đã khai báo. Xem trạng thái bằng:

```powershell
kubectl -n iam rollout history deployment/identity
kubectl -n iam get deployment identity -o 'jsonpath={.spec.template.spec.containers[0].image}'
kubectl -n argocd get application iam-staging -o yaml
```

Revert promotion commit trong Git, review rồi sync Argo. Nếu schema không tương thích app cũ, giữ maintenance và forward fix; không tự chạy down migration phá dữ liệu. `kubectl rollout undo` chỉ là thao tác emergency tạm thời được record, Argo có thể reconcile ngược; phải cập nhật Git. Token revoke/policy mutation sau deploy vẫn giữ nguyên, không phục hồi snapshot để quay app binary.

**Exit criteria:** digest và schema version đúng, SSO hai apps, online revoke/tenant negative tests pass, metrics về baseline. Lưu incident và regression test gây rollback.

## RB-07 — Outbox/audit lag và reconciliation

Prerequisites: operator đọc queue/outbox, không có quyền sửa allow state bằng projection. Kiểm tra pending count, oldest age và dead-letter reason; không dump payload token. Local broker commands:

```powershell
docker compose --env-file lab/infra/compose/.env -f lab/infra/compose/compose.yaml `
  exec rabbitmq rabbitmqctl list_queues name messages_ready messages_unacknowledged
```

Khôi phục broker binding/consumer/DB, retry cùng message IDs, không purge queue để tắt alert. Audit inbox dedup trước commit/ACK; reconciliation so operation ID/aggregate version với owner API. Message grant cũ không được chạy lại sau revoke chỉ vì có trong backup. Replay cần allowlist event type/time window và dry-run report trước apply. **Exit criteria:** lag giảm, không mất audit mutation, duplicates không tạo thêm quyền, live auth vẫn đúng trong suốt outage.

Nguồn: [PostgreSQL backup](https://www.postgresql.org/docs/18/backup.html), [continuous archiving](https://www.postgresql.org/docs/18/continuous-archiving.html), [Vault Transit](https://developer.hashicorp.com/vault/docs/secrets/transit), [Kubernetes debugging](https://kubernetes.io/docs/tasks/debug/debug-application/). Quy trình hạ tầng cụ thể phải được thêm vào change record trước production; phần chưa diễn tập luôn ở trạng thái pending.
