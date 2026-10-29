# P05 — Canary có đo lường, promotion và rollback thật

[Trang đầu](../../README.md) · Điều kiện: [Kubernetes](../chapters/18-kubernetes.md), [artifact và migration](../chapters/19-cicd.md), [SLO](../chapters/20-sre-production.md)

## Mục tiêu và quyết định triển khai

Đưa digest Identity qua **1% → 10% → 50% → 100% public traffic**. Promote artifact đã scan/attest, không rebuild. Envoy Gateway chia traffic; người vận hành tăng weight bằng PR sau gate. Pod Ready chỉ là điều kiện đầu vào.

Hai version cùng issuer, primary DB, session/grant/client registry, Vault signing key và JWKS. Login ở canary rồi callback tới stable vẫn đổi code được. Rotation key là change riêng, giữ verify keys đủ lâu. Mỗi môi trường có issuer/key/DB riêng.

Phần trăm áp cho **public Identity Gateway**; internal Service `identity` tiếp tục stable. Sau public 100%, rolling-promote stable và kiểm chứng riêng API nội bộ. Weight public chưa chứng minh canary toàn graph.

## Bước 1 — Chốt điều kiện trước rollout

Chạy tại root, PowerShell, staging context namespace `iam`. Các resources chương 18 phải tồn tại: Gateway `iam-gateway`, route `identity-public`, cert `identity-backend-tls`, CA `iam-internal-ca`, Deployment/Service `identity`. Local giữ các URL/port chương 18 và port-forward Envoy ở terminal khác. Production dùng DNS môi trường, không đổi issuer giữa tracks.

```powershell
kubectl config current-context
kubectl -n iam get deployment identity
kubectl -n iam get httproute identity-public -o yaml
kubectl -n iam get backendtlspolicy identity-tls -o yaml
kubectl -n iam rollout status deployment/identity --timeout=180s
if ($LASTEXITCODE -ne 0) { throw 'Stable chưa khỏe' }
New-Item -ItemType Directory -Force lab/evidence/p05,lab/infra/gitops/canary | Out-Null
$env:IAM_CANARY_IMAGE = Read-Host 'Dán GHCR image@sha256 đã được attest ở chương 19'
if ($env:IAM_CANARY_IMAGE -notmatch '^ghcr\.io/.+@sha256:[a-f0-9]{64}$') { throw 'Cần immutable GHCR digest' }
$releaseRepo = gh repo view --json nameWithOwner --jq .nameWithOwner
gh attestation verify "oci://$env:IAM_CANARY_IMAGE" --repo $releaseRepo `
  --signer-workflow "$releaseRepo/.github/workflows/release.yml"
if ($LASTEXITCODE -ne 0) { throw 'Attestation không hợp lệ' }
```

Stable cũng dùng digest đã verify. Expand migration PreSync **trước** canary; N và N−1 cùng đọc schema. Hết rollback window mới contract/drop column.

Release record ghi digests, SHA, schema, issuer, cert, error budget, người trực và rollback commit. Incident/burn-rate alert chặn promotion; bản vá khẩn cấp vẫn giữ security checks.

## Bước 2 — Tạo manifest đầy đủ từ workload đã kiểm chứng

Script xuất **hai Deployment đầy đủ và hai Service** thành YAML từ template chương 18, giữ Vault Agent, projected token, TLS/volumes/limits. Canary đổi app label để selectors không chồng lấn. Capture một lần, review rồi quản lý bằng GitOps.

```powershell
$ErrorActionPreference = 'Stop'
$liveText = kubectl -n iam get deployment identity -o json
if ($LASTEXITCODE -ne 0) { throw 'Không đọc được stable Deployment' }
$live = $liveText | ConvertFrom-Json
$stable = [ordered]@{
  apiVersion='apps/v1'; kind='Deployment'
  metadata=@{name='identity'; namespace='iam'}
  spec=$live.spec
}
$stableContainer = @($stable.spec.template.spec.containers | Where-Object name -eq 'identity')[0]
if (-not $stableContainer -or $stableContainer.image -notmatch '@sha256:[a-f0-9]{64}$') {
  throw 'Stable container identity phải dùng digest'
}
$stableContainer.env = @($stableContainer.env | Where-Object name -ne 'RELEASE_TRACK') +
  @([pscustomobject]@{name='RELEASE_TRACK'; value='stable'})
$canary = ($stable | ConvertTo-Json -Depth 100) | ConvertFrom-Json
$canary.metadata.name = 'identity-canary'
$canary.spec.replicas = 2
$canary.spec.selector.matchLabels.app = 'identity-canary'
$canary.spec.template.metadata.labels.app = 'identity-canary'
$canaryContainer = @($canary.spec.template.spec.containers | Where-Object name -eq 'identity')[0]
$canaryContainer.image = $env:IAM_CANARY_IMAGE
$canaryContainer.env = @($canaryContainer.env | Where-Object name -ne 'RELEASE_TRACK') +
  @([pscustomobject]@{name='RELEASE_TRACK'; value='canary'})
$stableService = [ordered]@{
  apiVersion='v1'; kind='Service'; metadata=@{name='identity'; namespace='iam'}
  spec=@{selector=@{app='identity'}; ports=@(@{name='https';port=3000;targetPort='https'})}
}
$canaryService = [ordered]@{
  apiVersion='v1'; kind='Service'; metadata=@{name='identity-canary'; namespace='iam'}
  spec=@{selector=@{app='identity-canary'}; ports=@(@{name='https';port=3000;targetPort='https'})}
}
$resources = @{apiVersion='v1';kind='List';items=@($stable,$canary,$stableService,$canaryService)}
$jsonPath = 'lab/evidence/p05/workloads.json'
$resources | ConvertTo-Json -Depth 100 | Set-Content -Encoding utf8 $jsonPath
kubectl create --dry-run=client -f $jsonPath -o yaml |
  Set-Content -Encoding utf8 lab/infra/gitops/canary/workloads.yaml
if ($LASTEXITCODE -ne 0) { throw 'Manifest generation failed' }
```

Review YAML không chứa secrets. Cả tracks dùng `identity-runtime`, service account `identity`, Vault chỉ sign đúng key. HPA stable cần bỏ `spec.replicas` khỏi GitOps, giữ Argo ignore rule; HPA không điều khiển weight.

Canary dùng `app:identity-canary` nên NetworkPolicy match `app:identity` chưa áp dụng. Với policies chuẩn chương 18 dùng `matchLabels.app`, tạo bản sao các cạnh đúng Identity, không mở toàn namespace:

```powershell
$policyList = kubectl -n iam get networkpolicy -o json | ConvertFrom-Json
$copies = @()
foreach ($policy in $policyList.items) {
  $specJson = $policy.spec | ConvertTo-Json -Depth 100
  if ($specJson -match '"app"\s*:\s*"identity"') {
    $newSpec = ($specJson -replace '"app"\s*:\s*"identity"','"app":"identity-canary"') | ConvertFrom-Json
    $copies += @{apiVersion='networking.k8s.io/v1';kind='NetworkPolicy'
      metadata=@{name=($policy.metadata.name + '-canary');namespace='iam'};spec=$newSpec}
  }
}
if ($copies.Count -eq 0) { throw 'Không tìm thấy allow policies của Identity' }
@{apiVersion='v1';kind='List';items=$copies} | ConvertTo-Json -Depth 100 |
  Set-Content -Encoding utf8 lab/evidence/p05/network.json
kubectl create --dry-run=client -f lab/evidence/p05/network.json -o yaml |
  Set-Content -Encoding utf8 lab/infra/gitops/canary/network.yaml
if ($LASTEXITCODE -ne 0) { throw 'Network manifest generation failed' }
```

Script dành cho matchLabels chương 18. Custom selectors cần sửa manifest và packet-test lại. Giữ default deny, các cạnh Envoy→canary, canary→DB/Redis/Vault và caller→canary; NetworkPolicy không thay authentication.

## Bước 3 — Route canary và TLS backend

Lưu `lab/infra/gitops/canary/route.yaml`; đây là **thay thế** resource `identity-public` hiện hữu, không tạo route cạnh tranh cùng hostname/path:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: identity-public, namespace: iam}
spec:
  parentRefs: [{name: iam-gateway, sectionName: https}]
  hostnames: [iam.local.test]
  rules:
    - matches:
        - {path: {type: PathPrefix, value: /oauth2}}
        - {path: {type: PathPrefix, value: /.well-known}}
        - {path: {type: PathPrefix, value: /login}}
        - {path: {type: PathPrefix, value: /interactions}}
      backendRefs:
        - {name: identity, port: 3000, weight: 100}
        - {name: identity-canary, port: 3000, weight: 0}
---
apiVersion: gateway.networking.k8s.io/v1
kind: BackendTLSPolicy
metadata: {name: identity-canary-tls, namespace: iam}
spec:
  targetRefs: [{group: "", kind: Service, name: identity-canary, sectionName: https}]
  validation:
    caCertificateRefs: [{group: "", kind: ConfigMap, name: iam-internal-ca}]
    hostname: identity.iam.svc.cluster.local
```

Certificate có SAN `identity.iam.svc.cluster.local`; Gateway xác minh cùng SNI cho hai backends. Internal callers dùng DNS stable. Test trực tiếp DNS canary cần cert có SAN canary; không tắt hostname verification. Giữ `identity-tls` cho stable. HTTPRoute weight là tỷ lệ tương đối, không sticky session. [Gateway traffic splitting](https://gateway.envoyproxy.io/latest/tasks/traffic/http-traffic-splitting/), [BackendTLSPolicy](https://gateway.envoyproxy.io/v1.9/api/gateway_api/backendtlspolicy/).

Application P04 đọc chart cùng environment values. Parameterize bản capture trước khi **thay** template Identity cũ; không copy config staging sang prod. Route chuyển sang Helm ownership, không apply lại file kind cũ. Kind lab dùng values issuer `https://iam.local.test:8443`.

```powershell
$yaml = Get-Content -Raw -Encoding utf8 lab/infra/gitops/canary/workloads.yaml
if ($stableContainer.image -eq $env:IAM_CANARY_IMAGE) { throw 'Candidate trùng stable' }
$issuerValue = @($stableContainer.env | Where-Object name -eq 'ISSUER')[0].value
if (-not $issuerValue) { throw 'Capture cần explicit ISSUER như chương 18' }
$yaml = $yaml.Replace($stableContainer.image, '{{ .Values.identity.image }}')
$yaml = $yaml.Replace($env:IAM_CANARY_IMAGE, '{{ .Values.identity.canaryImage }}')
$yaml = $yaml.Replace($issuerValue, '{{ .Values.identity.issuer }}')
$yaml = $yaml -replace '(?m)^(\s*environment:\s*)\S+\s*$', '${1}{{ .Values.environment }}'
$yaml | Set-Content -Encoding utf8 lab/infra/helm/iam/templates/identity.yaml
Copy-Item lab/infra/gitops/canary/network.yaml lab/infra/helm/iam/templates/identity-canary-network.yaml
$route = Get-Content -Raw -Encoding utf8 lab/infra/gitops/canary/route.yaml
$route = $route.Replace('weight: 100', 'weight: {{ sub 100 (int .Values.identity.canaryWeight) }}')
$route = $route.Replace('weight: 0', 'weight: {{ int .Values.identity.canaryWeight }}')
$route = $route.Replace('iam.local.test', '{{ (urlParse .Values.identity.issuer).host | splitList ":" | first }}')
$route | Set-Content -Encoding utf8 lab/infra/helm/iam/templates/identity-public.yaml
pnpm -C lab add -Dw --save-exact yaml@2.8.1
```

Tạo `lab/scripts/set-canary.mjs` để sửa đúng values môi trường, không regex thay production file ngoài ý muốn:

```javascript
import fs from 'node:fs';
import YAML from 'yaml';
const [environment, image, input] = process.argv.slice(2);
const weight = Number(input);
if (!['dev','staging','prod'].includes(environment) || ![0,1,10,50,100].includes(weight) ||
    !/^ghcr\.io\/.+@sha256:[a-f0-9]{64}$/.test(image ?? '')) throw Error('Invalid rollout input');
const file = `infra/gitops/environments/${environment}/values.yaml`;
const values = YAML.parse(fs.readFileSync(file,'utf8'));
values.identity.canaryImage = image;
values.identity.canaryWeight = weight;
fs.writeFileSync(file,YAML.stringify(values));
```

```powershell
pnpm -C lab exec node scripts/set-canary.mjs staging $env:IAM_CANARY_IMAGE 0
helm lint lab/infra/helm/iam -f lab/infra/gitops/environments/staging/values.yaml
if ($LASTEXITCODE -ne 0) { throw 'Chart invalid' }
helm template iam lab/infra/helm/iam -f lab/infra/gitops/environments/staging/values.yaml |
  kubectl apply --dry-run=server -f -
if ($LASTEXITCODE -ne 0) { throw 'Rendered resources invalid' }
```

Bootstrap **kind staging chưa có Argo** dùng lệnh sau; môi trường GitOps sync commit đã review:

```powershell
kubectl apply --dry-run=server -f lab/infra/gitops/canary
if ($LASTEXITCODE -ne 0) { throw 'Server validation failed' }
# Chỉ bootstrap lab chưa có Argo owner; production dùng sync revision đã review.
kubectl apply -f lab/infra/gitops/canary
kubectl -n iam rollout status deployment/identity-canary --timeout=180s
kubectl -n iam get httproute identity-public -o yaml
kubectl -n iam get endpointslice -l kubernetes.io/service-name=identity-canary
```

Kiểm Accepted/ResolvedRefs đúng generation và BackendTLSPolicy Accepted. Weight 0 giữ canary ngoài public traffic; metadata/JWKS phải đúng. Không public `/internal` hoặc `/health` để smoke.

## Bước 4 — Đo hành vi theo track trước tăng traffic

Cả images cần cùng metric contract. Tại Identity tạo `src/metrics.ts`, thêm `prom-client@15.1.3`, middleware trước routes và `/metrics` được bảo vệ như chương 20. Nếu file đã tồn tại, gộp imports/definitions và dùng **một registry** hiện hữu:

```typescript
import { Counter, Histogram, Registry } from 'prom-client';
import type { RequestHandler } from 'express';
export const registry = new Registry();
const labels = ['service', 'track', 'route', 'status'] as const;
const requests = new Counter({ name:'iam_http_requests_total', help:'HTTP results',
  labelNames:labels, registers:[registry] });
const duration = new Histogram({ name:'iam_http_request_duration_seconds', help:'HTTP latency',
  labelNames:labels, registers:[registry],
  buckets:[0.005,0.01,0.025,0.05,0.1,0.15,0.3,0.5,1,2] });
export const releaseMetrics: RequestHandler = (req,res,next) => {
  const start = performance.now();
  res.once('finish', () => {
    const route = typeof req.route?.path === 'string' ? req.route.path : 'unmatched';
    if (route === '/metrics' || route.startsWith('/health/')) return;
    const tags = {service:process.env.SERVICE_NAME ?? 'identity',
      track:process.env.RELEASE_TRACK ?? 'stable',route,status:String(res.statusCode)};
    requests.inc(tags); duration.observe(tags,(performance.now()-start)/1000);
  });
  next();
};
```

Invoice API dùng cùng metric contract với `SERVICE_NAME=invoice-api`; registry của từng process độc lập. Không dùng token, URL query, account/org ID làm labels. Collector phải scrape **cả** tracks với service selection được review; graph chỉ hiện stable là dữ liệu thiếu, không phải canary tốt. Bổ sung metric đổi schema trước ở release baseline; không dùng stable chưa có metrics để so sánh ngầm với canary mới.

PromQL dưới đây chạy trong dashboard/query API Prometheus của môi trường, thay `canary` bằng `stable` để so sánh. Không chia cho denominator giả nhằm che no-data:

```promql
sum(increase(iam_http_requests_total{service="identity",track="canary",route="/oauth2/introspect"}[5m]))
```

```promql
sum(rate(iam_http_requests_total{service="identity",track="canary",status=~"5.."}[5m]))
/
sum(rate(iam_http_requests_total{service="identity",track="canary"}[5m]))
```

```promql
histogram_quantile(0.95,
  sum by (le) (rate(iam_http_request_duration_seconds_bucket{
    service="identity",track="canary",route="/oauth2/introspect"}[5m])))
```

```promql
histogram_quantile(0.95,
  sum by (le) (rate(iam_http_request_duration_seconds_bucket{
    service="invoice-api",route="/v1/invoices/:id"}[5m])))
```

| Weight canary | Quan sát tối thiểu | Điều kiện tăng tiếp |
|---|---|---|
| 0% | Smoke + old/new schema compatibility | 2 replicas ready; route/TLS; issuer/JWKS; conformance subset |
| 1% | 30 phút, tổng ≥1.000 canary introspections | Gate bên dưới đạt; phân bố traffic quan sát được |
| 10% | 15 phút, ≥1.000 canary introspections | Gate đạt liên tục, không có regression so stable |
| 50% | 15 phút, ≥1.000 canary introspections | Gate đạt, concurrency/code/refresh race tests đạt |
| 100% | 30 phút, ≥1.000 canary introspections | Gate đạt rồi mới promote internal stable |

Mỗi cửa sổ 5 phút cần đủ ≥100 canary introspections, 5xx <0,1%, p95 introspection ≤50 ms và p95 protected Invoice API ≤150 ms; token/authorize latency không quá 1,2 lần baseline đã đo với cùng tải. Synthetic credential hợp lệ trả 401/403 bất ngờ cũng fail dù 5xx bằng 0. Bất kỳ tenant escape, revoked token active hay invalid token được chấp nhận đều rollback ngay. Burn rate vượt budget theo SLO chương 20 thì dừng; gate 0,1%/0,1%=1 nghĩa không cho release mới tiêu budget nhanh hơn SLO lâu dài.

Dùng load introspection và protected API của chương 20 trên staging, không chỉ load discovery. Có thể chạy cửa sổ k6 15 phút nối tiếp, seed refresh fixture mới mỗi lượt. Ít traffic thì kéo dài tối đa 60 phút hoặc bổ sung synthetic staging đã được duyệt; vẫn thiếu mẫu thì trạng thái **insufficient evidence**, không tăng weight. Hai lần refresh cùng token hoặc callback khác replica phải đúng invariant; không bật sticky session để che lỗi shared state.

## Bước 5 — Smoke xác thực, BFF SSO và revoke sau commit

Dùng token user synthetic mới từ fixture chương 20: client `web-a`, audience `invoice-api`, Acme và invoice cùng tenant. Secrets nằm trong environment từ secret store của phiên lab; không viết vào script/evidence. Lấy invoice ID từ fixture thực. Khối sau chạy PowerShell 7:

```powershell
$issuer = 'https://iam.local.test:8443'
$api = 'https://api.local.test:8446'
foreach ($name in 'SMOKE_ACCESS_TOKEN','SMOKE_INVOICE_ID','WEB_A_CLIENT_SECRET','INVOICE_CLIENT_SECRET') {
  if (-not [Environment]::GetEnvironmentVariable($name)) { throw "Thiếu $name" }
}
function BasicAuth([string]$client, [string]$secret) {
  $pair = [Uri]::EscapeDataString($client) + ':' + [Uri]::EscapeDataString($secret)
  'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
}
$metadata = Invoke-RestMethod "$issuer/.well-known/openid-configuration"
if ($metadata.issuer -ne $issuer) { throw 'Issuer changed' }
$jwks = Invoke-RestMethod "$issuer/oauth2/jwks"
if (@($jwks.keys).Count -eq 0) { throw 'JWKS missing' }
$bearer = @{Authorization="Bearer $env:SMOKE_ACCESS_TOKEN"}
$before = Invoke-WebRequest "$api/v1/invoices/$env:SMOKE_INVOICE_ID" -Headers $bearer -SkipHttpErrorCheck
if ($before.StatusCode -ne 200) { throw 'Valid authorized request failed' }
$revoke = Invoke-WebRequest "$issuer/oauth2/revoke" -Method Post -SkipHttpErrorCheck `
  -Headers @{Authorization=(BasicAuth 'web-a' $env:WEB_A_CLIENT_SECRET)} `
  -ContentType 'application/x-www-form-urlencoded' `
  -Body @{token=$env:SMOKE_ACCESS_TOKEN;token_type_hint='access_token'}
if ($revoke.StatusCode -ne 200) { throw 'Revoke not acknowledged' }
1..20 | ForEach-Object {
  $state = Invoke-RestMethod "$issuer/oauth2/introspect" -Method Post `
    -Headers @{Authorization=(BasicAuth 'invoice-api' $env:INVOICE_CLIENT_SECRET)} `
    -ContentType 'application/x-www-form-urlencoded' -Body @{token=$env:SMOKE_ACCESS_TOKEN}
  if ($state.active -ne $false) { throw 'SECURITY: revoked token active' }
}
$after = Invoke-WebRequest "$api/v1/invoices/$env:SMOKE_INVOICE_ID" -Headers $bearer -SkipHttpErrorCheck
if ($after.StatusCode -ne 401) { throw 'API must reject revoked token' }
Remove-Item Env:SMOKE_ACCESS_TOKEN
```

20 calls chưa đảm bảo hit 1% canary; kết hợp per-track metrics và concurrency tests. Revoke access token không mặc nhiên revoke session. Kiểm **session revoke** riêng: login A, mở B cùng browser, xác nhận SSO không hỏi password IAM; consent/org picker có thể xuất hiện. Lưu state ở `.secrets`:

```powershell
pnpm -C lab exec playwright install chromium
pnpm -C lab exec playwright codegen --save-storage .secrets/rollout-browser.json https://app-a.local.test:8444/login
# Trong browser: hoàn thành A, mở B/login, kiểm SSO; đóng cửa sổ để lưu state.
```

Tại BFF thêm `app.use((_req,res,next)=>{res.set('Cache-Control','no-store');next();});` trước routes; tạo `lab/test/release/bff.spec.ts`:

```typescript
import { test, expect } from '@playwright/test';
test.use({ storageState:'.secrets/rollout-browser.json', trace:'off', screenshot:'off' });
for (const origin of ['https://app-a.local.test:8444','https://app-b.local.test:8445']) {
  test(`BFF online state ${origin}`, async ({request}) => {
    const response = await request.get(`${origin}/me`, {maxRedirects:0});
    expect(response.status()).toBe(process.env.IAM_EXPECT_AUTH === 'false' ? 401 : 200);
    expect(response.headers()['cache-control']).toContain('no-store');
  });
}
```

```powershell
$env:IAM_EXPECT_AUTH='true'
pnpm -C lab exec playwright test test/release/bff.spec.ts --workers=1
if ($LASTEXITCODE -ne 0) { throw 'BFF positive check failed' }
# Browser cùng phiên: /me lấy csrf; POST /logout của A, xác nhận IAM logout.
# Không chỉ logout-local: cần IAM session/grants bị revoke theo chương 09.
$env:IAM_EXPECT_AUTH='false'
pnpm -C lab exec playwright test test/release/bff.spec.ts --workers=1
if ($LASTEXITCODE -ne 0) { throw 'BFF accepted revoked IAM session' }
```

Không commit state/trace chứa credentials. Mỗi stage dùng fixture/state mới. Thử dependency outage trên staging: phải trả 503 trong budget, không profile cũ.

## Bước 6 — Promotion PR và đường rollback

Mỗi stage sửa environment values; chart render hai weights tổng 100. Lệnh chỉ tạo local diff, không patch cluster:

```powershell
$nextWeight = 10 # lần lượt 1,10,50,100 sau gate trước
pnpm -C lab exec node scripts/set-canary.mjs staging $env:IAM_CANARY_IMAGE $nextWeight
if ($LASTEXITCODE -ne 0) { throw 'Invalid stage' }
git diff -- lab/infra/gitops/environments/staging/values.yaml
helm template iam lab/infra/helm/iam -f lab/infra/gitops/environments/staging/values.yaml |
  kubectl apply --dry-run=server -f -
if ($LASTEXITCODE -ne 0) { throw 'Invalid rendered release' }
```

Production operator review evidence, weight, digest và schema trước sync commit. Manual approval là bước workflow thực hành. Staging có thể auto-sync; production không tăng weight vì pods Ready. Ghi Git merge, Argo Synced và route observedGeneration để đo control-plane delay.

Canary fail: emergency PR đặt **stable 100/canary 0**, sync và kiểm synthetic. Rollback không rebuild/restore DB nhưng vẫn chờ control plane converge. Patch ngoài Git chỉ qua emergency RBAC/runbook và reconcile commit; CI không có cluster-admin. Chờ weight 0 có hiệu lực trước scale-down.

Sau public 100% đạt gate, PR đổi stable sang canary digest; giữ selector và rollingUpdate `maxUnavailable:0`. Public vẫn tới canary, internal API tests giám sát stable rolling. Khi internal latency/revoke đạt, route stable 100/canary 0, quan sát 30 phút. Giữ canary hai replicas và old digest trong rollback window 24 giờ của lab.

Rollback image không rollback security state. Schema expand còn tương thích; token đã revoke vẫn inactive trước/sau đổi image. Nếu migration phá tương thích hoặc mất dữ liệu, dừng traffic theo incident runbook và khôi phục có security reset, không chạy down migration tùy ý.

Blue-green giữ hai fleet, chuyển 100% một lần: phù hợp khi đủ ngân sách compute và cần thử toàn môi trường trước cutover. Canary cần telemetry/mẫu đủ lớn. Cả hai vẫn cần state compatibility; database copy cũ có thể hồi sinh quyền đã revoke.

## Failure lab, troubleshooting và nghiệm thu

Ở staging, dùng image canary thiếu readiness: không tăng từ 0%. Dùng canary TLS policy hostname sai: route/service có thể tồn tại nhưng request lỗi, gate phải fail. Dùng regression image trả UserInfo 401 cho principal hợp lệ: synthetic phát hiện dù 5xx đẹp. Chặn DB canary bằng policy chỉ trên canary: 503 có giới hạn, traffic stable vẫn hoạt động. Không đưa auth-bypass flag vào image chỉ để tạo failure lab.

Nếu 1% tạo gần 50% tải nội bộ, kiểm selector Service identity có vô tình chọn canary. 502/503 sau tăng weight: xem ResolvedRefs, EndpointSlice, BackendTLSPolicy/SAN và NetworkPolicy trước sửa code. Callback ngẫu nhiên lỗi: kiểm shared interaction/session store, cùng secrets và key compatibility; không dùng sticky session chữa. Dashboard canary trống: kiểm target scrape/track label, đánh dấu no-data. Argo tự hoàn tác weight: có hai sources cùng quản resource hoặc patch ngoài Git.

Lưu `lab/evidence/p05/`: revision/weights, request counts, PromQL/timestamp, SSO/revoke, digests, schema, approval và thời gian phục hồi. Hoàn thành khi có rollout thành công và canary Ready bị semantic gate rollback. Chưa chạy ghi pending. Nguồn: [Argo sync phases](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/), [Prometheus histogram quantiles](https://prometheus.io/docs/practices/histograms/).
