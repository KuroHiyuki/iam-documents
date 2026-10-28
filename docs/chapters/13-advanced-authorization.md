# 13. ABAC, explicit deny, constraints và ReBAC có giới hạn

[Mục lục](../../README.md) · [Trước: messaging/audit](12-messaging-audit.md) · [Tiếp: enterprise federation](14-enterprise-federation.md)

**Điều kiện đầu vào:** RBAC của chương 11 đã có tests, publisher/audit chương 12 chạy được. Không bắt đầu bằng cách chép một policy JSON từ AWS vào evaluator của bạn. Contract lab khác cloud, được mô tả tại [authorization contract](../reference/authorization-contract.md); SQL nâng cao đã có trong [authorization.sql](../reference/sql/authorization.sql).

## 13.1. Từ role tới một quyết định có giải thích

Role InvoiceApprover nói người dùng có chức năng approve. Nghiệp vụ có thể yêu cầu số tiền không quá hạn mức, session có MFA, invoice đang pending, người duyệt không phải người tạo. Một role cho từng tổ hợp sẽ bùng nổ. ABAC đưa những điều kiện này vào policy; business state transition cuối cùng vẫn do Invoice API kiểm tra.

Explicit deny phục vụ guardrail: cấm đọc invoice đã khoá dù có Reader; constraints là điều kiện mọi nguồn allow phải đáp ứng. ReBAC diễn tả chia sẻ một invoice hoặc folder với owner/editor/viewer. Cả ba bổ sung RBAC, không mở đường vòng tenant isolation.

Thứ tự duy nhất của evaluator: tenant boundary, deny, constraints, allow, default deny. Nếu graph nói viewer nhưng org không khớp, deny trước. Nếu role allow nhưng policy deny phù hợp, deny. Nếu policy malformed, trả 503/policy_invalid và alarm; không bỏ qua policy hỏng để duy trì availability.

## 13.2. Nguồn thuộc tính đáng tin

Principal sub, org, groups, amr, acr và auth_time lấy từ online introspection. Mở rộng LivePrincipal chương 11 với amr:string[], acr:string, auth_time:number; Identity đọc session hiện hành. Machine token không có human MFA; constraint cần human MFA phải thất bại cho machine, không giả một amr=mfa.

Resource owner lấy owner_id, amount_cents, status từ database, không từ request approve. Context.now và auth_age_seconds do PDP tính bằng đồng hồ server. Đừng nhận một field arbitrary context từ browser rồi coi là đã xác thực. Các thuộc tính từ HR/event projection chỉ được dùng nếu live source of truth được kiểm tra theo contract; bài này chưa cấp authority cho chúng.

Không nhét toàn bộ permissions vào access token để tránh live query. Token vẫn opaque; policy đọc database hiện hành trên mỗi request. Có thể cache schema tĩnh đã build vào binary, không cache assignment/allow. Điều này khiến request sau revoke commit nhìn thấy quyền mới mà không phụ thuộc TTL hay event.

## 13.3. Viết expression evaluator, không eval JavaScript

Chọn AST nhỏ với all tối đa 16 tests; operators eq, neq, lte, includes. Không hỗ trợ code strings, regex do tenant nhập, remote URL, arbitrary object traversal hoặc script execution. Mỗi policy được validate lúc ghi và đọc; không tin jsonb có nghĩa schema hợp lệ.

Tạo conditions.ts trong Authorization:

```ts
type Scalar = string | number | boolean;
type Context = Record<string,Scalar | string[]>;
type Test = {left:string;op:"eq"|"neq"|"lte"|"includes";right:Scalar | {ref:string}};
type Condition = {all:Test[]};
const paths = new Set([
  "principal.sub","principal.org_id","principal.amr",
  "resource.owner_id","resource.amount_cents","resource.status",
  "context.auth_age_seconds"
]);
const record = (v:unknown): v is Record<string,unknown> =>
  v !== null && typeof v === "object" && !Array.isArray(v);
const scalar = (v:unknown): v is Scalar =>
  typeof v === "string" || typeof v === "boolean" ||
  (typeof v === "number" && Number.isFinite(v));

export function parseCondition(input:unknown): Condition {
  if (!record(input) || Object.keys(input).join() !== "all" ||
      !Array.isArray(input.all) || input.all.length > 16) throw new Error("policy_invalid");
  for (const t of input.all) {
    if (!record(t) || Object.keys(t).some(k => !["left","op","right"].includes(k)) ||
        typeof t.left !== "string" || !paths.has(t.left) ||
        !["eq","neq","lte","includes"].includes(String(t.op))) throw new Error("policy_invalid");
    if (!scalar(t.right) &&
        !(record(t.right) && Object.keys(t.right).join()==="ref" &&
          typeof t.right.ref==="string" && paths.has(t.right.ref))) throw new Error("policy_invalid");
  }
  return input as Condition;
}

export function matches(condition:Condition, context:Context): boolean {
  return condition.all.every(test => {
    const left = context[test.left];
    const right = typeof test.right === "object" ? context[test.right.ref] : test.right;
    if (left === undefined || right === undefined) throw new Error("policy_attribute_missing");
    switch (test.op) {
      case "eq":
        if (Array.isArray(left) || typeof left!==typeof right) throw new Error("policy_type_error");
        return left===right;
      case "neq":
        if (Array.isArray(left) || typeof left!==typeof right) throw new Error("policy_type_error");
        return left!==right;
      case "lte":
        if (typeof left!=="number" || typeof right!=="number") throw new Error("policy_type_error");
        return left<=right;
      case "includes":
        if (!Array.isArray(left) || typeof right!=="string") throw new Error("policy_type_error");
        return left.includes(right);
    }
  });
}
```

Kiểu sai ở eq/neq không được trở thành cách né deny. Khi policy writer biết field types, phải chặn so sánh number với string trước commit; evaluator cũng throw khi mismatch. Việc phân biệt condition false hợp lệ với condition invalid rất quan trọng; test phải thể hiện cả hai.

Ví dụ constraint “approve cần MFA không quá 5 phút và invoice pending”:

```json
{
  "all":[
    {"left":"principal.amr","op":"includes","right":"mfa"},
    {"left":"context.auth_age_seconds","op":"lte","right":300},
    {"left":"resource.status","op":"eq","right":"pending"}
  ]
}
```

MFA recency thực tế nên dùng thời điểm MFA đã kiểm chứng, không luôn đồng nhất auth_time password với mfa_at. Khi nâng cấp policy này, Identity trả mfa_time từ session, PDP tính mfa_age_seconds và đổi AST paths tương ứng. Trong baseline, chỉ sessions được tạo/step-up với cả auth_time và MFA hiện hành mới đủ; không dùng một mfa flag cũ vô hạn.

## 13.4. Gắn deny và constraints vào snapshot

Giữ BEGIN REPEATABLE READ của chương 11. Sau tenant boundary và trước RBAC SELECT, đọc tất cả enabled rules cho org/action/type. Filter subjects bằng sub/groups sống; resource_id null nghĩa toàn type trong org. Không dùng wildcard action trong v1.

```ts
// Trong evaluate.ts, c là connection transaction và subject/input từ chương 11.
const rules = await c.query<{
  effect:"allow"|"deny";condition:unknown
}>(
  "SELECT effect,condition FROM policy_rules WHERE org_id=$1 AND enabled" +
  " AND action=$2 AND resource_type=$3 AND (resource_id IS NULL OR resource_id=$4)" +
  " AND (subject_type='any' OR (subject_type='user' AND subject_id=$5)" +
  " OR (subject_type='group' AND subject_id=ANY($6::text[]))" +
  " OR (subject_type='client' AND subject_id=$7))",
  [subject.org_id,input.action,input.resource.type,input.resource.id,subject.sub,
   subject.groups,subject.sub.startsWith("client:") ? subject.sub.slice(7) : ""]
);
const context = {
  "principal.sub":subject.sub,
  "principal.org_id":subject.org_id,
  "principal.amr":subject.amr ?? [],
  "resource.owner_id":input.resource.attributes.owner_id,
  "resource.amount_cents":input.resource.attributes.amount_cents,
  "resource.status":input.resource.attributes.status,
  "context.auth_age_seconds":subject.auth_time === undefined
    ? Number.MAX_SAFE_INTEGER : Math.max(0,Math.floor(Date.now()/1000)-subject.auth_time)
};
// Parse TẤT CẢ trước khi đánh giá; malformed deny không được bỏ qua vì allow khác match.
const parsed = rules.rows.map(r => ({...r,condition:parseCondition(r.condition)}));
if (parsed.some(r => r.effect==="deny" && matches(r.condition,context))) {
  // Trả EXPLICIT_DENY sau COMMIT read-only transaction.
}
const constraints = await c.query<{condition:unknown}>(
  "SELECT condition FROM policy_constraints WHERE org_id=$1 AND action=$2" +
  " AND resource_type=$3 AND enabled",
  [subject.org_id,input.action,input.resource.type]
);
const required = constraints.rows.map(r => parseCondition(r.condition));
if (!subject.scope.split(" ").includes(input.action) ||
    !required.every(rule => matches(rule,context))) {
  // Trả CONSTRAINT_FAILED; không tiếp tục sang role/relation allow.
}
const conditionalAllow = parsed.some(r => r.effect==="allow" && matches(r.condition,context));
```

Thay các nhánh comment bằng return theo cùng mẫu COMMIT/response chương 11; dùng helper finish(reason,allow) đóng transaction đúng một lần để tránh bỏ sót. Sau constraints: conditionalAllow trả ABAC_ALLOW; RBAC query cũ trả RBAC_ALLOW; relation allow trả RELATION_ALLOW; không có gì match trả DEFAULT_DENY. Có thể đổi thứ tự giữa các nguồn allow nếu reason precedence được công bố, nhưng không đổi thứ tự deny/constraints.

Thêm test malformed policy cùng RBAC allow: phải fail closed. Test all=[] rõ nghĩa true; rule deny với all rỗng cấm mọi matching principal/resource. Admin UI cần hiển thị cảnh báo phạm vi khi tạo rule này, nhưng backend vẫn giữ semantics.

## 13.5. Mutation API phải version và audit cùng transaction

Một policy update khoá row policy_versions theo org, validate input, ghi rules/constraints, tăng version, INSERT outbox rồi COMMIT. Dùng expected_version để operator không overwrite thay đổi của người khác. Simulation đọc live policy nhưng không tạo quyền; response include policy_version để phân biệt kết quả preview với thời điểm apply.

```sql
BEGIN;
SELECT version FROM policy_versions WHERE org_id=$1 FOR UPDATE;
-- Service so sánh expected_version rồi validate condition AST trước INSERT/UPDATE.
UPDATE policy_versions SET version=version+1 WHERE org_id=$1 RETURNING version;
-- Ghi policy_rules/policy_constraints và outbox cùng connection.
COMMIT;
```

API quản trị không lấy principal từ policy JSON. Guard phải online introspect admin token, xác minh org, rồi live authorize management action hoặc dùng service control-plane scope đã giới hạn; kiểm tra người quản trị không cấp quyền vượt grant boundary. Không cho tenant admin thay resource_types.owner_client_id. Role assignment expiry được query bằng database transaction timestamp; scheduled job chỉ dọn dữ liệu, không phải cơ chế duy nhất hết hạn quyền.

Lưu history của change set hoặc immutable versions để rollback một cách chủ động. “Rollback” tạo một version mới có nội dung cũ, không giảm số version và không sửa audit lịch sử. Idempotency operation ID có payload hash để retry không tạo hai policy changes.

## 13.6. ReBAC nhỏ, có ownership và consistency rõ ràng

Ví dụ invoice thuộc folder, Alice là viewer folder. Tuple invoice#viewer → folder#viewer và folder#viewer → user Alice cho phép read invoice. Owner/editor cũng được read; approve vẫn cần role/ABAC, không suy ra từ quyền xem. Các tuples được quản lý bởi owning service, được online xác thực và chỉ ghi trong đúng org. Browser không gửi một tuple đã “xác thực”.

Đăng ký resource type folder owner invoice-api trong migration lab. Không thêm subject_kind=object tuỳ ý tới namespace tenant khác. ID không tự mang authority; tuple luôn có org_id và tất cả recursive joins phải giữ nó.

```sql
WITH RECURSIVE walk(namespace,object_id,relation,depth,path,cycle) AS (
  SELECT $2::text,$3::text,r,0,
         ARRAY[$2::text||':'||$3::text||'#'||r],false
  FROM unnest(ARRAY['viewer','editor','owner']) AS r
  UNION ALL
  SELECT t.subject_namespace,t.subject_id,t.subject_relation,w.depth+1,
         w.path||(t.subject_namespace||':'||t.subject_id||'#'||t.subject_relation),
         (t.subject_namespace||':'||t.subject_id||'#'||t.subject_relation)=ANY(w.path)
  FROM walk w JOIN relation_tuples t
    ON t.org_id=$1 AND t.resource_type=w.namespace
    AND t.resource_id=w.object_id AND t.relation=w.relation
  WHERE t.subject_kind='object' AND NOT w.cycle AND w.depth<8
)
SELECT
  bool_or(w.cycle OR (w.depth=8 AND EXISTS(
    SELECT 1 FROM relation_tuples t WHERE t.org_id=$1
    AND t.resource_type=w.namespace AND t.resource_id=w.object_id
    AND t.relation=w.relation AND t.subject_kind='object'
  ))) AS invalid_graph,
  bool_or(EXISTS(
    SELECT 1 FROM relation_tuples t WHERE t.org_id=$1
    AND t.resource_type=w.namespace AND t.resource_id=w.object_id
    AND t.relation=w.relation AND
      ((t.subject_kind='user' AND t.subject_id=$4) OR
       (t.subject_kind='group' AND t.subject_id=ANY($5::text[])))
  )) AS allowed
FROM walk w;
```

Parameters: org, invoice type, invoice ID, subject.sub, live groups. Execute trong cùng policy snapshot, sau deny/constraints và chỉ cho action invoice.read. Set local statement_timeout=300ms, giới hạn số edges mỗi object ở write API, depth tối đa 8. invalid_graph=true phải graph_invalid/fail closed, không lấy allowed=true từ một nhánh khác. Timeout cũng fail closed. Không giả rằng depth limit đã làm mọi graph query nhẹ; branching vẫn có thể bùng nổ.

Đọc tuples sống trên mọi request. Thay đổi quyền chia sẻ commit xong phải có hiệu lực ở request kế tiếp. Bài này không tái tạo external-consistency guarantees của Zanzibar. Invoice content write có thể diễn ra đồng thời ACL change; owning service cần xác định serialization/transaction của riêng nó và không hứa toàn hệ thống có một distributed transaction.

## 13.7. Thực hành request và negative tests

Trong local migration riêng, thêm deny invoice.read khi resource.status=paid; thêm constraint approve như ví dụ. Không INSERT production policy bằng psql session superuser. Gửi lại PDP request chương 11 bằng PowerShell, chỉ đổi attributes từ database fixture tương ứng, rồi gọi cả Invoice API để chứng minh browser không điều khiển chúng.

```powershell
$case = $request | ConvertFrom-Json
$case.action = "invoice.read"
$case.resource.attributes.status = "paid"
$denyBody = $case | ConvertTo-Json -Depth 7
Invoke-RestMethod http://127.0.0.1:3300/v1/decisions -Method Post -Headers @{Authorization="Bearer $($machine.access_token)"} -ContentType application/json -Body $denyBody
```

Expected EXPLICIT_DENY dù Alice có Reader. Request trực tiếp này là test harness của owner service, không endpoint UI public. Trên Invoice API, gửi body status=pending khi database đang paid vẫn phải deny. Với approve, thiếu mfa hoặc auth_time quá cũ trả CONSTRAINT_FAILED; có MFA nhưng không role/conditional allow vẫn DEFAULT_DENY.

Tạo bảng test cases gồm tenant match/mismatch, allow+deny, allow+constraint false, unknown path, number/string mismatch, missing owner, expired assignment, group removal, graph cycle, graph depth 9, duplicate tuple và cross-org edge. Mỗi test kiểm tra cả allow, reason_code và version. Property test một invariant quan trọng: thêm matching deny không được làm một decision từ deny thành allow.

## 13.8. Failure lab và Definition of Done

Chạy hai admin updates cùng expected_version: chỉ một commit; request còn lại 409 và phải reload. Trong lúc audit/broker dừng, revoke tuple/role rồi check phải deny. Dừng Policy DB: Invoice API trả 503 thay vì dùng relation cache. Tạo graph phân nhánh lớn trong database lab, đo timeout và xác minh pool phục hồi sau rollback; không chạy payload phá tải vào hệ thống thật.

Nếu deny bị bỏ qua, kiểm tra evaluator không return RBAC_ALLOW trước rules. Nếu MFA luôn pass, kiểm tra caller không tự cung cấp amr và age không dùng timestamp token issuance. Nếu permission thay đổi nhưng version không tăng, sửa mutation transaction trước khi thêm cache invalidation. Nếu recursive query rò org, thêm org predicate ở mọi bước và viết regression test dùng cùng object_id ở Acme/Beta.

### Troubleshooting

| Triệu chứng | Nguyên nhân thường gặp | Kiểm chứng sửa |
|---|---|---|
| RBAC vượt explicit deny | Early return ở role evaluator | Test allow+deny cùng action trả EXPLICIT_DENY |
| Policy sai kiểu vẫn allow | Unknown/missing attrs bị coi false hoặc ignore | Invalid AST/type trả503 và alarm |
| Group removal chậm | Dùng event projection hoặc token snapshot groups | Thu hồi group, request kế tiếp deny khi broker dừng |
| Graph timeout kéo pool chết | Không rollback/release hoặc graph không giới hạn | Timeout có503, query sau vẫn thành công |

**DoD:** AST có parser và negative tests; attributes có nguồn owner; thứ tự quyết định đúng; policy/role/tuple update có version+outbox+idempotency; expiry thực thi lúc read; graph có cycle/depth/time budget; mọi protected check online, không projection authority; scenario deny precedence/revoke/concurrency được lưu evidence. Bạn phải giải thích được khác biệt giữa simulation, authorization và commit nghiệp vụ.

Nguồn: [NIST ABAC guide SP 800-162](https://csrc.nist.gov/pubs/sp/800/162/upd2/final), [Google IAM policy types](https://docs.cloud.google.com/iam/docs/policy-types), [AWS evaluation](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html), [Google Zanzibar paper](https://research.google/pubs/zanzibar-googles-consistent-global-authorization-system/), [PostgreSQL recursive queries](https://www.postgresql.org/docs/current/queries-with.html).
