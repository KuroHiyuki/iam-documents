# P04. Dev, staging, production: cách ly môi trường và phát hành cùng một artifact

[Mục lục](../../README.md) · [Trước: Infrastructure as Code](03-infrastructure-as-code.md) · [CI/CD ứng dụng](../chapters/19-cicd.md) · [SRE](../chapters/20-sre-production.md)

## Mục tiêu và đầu vào

Một release không chỉ là image mới. Nó là một tập đã biết gồm source commit, image digest, migration, cấu hình môi trường, policy và quyền triển khai. Bài này nối bước merge code với bước người dùng truy cập phiên bản mới: build một lần, thử ở dev/staging, review bằng chứng, promote chính artifact đó sang production, rồi rollback được khi cần.

Đầu vào: CI/test/image ở [chương 19](../chapters/19-cicd.md), chart/NetworkPolicy/TLS ở [chương 18](../chapters/18-kubernetes.md), root Terraform/state ở P03. Bạn cần repository GitOps, quyền quản trị GitHub environments/rulesets và operator SSO từng AWS account. Lab chỉ chạy kind vẫn thực hành được: dùng ba cluster kind riêng theo tên, issuer/CA/dữ liệu riêng; không cần tạo ba EKS cluster để học promotion. Không áp failure drill vào người dùng thật.

Vì IAM là dependency của nhiều ứng dụng, lỗi trộn môi trường có thể biến dữ liệu dev thành nguồn xác thực production. Điều kiện thành công: token, browser cookie, client secret, khóa ký, database và deployment role của staging không dùng được ở prod; image ở staging/prod có cùng digest đã kiểm tra; schema mới vẫn cho phép rollback ứng dụng trong cửa sổ đã công bố.

## Bước 1 — Lập ma trận môi trường và chỉ rõ ranh giới

Tạo `lab/infra/gitops/environment-matrix.md`. Bảng sau là mẫu với tên miền dành cho tài liệu; thay `example.com` bằng domain thật bạn sở hữu trước khi cấp certificate. Các account ID thật được ghi trong inventory, không lấy tự động từ tài khoản đang login rồi coi là cấu hình mong muốn.

| Thuộc tính | Local | Dev tích hợp | Staging | Production |
|---|---|---|---|---|
| AWS account | Không cần | Account dev | Account staging riêng | Account prod riêng |
| Cluster/context | `kind-iam` | `iam-dev` | `iam-staging` | `iam-prod` |
| Namespace app | `iam` | `iam` | `iam` | `iam` |
| Issuer | `https://iam.local.test:8443` | `https://iam.dev.example.com` | `https://iam.staging.example.com` | `https://iam.example.com` |
| BFF A/B | Ports 8444/8445 | `app-a.dev...` / `app-b.dev...` | `app-a.staging...` / `app-b.staging...` | `app-a...` / `app-b...` |
| Invoice API | Port 8446 | `api.dev.example.com` | `api.staging.example.com` | `api.example.com` |
| Terraform state | Không có | Bucket/key dev | Bucket/key staging | Bucket/key prod |
| Data/Redis/RabbitMQ | Volume local | Instance/vhost riêng | Instance/vhost riêng | Instance/vhost riêng |
| Secrets/Transit keys | Sinh local | Prefix và KMS riêng | Prefix và KMS riêng | Prefix và KMS riêng |
| Dữ liệu test | Fixture | Synthetic | Synthetic gần quy mô thật | Dữ liệu người dùng thật |
| Quyền phát hành | Developer | CI sau merge | Release workflow | Reviewer độc lập + release workflow |

Account khác nhau là lớp ranh giới AWS: tài nguyên và quyền nằm trong account; tổ chức có thể quản lý tập accounts bằng AWS Organizations. Không dùng management account chạy workloads. [AWS Organizations accounts](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_accounts.html). Hai namespace cùng cluster có thể đủ cho bài demo tiết kiệm nhưng chia sẻ control plane/nodes/cluster-admin; ghi rõ đây là mô hình lab, không thay tiêu chí cách ly production của bài này.

Giữ tên client logic `web-a`, `web-b`, `invoice-api`, `iam-policy-api` xuyên môi trường để code dễ tái sử dụng, nhưng client records/secret/redirect URIs nằm trong từng Identity DB. Audience `invoice-api` có thể trùng tên; resource server luôn gọi đúng introspection endpoint của **môi trường của nó**, không nhận issuer URL hoặc endpoint introspection do request gửi lên. ID token nhận diện bằng issuer + subject; cùng `sub` ở hai môi trường không trở thành cùng principal.

Tách IAM session/BFF session store, cookie encryption keys, refresh grants, signing keys, TOTP encryption keys, federation credentials và SCIM tokens. Cookie production dùng host-only, Secure, HttpOnly, SameSite theo luồng đã thiết kế; không `Domain=.example.com` cho phép gửi cookie prod tới staging subdomain. Không restore DB production nguyên trạng vào staging; dữ liệu test synthetic là mặc định. Bản sao cần phục vụ điều tra phải được cô lập, giảm nhận dạng, vô hiệu hóa credentials/sessions, tắt mail/webhooks/provisioning outbound và có quy trình kiểm soát riêng.

## Bước 2 — Tách state và secrets trước khi deploy

Tạo roots Terraform `environments/dev`, `environments/staging`, `environments/prod`; dùng cùng module platform đã version hóa, mỗi root có account guard, region/CIDR, state bucket/key và tfvars riêng theo P03. Ví dụ prod VPC dùng `10.60.0.0/16`, staging `10.50.0.0/16`; đừng chép nguyên CIDR `10.40...` nếu sau này cần routing giữa môi trường. Không tạo peering mặc định giữa chúng.

Không dùng `terraform_remote_state` để trao mọi state cho runtime hoặc service khác. Xuất giá trị cần chia sẻ như hostname/ARN qua inventory/parameter có quyền đọc tối thiểu; người được đọc state có thể thấy nhiều hơn outputs. Backend credentials, master DSN, private keys không nằm trong `backend.hcl`, tfvars đã commit hoặc Helm values. CI prod chỉ có quyền đọc/ghi state prod và lock prod; role dev không đọc state prod.

Mỗi ứng dụng có runtime secret riêng theo môi trường, ví dụ `iam/prod/identity/runtime`, `iam/prod/authorization/runtime`. Mỗi service có migration secret riêng; runtime không có quyền DDL. BFF A/B giữ credentials/token encryption riêng. Tại local dùng `.secrets/*.env` được ignore; cloud dùng secret manager/Vault và cơ chế inject có rotation. Một file `.env` không được dùng chung dev/staging/prod dù mọi service đều khởi động được.

Trước rollout, release job kiểm tra inventory với STS account và kube context; check account ID bằng AWS API độc lập với tên context, vì tên context do người dùng đặt tùy ý:

```powershell
$expectedAccount = 'REPLACE_WITH_STAGING_ACCOUNT_ID'
$env:AWS_PROFILE = 'iam-staging-operator'
$actualAccount = aws sts get-caller-identity --query Account --output text
if ($LASTEXITCODE -ne 0 -or $actualAccount.Trim() -ne $expectedAccount) {
  throw 'Sai AWS account hoặc SSO session không hợp lệ'
}
kubectl --context iam-staging cluster-info
if ($LASTEXITCODE -ne 0) { throw 'Không tới được cluster staging' }
kubectl --context iam-staging get namespace iam -o 'jsonpath={.metadata.labels.environment}'
```

Namespace label là một guard bổ sung, không phải bằng chứng account. Gắn label `environment=staging` qua platform GitOps và làm tương tự dev/prod. Startup/config validation cần issuer exact từ manifest, endpoints nội bộ cố định, DSN host/database nằm trong inventory, TLS bật, cookie keys có đủ entropy. Kiểm tra connectivity không thực hiện login/migration vào database bất kỳ chỉ vì DSN parse được.

## Bước 3 — Tổ chức GitOps values sao cho reviewer nhìn thấy khác biệt

Tạo các file sau trong **repository ứng dụng/GitOps của người học**, không ở repository sách:

```text
lab/infra/gitops/
  applications/iam-dev.yaml
  applications/iam-staging.yaml
  applications/iam-prod.yaml
  environments/dev/values.yaml
  environments/staging/values.yaml
  environments/prod/values.yaml
  releases/candidate.json
  releases/approved-staging.json
  releases/approved-prod.json
```

`values.yaml` chỉ giữ cấu hình không bí mật và **image reference có digest**. Ví dụ staging dưới đây mở rộng chart chương 18; template phải thực sự dùng các field thêm mới như environment/replicas, không chỉ thêm values rồi nghĩ chúng đã có tác dụng:

```yaml
environment: staging
identity:
  issuer: https://iam.staging.example.com
  image: ghcr.io/REPLACE_OWNER/REPLACE_REPO/identity@sha256:REPLACE_64_HEX_DIGEST
  replicas: 2
webA:
  publicUrl: https://app-a.staging.example.com
  image: ghcr.io/REPLACE_OWNER/REPLACE_REPO/web-a@sha256:REPLACE_64_HEX_DIGEST
webB:
  publicUrl: https://app-b.staging.example.com
  image: ghcr.io/REPLACE_OWNER/REPLACE_REPO/web-b@sha256:REPLACE_64_HEX_DIGEST
invoiceApi:
  audience: invoice-api
  publicUrl: https://api.staging.example.com
authorization:
  audience: iam-policy-api
runtimeSecrets:
  identity: identity-runtime
  authorization: authorization-runtime
```

Thay các placeholders bằng artifacts thật, bổ sung images audit/governance/invoice theo cùng quy ước; không deploy giá trị minh họa. Chart chương 18 đang có `replicas:2` literal thì đổi thành `.Values.identity.replicas`, thêm environment label/env và secret references tương ứng. Defaults chart không chứa issuer prod hay credential; thiếu issuer/image phải fail render bằng Helm `required`/schema validation.

Render ở CI với `helm lint` và `helm template ... -f .../staging/values.yaml`, kiểm tra image fields có `@sha256:` đủ 64 hex, issuer/hostnames đúng ma trận, namespace/account labels không lẫn, không có Secret plaintext. Những trường cấu hình runtime còn lại như DB secret version được ghi bằng reference trong release evidence. Promotion cùng digest có thể vẫn lỗi do config/secret khác; vì vậy config thay đổi cũng phải review và smoke test.

Một Argo CD Application cho staging, với Argo được cài riêng trong cluster staging:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: iam-staging
  namespace: argocd
spec:
  project: iam-staging
  source:
    repoURL: https://github.com/REPLACE_OWNER/REPLACE_REPO.git
    targetRevision: main
    path: lab/infra/helm/iam
    helm:
      valueFiles:
        - ../../gitops/environments/staging/values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: iam
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
      - CreateNamespace=false
```

Platform operator tạo AppProject `iam-staging`: source repo allowlist đúng repo, destination chỉ namespace `iam` trên cluster staging; app không có quyền tạo ClusterRole/CRD/Namespace. Controllers/CRDs/namespace/secrets được platform bootstrap quản lý riêng. Giữ Application resource trong đường dẫn platform được bảo vệ; repo app tự sửa AppProject để tự cấp quyền sẽ làm mất ranh giới. [Argo CD projects](https://argo-cd.readthedocs.io/en/stable/user-guide/projects/).

Prod có Application tương tự nhưng project/values/cluster prod. Chọn **merge PR được bảo vệ là approval cuối** cho app production rồi Argo tự sync; không vừa auto-sync manifest đã merge vừa nghĩ một nút approve ở workflow khác vẫn chặn deploy. Với thay đổi hạ tầng, apply chạy trong GitHub protected environment riêng. Nếu tổ chức muốn manual Argo sync là release gate, tắt automated sync prod và ghi rõ người có quyền sync; không để hai cơ chế gate mâu thuẫn.

## Bước 4 — Build một lần, kiểm tra rồi promote digest

Chương 19 đã có build/publish/provenance/SBOM; bài này sử dụng kết quả đó. Baseline registry ở chương 19 là GHCR. P03 tạo ECR để học nền tảng AWS; nếu chọn ECR cho deployment, mirror OCI artifact với công cụ giữ nguyên manifest/digest rồi xác nhận digest sau copy. `docker pull` một platform rồi push lại có thể đổi manifest/index, không chứng minh cùng artifact multi-architecture. Chọn một registry contract và ghi nó trong inventory; không rebuild riêng cho prod.

Release workflow sau CI xanh tạo `releases/candidate.json`. Ví dụ **shape**, mọi placeholder cần thay bằng kết quả pipeline:

```json
{
  "release_id": "iam-0.1.0",
  "source_commit": "REPLACE_FULL_40_HEX_COMMIT",
  "created_at": "REPLACE_UTC_TIMESTAMP",
  "images": {
    "identity": "ghcr.io/REPLACE_OWNER/REPLACE_REPO/identity@sha256:REPLACE_64_HEX_DIGEST",
    "authorization": "ghcr.io/REPLACE_OWNER/REPLACE_REPO/authorization@sha256:REPLACE_64_HEX_DIGEST"
  },
  "migration_set": "REPLACE_VERSIONED_MIGRATION_SET",
  "schema_compatibility": {"minimum": "previous", "maximum": "current"},
  "evidence_run": "REPLACE_CI_RUN_URL"
}
```

Thêm mọi deployable còn lại vào `images`. Tốt hơn một tag `v0.1.0`, manifest cho reviewer biết chính xác các service tạo thành release. Có thể promote từng service nếu compatibility matrix chứng minh tương thích các phiên bản chạy xen kẽ; chưa có matrix thì promote bộ release đã thử cùng nhau.

Quy trình cụ thể:

1. CI trên protected main xuất digest, attestations, SBOM và kết quả tests; tạo candidate bằng kết quả registry, không nhập tay tag tùy ý từ người chạy workflow.
2. PR dev thay image refs bằng candidate, render chart, merge rồi Argo sync. Ghi source GitOps commit và digest thực chạy từ Kubernetes.
3. PR staging dùng **cùng refs**, chỉ thay cấu hình môi trường đã định nghĩa. Chạy browser SSO hai app, negative tenant test, refresh concurrency, dependency outage có kiểm soát và online revoke test sau commit.
4. Người chịu trách nhiệm release ghi `approved-staging.json`: release ID, digests đã thử, GitOps commit, migration/schema version, evidence run, kết quả thật và thời gian. Commit evidence summary đã redact; raw private results giữ trong storage có retention.
5. PR prod chỉ lấy artifacts đã đạt staging, đính kèm reviewer/rollback point/SLO window. CI kiểm tra digest prod là subset đúng release đã phê duyệt. CODEOWNERS/ruleset yêu cầu reviewer release và platform khi schema/config nhạy cảm đổi.
6. Sau merge prod, Argo sync, chạy smoke/negative tests bằng synthetic tenant riêng rồi theo dõi error budget. Phát hiện regression thì revert GitOps digest trước, theo quy tắc schema ở bước 7.

Lấy bằng chứng digest đang chạy bằng lệnh đọc sau; với runtime multi-arch, `imageID` có thể là platform manifest digest trong khi `spec.image` là index digest, nên đối chiếu đúng loại artifact:

```powershell
kubectl --context iam-staging -n iam get deployment identity `
  -o 'jsonpath={.spec.template.spec.containers[0].image}'
kubectl --context iam-staging -n iam get pods -l app=identity `
  -o 'jsonpath={range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].imageID}{"\n"}{end}'
kubectl --context iam-staging -n iam rollout status deployment/identity --timeout=180s
```

Không log `/oauth2/token` response, browser cookies hay master DSN trong evidence. Kiểm tra image provenance/attestation theo chương 19, không chỉ so chuỗi digest trong hai files do cùng một PR có thể sửa. Artifact và staging report phải gắn cùng source commit/digest; reviewer mở evidence run để xác nhận.

## Bước 5 — GitHub OIDC với quyền tối thiểu

GitHub Actions nhận credential AWS ngắn hạn qua STS; không lưu AWS access key dài hạn trong repository secrets. Có ba vai trò khác nhau: publisher chỉ push repository images; Terraform plan chỉ read resources/state và quản lý lock; Terraform apply có quyền thay hạ tầng trong account tương ứng sau approval. GitOps bot chỉ mở PR vào đường dẫn cho phép, không có quyền admin repository hay kubectl prod. Không dùng chung một role cho bốn nhiệm vụ.

Trước hết tạo GitHub environments `dev-infra`, `staging-infra`, `prod-infra`, giới hạn deployment branches là `main` đã bảo vệ; `prod-infra` có required reviewer, bật prevent self-review, hạn chế bypass. Các tính năng protection phụ thuộc loại repo/gói GitHub: kiểm tra chúng thực sự có hiệu lực. Nếu gói hiện tại không hỗ trợ reviewer cần thiết, dùng protected PR + operator apply theo runbook và ghi rõ cơ chế thay thế, không gọi một environment không gate là đã được bảo vệ. [GitHub environments](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments).

Trust policy phải kiểm tra audience và **exact subject thực tế của repository**. Với legacy subject: `repo:ORG/REPO:environment:prod-infra`. Repo mới có thể dùng subject chứa immutable owner/repository IDs hoặc subject template đã tùy chỉnh; đọc cấu hình OIDC và inspect claims thật rồi pin chính xác, không dùng wildcard `repo:*`. Khi job dùng environment, subject thường theo environment; nó không đồng thời có dạng `ref:refs/heads/main`, nên branch gate nằm ở environment/ruleset. [GitHub OIDC reference](https://docs.github.com/en/actions/reference/security/oidc), [AWS integration](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws).

Để lấy subject không cần cấp AWS quyền trước, chạy workflow diagnostic trong `prod-infra` đã bảo vệ, quyền `id-token:write`. Dùng Node builtin fetch, request audience STS và chỉ in `iss/aud/sub`, không in JWT. Đây là **Bash/Node cho runner Linux**:

```bash
node --input-type=module <<'NODE'
const endpoint = new URL(process.env.ACTIONS_ID_TOKEN_REQUEST_URL);
endpoint.searchParams.set('audience', 'sts.amazonaws.com');
const response = await fetch(endpoint, {
  headers: {Authorization: `Bearer ${process.env.ACTIONS_ID_TOKEN_REQUEST_TOKEN}`},
});
if (!response.ok) throw new Error(`OIDC request failed: ${response.status}`);
const {value} = await response.json();
const claims = JSON.parse(Buffer.from(value.split('.')[1], 'base64url').toString());
console.log(JSON.stringify({iss: claims.iss, aud: claims.aud, sub: claims.sub}));
NODE
```

Decode này chỉ giúp đọc claims để cấu hình trust; nó không phải xác minh JWT. AWS STS sẽ thực hiện xác minh khi assume role. Tạo resource một lần/account trong root security bootstrap; nếu provider GitHub đã tồn tại, import nó thay vì tạo provider trùng:

```hcl
variable "github_prod_subject" { type = string }
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}
resource "aws_iam_role" "production_plan" {
  name                 = "iam-prod-plan"
  max_session_duration = 3600
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow", Action = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Condition = { StringEquals = {
        "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        "token.actions.githubusercontent.com:sub" = var.github_prod_subject
      } }
    }]
  })
}
```

Provider AWS 6.59 cho phép bỏ `thumbprint_list` với các IdP được AWS xác minh bằng trusted CA, gồm GitHub; không sao chép thumbprint cũ từ bài blog rồi coi đó là pin security. [OIDC provider resource](https://registry.terraform.io/providers/hashicorp/aws/6.59.0/docs/resources/iam_openid_connect_provider).

Trust chỉ quyết định **ai assume**, chưa cho quyền làm gì. Attach policy riêng cho plan role: đọc đúng S3 state prefix/KMS, tạo/xóa `.tflock`, các API Describe/List/Get cần để refresh tài nguyên thuộc root. Không attach AdministratorAccess; `ReadOnlyAccess` có thể làm baseline khám phá sandbox tạm thời nhưng quá rộng cho gate production, và không tự cấp quyền ghi lock. Thu hẹp từ danh sách provider resources + CloudTrail, dùng IAM Access Analyzer validate policy, kiểm thử cả allowed/denied APIs. Apply role riêng có permissions boundary và `iam:PassRole` chỉ các role EKS/controller/migration được review; không cho tự sửa trust/policy/boundary của chính nó. Root security bootstrap do operator khác quản lý.

Ví dụ workflow **chỉ tạo plan**, không apply cloud, lưu tại `.github/workflows/infra-prod-plan.yml` trong repo ứng dụng. `AWS_ACCOUNT_ID`, `AWS_PLAN_ROLE_ARN`, `AWS_REGION` là environment variables của `prod-infra`; root prod có backend.hcl/tfvars không chứa secrets đã review. Dùng full SHA của official action đã tra tag v5.1.0 qua GitHub API; việc nâng pin cần PR.

```yaml
name: infra-prod-plan
on:
  workflow_dispatch:
permissions:
  contents: read
concurrency:
  group: infrastructure-prod
  cancel-in-progress: false
jobs:
  plan:
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-24.04
    environment: prod-infra
    timeout-minutes: 20
    permissions:
      contents: read
      id-token: write
    env:
      TF_IN_AUTOMATION: 'true'
      EXPECTED_ACCOUNT: ${{ vars.AWS_ACCOUNT_ID }}
    steps:
      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803
        with:
          persist-credentials: false
      - uses: aws-actions/configure-aws-credentials@00943011d9042930efac3dcd3a170e4273319bc8
        with:
          role-to-assume: ${{ vars.AWS_PLAN_ROLE_ARN }}
          aws-region: ${{ vars.AWS_REGION }}
          allowed-account-ids: ${{ vars.AWS_ACCOUNT_ID }}
          role-session-name: iam-plan-${{ github.run_id }}
          role-duration-seconds: 3600
      - name: Install pinned Terraform
        shell: bash
        run: |
          set -euo pipefail
          install_dir="$RUNNER_TEMP/terraform-bin"
          mkdir -p "$install_dir"
          cd "$install_dir"
          base=https://releases.hashicorp.com/terraform/1.13.5
          curl --fail --silent --show-error --location --retry 2 "$base/terraform_1.13.5_linux_amd64.zip" -o terraform.zip
          curl --fail --silent --show-error --location --retry 2 "$base/terraform_1.13.5_SHA256SUMS" -o SHA256SUMS
          expected="$(awk '$2 == "terraform_1.13.5_linux_amd64.zip" {print $1}' SHA256SUMS)"
          test "${#expected}" = 64
          printf '%s  %s\n' "$expected" terraform.zip | sha256sum --check --strict
          unzip -q terraform.zip
          echo "$install_dir" >> "$GITHUB_PATH"
      - name: Verify account and toolchain
        shell: bash
        run: |
          set -euo pipefail
          test "$(aws sts get-caller-identity --query Account --output text)" = "$EXPECTED_ACCOUNT"
          command -v terraform
          test "$(terraform version -json | jq -r .terraform_version)" = "1.13.5"
      - name: Plan only
        shell: bash
        run: |
          set -euo pipefail
          root=lab/infra/terraform/environments/prod
          terraform -chdir="$root" init -input=false -lockfile=readonly -backend-config=backend.hcl
          terraform -chdir="$root" validate
          terraform -chdir="$root" plan -input=false -lock-timeout=60s -out=review.tfplan
          terraform -chdir="$root" show -no-color review.tfplan
```

Runner GitHub hosted không mặc định có Terraform đúng pin; bước cài ở trên lấy binary/checksum từ release HTTPS chính thức rồi Verify xác nhận exact version. Với supply chain production, lưu checksum đã review trong BOM thay vì tin checksum tải mới mỗi run, xác minh chữ ký checksum bằng key HashiCorp đã thiết lập tin cậy, hoặc dùng runner image được pin. Plan stdout có thể chứa thuộc tính nhạy cảm ngoài secret-marked values; repository/run logs phải private phù hợp và review cách redact của provider. Saved plan chứa secrets thì không upload public artifact. Policy Checkov bước P03 phải được đưa vào workflow trước khi biến plan thành release gate.

Apply job production dùng environment reviewer khác nếu plan cần chạy tự động trước approval; artifact encrypted với TTL ngắn, gắn SHA256 plan/source commit/backend serial/lockfile. Verify SHA256/provenance ở job apply, kiểm tra lại account rồi `terraform apply review.tfplan`; không tạo plan mới sau approval và gọi đó là plan đã review. Nếu stale, quay lại plan+review. Tất cả apply cùng root dùng concurrency group trên; không cancel giữa chừng khi Terraform đang mutation. Xóa runner workspace ephemeral sau job, không dùng runner persistent chung cho PR fork và prod credentials.

## Bước 6 — Kiểm tra promotion qua boundary thực tế

Trước phát hành đầu tiên tạo synthetic tenant ở staging và prod độc lập. Đăng nhập qua BFF đúng issuer lấy token ngắn hạn, giữ trong secret file cục bộ/runner memory, không đưa vào query string hoặc log. Gọi Invoice API production bằng access token staging phải trả `401`; token production đúng user nhưng tenant/resource khác phải `403` hoặc `404` theo contract. ID token staging/prod đều không làm access token hợp lệ. BFF production dùng discovery exact issuer production và kiểm tra `iss`/`aud`/nonce; một JWT cùng `kid` từ staging không được chấp nhận.

Kiểm tra quyền triển khai âm tính: workflow không khai báo `prod-infra` không assume prod role được; workflow fork/branch không được phép không qua environment gate; role dev đọc bucket state prod phải AccessDenied; plan role thử tạo EC2 trong sandbox phải bị deny. Chỉ thực hiện lệnh mutation âm tính với tài nguyên sandbox đã định nghĩa và guard account; tốt hơn dùng IAM policy simulator/dry-run APIs có hỗ trợ để chứng minh deny.

Ghi lại credential source bằng CloudTrail role/session name và GitHub run ID. Không in STS credentials để chứng minh OIDC hoạt động. Kiểm tra sau workflow AWS temporary credentials hết hạn; không tồn tại access key dài hạn mới. Repo rename/transfer hoặc OIDC subject template thay đổi cần review trust trước, fail closed trong khoảng chuyển đổi.

## Bước 7 — Migration, rolling rollout và rollback theo hợp đồng dữ liệu

Không chạy migration ở startup mọi replica. Một PreSync Job/controlled migration stage theo chương 19 giữ PostgreSQL advisory lock, có timeout, version/checksum, role owner riêng và audit. Secret cần cho PreSync phải có sẵn từ platform/secret controller trước hook; không đặt Secret chỉ tạo trong Sync rồi yêu cầu PreSync sử dụng nó. Argo sync phases/waves giúp sắp thứ tự nhưng không tự bảo đảm schema backward compatible. [Argo sync phases](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/).

Ví dụ thay field hiển thị user: release N thêm `display_name` nullable, cả N và N−1 vẫn đọc schema được; N+1 dual-write/backfill theo batch có checkpoint; N+2 chuyển reads; chỉ contract/drop field cũ khi hết rollback window và không còn consumer cũ. Không dùng rename/drop ngay đầu rollout rồi hi vọng pods phiên bản cũ vẫn hoạt động. Test integration cho N và N−1 chạy trên schema expanded trước khi promote.

Trong mỗi release record ghi **application rollback window**, ví dụ 24 giờ theo bài lab, và migration contract chưa được chạy trước khi cửa sổ kết thúc. Khi code lỗi nhưng schema còn tương thích, revert image refs trong PR GitOps tới release trước; Argo reconcile lại, chạy online revoke/tenant tests. Không `helm rollback` ngoài Git rồi để Argo tự kéo trở lại image lỗi. Khi thay đổi dữ liệu đã mất tính tương thích, dừng rollout và làm forward fix hoặc DR theo runbook, không `down.sql` xóa dữ liệu để ép rollback.

IAM có yêu cầu đặc biệt: rollback ứng dụng không rollback trạng thái thu hồi đã commit. Token/session đã revoke trước release phải tiếp tục bị từ chối sau rollback. Backup restore thì cần cô lập môi trường, bump security epoch/invalidate grants/sessions theo owner và đồng bộ trạng thái trước mở traffic; restore snapshot cũ có thể hồi sinh credential đã bị thu hồi nếu bỏ bước này. [Chương 20](../chapters/20-sre-production.md) có quy trình kiểm chứng failover/restore.

## Failure lab, troubleshooting và Definition of Done

Thực hành ba lượt riêng trên staging: đưa issuer sai vào values, CI/render config guard phải chặn; đưa image không Ready, rollout phải giữ replica cũ và alert; tạo phiên bản chạy được nhưng bỏ online revoke check, regression test phải phát hiện rồi quay lại artifact trước. Mỗi lượt ghi thời điểm bắt đầu, GitOps SHA, image refs, schema version, SLO và kết quả revoke sau phục hồi. Không gộp các lỗi vào một lần làm mất khả năng biết control nào đã chặn.

| Triệu chứng | Cách điều tra |
|---|---|
| STS `AccessDenied` | So aud/sub thật, environment name, immutable subject/template, provider ARN và account; không mở wildcard trust |
| Workflow không chờ reviewer | Kiểm tra job có environment, rule gói GitHub, bypass/self-review và branch restrictions |
| Prod rollout trước approve | Argo đang auto-sync manifest đã merge; đưa gate về protected merge hoặc tắt auto-sync theo thiết kế đã chọn |
| Argo OutOfSync lặp | So chart/values commit, controllers cùng sửa fields, manual hotfix và quyền AppProject |
| Image digest không giống staging | Rebuild/pull-push single-arch, tag trôi, manifest index khác platform digest; đối chiếu registry metadata |
| PreSync thiếu secret | Secret được tạo ở phase Sync hoặc chưa reconcile; bootstrap secret trước hook, không in DSN để debug |
| Rollback xong vẫn lỗi | Cấu hình/secret/schema/policy khác release trước; xác định thành phần thay đổi thay vì chỉ đổi image lần nữa |

**Definition of Done:** ma trận môi trường có owner và account IDs; state/data/keys/secrets cách ly có negative tests; source+artifact+evidence liên kết được; cùng digest đi từ staging sang prod; reviewer gate đã được thử bằng release không đủ điều kiện; OIDC trust chỉ cho subject dự kiến; rollout/rollback tương thích schema đã diễn tập; token đã revoke vẫn inactive sau rollback. Lưu `lab/evidence/p04/` với manifest đã loại secret, hashes, run URLs và kết quả thật. Những đoạn YAML/HCL trên là hướng dẫn để bạn triển khai, chưa là bằng chứng một môi trường production đã đạt gate.
