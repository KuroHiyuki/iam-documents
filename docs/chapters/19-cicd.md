# 19. CI/CD, supply chain và migration có đường phục hồi

[Mục lục](../../README.md) · [Trước: Kubernetes](18-kubernetes.md) · [Tiếp: SRE và production](20-sre-production.md)

## Điều kiện và kết quả cần đạt

Bạn có ứng dụng chạy được trong Compose/kind và các negative tests của chương trước. Dockerfile, workflow, migration runner dưới đây là file **người học tạo trong lab/repository của mình**, không phải pipeline đã chạy khi đọc sách. GitHub Actions chỉ nhận workflow tại root `.github/workflows/`; đặt file ở `lab/.github/` sẽ không chạy. Source ứng dụng vẫn nằm `lab/`.

CI trả lời “commit này có đủ bằng chứng để phát hành?”, CD trả lời “môi trường đang chạy đúng artifact đã duyệt?”. Chúng không dùng chung credential toàn quyền cluster. Pull request từ fork được test nhưng không có registry push token, signing permission hoặc database production DSN. Production release dùng GitOps pull: Argo CD đọc manifest được review, không để mỗi CI job tự `kubectl apply` vào production.

```mermaid
flowchart LR
    PR[Pull request] --> C[Typecheck + unit + integration]
    C --> B[Build artifact một lần]
    B --> R[GHCR digest + SBOM + provenance]
    R --> V[Verify và promotion PR]
    V --> G[GitOps values được merge]
    G --> A[Argo CD]
    A --> M[Expand migration Job]
    M --> D[Rolling deployment]
    D --> S[Smoke + online revoke checks]
```

## Bước 1 — Chuẩn hóa lệnh kiểm tra trước tự động hóa

Chốt `lab/.node-version` là `24.22.1`, `lab/package.json.packageManager` là `pnpm@10.32.1` theo [versions](../reference/versions.md); commit lockfile. Mọi package có `typecheck` và `build`; không dùng `--if-present` để che package thiếu kiểm tra. Tạo `lab/scripts/ci/verify.ps1`:

```powershell
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
Set-Location $repoRoot
pnpm -C lab install --frozen-lockfile
if ($LASTEXITCODE -ne 0) { throw 'Lockfile/install failed' }
pnpm -C lab -r run typecheck
if ($LASTEXITCODE -ne 0) { throw 'Typecheck failed' }
pnpm -C lab -r run build
if ($LASTEXITCODE -ne 0) { throw 'Build failed' }
pnpm -C lab exec vitest run --config vitest.integration.config.ts
if ($LASTEXITCODE -ne 0) { throw 'Test failed' }
```

Tạo config `lab/vitest.integration.config.ts` với `defineConfig` import từ `vitest/config`, `test.include=['services/*/test/**/*.test.ts','packages/*/test/**/*.test.ts']`, `fileParallelism:false`, `testTimeout:15000`, `reporters:['default','junit']`, `outputFile:'evidence/ch19/junit.xml'`. Test fixtures tạo schema/database tạm, seed fixture và cleanup riêng; tên DB có suffix `_test`. Guard fixture không cho chạy trên DSN production, staging hoặc DB không có suffix test. Tests không được ghi vào DB developer đang đăng nhập.

Tests security bắt buộc có: authorization-code replay, PKCE/redirect/nonce sai, refresh-family revoke commit, tenant isolation, online membership/session/client disable, revoked assignment và dependency outage. Mỗi test phải assert side effect DB, không chỉ HTTP status. Test concurrency dùng barrier và transaction thật thay sleep tùy ý. Hai ứng dụng SSO và logout được browser-test trên môi trường staging TLS ở bước 6.

## Bước 2 — CI pull request có dependencies thật

Tạo `.github/workflows/lab-ci.yml`. Actions được pin full commit SHA đã tra GitHub API; cập nhật pin cần review release/security notes. Mẫu này chạy integration với PostgreSQL/Redis/RabbitMQ ephemeral, không khởi động production services:

```yaml
name: lab-ci
on:
  pull_request:
    paths: ["lab/**", ".github/workflows/lab-ci.yml"]
  push:
    branches: [main]
    paths: ["lab/**", ".github/workflows/lab-ci.yml"]
permissions: {contents: read}
concurrency:
  group: lab-ci-${{ github.ref }}
  cancel-in-progress: true
jobs:
  verify:
    runs-on: ubuntu-24.04
    timeout-minutes: 20
    services:
      postgres:
        image: postgres:18
        env:
          POSTGRES_USER: iam_test
          POSTGRES_PASSWORD: ephemeral-ci-only
          POSTGRES_DB: iam_test
        ports: ["5432:5432"]
        options: >-
          --health-cmd="pg_isready -U iam_test -d iam_test"
          --health-interval=5s --health-timeout=3s --health-retries=20
      redis:
        image: redis:8
        ports: ["6379:6379"]
        options: --health-cmd="redis-cli ping" --health-interval=5s --health-retries=20
      rabbitmq:
        image: rabbitmq:4-management
        env: {RABBITMQ_DEFAULT_USER: iam_test, RABBITMQ_DEFAULT_PASS: ephemeral-ci-only}
        ports: ["5672:5672"]
        options: --health-cmd="rabbitmq-diagnostics -q ping" --health-interval=5s --health-retries=20
    env:
      NODE_ENV: test
      TEST_DATABASE_URL: postgres://iam_test:ephemeral-ci-only@127.0.0.1:5432/iam_test
      TEST_REDIS_URL: redis://127.0.0.1:6379/15
      TEST_AMQP_URL: amqp://iam_test:ephemeral-ci-only@127.0.0.1:5672
    steps:
      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6
        with: {persist-credentials: false}
      - uses: actions/setup-node@249970729cb0ef3589644e2896645e5dc5ba9c38 # v6
        with: {node-version-file: lab/.node-version}
      - name: Install pinned pnpm
        run: npm install --global pnpm@10.32.1
      - name: Verify
        shell: pwsh
        run: ./lab/scripts/ci/verify.ps1
      - uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4
        if: always()
        with:
          name: lab-ci-evidence
          path: lab/evidence/ch19/junit.xml
          if-no-files-found: warn
          retention-days: 7
```

Password trong job là fixture cho service container bị hủy cùng runner, không phải credential IAM hay production secret. Đừng tái sử dụng nó ngoài test. `TEST_DATABASE_URL` là bootstrap DSN; fixture tạo database riêng từng service rồi áp SQL owner tương ứng bằng migration role test. Không chạy mọi schema owner vào cùng namespace và coi đó là isolation test.

Trước production, pin digest ba service images đã kiểm chứng vào manifest versions. PR chỉ sửa Markdown không cần chạy toàn lab; root giáo trình có checker riêng. Branch protection yêu cầu check `lab-ci / verify`; thử một PR cố tình làm replay test fail để chứng minh check thực sự chặn merge. Không dùng `pull_request_target` checkout code không tin cậy rồi trao secret.

## Bước 3 — Image nhỏ, immutable và build một lần

Tạo `lab/infra/Dockerfile`, build context `lab`. Thêm `.dockerignore` loại `.secrets`, `.env`, evidence, node_modules và Git. Service package khai báo `files:["dist","migrations"]`; entrypoint `src/index.ts` build thành `dist/index.js`. Nếu chương trước dùng tên khác, đổi entrypoint ở package/Dockerfile cùng một commit:

```dockerfile
FROM node:24.22.1-bookworm-slim AS build
WORKDIR /src
RUN npm install --global pnpm@10.32.1
COPY . .
RUN pnpm install --frozen-lockfile
RUN pnpm -r run build
ARG PACKAGE=@iam/identity
RUN pnpm --filter "$PACKAGE" deploy --legacy --prod /out

FROM node:24.22.1-bookworm-slim AS runtime
ENV NODE_ENV=production
WORKDIR /app
COPY --from=build --chown=node:node /out/ ./
USER node
CMD ["node", "dist/index.js"]
```

`--legacy` chọn deployment behavior tương thích workspace hiện tại; nếu chuyển injected workspace packages, thay cấu hình và test deploy artifact thực tế, không chỉ build TypeScript. Password hashing native addon phải build/runtime cùng libc và architecture. Base tag phục vụ bootstrap; release pipeline resolve/pin base digest và lưu provenance, định kỳ rebuild khi base có bản vá. Không COPY private signing key hoặc prod `.env` vào layer rồi xóa ở layer sau.

```powershell
docker build -f lab/infra/Dockerfile --build-arg 'PACKAGE=@iam/identity' -t iam/identity:lab lab
docker run --rm --entrypoint node iam/identity:lab -e "console.log(process.getuid())"
```

Output kỳ vọng UID nonzero, không phải một số được sách đo sẵn. Lặp PACKAGE cho các services/apps, chạy container read-only với env/volume cần thiết rồi smoke `/health/live`. Image được push một lần và promote bằng digest; staging và production không build lại cùng commit với dependency khác.

## Bước 4 — GHCR, provenance và promotion

Tạo workflow release chạy **sau CI thành công** trên protected main hoặc release tag đã bảo vệ, không chỉ `push` bất kỳ. Dùng job `needs:verify` khi gộp workflow; nếu tách workflow, xác minh kết quả check và source SHA trước publish. Đặt permissions trên riêng publish job: `contents:read`, `packages:write`, `id-token:write`, `attestations:write`.

Đoạn Bash sau dành Linux/CI, không dán nguyên vào PowerShell. `GH_TOKEN` lấy từ GITHUB_TOKEN của job và không in ra:

```bash
set -euo pipefail
image="ghcr.io/${GITHUB_REPOSITORY,,}/identity"
printf '%s' "$GH_TOKEN" | docker login ghcr.io --username "$GITHUB_ACTOR" --password-stdin
mkdir -p lab/evidence/ch19
docker buildx build --file lab/infra/Dockerfile --build-arg PACKAGE=@iam/identity \
  --tag "$image:$GITHUB_SHA" --provenance=mode=max --sbom=true --push \
  --metadata-file lab/evidence/ch19/image-metadata.json lab
digest="$(jq -r '."containerimage.digest"' lab/evidence/ch19/image-metadata.json)"
test "$digest" != null
printf 'image=%s\ndigest=%s\n' "$image" "$digest" >> "$GITHUB_OUTPUT"
```

Step có `id:build`, env `GH_TOKEN:${{secrets.GITHUB_TOKEN}}`. Sau đó gọi `actions/attest-build-provenance@977bb373ede98d70efdf65b84cb5f73e068dcc2a` với `subject-name:${{steps.build.outputs.image}}`, `subject-digest:${{steps.build.outputs.digest}}`, `push-to-registry:true`. GHCR package private cần read credential ở cluster, không dùng GITHUB_TOKEN hết hạn làm imagePullSecret lâu dài. Mirror SBOM/provenance ngoài registry nếu retention yêu cầu.

Trước tạo promotion PR, chạy `gh attestation verify oci://<image>@<digest> --repo <owner/repo> --signer-workflow <owner/repo>/.github/workflows/release.yml`; các giá trị lấy từ artifact/source của job, không từ issue/comment. Fail khi subject digest/workflow/repository không đúng. Scan CVEs và secrets trong image, cấm critical không có quyết định ngoại lệ có thời hạn. Scan không thay threat model và protocol tests. Production admission phải chặn mutable tags và artifact không đáp ứng signature/provenance policy; dùng policy controller đã chọn, negative-test một image unsigned trước mở production. Không gọi bước verify trong CI là admission enforcement.

## Bước 5 — Argo CD và database migration

Cài Argo CD 3.5.6 theo manifest release, tải về file để review/checksum trước apply; không dùng URL nhánh `stable` biến động. Namespace argocd riêng, login quản trị độc lập với IAM đang xây để tránh lockout dây chuyền. Tạo AppProject chỉ được đọc GitOps repo và deploy namespace iam, cấm cluster-scoped resources/namespace wildcard cho application project.

```powershell
New-Item -ItemType Directory -Force lab/infra/gitops/vendor | Out-Null
Invoke-WebRequest 'https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.6/manifests/install.yaml' `
  -OutFile lab/infra/gitops/vendor/argocd-3.5.6.yaml
Get-FileHash lab/infra/gitops/vendor/argocd-3.5.6.yaml -Algorithm SHA256
kubectl create namespace argocd
kubectl apply -n argocd --server-side -f lab/infra/gitops/vendor/argocd-3.5.6.yaml
```

Tạo `Application` source path `lab/infra/helm/iam`, `targetRevision` là branch GitOps đã bảo vệ, Helm `valueFiles:[values-staging.yaml]`, destination namespace iam. Promotion PR sửa `identity.image` thành full `ghcr.io/owner/repo/identity@sha256:...`. Auto-sync cho staging sau tests; production sync theo change window/approval đã quy định. Chặn sửa pod thủ công bằng RBAC; mọi hotfix emergency phải reconcile về Git.

Mỗi service có migration runner và migration credential riêng. Runner dùng `pg.PoolClient`, acquire PostgreSQL advisory lock cố định theo owner, bảng `schema_migrations(version,checksum,applied_at)`, từ chối checksum đổi, áp file theo thứ tự trong transaction khi DDL hỗ trợ. `CREATE INDEX CONCURRENTLY` chạy migration riêng ngoài transaction, có kiểm tra index invalid sau interruption. Advisory lock không được trả connection về pool khi vẫn giữ lock. Command cùng image là `node dist/migrate.js`; file migration được đóng gói vào image bằng bước 3, exit nonzero khi lỗi.

Thêm Job Helm có `argocd.argoproj.io/hook:PreSync`, `hook-delete-policy:BeforeHookCreation,HookSucceeded`, `sync-wave:"-1"`, `backoffLimit:0`, `activeDeadlineSeconds:300`. Job dùng **cùng digest** bản release, command runner trên, envFrom secret `identity-migration`; Deployment dùng secret runtime không có ALTER. Lưu Job failure logs trước cleanup. [Argo sync waves](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/) điều phối thứ tự sync; chúng không tự chứng minh schema tương thích app cũ.

Expand/contract ví dụ: release N thêm cột nullable/index mới; N và N−1 đọc được schema; N+1 dual-write/backfill có progress marker; N+2 chuyển reads; chỉ sau hết rollback window mới drop cột. App rollback là revert image digest trong Git khi schema còn tương thích, không chạy `down.sql` xóa dữ liệu. Migration đã làm mất dữ liệu cần restore/PITR vào môi trường cô lập và security reset theo runbook, không “helm rollback là xong”.

## Bước 6 — Release tests và failure lab

Sau staging sync, browser tests chạy Playwright từ `lab/apps/web-a/test/` và web-b: login một lần, mở app thứ hai, consent/client binding, logout và session revoke, no cross-org invoices. Runner trust staging CA thật; không skip TLS. Test principal thuộc tenant synthetic riêng, cleanup qua owner API, không dùng tài khoản operator. Release workflow cần stage smoke check online introspection và grant revoke sau commit; không chỉ health endpoint.

Failure lab gồm ba lượt: migration invalid SQL phải chặn rollout; image mới readiness fail phải giữ replicas cũ; image hợp lệ nhưng policy regression phải bị post-deploy negative test phát hiện và rollback digest. Đối chiếu Git commit, digest, schema version và decision IDs để biết đã quay về đâu. Revoke trước rollout rồi kiểm tra sau rollback: token/quyền không được sống lại vì restore schema/state.

Troubleshooting: workflow không chạy kiểm tra vị trí root và paths filter; thiếu native module kiểm tra deploy artifact/libc; GHCR 403 kiểm tra packages permission/repo package linkage; Argo OutOfSync lặp kiểm tra controller nào đang sửa field; PreSync treo kiểm tra advisory lock/Job deadline. Không dùng force-delete Job đang migration nếu chưa biết transaction đã commit.

## Definition of Done và nguồn

- Một PR lỗi security test bị branch protection chặn; PR fork không nhận release secret.
- Artifact digest nhất quán qua build, attest, promotion và rollout; unsigned artifact bị admission test từ chối trước production.
- Migration hai phiên bản và rollback digest đã diễn tập; không có runtime DDL credential.
- Staging SSO/revoke tests, evidence, reviewer và release rollback point được lưu, không ghi test chưa chạy là passed.

Nguồn: [GitHub publish images](https://docs.github.com/en/actions/tutorials/publish-packages/publish-docker-images), [secure Actions](https://docs.github.com/en/actions/reference/security/secure-use), [artifact attestations](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations), [Argo 3.5.6 release](https://github.com/argoproj/argo-cd/releases/tag/v3.5.6), [PostgreSQL explicit locking](https://www.postgresql.org/docs/18/explicit-locking.html). Automation trong chương cần được bạn chạy và ghi bằng chứng; template không chứng nhận supply chain của một deployment chưa tồn tại.
