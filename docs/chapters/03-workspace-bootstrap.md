# 03 — Dựng workspace đầu tiên chạy được

[Trước: nền tảng](02-foundations.md) · [Trang đầu](../../README.md) · [Tiếp: dữ liệu và tenant](04-data-tenancy.md)

## 1. Mục tiêu và điều kiện đầu vào

Bạn đã làm demo HTTP ở chương 02. Mục tiêu là tạo **walking skeleton**: một service Express build/test được, có structured logs, readiness, shutdown, dependency nền và HTTPS local. Chưa có endpoint login; trước hết cần một nơi có thể chạy và điều tra lỗi đáng tin cậy.

Mọi lệnh từ thư mục `IAM`, PowerShell. Mỗi code block có nhãn file là nội dung bạn tạo bằng editor; chỉ các khối `powershell` là lệnh terminal. Đọc [implementation map](../reference/implementation-map.md) trước khi đổi tên file/port.

## 2. Xác nhận toolchain

```powershell
Get-Location
git --version
node --version
pnpm --version
docker version
docker compose version
```

Chọn Docker Desktop **Linux containers**. Docker CLI có mặt nhưng `Server` lỗi nghĩa daemon chưa sẵn sàng. Node của máy có thể khác baseline; dùng version manager để không thay dự án khác:

```powershell
winget install --id Schniz.fnm --exact
# Mở lại terminal sau khi cài fnm nếu PATH chưa cập nhật.
fnm env --shell powershell | Out-String | Invoke-Expression
fnm install 24.22.1
fnm use 24.22.1
npm install --global pnpm@10.32.1
node --version
pnpm --version
```

Kỳ vọng Node `v24.22.1`, pnpm `10.32.1`. Nếu tổ chức chặn winget, dùng gói Windows từ trang chính thức và kiểm tra checksum; không tắt TLS validation của npm. Các phiên bản xem [versions](../reference/versions.md).

## 3. Tạo workspace riêng cho ứng dụng

```powershell
New-Item -ItemType Directory -Force -Path lab/services/identity/src,lab/services/identity/test,lab/apps,lab/packages/contracts/src,lab/infra/compose,lab/scripts,lab/evidence/ch03 | Out-Null
'24.22.1' | Set-Content -Encoding ASCII lab/.node-version
```

Tạo `lab/package.json`:

```json
{
  "name": "iam-lab", "private": true, "type": "module",
  "packageManager": "pnpm@10.32.1",
  "engines": {"node": ">=24 <25"},
  "scripts": {
    "build": "pnpm -r --if-present build",
    "typecheck": "pnpm -r --if-present typecheck",
    "test": "pnpm -r --if-present test"
  }
}
```

Tạo `lab/pnpm-workspace.yaml`:

```yaml
packages:
  - services/*
  - apps/*
  - packages/*
onlyBuiltDependencies:
  - argon2
  - esbuild
```

`onlyBuiltDependencies` cho phép build đúng native dependencies đã biết. Không bật cho phép mọi postinstall script; audit dependency mới trước khi thêm. Tạo `lab/.npmrc` với `save-exact=true`, `engine-strict=true` (mỗi dòng một setting).

Tạo `lab/services/identity/package.json`:

```json
{
  "name": "@iam/identity", "private": true, "version": "0.1.0", "type": "module",
  "scripts": {
    "dev": "node --env-file=.env --import tsx src/main.ts",
    "build": "tsc -p tsconfig.json",
    "start": "node --env-file=.env dist/main.js",
    "typecheck": "tsc -p tsconfig.json --noEmit",
    "test": "vitest run"
  }
}
```

Cài pin từ bảng chung; các service sau cũng dùng pattern này:

```powershell
pnpm -C lab --filter @iam/identity add --save-exact express@5.3.0 zod@4.6.7 pino@10.4.0 pino-http@11.0.0 helmet@8.1.0
pnpm -C lab --filter @iam/identity add --save-exact -D typescript@5.9.3 tsx@4.23.15 vitest@5.0.5 supertest@7.3.1 @types/node@24.10.0 @types/express@5.0.6 @types/supertest@7.2.1
pnpm -C lab install
```

Commit lockfile sau lần này. Đừng dùng frozen install trước khi lockfile tồn tại.

Tạo `lab/services/identity/tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ES2023", "module": "NodeNext", "moduleResolution": "NodeNext",
    "strict": true, "noUncheckedIndexedAccess": true, "exactOptionalPropertyTypes": true,
    "esModuleInterop": true, "forceConsistentCasingInFileNames": true,
    "skipLibCheck": true, "outDir": "dist", "rootDir": "src",
    "sourceMap": true
  },
  "include": ["src/**/*.ts"]
}
```

Vitest transpile test ngoài `src`; chương sau có thể thêm tsconfig test để typecheck tests. Không tắt strict chỉ để đoạn code ghép sai compile được.

## 4. Config, errors và app factory

Tạo `lab/services/identity/src/config.ts`:

```typescript
import { z } from 'zod';
const env = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  PORT: z.coerce.number().int().min(1).max(65535).default(3000),
  ISSUER: z.url().default('https://iam.local.test:8443'),
  DATABASE_URL: z.string().min(1).default('postgresql://not-configured'),
  LOG_LEVEL: z.enum(['debug', 'info', 'warn', 'error']).default('info'),
  TRUST_PROXY: z.string().default('loopback')
}).parse(process.env);
if (!env.ISSUER.startsWith('https://')) throw new Error('ISSUER must use HTTPS');
export const config = {
  nodeEnv: env.NODE_ENV, port: env.PORT, issuer: env.ISSUER.replace(/\/$/, ''),
  databaseUrl: env.DATABASE_URL, logLevel: env.LOG_LEVEL, trustProxy: env.TRUST_PROXY,
  cookie: {name: '__Host-iam_session', secure: true, httpOnly: true, sameSite: 'lax' as const}
};
```

Default URL database chỉ cho skeleton trước chương 04; readiness chưa kiểm tra DB ở bước này. Sau chương 04 database URL bắt buộc đúng, không đưa default vào production manifest.

Tạo `src/errors.ts`:

```typescript
import type { ErrorRequestHandler } from 'express';
import { ZodError } from 'zod';
export class AppError extends Error {
  constructor(public status: number, public code: string, message = code) {
    super(message);
  }
}
export function isDependencyFailure(error: unknown): boolean {
  if (!(error instanceof Error)) return false;
  const code = 'code' in error ? String(error.code) : '';
  return new Set(['ECONNREFUSED','ECONNRESET','ETIMEDOUT','08000','08001','08003',
    '08004','08006','08007','08P01','53300','57014','57P01','57P02','57P03']).has(code)
    || error.message === 'timeout exceeded when trying to connect';
}
export const errorHandler: ErrorRequestHandler = (error: unknown, _req, res, _next) => {
  const known = error instanceof AppError;
  const input = error instanceof ZodError;
  const dependency = isDependencyFailure(error);
  const status = known ? error.status : input ? 400 : dependency ? 503 : 500;
  res.status(status).set('Cache-Control', 'no-store').json({
    error: known ? error.code : input ? 'invalid_request' : dependency ? 'dependency_unavailable' : 'internal_error',
    correlation_id: res.locals.correlationId
  });
};
```

OAuth errors ở chương 06 có handler riêng đúng wire protocol; không bọc chúng thành management JSON tùy ý.

Tạo `src/app.ts`:

```typescript
import express from 'express';
import helmet from 'helmet';
import pino from 'pino';
import pinoHttp from 'pino-http';
import { randomUUID } from 'node:crypto';
import { config } from './config.js';
import { errorHandler } from './errors.js';

type Options = {readiness?: () => Promise<boolean>};
export function createApp(options: Options = {}) {
  const app = express();
  app.disable('x-powered-by');
  app.set('trust proxy', config.trustProxy);
  const logger = pino({
    level: config.logLevel,
    redact: ['req.headers.authorization', 'req.headers.cookie',
      'res.headers["set-cookie"]', 'req.body', 'res.body']
  });
  app.use((req, res, next) => {
    res.locals.correlationId = randomUUID();
    res.setHeader('X-Request-ID', res.locals.correlationId as string);
    // Never log OAuth URLs with code/state/query, or request bodies.
    next();
  });
  app.use(pinoHttp({logger,
    serializers: {
      req(req) { return {method: req.method, path: String(req.url ?? '').split('?')[0]}; },
      res(res) { return {statusCode: res.statusCode}; }
    },
    genReqId: (_req, res) => String(res.getHeader('X-Request-ID'))
  }));
  app.use(helmet());
  app.get('/health/live', (_req, res) => res.json({status: 'ok'}));
  app.get('/health/ready', async (_req, res) => {
    try {
      const ready = options.readiness ? await options.readiness() : true;
      res.status(ready ? 200 : 503).json({status: ready ? 'ready' : 'not_ready'});
    } catch {
      res.status(503).json({status: 'not_ready'});
    }
  });
  app.get('/demo/failure', () => { throw new Error('demo failure'); });
  // Router registration in later chapters goes HERE, before 404/error handler.
  app.use((_req, res) => res.status(404).json({error: 'not_found'}));
  app.use(errorHandler);
  return app;
}
```

Không gắn global body parser trước OAuth raw/form parser. Management router tự dùng `express.json({limit:'16kb'})`; token route sẽ có parser riêng chống duplicate. Đường `/demo/failure` xóa trước staging; dùng nó để kiểm tra 500 lúc học.

Tạo `src/main.ts`:

```typescript
import { config } from './config.js';
import { createApp } from './app.js';
const app = createApp();
const server = app.listen(config.port, '127.0.0.1');
server.requestTimeout = 10_000;
server.headersTimeout = 5_000;
let stopping = false;
function stop() {
  if (stopping) return;
  stopping = true;
  const deadline = setTimeout(() => process.exit(1), 10_000).unref();
  server.close(() => { clearTimeout(deadline); process.exit(0); });
}
process.on('SIGINT', stop);
process.on('SIGTERM', stop);
```

Kubernetes sẽ bind `0.0.0.0` trong container thay loopback và tắt readiness trước drain. Chương 04 bổ sung đóng pool trước process exit. Timeout HTTP không thay query deadline/transaction rollback.

## 5. Test có ý nghĩa và chạy service

Tạo `test/app.test.ts`:

```typescript
import { describe, expect, it } from 'vitest';
import request from 'supertest';
import { createApp } from '../src/app.js';
describe('operational contract', () => {
  it('live stays up while dependency readiness fails', async () => {
    const app = createApp({readiness: async () => false});
    expect((await request(app).get('/health/live')).status).toBe(200);
    expect((await request(app).get('/health/ready')).status).toBe(503);
  });
  it('does not disclose stack or internal failure message', async () => {
    const response = await request(createApp()).get('/demo/failure');
    expect(response.status).toBe(500);
    expect(response.body.error).toBe('internal_error');
    expect(JSON.stringify(response.body)).not.toContain('demo failure');
    expect(response.headers['x-request-id']).toBeTruthy();
  });
});
```

Tạo `.env` cho Identity:

```powershell
@'
NODE_ENV=development
PORT=3000
ISSUER=https://iam.local.test:8443
LOG_LEVEL=info
TRUST_PROXY=loopback
'@ | Set-Content -Encoding UTF8 lab/services/identity/.env
pnpm -C lab --filter @iam/identity typecheck
pnpm -C lab --filter @iam/identity test
pnpm -C lab --filter @iam/identity build
pnpm -C lab --filter @iam/identity dev
```

Kỳ vọng hai test pass, build sinh `dist/`, service nghe port 3000. Terminal khác gọi `curl.exe -i http://127.0.0.1:3000/health/live`; kiểm tra status, request ID và log JSON không có query/credential.

## 6. Docker Compose và khóa image digest

Tạo secret cấu hình local không commit:

```powershell
$composeSecrets = node --input-type=module -e 'import {randomBytes} from "node:crypto"; console.log(JSON.stringify({pg:randomBytes(24).toString("hex"),redis:randomBytes(24).toString("hex"),rabbit:randomBytes(24).toString("hex")}));' | ConvertFrom-Json
@"
PG_PASSWORD=$($composeSecrets.pg)
REDIS_PASSWORD=$($composeSecrets.redis)
RABBITMQ_PASSWORD=$($composeSecrets.rabbit)
"@ | Set-Content -Encoding UTF8 lab/infra/compose/.env
```

Pull rồi resolve digest; đoạn này ghi append cấu hình image, không echo secret:

```powershell
$imageChoices = [ordered]@{POSTGRES_IMAGE='postgres:18';REDIS_IMAGE='redis:8';RABBITMQ_IMAGE='rabbitmq:4-management';MAILPIT_IMAGE='axllent/mailpit:v1'}
$lockedImages = @{}
foreach ($entry in $imageChoices.GetEnumerator()) {
  docker pull $entry.Value
  if ($LASTEXITCODE -ne 0) { throw "Pull failed: $($entry.Value)" }
  $imageDigest = docker image inspect $entry.Value --format '{{index .RepoDigests 0}}'
  if ($LASTEXITCODE -ne 0 -or -not $imageDigest.Contains('@sha256:')) { throw 'Cannot resolve digest' }
  $lockedImages[$entry.Key] = $imageDigest
  Add-Content -Encoding UTF8 lab/infra/compose/.env "$($entry.Key)=$imageDigest"
}
$lockedImages | ConvertTo-Json | Set-Content -Encoding UTF8 lab/infra/compose/images.lock.json
```

Chạy script này một lần; khi upgrade, thay các dòng image thay vì append key trùng. Commit `images.lock.json` (không chứa secret), giữ `.env` ngoài Git.

Tạo `lab/infra/compose/compose.yaml`:

```yaml
name: iam-lab
services:
  postgres:
    image: ${POSTGRES_IMAGE:?resolve image digest first}
    environment:
      POSTGRES_USER: iam_migrator
      POSTGRES_PASSWORD: ${PG_PASSWORD:?set PG_PASSWORD}
      POSTGRES_DB: identity
    ports: ["127.0.0.1:5432:5432"]
    volumes: ["pgdata:/var/lib/postgresql"]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U iam_migrator -d identity"]
      interval: 5s
      timeout: 3s
      retries: 10
  redis:
    image: ${REDIS_IMAGE:?resolve image digest first}
    profiles: [cache]
    environment:
      REDIS_PASSWORD: ${REDIS_PASSWORD:?set REDIS_PASSWORD}
    command: ["sh", "-c", "exec redis-server --requirepass \"$$REDIS_PASSWORD\""]
    ports: ["127.0.0.1:6379:6379"]
  rabbitmq:
    image: ${RABBITMQ_IMAGE:?resolve image digest first}
    profiles: [messaging]
    environment:
      RABBITMQ_DEFAULT_USER: iam_lab
      RABBITMQ_DEFAULT_PASS: ${RABBITMQ_PASSWORD:?set RABBITMQ_PASSWORD}
    ports: ["127.0.0.1:5672:5672", "127.0.0.1:15672:15672"]
    volumes: ["rabbitdata:/var/lib/rabbitmq"]
  mailpit:
    image: ${MAILPIT_IMAGE:?resolve image digest first}
    profiles: [mail]
    ports: ["127.0.0.1:1025:1025", "127.0.0.1:8025:8025"]
volumes:
  pgdata: {}
  rabbitdata: {}
```

```powershell
docker compose --env-file lab/infra/compose/.env -f lab/infra/compose/compose.yaml config --quiet
docker compose --env-file lab/infra/compose/.env -f lab/infra/compose/compose.yaml up -d postgres
docker compose --env-file lab/infra/compose/.env -f lab/infra/compose/compose.yaml ps
```

`config --quiet` tránh in interpolated secrets. Không dùng `down -v` như một bước restart vì nó xóa dữ liệu. `stop/start` dùng cho failure lab; backup trước reset có chủ đích.

## 7. HTTPS local và tên miền

Cài mkcert và Caddy theo distribution chính thức, xác nhận `mkcert --version`, `caddy version`. Trên Windows dùng `winget search mkcert` / `winget search Caddy` để đối chiếu publisher/ID trước cài; các package manager có thể thay catalog. [mkcert Windows](https://github.com/FiloSottile/mkcert#windows), [Caddy install](https://caddyserver.com/docs/install).

Tạo root CA local/chứng chỉ ở terminal của bạn:

```powershell
New-Item -ItemType Directory -Force lab/.secrets/tls | Out-Null
mkcert -install
mkcert -cert-file lab/.secrets/tls/local.pem -key-file lab/.secrets/tls/local-key.pem iam.local.test app-a.local.test app-b.local.test api.local.test localhost 127.0.0.1
```

Chỉ nhập **CA public certificate** vào trust store cần dùng; không chia sẻ root CA private key. Thêm dòng `127.0.0.1 iam.local.test app-a.local.test app-b.local.test api.local.test` vào Windows hosts bằng editor chạy quyền admin; giữ nội dung khác nguyên vẹn. Đây là thay đổi môi trường local được người học thực hiện, không phải bước production DNS.

Tạo `lab/infra/compose/Caddyfile` (Caddy chạy native để proxy đến loopback):

```caddyfile
{
  auto_https disable_redirects
}
https://iam.local.test:8443 {
  tls {$LAB_CERT_FILE} {$LAB_KEY_FILE}
  reverse_proxy 127.0.0.1:3000
}
https://app-a.local.test:8444 {
  tls {$LAB_CERT_FILE} {$LAB_KEY_FILE}
  reverse_proxy 127.0.0.1:3101
}
https://app-b.local.test:8445 {
  tls {$LAB_CERT_FILE} {$LAB_KEY_FILE}
  reverse_proxy 127.0.0.1:3102
}
https://api.local.test:8446 {
  tls {$LAB_CERT_FILE} {$LAB_KEY_FILE}
  reverse_proxy 127.0.0.1:3200
}
```

```powershell
$env:LAB_CERT_FILE = (Resolve-Path lab/.secrets/tls/local.pem).Path.Replace('\','/')
$env:LAB_KEY_FILE = (Resolve-Path lab/.secrets/tls/local-key.pem).Path.Replace('\','/')
$env:NODE_EXTRA_CA_CERTS = Join-Path (mkcert -CAROOT) 'rootCA.pem'
caddy validate --config lab/infra/compose/Caddyfile --adapter caddyfile
caddy run --config lab/infra/compose/Caddyfile --adapter caddyfile
```

Các Node process làm HTTPS client cần `NODE_EXTRA_CA_CERTS` **trước khi process khởi động**. Terminal khác gọi `curl.exe --cacert <đường-dẫn-rootCA.pem> -i https://iam.local.test:8443/health/live`. Browser mở health endpoint phải không báo certificate error. App A/B chưa tạo nên 502 ở những host đó là dự kiến; chỉ kiểm tra IAM lúc này. Không dùng `NODE_TLS_REJECT_UNAUTHORIZED=0` hoặc `curl -k` để vượt bài TLS.

## 8. Git và CI tối thiểu

Tạo `.gitignore` root gồm:

```gitignore
node_modules/
lab/**/dist/
lab/**/.env
lab/.secrets/
lab/evidence/
lab/**/coverage/
*.log
```

Lưu `.env.example` chỉ có tên setting và giá trị không nhạy cảm. Tại workspace chưa có Git, chạy `git init`, kiểm tra `git status --short` và `git diff --cached` trước commit. Không tự push repository ra ngoài khi học chưa cần.

CI tối thiểu có bốn lệnh: setup đúng Node/pnpm → `pnpm -C lab install --frozen-lockfile` → typecheck → test → build. Chương 19 cung cấp workflow pin action SHA, integration dependencies và release pipeline đầy đủ. Local phải pass bốn bước này trước khi checkpoint.

## 9. Failure lab và troubleshooting

- Đặt `PORT=not-a-number`, chạy dev: process phải fail startup, không dùng port ngầm khác. Sửa lại 3000.
- Cho readiness callback trả false: live vẫn 200, ready 503, test bảo vệ khác biệt này.
- Gửi `/demo/failure`: response không có stack; log có request ID để liên kết.
- Dừng Caddy: HTTPS không tới được; backend loopback health còn chạy. Khởi động lại Caddy và phân biệt lỗi proxy với app.

| Triệu chứng | Kiểm tra | Cách sửa |
|---|---|---|
| `EADDRINUSE` | `Get-NetTCPConnection -LocalPort 3000` | Xác định process trước khi dừng; hoặc đổi port và cả proxy |
| Docker port 5432 bận | Compose logs và local process | Chọn port lab khác, cập nhật URL rõ ràng |
| Argon2 build script bị chặn | pnpm build approval | allowlist đúng native dependency, không cho phép toàn bộ |
| HTTPS client báo CA | Env được đặt sau startup | Set CA env trước Node process |
| Router mới luôn 404 | Đặt sau fallback middleware | Đăng ký router trước 404/error handler |

## 10. Definition of Done

- [ ] Có `lab/.node-version`, packageManager pin và lockfile.
- [ ] Typecheck, hai test và build thành công trên máy của bạn.
- [ ] Health qua HTTPS local với certificate verification bật.
- [ ] Compose config hợp lệ, PostgreSQL healthy, image digest đã lưu.
- [ ] Không secret/cookie/token/query nhạy cảm trong Git hoặc logs.
- [ ] Tái hiện config failure, readiness failure và shutdown.
- [ ] Lưu commands/version/output đã redaction trong evidence; commit `ch03-skeleton`.

Nguồn: [pnpm workspaces](https://pnpm.io/workspaces), [Express error handling](https://expressjs.com/en/guide/error-handling.html), [Node env file](https://nodejs.org/docs/latest-v24.x/api/cli.html), [Docker Compose profiles](https://docs.docker.com/compose/how-tos/profiles/), [Caddy reverse proxy](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy).
