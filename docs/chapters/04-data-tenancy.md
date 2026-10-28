# 04 — Thiết kế dữ liệu và cách ly tenant

[Trước: workspace](03-workspace-bootstrap.md) · [Trang đầu](../../README.md) · [Tiếp: account lifecycle](05-account-lifecycle.md)

## 1. Mục tiêu và điều kiện đầu vào

Skeleton chương 03 đang chạy, PostgreSQL healthy. Chương này tạo schema Identity, fixture, database roles, transaction helper và bài kiểm chứng RLS. Bạn phải phân biệt account global với membership, và biết ranh giới tenant được bảo vệ ở API, query, constraint và database role.

Đọc SQL đích [identity.sql](../reference/sql/identity.sql). Schema có trước cả những bảng protocol sẽ học sau; mục đích là giữ tên cột nhất quán. Áp dụng bằng migration có version, không sửa trực tiếp database một cách không ghi nhận.

## 2. ERD và các invariant

```mermaid
erDiagram
  USERS ||--o{ MEMBERSHIPS : participates
  ORGANIZATIONS ||--o{ MEMBERSHIPS : contains
  ORGANIZATIONS ||--o{ GROUPS : owns
  GROUPS ||--o{ GROUP_MEMBERS : includes
  MEMBERSHIPS ||--o{ GROUP_MEMBERS : scopes
  USERS ||--o{ SESSIONS : authenticates
  CLIENTS ||--o{ APP_ASSIGNMENTS : registered
  ORGANIZATIONS ||--o{ APP_ASSIGNMENTS : enables
  CLIENTS ||--o{ OAUTH_GRANTS : receives
  SESSIONS ||--o{ OAUTH_GRANTS : backs
  OAUTH_GRANTS ||--o{ OAUTH_CODES : binds
  OAUTH_GRANTS ||--o{ OAUTH_TOKENS : issues
```

`users.id` không đổi khi email đổi. `memberships(org_id,user_id)` là composite primary key, ngăn tạo hai membership mâu thuẫn. Group membership tham chiếu cả group và user trong cùng organization bằng composite FK. Foreign key không tự chứng minh user active; live status vẫn phải query trong authentication/authorization.

Role không nằm trong `users`. Role/assignment thuộc Authorization database ở chương 11. Credential/password thuộc Identity; email verification không đồng nghĩa đủ MFA hay corporate SSO.

## 3. Database role: migration khác runtime

Image lab tạo `iam_migrator` làm bootstrap administrator. **Không chạy app bằng role đó.** Production có owner/migrator riêng, chỉ quyền cần thiết; runtime không superuser, không BYPASSRLS, không sở hữu table. Local user bootstrap có đặc quyền vì image init, chỉ dùng để thiết lập bài học.

Tạo secret app và file setup ngoài Git:

```powershell
New-Item -ItemType Directory -Force lab/.secrets | Out-Null
$appDbSecret = node --input-type=module -e 'import {randomBytes} from "node:crypto";console.log(randomBytes(24).toString("hex"));'
$composeEnv = Get-Content -Encoding UTF8 lab/infra/compose/.env
$pgSecret = (($composeEnv | Where-Object { $_ -like 'PG_PASSWORD=*' }) -split '=',2)[1]
@"
CREATE ROLE identity_app LOGIN NOSUPERUSER NOBYPASSRLS PASSWORD '$appDbSecret';
GRANT CONNECT ON DATABASE identity TO identity_app;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO identity_app;
"@ | Set-Content -Encoding UTF8 lab/.secrets/setup-roles.sql
docker compose --env-file lab/infra/compose/.env -f lab/infra/compose/compose.yaml cp lab/.secrets/setup-roles.sql postgres:/tmp/setup-roles.sql
docker compose --env-file lab/infra/compose/.env -f lab/infra/compose/compose.yaml exec -T postgres psql -U iam_migrator -d identity -v ON_ERROR_STOP=1 -f /tmp/setup-roles.sql
Add-Content -Encoding UTF8 lab/services/identity/.env "DATABASE_URL=postgresql://identity_app:$appDbSecret@127.0.0.1:5432/identity"
Add-Content -Encoding UTF8 lab/services/identity/.env "MIGRATION_DATABASE_URL=postgresql://iam_migrator:$pgSecret@127.0.0.1:5432/identity"
```

Hai secret là hex nên dùng được trong URL/SQL literal của script cụ thể này; không áp pattern interpolate SQL cho input người dùng. Chỉ tạo role một lần. Khi retry, kiểm tra `pg_roles`, không drop database/role tùy tiện. `.env` local có cả hai credential cho tiện học; production migration job nhận migration credential riêng, app pod chỉ có runtime credential.

## 4. Migration có checksum và lock

Cài SQL driver:

```powershell
pnpm -C lab --filter @iam/identity add --save-exact pg@8.23.1
pnpm -C lab --filter @iam/identity add --save-exact -D @types/pg@8.23.1
New-Item -ItemType Directory -Force lab/services/identity/migrations | Out-Null
$coreSql = Get-Content -Raw -Encoding UTF8 docs/reference/sql/identity.sql
$coreSql = $coreSql -replace '(?m)^BEGIN;\r?$', '' -replace '(?m)^COMMIT;\r?$', ''
[IO.File]::WriteAllText((Join-Path (Get-Location) 'lab/services/identity/migrations/001-core.sql'),$coreSql,[Text.UTF8Encoding]::new($false))
$rlsSql = Get-Content -Raw -Encoding UTF8 docs/reference/sql/identity-rls.sql
$rlsSql = $rlsSql -replace '(?m)^BEGIN;\r?$', '' -replace '(?m)^COMMIT;\r?$', ''
[IO.File]::WriteAllText((Join-Path (Get-Location) 'lab/services/identity/migrations/002-rls.sql'),$rlsSql,[Text.UTF8Encoding]::new($false))
```

Chỉ bỏ hai wrapper transaction độc lập của các file tham chiếu này vì runner sẽ bọc transaction. Không dùng regex này làm SQL parser tổng quát cho migration có stored procedure.

Tạo `src/migrate.ts`:

```typescript
import { Pool } from 'pg';
import { readdir, readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { join } from 'node:path';

const connectionString = process.env.MIGRATION_DATABASE_URL;
if (!connectionString) throw new Error('MIGRATION_DATABASE_URL required');
const migratorPool = new Pool({connectionString, max: 1});
const db = await migratorPool.connect();
try {
  await db.query('SELECT pg_advisory_lock(74103001)');
  await db.query(`CREATE TABLE IF NOT EXISTS schema_migrations (
    name text PRIMARY KEY, checksum text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now()
  )`);
  const names = (await readdir('migrations')).filter(n => /^\d+[-\w]*\.sql$/.test(n)).sort();
  for (const name of names) {
    const sql = await readFile(join('migrations', name), 'utf8');
    const checksum = createHash('sha256').update(sql).digest('hex');
    await db.query('BEGIN');
    try {
      const old = await db.query<{checksum: string}>(
        'SELECT checksum FROM schema_migrations WHERE name=$1', [name]);
      if (old.rows[0]) {
        if (old.rows[0].checksum !== checksum) throw new Error(`Changed applied migration: ${name}`);
      } else {
        await db.query(sql);
        await db.query('INSERT INTO schema_migrations(name,checksum) VALUES($1,$2)', [name,checksum]);
      }
      await db.query('COMMIT');
      console.log(JSON.stringify({migration:name, status:old.rows[0] ? 'already_applied':'applied'}));
    } catch (error) {
      await db.query('ROLLBACK');
      throw error;
    }
  }
} finally {
  await db.query('SELECT pg_advisory_unlock(74103001)');
  db.release();
  await migratorPool.end();
}
```

Thêm script `migrate` vào package Identity: `node --env-file=.env --import tsx src/migrate.ts`. Chạy hai lần:

```powershell
pnpm -C lab --filter @iam/identity migrate
pnpm -C lab --filter @iam/identity migrate
```

Kỳ vọng lần đầu `applied`, lần hai `already_applied`. Sửa migration đã áp dụng phải bị chặn bởi checksum. Thay đổi thật cần file version tiếp theo; chương 19 dạy expand/contract và rollback compatibility.

Sau migration, cấp quyền runtime bằng bootstrap psql:

```sql
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO identity_app;
REVOKE ALL ON schema_migrations FROM identity_app;
-- App không được sửa public/private key registry trực tiếp qua management routes.
REVOKE INSERT, UPDATE, DELETE ON signing_keys FROM identity_app;
-- Key rotation chạy bằng operational credential riêng.
```

Tạo file grant SQL ở `lab/.secrets/runtime-grants.sql`, copy/exec như setup role. Migration mới cần GRANT rõ ràng cho bảng mới; không dùng ALL PRIVILEGES cho database khác. Schema runtime SQL privilege rộng theo nghiệp vụ service chưa thay guard của từng endpoint; production có thể tách read/write protocol/admin roles như bài nâng cao.

## 5. Seed fixture và xác nhận schema

```powershell
docker compose --env-file lab/infra/compose/.env -f lab/infra/compose/compose.yaml cp docs/reference/sql/seed.sql postgres:/tmp/seed.sql
docker compose --env-file lab/infra/compose/.env -f lab/infra/compose/compose.yaml exec -T postgres psql -U iam_migrator -d identity -v ON_ERROR_STOP=1 -f /tmp/seed.sql
docker compose --env-file lab/infra/compose/.env -f lab/infra/compose/compose.yaml exec -T postgres psql -U iam_migrator -d identity -c 'SELECT org_id,user_id,status FROM memberships ORDER BY org_id,user_id'
```

Kỳ vọng ba memberships: Alice ở Acme/Beta, Bob ở Beta. Fixtures chưa có password/client secret; chương 05 và 06 sẽ sinh tại máy bạn. Không đặt password cố định dễ đoán trong seed. Seed chạy một lần trên DB lab mới, không là một production migration.

## 6. Pool và transaction helper

Tạo `src/db.ts`:

```typescript
import { Pool, type PoolClient } from 'pg';
import { config } from './config.js';
export const pool = new Pool({
  connectionString: config.databaseUrl, max: 10,
  connectionTimeoutMillis: 1000, idleTimeoutMillis: 30_000,
  statement_timeout: 1000, application_name: 'iam-identity'
});
export async function withTransaction<T>(fn: (db: PoolClient) => Promise<T>): Promise<T> {
  const db = await pool.connect();
  let releaseWithError: Error | undefined;
  try {
    await db.query('BEGIN');
    const result = await fn(db);
    await db.query('COMMIT');
    return result;
  } catch (error) {
    try { await db.query('ROLLBACK'); }
    catch (rollbackError) { releaseWithError = rollbackError instanceof Error ? rollbackError : new Error('rollback_failed'); }
    throw error;
  } finally { db.release(releaseWithError); }
}
export async function withOrgTransaction<T>(orgId: string, fn: (db: PoolClient) => Promise<T>): Promise<T> {
  return withTransaction(async db => {
    await db.query("SELECT set_config('app.org_id',$1,true)", [orgId]);
    return fn(db);
  });
}
```

Một transaction dùng **cùng PoolClient**. `pool.query('BEGIN')` rồi nhiều `pool.query` khác có thể đi các connection khác nhau và phá atomicity. [node-postgres transactions](https://node-postgres.com/features/transactions).

`set_config(...,true)` là transaction-local; không giữ organization trên connection sau COMMIT/ROLLBACK. `orgId` chỉ được truyền sau authentication/membership validation; RLS không biến header tùy ý thành context đáng tin.

Update `main.ts`: import `pool`, tạo app với `readiness: async () => { await pool.query('SELECT 1'); return true; }`; shutdown phải `await pool.end()` sau server drain. Không log connection string. Trong production, pool budget là tổng `replicas × pool.max` của tất cả service, migration và worker.

## 7. RLS có tác dụng và giới hạn

Bảng `organization_settings` dùng RLS ở migration 002. Seed bằng owner/superuser trong lab:

```sql
INSERT INTO organization_settings(org_id,support_email) VALUES
 ('10000000-0000-4000-8000-000000000001','support@acme.example.test'),
 ('10000000-0000-4000-8000-000000000002','support@beta.example.test');
BEGIN;
SET LOCAL ROLE identity_app;
SELECT set_config('app.org_id','10000000-0000-4000-8000-000000000001',true);
SELECT org_id,support_email FROM organization_settings;
COMMIT;
```

Kỳ vọng chỉ Acme. Query lại dưới `identity_app` không context phải không thấy row. INSERT/UPDATE một row Beta khi context Acme phải bị policy `WITH CHECK` chặn, không chỉ che SELECT.

Core protocol cần tra global account và tìm org của opaque token; không bật RLS một cách máy móc trên mọi bảng rồi cấp BYPASSRLS cho app để chữa lỗi. Giáo trình dùng explicit bound predicates/constraints cho core protocol và RLS cho đường tenant settings, sau đó mở rộng pattern sang resource store. Muốn bao toàn bộ core tables bằng RLS phải thiết kế privileged lookup functions/role boundaries riêng và kiểm thử. **Không tuyên bố một demo RLS đã bảo vệ mọi query.**

Superuser/BYPASSRLS vẫn bypass, owner thường bypass trừ FORCE. Vì thế test bằng runtime role; chạy bằng administrator sẽ tạo kết luận sai. [PostgreSQL RLS](https://www.postgresql.org/docs/18/ddl-rowsecurity.html).

## 8. Truy vấn đúng tenant và thử constraint

```typescript
// orgId từ context đã xác thực; userId là target được validate.
export async function getMembership(orgId: string, userId: string) {
  const result = await pool.query(
    'SELECT org_id,user_id,status FROM memberships WHERE org_id=$1 AND user_id=$2',
    [orgId,userId]);
  return result.rows[0] ?? null;
}
```

Không nối chuỗi input vào SQL. Các filter/sort động phải map qua allowlist, không parameterize tên cột bằng `$1` rồi tưởng đã chọn được column. List/export cũng cần tenant predicate, không chỉ GET-by-ID.

Kiểm thử bằng SQL:

- Insert membership Alice/Acme lần hai → unique violation.
- Insert group member Bob vào group Acme khi Bob không có Acme membership → FK violation.
- Gửi `org_id=Beta` trong JSON khi access token bind Acme → API không dùng hint đó làm context.
- RLS query không context → không có row; WRITE sai org → lỗi.
- Dùng pool `max=1`, lần lượt context Acme → commit → Beta → rollback → không context; không có dữ liệu org trước rò sang lần sau.

## 9. Failure lab và troubleshooting

Dừng PostgreSQL bằng `docker compose ... stop postgres`, gọi ready endpoint và một đường database: ready 503, live vẫn 200. Khởi động `start postgres`, đợi healthy, xác nhận phục hồi. Không tạo retry loop vô hạn hoặc trả cache allow khi DB down.

Thực hành transaction: BEGIN → update membership → cố ý query cột không tồn tại → ROLLBACK. Membership và outbox phải chưa đổi. Khi viết refresh reuse ở chương 08, lưu ý lỗi nghiệp vụ sau mutation có thể phải **commit** rồi mới trả lỗi; throw tùy tiện sẽ rollback revoke.

| Lỗi | Kiểm tra | Sửa |
|---|---|---|
| `relation does not exist` | Database/schema/migration ledger | Chạy migrate đúng connection, không tạo tay table thiếu |
| RLS test nhìn mọi tenant | `current_user`, rolbypassrls, owner | Test runtime role, kiểm tra FORCE |
| Query vẫn thấy org cũ | Session-level SET trên pool | SET LOCAL trong transaction và release trong finally |
| Migration treo | Advisory lock/process còn chạy | Điều tra session trước terminate, không chạy nhiều migrator |
| Checksum mismatch | Đã sửa migration cũ | Khôi phục file cũ, tạo migration version mới |

## 10. Definition of Done

- [ ] Tạo runtime role ít quyền, app không dùng bootstrap credential.
- [ ] Migrate hai lần đúng ledger/checksum và seed đúng ba memberships.
- [ ] Có db helper dùng một connection/transaction, pool limit và query timeout.
- [ ] RLS SELECT/WRITE/no-context/pool reuse đều được kiểm chứng dưới runtime role.
- [ ] Constraints chặn cross-org group membership và duplicate.
- [ ] DB outage không biến thành auth bypass; readiness phục hồi.
- [ ] Evidence và checkpoint `ch04-data-tenancy`.

Nguồn: [PostgreSQL constraints](https://www.postgresql.org/docs/18/ddl-constraints.html), [transactions](https://www.postgresql.org/docs/18/tutorial-transactions.html), [row locking](https://www.postgresql.org/docs/18/explicit-locking.html), [node-postgres pool](https://node-postgres.com/features/pooling).
