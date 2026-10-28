# Baseline phiên bản và cách khóa dependency

[versions.json](versions.json) là dữ liệu máy đọc được của baseline. Baseline phục vụ tái hiện bài học; trước phát hành phải kiểm tra advisory, support window và tương thích lại. Không suy luận một package có trên registry nghĩa là không có vulnerability.

## Runtime và thư viện

Node **24.22.1**, pnpm **10.32.1**, TypeScript **5.9.3**, Express **5.3.0**. Các pin npm đã được đối chiếu registry chính thức khi biên soạn. Node tải từ [distribution chính thức](https://nodejs.org/dist/v24.22.1/); kiểm tra SHA-256 bằng `SHASUMS256.txt` trước khi dùng binary.

| Vai trò | Package / baseline |
|---|---|
| SQL driver | `pg@8.23.1` |
| JOSE | `jose@6.2.13` |
| Password | `argon2@0.45.1` |
| Input validation | `zod@4.6.7` |
| Logging | `pino@10.4.0`, `pino-http@11.0.0` |
| HTTP defaults | `helmet@8.1.0`, `cookie-parser@1.4.7` |
| OIDC client độc lập | `openid-client@6.8.8` |
| WebAuthn | server `14.0.3`, browser `14.0.0` |
| RabbitMQ client | `amqplib@0.10.9` cùng types `0.10.8` |
| Redis client | `ioredis@5.8.2` |
| Test | `vitest@5.0.5`, `supertest@7.3.1`, Playwright `1.64.1` |
| Dev runner | `tsx@4.23.15` |

Các chương có thể viết `pnpm add package` để giải thích thao tác. Khi thực hiện dùng version trong JSON và `--save-exact`; commit `lab/pnpm-lock.yaml`. Các phiên bản mới ngoài baseline cần upgrade PR, tests và review, không được dùng `latest` trong CI của lab hoàn chỉnh.

```powershell
$baseline = Get-Content -Raw -Encoding UTF8 docs/reference/versions.json | ConvertFrom-Json
$expressPin = $baseline.dependencies.express
pnpm -C lab --filter @iam/identity add --save-exact "express@$expressPin"
pnpm -C lab install --frozen-lockfile
```

Phải có lockfile sau lần install đầu tiên mới dùng `--frozen-lockfile`. Mọi secret sinh tại runtime; không ghi secret vào lockfile.

## Hạ tầng local

PostgreSQL 18, Redis 8, RabbitMQ 4-management, Caddy 2, Mailpit 1 là dòng được dùng. Chương 03 hướng dẫn pull rồi resolve thành **digest**, ghi vào Compose `.env`/`images.lock.json` để một lần học có image bất biến. Major tag chỉ là bước chọn baseline ban đầu, không phải pin cuối. Bảng này không khẳng định đã boot mọi combination hạ tầng.

PostgreSQL 18 đổi layout volume Docker image: mount `/var/lib/postgresql` thay vì lấy ví dụ volume PG17 ghép vào PG18. Tham khảo [image PostgreSQL chính thức](https://hub.docker.com/_/postgres).

## Kubernetes và chart

| Thành phần | Pin lab | Nguồn |
|---|---|---|
| kind | `v0.33.0` | [release](https://github.com/kubernetes-sigs/kind/releases/tag/v0.33.0) |
| kind node | `v1.35.8` | [kind release images](https://github.com/kubernetes-sigs/kind/releases/tag/v0.33.0) |
| kubectl | `v1.35.10` | [official stable 1.35](https://dl.k8s.io/release/stable-1.35.txt) |
| Helm | `v3.22.1` | [release](https://github.com/helm/helm/releases/tag/v3.22.1) |
| Envoy Gateway | `v1.9.3` | [compatibility matrix](https://gateway.envoyproxy.io/news/releases/matrix/) |
| cert-manager | `v1.21.3` | [release/support](https://cert-manager.io/docs/releases/) |
| Calico | `v3.33.0` | [requirements](https://docs.tigera.io/calico/latest/getting-started/kubernetes/requirements) |
| Argo CD | `v3.5.6` | [tested Kubernetes](https://argo-cd.readthedocs.io/en/stable/operator-manual/tested-kubernetes-versions/) |
| Vault server | `2.2.1` | [release](https://github.com/hashicorp/vault/releases/tag/v2.2.1) |
| Vault chart | `0.34.1` | [chart release](https://github.com/hashicorp/vault-helm/releases/tag/v0.34.1) |

kind node digest được nêu ở chương 18. Chart Vault mặc định có thể khác server pin: set image tag tường minh. Compatibility matrix là điều kiện đầu vào, chưa thay cho `helm template`, server-side dry run và failure tests trên cluster của bạn.

## Quy trình upgrade

1. Ghi advisory/release note và reason upgrade; giữ exact version/digest.
2. Chạy typecheck, unit, SQL/integration, browser và protocol regressions.
3. Kiểm tra metadata/JWKS/cookie/proxy/body-parser behavior không đổi.
4. Chạy migration theo expand/contract, rollout một phần, đo error/latency và revoke tests.
5. Giữ image/config trước đó; rollback code chỉ khi schema còn tương thích.

Nguồn API: [Node releases](https://nodejs.org/en/about/previous-releases), [TypeScript](https://www.typescriptlang.org/docs/), [Express 5](https://expressjs.com/en/guide/migrating-5/), [node-postgres](https://node-postgres.com/), [JOSE](https://github.com/panva/jose), [SimpleWebAuthn](https://simplewebauthn.dev/docs/packages/server).
