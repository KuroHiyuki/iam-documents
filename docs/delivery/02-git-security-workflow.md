# P02 — Từ một thay đổi nhỏ đến pull request được kiểm chứng

[Trang đầu](../../README.md) · Đọc cùng [chương 03](../chapters/03-workspace-bootstrap.md) và [chương 19](../chapters/19-cicd.md)

## Mục tiêu, điều kiện và ranh giới tin cậy

Sau bài này, một lỗi replay token, dependency nguy hiểm hoặc secret bị commit phải ngăn thay đổi đi vào `main`. Bạn cần workspace `lab/` chạy được, Git, GitHub CLI đã đăng nhập và repository thực hành do mình quản lý. Lệnh chạy tại root repository giáo trình; workflow nằm ở `.github/workflows/`, ứng dụng ở `lab/`. Đây là hướng dẫn để bạn cấu hình repository của mình; tài liệu không tự thay đổi GitHub hay tạo PR từ tài khoản của bạn.

DevOps thiết lập đường đi và bằng chứng; người thiết kế xác định invariant cần bảo vệ, chẳng hạn tenant isolation. Scanner không thay thế việc review nghiệp vụ IAM. PR từ fork được coi là code không tin cậy, kể cả khi tác giả quen biết. Dùng GitHub-hosted runner dùng một lần; không đưa PR chưa tin cậy vào self-hosted runner có đường mạng production.

## Bước 1 — Làm một thay đổi có thể review

Dùng trunk-based development: `main` luôn phát hành được, feature branch tồn tại ngắn, mỗi PR chỉ giải quyết một hành vi. Không tạo nhánh `dev` sống nhiều tháng rồi merge một lần. Ví dụ thêm test refresh reuse trước khi sửa handler:

```powershell
git status --short
git fetch origin
git switch main
git pull --ff-only origin main
git switch -c fix/refresh-reuse-commit
# Tự sửa test và implementation trong editor.
git diff --check
git diff --stat
pnpm -C lab exec vitest run --config vitest.integration.config.ts
if ($LASTEXITCODE -ne 0) { throw 'Regression test chưa đạt' }
git add lab/services/identity/src lab/services/identity/test
git diff --cached
git commit -m 'fix(identity): commit family revoke before invalid_grant'
git push -u origin fix/refresh-reuse-commit
```

Trước khi push, kiểm tra staged diff không chứa `.env`, `.secrets`, token hoặc output test thô. Không dùng `git add .` theo thói quen khi đang làm security lab. Viết nội dung PR vào file `lab/.secrets/pr-body.md` để không làm hỏng newline hoặc shell escaping:

```text
Refresh token bị dùng lại hiện ném lỗi trước commit nên revoke bị rollback.
Thay đổi commit family revoke rồi mới trả invalid_grant.

Validation: integration test assert mọi access token trong family inactive,
kể cả khi hai replica cùng refresh. Không có migration.
Rollback: revert commit; chỉ thực hiện nếu regression test vẫn bảo vệ revoke.
```

```powershell
gh pr create --base main --title 'Commit refresh-family revocation' --body-file lab/.secrets/pr-body.md
gh pr checks --watch
```

Reviewer đọc test trước, rồi transaction boundary, client binding, logging và tình huống đồng thời. Diff lớn hơn mức có thể giải thích trong một phiên review nên chia thành PR schema tương thích, PR code và PR chuyển traffic. Feature chưa hoàn thành có thể sau flag mặc định tắt; flag không được vô hiệu hóa introspection hoặc tenant checks.

## Bước 2 — Phân công review và khóa main

Tạo `.github/CODEOWNERS`; thay team minh họa bằng team tồn tại và có quyền write trong organization của bạn:

```text
*                              @your-org/iam-maintainers
/lab/services/identity/         @your-org/identity-security
/lab/services/authorization/    @your-org/identity-security
/lab/infra/                     @your-org/platform
/.github/                      @your-org/platform
/.github/CODEOWNERS             @your-org/iam-maintainers
```

Trong Settings → Rules → Rulesets, tạo branch ruleset **Active**, target default branch `main`, bypass list rỗng. Bật require pull request, một approval của người khác, code owner review, dismiss stale approvals khi code đổi, require approval của lần push mới nhất, resolve conversations, block force push/delete. Bật required status checks và require up-to-date branch. Không thêm admin hoặc release bot vào bypass. Quyền admin vẫn có thể sửa ruleset: giảm số admin, bật MFA và lưu audit thay đổi cấu hình.

Required check names của bài là **`iam-integration`** và **`iam-security`**; đây là trường `jobs.<id>.name`, không tự gõ chuỗi `workflow / job` từ giao diện. Đổi `verify` trong workflow chương 19 thành `name: iam-integration`; bỏ `paths` filter trên workflow bắt buộc để PR chỉ sửa tài liệu cũng tạo kết quả, tránh check chờ vô hạn. Chạy workflow một lần rồi chọn đúng context và GitHub Actions App trong ruleset. Xác nhận tên thật bằng API:

```powershell
$headSha = gh pr view --json headRefOid --jq .headRefOid
gh api "repos/{owner}/{repo}/commits/$headSha/check-runs" --jq '.check_runs[] | {name,conclusion}'
```

Protected branches/rulesets có phạm vi hỗ trợ khác nhau giữa public/private và gói tài khoản. Kiểm tra [protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches) trước khi chọn repository lab; không ghi “enforced” khi tài khoản chỉ lưu được cấu hình mà không áp dụng.

Nếu học một mình, làm self-review theo checklist rồi ghi **solo lab, chưa có independent review**. Có thể dùng repository lab riêng với approval requirement bằng 0 để học các gate kỹ thuật; đó là cấu hình lab được công bố, không phải production sign-off. Muốn chứng minh cổng hai người, mời một người thật có quyền review. Hai tài khoản do cùng bạn điều khiển không tạo ra kiểm soát độc lập.

## Bước 3 — Chia kiểm thử theo thứ cần chứng minh

Unit test kiểm tra hàm thuần như scope intersection; integration dùng PostgreSQL transaction thật cho code consume/refresh race/RLS; browser test kiểm tra cookie, redirect và SSO qua TLS. Không mock DB rồi gọi đó là bằng chứng row locking. Tạo `lab/vitest.unit.config.ts`:

```typescript
import { defineConfig } from 'vitest/config';
export default defineConfig({ test: {
  include: ['services/*/test/**/*.unit.test.ts', 'apps/*/test/**/*.unit.test.ts',
    'packages/*/test/**/*.unit.test.ts'],
  reporters: ['default'],
} });
```

Trong integration config chương 19, loại `**/*.unit.test.ts` khỏi tập test integration. Đặt ít nhất một test thực ở mỗi tập; không dùng `passWithNoTests`. Thêm ESLint tại workspace root, commit dependency pins và lockfile:

```powershell
pnpm -C lab add -Dw --save-exact eslint@10.13.0 @eslint/js@10.0.1 typescript-eslint@8.72.1 vitest@5.0.5 @playwright/test@1.64.1
```

Tạo `lab/eslint.config.mjs`; lint kiểm quy tắc code, TypeScript compiler kiểm kiểu:

```javascript
import js from '@eslint/js';
import ts from 'typescript-eslint';
export default ts.config(
  { ignores: ['**/dist/**', '**/node_modules/**', 'evidence/**', '.secrets/**'] },
  { files: ['**/*.ts'], extends: [js.configs.recommended, ...ts.configs.recommended] },
);
```

Root Vitest/Playwright cần thiết cho `pnpm -C lab exec` và config root; dependency chỉ cài trong service không tự resolve từ workspace root. Thêm scripts `lint: eslint . --max-warnings 0`, `test:unit: vitest run --config vitest.unit.config.ts` vào `lab/package.json`. Sửa lỗi thay vì disable toàn bộ rule.

## Bước 4 — CI security không nhận production credentials

Resolve scanner image thành digest trên máy lab, lưu giá trị vào GitHub Actions repository variables `GITLEAKS_IMAGE` và `TRIVY_IMAGE`. Variables này là metadata công khai, không phải secrets. Bản chọn khi biên soạn: Gitleaks 8.30.1, Trivy 0.76.1; review release/advisory trước khi cập nhật:

```powershell
docker pull ghcr.io/gitleaks/gitleaks:v8.30.1
if ($LASTEXITCODE -ne 0) { throw 'Pull Gitleaks failed' }
$gitleaksImage = docker image inspect ghcr.io/gitleaks/gitleaks:v8.30.1 --format '{{index .RepoDigests 0}}'
docker pull aquasec/trivy:0.76.1
if ($LASTEXITCODE -ne 0) { throw 'Pull Trivy failed' }
$trivyImage = docker image inspect aquasec/trivy:0.76.1 --format '{{index .RepoDigests 0}}'
gh variable set GITLEAKS_IMAGE --body $gitleaksImage
gh variable set TRIVY_IMAGE --body $trivyImage
```

Tạo `.github/workflows/iam-pr-security.yml`. Pins checkout/setup-node theo chương 19; CodeQL pin `v4.39.1` được đối chiếu upstream. Job container chạy mọi image chứ không chỉ Identity:

```yaml
name: iam-pr-security
on:
  pull_request:
  push: {branches: [main]}
permissions: {contents: read}
jobs:
  quality:
    name: iam-quality
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803
        with: {persist-credentials: false}
      - uses: actions/setup-node@249970729cb0ef3589644e2896645e5dc5ba9c38
        with: {node-version-file: lab/.node-version}
      - run: npm install -g pnpm@10.32.1
      - run: pnpm -C lab install --frozen-lockfile
      - run: pnpm -C lab run lint
      - run: pnpm -C lab -r run typecheck
      - run: pnpm -C lab run test:unit
  sca:
    name: iam-sca
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803
        with: {persist-credentials: false}
      - uses: actions/setup-node@249970729cb0ef3589644e2896645e5dc5ba9c38
        with: {node-version-file: lab/.node-version}
      - run: npm install -g pnpm@10.32.1
      - run: pnpm -C lab audit --audit-level high
  secrets:
    name: iam-secret-scan
    runs-on: ubuntu-24.04
    env: {SCANNER: '${{ vars.GITLEAKS_IMAGE }}'}
    steps:
      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803
        with: {fetch-depth: 0, persist-credentials: false}
      - run: |
          test -n "$SCANNER"
          docker run --rm -v "$PWD:/repo:ro" "$SCANNER" git /repo --redact --exit-code 1
  containers:
    name: iam-container-${{ matrix.component }}
    runs-on: ubuntu-24.04
    strategy:
      fail-fast: false
      matrix: {component: [identity, authorization, audit, governance, invoice-api, web-a, web-b]}
    env:
      COMPONENT: ${{ matrix.component }}
      SCANNER: ${{ vars.TRIVY_IMAGE }}
    steps:
      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803
        with: {persist-credentials: false}
      - run: |
          set -euo pipefail
          test -n "$SCANNER"
          docker build -f lab/infra/Dockerfile --build-arg "PACKAGE=@iam/$COMPONENT" -t "iam-ci:$COMPONENT" lab
          mkdir -p "$RUNNER_TEMP/iam-scan"
          if docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
            -v "$RUNNER_TEMP/iam-scan:/report" "$SCANNER" image --quiet \
            --scanners vuln,secret --severity HIGH,CRITICAL --exit-code 1 \
            --format json --output /report/result.json "iam-ci:$COMPONENT"; then
            echo 'Container scan passed'
          else
            echo 'Container scan failed; investigate in a controlled environment without publishing secret values'
            exit 1
          fi
  codeql:
    name: iam-codeql
    runs-on: ubuntu-24.04
    permissions: {contents: read, security-events: write}
    steps:
      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803
        with: {persist-credentials: false}
      - uses: github/codeql-action/init@9b3254085494b55a0f7c4c2b3d2d52cc712ce370
        with: {languages: javascript-typescript, build-mode: none}
      - uses: github/codeql-action/analyze@9b3254085494b55a0f7c4c2b3d2d52cc712ce370
        with: {category: /language:javascript-typescript}
  gate:
    name: iam-security
    if: always()
    needs: [quality, sca, secrets, containers, codeql]
    runs-on: ubuntu-24.04
    env: {RESULTS: '${{ toJSON(needs) }}'}
    steps:
      - run: |
          jq -e 'all(.[]; .result == "success")' <<< "$RESULTS"
```

Docker socket nằm trong runner dùng một lần, không trên máy production. Gitleaks redact output; Trivy ghi report tại runner, không upload vì có thể chứa đoạn source nhạy cảm. Điều tra lại trong môi trường kiểm soát và chỉ xuất rule/path đã che giá trị. Scanner lỗi mạng cũng phải fail, không `|| true`.

CodeQL hỗ trợ repository public hoặc các repository organization đủ gói và bật GitHub Code Security. Nếu repo private chưa đủ điều kiện, dùng public repository chứa code lab đã loại dữ liệu thật, hoặc cấp license trước gate này. Không âm thầm skip CodeQL rồi ghi SAST đã đạt. JavaScript/TypeScript dùng `build-mode:none`; job thành công nghĩa phân tích hoàn tất, **chưa có nghĩa không có findings**. Trong ruleset thêm Require code scanning results → CodeQL → chặn security severity high/critical và error-level findings. Theo [advanced setup](https://docs.github.com/en/code-security/how-tos/find-and-fix-code-vulnerabilities/configure-code-scanning/configuring-advanced-setup-for-code-scanning) và [ruleset code scanning](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets), đây là cổng riêng với status check.

Workflow PR không khai báo environment production, registry push, OIDC token hoặc secret staging. `security-events:write` chỉ ở job CodeQL; permission từ fork bị GitHub giới hạn theo sự kiện. Không bật gửi write token/secrets cho fork để sửa lỗi SARIF; kiểm tra cách upload hỗ trợ `pull_request` của CodeQL. Tuyệt đối không dùng `pull_request_target` checkout HEAD của fork rồi chạy script. [GITHUB_TOKEN](https://docs.github.com/en/actions/tutorials/authenticate-with-github_token) vẫn truy cập được qua context trong action, nên `persist-credentials:false` không thay permission tối thiểu.

## Bước 5 — Dependency maintenance và release evidence

Tạo `.github/dependabot.yml`:

```yaml
version: 2
updates:
  - package-ecosystem: npm
    directory: /lab
    schedule: {interval: weekly}
    open-pull-requests-limit: 5
  - package-ecosystem: github-actions
    directory: /
    schedule: {interval: weekly}
  - package-ecosystem: docker
    directory: /lab/infra
    schedule: {interval: weekly}
```

Dependabot mở PR, người review đọc changelog, lockfile, transitive changes rồi chạy gate như PR thường; không auto-merge major upgrades. `pnpm audit` kiểm CVE của dependency, Gitleaks tìm credential trong lịch sử, CodeQL phân tích dòng dữ liệu nguy hiểm, Trivy kiểm artifact thực tế: bốn lớp có phạm vi khác nhau. [Dependabot reference](https://docs.github.com/en/code-security/reference/supply-chain-security/dependabot-options-reference) giải thích directory và ecosystem.

Browser E2E chạy trên staging TLS sau promotion của chương 19, check tên **`iam-staging-e2e`**: login A, mở B dùng IAM session, đọc `/me`, đọc invoice, logout/revoke rồi protected route phải thất bại. Nó là release gate, không phải job fork được dùng staging credentials. Dùng tenant synthetic, credential environment staging và Playwright trace không ghi password/token; không chuyển artifact PR chưa tin cậy vào job có secrets để chạy. P05 có luồng smoke cụ thể.

Sau protected-main CI, chương 19 build một lần, tạo SBOM/provenance và ký artifact bằng attestation gắn workflow identity; P05 promote đúng digest. Trivy có thể xuất inventory bằng `trivy image --format cyclonedx --output sbom.json IMAGE@DIGEST`. Xác minh provenance bằng `gh attestation verify` của chương 19; signature chứng minh nguồn artifact, không chứng minh hết vulnerability. Admission production phải từ chối unsigned/wrong-workflow artifact; [Trivy image scanning](https://trivy.dev/docs/latest/target/container_image/) và [Gitleaks CLI](https://github.com/gitleaks/gitleaks) là nguồn syntax.

## Failure lab, troubleshooting và Definition of Done

Mở PR cố tình làm test refresh reuse fail, kiểm tra `iam-integration` đỏ và merge bị chặn. Sửa test rồi thêm lint error để `iam-security` đỏ. Thử CodeQL finding trong fixture lab được cô lập, xác nhận cổng findings chặn dù analysis job xanh. Với secret scanner, dùng custom rule bắt chuỗi canary vô hại chỉ trong nhánh test; không tạo AWS key thật để thử. Đóng PR thử nghiệm thay vì merge fixture lỗi vào main. Kiểm tra fork run không có secret hoặc quyền publish bằng job permissions hiển thị trong run, không in environment.

Để thử scanner, thêm `.gitleaks.toml` sau trong nhánh lab và thêm `--config /repo/.gitleaks.toml` vào lệnh Gitleaks của nhánh đó:

```toml
[extend]
useDefault = true
[[rules]]
id = "iam-lab-canary"
description = "Harmless IAM lab fixture"
regex = '''IAM_LAB_CANARY_[A-Z]{12}'''
```

```powershell
('IAM_LAB_CANARY_' + ('X' * 12)) | Set-Content lab/secret-canary.txt
git add .gitleaks.toml lab/secret-canary.txt
git commit -m 'test: prove secret gate blocks harmless canary'
git push
```

Workflow phải đỏ dù chuỗi này không mở được bất kỳ tài khoản nào. Chỉ xóa file ở commit kế tiếp vẫn bị historical scan phát hiện; đóng nhánh thử nghiệm và tạo nhánh sạch từ main, không bỏ full-history scan để làm xanh.

Check mãi Pending: kiểm paths filter, tên job và required check App. Mọi job xanh nhưng merge được với finding high: kiểm rule CodeQL severity. CODEOWNERS không yêu cầu review: kiểm team quyền write và rule require code owner. Solo author không approve được PR của mình là hành vi đúng. Audit/GHCR timeout không được phân loại “không có lỗi”. Exception cần owner, lý do, compensating control, hạn hết hiệu lực và review; không thêm ignore toàn bộ scanner.

Hoàn thành khi có PR tốt và PR lỗi, check-run JSON, ảnh ruleset không bypass, review thật hoặc nhãn solo lab, kết quả replay/tenant tests và map commit → digest → SBOM/provenance. Lưu bằng chứng đã redact ở `lab/evidence/p02/`. Nếu chưa chạy trên GitHub, ghi **pending**; một workflow YAML parse được chỉ chứng minh cú pháp tài liệu.
