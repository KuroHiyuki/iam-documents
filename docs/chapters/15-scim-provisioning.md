# 15. SCIM 2.0: provisioning Users/Groups và deprovision không rò tenant

[Mục lục](../../README.md) · [Trước: federation](14-enterprise-federation.md) · [Tiếp: governance](16-governance-privileged-access.md)

**Điều kiện đầu vào:** Identity/Federation, Authorization và Audit đã chạy; đọc ownership tại [implementation map](../reference/implementation-map.md). Bạn sẽ thêm SCIM facade vào lab/services/governance và directory-owner commands vào Identity. Không dựng một “user database thứ hai” trong Governance rồi để nó quyết định membership hiện hành.

## 15.1. Provisioning khác login và khác role assignment

OIDC/SAML cho biết người vừa đăng nhập là ai. SCIM giúp một hệ thống doanh nghiệp tạo/cập nhật/vô hiệu tài khoản và nhóm tại platform. SCIM client có thể là corporate directory của Acme; nó không được sửa users của Beta hoặc cấp platform-admin role chỉ bằng một attribute roles.

Mô hình global identity đòi tách tài khoản và membership. active=false từ Acme chỉ suspend membership Acme và các grants thuộc Acme. Alice vẫn dùng Beta nếu Beta cho phép. DELETE SCIM user là remove provisioning resource/membership ở source scope, không xoá global user hay tất cả sessions trên platform. Xoá global account là workflow riêng có kiểm tra ảnh hưởng và retention.

SCIM externalId là identifier của hệ thống nguồn, id là identifier do service provider cấp. Không dùng email làm cả hai. SCIM userName có thể là địa chỉ email nhưng collision với global account có sẵn không tự động chứng minh cùng người. Default: trả 409, yêu cầu admin liên kết explicit; sau link, provisioning chỉ thay tenant profile/membership, không đổi email/password global mà user đang dùng ở tổ chức khác.

## 15.2. Support matrix trước khi code

Base URL lab là http://127.0.0.1:3500/scim/v2, chỉ internal/local. Production có HTTPS endpoint riêng được cấu hình trong directory khách hàng, WAF/rate limit và connector credential bound một org. Không expose cổng 3500 public trực tiếp.

| Capability | Triển khai trong bài |
|---|---|
| ServiceProviderConfig, Schemas, ResourceTypes | GET mô tả đúng profile đang hỗ trợ |
| Users | POST, GET id/list, PUT, PATCH active/profile, DELETE |
| Groups | POST, GET id/list, PUT, PATCH members, DELETE |
| Filtering | userName eq, externalId eq; displayName eq cho Groups |
| Pagination | startIndex/count, stable ordering; count=0 chỉ trả total |
| Concurrency | meta.version/ETag và If-Match; operation receipt |
| Bulk/password/sort | Không hỗ trợ, quảng bá false; lỗi rõ ràng |

Đây là interoperability profile có chủ đích, chưa phải implementation mọi SCIM extension. RFC 9865 thêm cursor pagination và RFC 9967 thêm security-event/asynchronous capability; bài chọn synchronous baseline index pagination, không quảng bá những extension chưa code. Kiểm tra provider thực tế có cần thêm filter/PATCH grammar trước onboarding; không im lặng ignore thao tác quan trọng.

## 15.3. Credentials và live authorization

Tạo connector scim-acme trong Governance, gồm org_id Acme, client_id scim-acme, allowed operations, enabled state và source/federation mapping được admin phê duyệt. Đăng ký confidential client trong Identity audience governance-api, scope scim:provision, service_org_id Acme. Governance có introspection credential kiểm tra audience governance-api; service token của Governance gọi PDP audience iam-policy-api.

Trên mỗi HTTP request SCIM: online introspect SCIM token; query connector config sống; so org/client/scope; gọi PDP với original subject_token, action directory.provision, resource type directory do Governance sở hữu; PDP đọc live policy. Registry/permission/role assignment cho service principal scim-acme ở Acme phải được cấp explicit. Không lấy org từ JSON body, filter hoặc header X-Tenant.

Governance gọi Identity internal directory API bằng machine token audience identity-internal-api, scope directory:provision và organization được bind. Identity introspect/verify client rồi dùng local control-plane policy kiểm tra scope hiện hành, connector/org và owner command; không gọi PDP để tránh vòng phụ thuộc. Introspection credentials không tự có quyền provision chỉ vì nằm trong mạng internal.

```powershell
$basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("scim-acme:" + $env:SCIM_ACME_SECRET))
$scimToken = Invoke-RestMethod https://iam.local.test:8443/oauth2/token -Method Post -Headers @{Authorization="Basic $basic"} -Body @{grant_type="client_credentials";audience="governance-api";scope="scim:provision"}
$scimHeaders = @{Authorization="Bearer $($scimToken.access_token)";Accept="application/scim+json"}
```

Không đặt user token quản trị lâu dài vào connector config. Token client credentials ngắn hạn vẫn cần online validation; token còn exp nhưng connector disabled phải bị chặn.

## 15.4. Dữ liệu owner và idempotent command

Thêm migration trong Identity:

```sql
CREATE TABLE provisioned_resources (
  org_id uuid NOT NULL REFERENCES organizations(id),
  connector_id uuid NOT NULL,
  id uuid NOT NULL,
  kind text NOT NULL CHECK(kind IN ('User','Group')),
  external_id text,
  user_id uuid REFERENCES users(id),
  group_id uuid,
  user_name_normalized text,
  document jsonb NOT NULL,
  version bigint NOT NULL DEFAULT 1,
  deleted_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(org_id,connector_id,id),
  FOREIGN KEY(org_id,group_id) REFERENCES groups(org_id,id),
  CHECK ((kind='User' AND user_id IS NOT NULL AND group_id IS NULL)
      OR (kind='Group' AND group_id IS NOT NULL AND user_id IS NULL))
);
CREATE UNIQUE INDEX provisioned_external_id_unique
  ON provisioned_resources(org_id,connector_id,external_id)
  WHERE external_id IS NOT NULL AND deleted_at IS NULL;
CREATE UNIQUE INDEX provisioned_username_unique
  ON provisioned_resources(org_id,connector_id,user_name_normalized)
  WHERE kind='User' AND deleted_at IS NULL;
```

Governance operation journal không giữ authoritative active state. Owner API contract:

| Method/Identity route | Ý nghĩa |
|---|---|
| GET /internal/v1/orgs/:orgId/scim/:connectorId/Users | Live list/filter/count từ owner |
| GET .../Users/:id | Live resource + version |
| PUT .../Users/:id | Create/replace normalized command, operation_id, expected_version |
| DELETE .../Users/:id | Remove membership/resource, operation_id, expected_version |
| Tương tự /Groups | Groups và group_members nằm cùng transaction owner |

POST SCIM do Governance cấp UUID mới, gọi PUT owner với expected_version=null (create-only). PUT/PATCH existing cần expected_version từ live GET/If-Match. Body normalized có desired document, không chứa SQL hoặc user-supplied org. Dùng idempotency_records trong Identity, scope gồm org/connector/resource/command, payload hash và result; cùng operation ID/body trả receipt, khác body trả409.

Operation_id được Governance persist trước khi gọi owner. Retry sau timeout dùng lại ID. Có hai database nên một operation có thể ở trạng thái unknown sau owner commit; đọc receipt owner bằng cùng operation ID để resolve. Không “compensate” bằng cách re-enable user khi một bước audit/email sau đó lỗi.

## 15.5. Chuẩn hoá SCIM và error responses

Tạo scim/errors.ts và scim/filter.ts trong Governance:

```ts
import type {Response} from "express";
export function scimError(res:Response,status:number,detail:string,scimType?:string) {
  res.status(status).type("application/scim+json").json({
    schemas:["urn:ietf:params:scim:api:messages:2.0:Error"],
    status:String(status),detail,...(scimType ? {scimType} : {})
  });
}
export function parseFilter(value:unknown,kind:"User"|"Group") {
  if (value===undefined) return null;
  if (typeof value!=="string" || value.length>512) throw new Error("invalidFilter");
  const m=/^(userName|externalId|displayName) eq ("(?:[^"\\]|\\.)*")$/.exec(value);
  if (!m || (kind==="User" && m[1]==="displayName") ||
      (kind==="Group" && m[1]==="userName")) throw new Error("invalidFilter");
  return {attribute:m[1]!,value:JSON.parse(m[2]!) as string};
}
export function pagination(start:unknown,count:unknown) {
  const a=start===undefined ? "1" : String(start);
  const b=count===undefined ? "100" : String(count);
  if (!/^\d+$/.test(a) || !/^\d+$/.test(b)) throw new Error("invalidValue");
  const startIndex=Math.max(1,Number(a)), size=Math.min(100,Number(b));
  if (!Number.isSafeInteger(startIndex) || !Number.isSafeInteger(size))
    throw new Error("invalidValue");
  return {startIndex,count:size};
}
```

SQL filter chọn column từ allowlist ở code, value luôn parameter; không nối raw filter vào WHERE. List dùng ORDER BY id, cùng snapshot cho total và Resources; trả schemas ListResponse, totalResults, startIndex, itemsPerPage và Resources. count=0 không query page data. Pagination không bảo đảm snapshot giữ nguyên giữa hai HTTP pages có mutations; ghi rõ để connector reconciliation xử lý.

User schemas gồm urn:ietf:params:scim:schemas:core:2.0:User; Group tương ứng Group. Require userName chuỗi, active boolean nếu có, externalId optional string, displayName optional. Không nhận password trong profile này. Ignore id/meta read-only trên create/replace theo profile; PATCH vào read-only trả400 mutability. Không trust emails.verified từ SCIM như chứng minh global email.

ETag W/"version" do owner tạo; GET trả header ETag và meta.version, Location thuộc SCIM URL bên ngoài. POST thành công201; GET/PUT/PATCH200; DELETE204; missing404; duplicate409 uniqueness; wrong version412; malformed400 invalidSyntax/invalidValue; unsupported filter400 invalidFilter. Dependency lỗi503 dùng SCIM error body, không trả một ListResponse rỗng.

## 15.6. PATCH active và owner transaction

Không merge một object PATCH tuỳ ý vào database. Validate schemas PatchOp, Operations array giới hạn20 và apply vào copy live document. Baseline User hỗ trợ replace/add active, displayName; remove displayName; không remove active/userName. Implement active path trước, rồi mở rộng có tests:

```ts
type ScimUser={userName:string;active:boolean;displayName?:string;externalId?:string};
export function applyUserPatch(current:ScimUser,body:unknown):ScimUser {
  if (!body || typeof body!=="object") throw new Error("invalidSyntax");
  const p=body as {schemas?:unknown;Operations?:unknown};
  if (!Array.isArray(p.schemas) ||
      !p.schemas.includes("urn:ietf:params:scim:api:messages:2.0:PatchOp") ||
      !Array.isArray(p.Operations) || p.Operations.length<1 || p.Operations.length>20)
    throw new Error("invalidSyntax");
  const next={...current};
  for (const value of p.Operations) {
    if (!value || typeof value!=="object") throw new Error("invalidSyntax");
    const op=value as {op?:unknown;path?:unknown;value?:unknown};
    const method=String(op.op).toLowerCase();
    if (op.path==="active" && ["add","replace"].includes(method)) {
      if (typeof op.value!=="boolean") throw new Error("invalidValue");
      next.active=op.value;
    } else if (op.path==="displayName" && ["add","replace"].includes(method)) {
      if (typeof op.value!=="string" || op.value.length>200) throw new Error("invalidValue");
      next.displayName=op.value;
    } else if (op.path==="displayName" && method==="remove") {
      delete next.displayName;
    } else {throw new Error("invalidPath");}
  }
  return next;
}
```

PUT replacement khác PATCH: các writable optional attributes bị bỏ có thể được xoá; userName/active defaults theo profile đã công bố. Không dùng PATCH shallow merge để thực hiện PUT. Tất cả Operations được validate và apply trước owner mutation, không commit từng operation riêng rồi fail ở operation cuối.

Owner xử lý update existing trong withTransaction của chương04:

```ts
// Các biến command đã validate và guard ngoài transaction; db là PoolClient.
const rows=await db.query(
  "SELECT * FROM provisioned_resources WHERE org_id=$1 AND connector_id=$2" +
  " AND id=$3 AND kind='User' AND deleted_at IS NULL FOR UPDATE",
  [orgId,connectorId,resourceId]
);
const row=rows.rows[0];
if (!row) throw new Error("not_found");
if (String(row.version)!==expectedVersion) throw new Error("precondition_failed");
await db.query(
  "UPDATE memberships SET status=$3,version=version+1 WHERE org_id=$1 AND user_id=$2",
  [orgId,row.user_id,desired.active ? "active" : "suspended"]
);
if (!desired.active) {
  await db.query(
    "UPDATE oauth_grants SET revoked_at=COALESCE(revoked_at,clock_timestamp())" +
    " WHERE org_id=$1 AND user_id=$2",[orgId,row.user_id]
  );
}
const updated=await db.query(
  "UPDATE provisioned_resources SET document=$4,version=version+1,updated_at=clock_timestamp()" +
  " WHERE org_id=$1 AND connector_id=$2 AND id=$3 RETURNING version",
  [orgId,connectorId,resourceId,desired]
);
// Cùng transaction: receipt operation_id + outbox + result với version updated.rows[0].version.
```

Create path tạo global user khi địa chỉ chưa tồn tại hoặc explicit account mapping đã được admin duyệt, tạo membership và provisioned_resources cùng transaction. Không generate password mặc định. Re-enable active=true không làm revoked grants sống lại; user login/cấp grant mới. DELETE đánh dấu deleted_at, membership removed, revoke grants org, gỡ group_members org, increment version và outbox cùng transaction. Không xoá user global.

## 15.7. Groups và membership atomic

Group resource id maps group_id riêng của Identity. POST tạo groups và provisioned_resources; displayName được normalize cho uniqueness trong source. members[].value là SCIM User resource ID trong cùng connector/org, không user_id do client phỏng đoán. Resolve tất cả members trước mutation; missing/cross-org trả400 invalidValue hoặc404 theo policy, không tạo membership mới từ Group PATCH.

PATCH Groups hỗ trợ add members với array, replace members để thay toàn bộ set, remove path members[value eq "SCIM_USER_ID"], và remove path members để xoá toàn bộ set. Parser value-filter chỉ chấp nhận mẫu này, không dùng eval hoặc raw SQL. Dùng Set để dedup. DELETE/INSERT group_members và tăng group/provisioned version trong cùng transaction, constraint FK giữ đúng org.

Group removal có hiệu lực với request kế tiếp vì introspection query groups sống. Không chờ SCIM event đến Authorization. Group membership không tự cấp role; admin gán role cho group trong Policy service qua owner API. Nếu external groups mapping tới application roles, dùng allowlisted mapping được tenant admin phê duyệt, tuyệt đối không map text "admin" thành platform admin.

## 15.8. Requests thật, concurrency và failure lab

```powershell
$newUser=@{
  schemas=@("urn:ietf:params:scim:schemas:core:2.0:User")
  externalId="acme-employee-003"
  userName="learner003@example.test"
  displayName="Learner Three"
  active=$true
} | ConvertTo-Json
$created=Invoke-RestMethod http://127.0.0.1:3500/scim/v2/Users -Method Post -Headers $scimHeaders -ContentType application/scim+json -Body $newUser
Invoke-RestMethod 'http://127.0.0.1:3500/scim/v2/Users?filter=userName%20eq%20%22learner003%40example.test%22&startIndex=1&count=10' -Headers $scimHeaders
$patch=@{
  schemas=@("urn:ietf:params:scim:api:messages:2.0:PatchOp")
  Operations=@(@{op="replace";path="active";value=$false})
} | ConvertTo-Json -Depth 5
$writeHeaders=$scimHeaders.Clone()
$writeHeaders["If-Match"]=$created.meta.version
Invoke-RestMethod ("http://127.0.0.1:3500/scim/v2/Users/" + $created.id) -Method Patch -Headers $writeHeaders -ContentType application/scim+json -Body $patch
```

Expected POST201, filter totalResults=1, PATCH200 active=false/version tăng. SCIM id là UUID mới của resource, không giả một fixed output. Sau PATCH commit, token của membership đó introspect inactive ngay. Với Alice đã có Beta, seed explicit SCIM mapping vào Alice/Acme rồi chứng minh Beta vẫn active; không auto-link Alice bằng email trong test setup production-like.

Hai PATCH dùng cùng If-Match: một200, một412. Retry cùng operation ID sau owner timeout trả receipt; payload khác409. POST externalId/userName duplicate409, malformed filter400; count0 không có Resources; userName chứa quote không SQL injection. Group member Beta dùng token Acme bị chặn. Token scim-acme gắn orgBeta trong body không đổi authority.

Dừng Identity ngay trước command: Governance trả503, operation queued/unknown có thể reconcile, không trả201 giả. Dừng Governance sau owner commit: retry dùng receipt không tạo user thứ hai. Dừng broker: provisioning commit và revoke vẫn đúng, outbox pending; phục hồi broker audit theo sau. Không chạy retry vô hạn với validation conflict.

Troubleshooting: kiểm tra schemas/content type, exact base URL, service scopes/audience, connector enabled/org binding, externalId mapping và ETag. Directory gửi filter không hỗ trợ thì mở rộng parser có test hoặc sửa connector configuration; không trả200 rỗng. Lỗi permission không được chữa bằng bỏ Authorization guard vì endpoint “internal”.

**DoD:** live owner GET/commands, Users/Groups CRUD/PATCH đúng support matrix; stable IDs/scoped uniqueness; no email auto-link; active/delete chỉ ảnh hưởng tenant; optimistic concurrency/idempotency receipt/outbox; connector credential isolation; pagination/filter/error tests; downstream token revoke và group revoke online; real provisioning client interoperability test được lưu evidence. Bài governance tiếp theo dùng chính owner commands, không bypass chúng bằng SQL xuyên database.

### Definition of Done

- [ ] Users và Groups có CRUD/list/filter/PATCH tests đúng capability metadata đã quảng bá.
- [ ] active=false và DELETE chặn access Acme sau commit; Alice ở Beta vẫn hoạt động.
- [ ] If-Match conflict, duplicate externalId, cross-org members, timeout-after-commit và operation retry có regression tests.
- [ ] Governance chỉ facade/journal; GET và mutation authority ở Identity owner, không dùng projection để cấp quyền.
- [ ] Corporate/test SCIM client chạy interoperability scenario; không có plaintext secrets trong logs/evidence.

Nguồn: [RFC 7643 core schema](https://www.rfc-editor.org/rfc/rfc7643), [RFC 7644 protocol](https://www.rfc-editor.org/rfc/rfc7644), [RFC 9865 cursor extension](https://www.rfc-editor.org/rfc/rfc9865), [RFC 9967 event extension](https://www.rfc-editor.org/rfc/rfc9967), [Microsoft SCIM provisioning guide](https://learn.microsoft.com/en-us/entra/identity/app-provisioning/use-scim-to-provision-users-and-groups).
