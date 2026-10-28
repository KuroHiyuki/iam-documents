# Cổng kiểm tra OAuth/OIDC độc lập

[Protocol support](protocol-support.md) xác định server hứa cung cấp gì; tài liệu này xác định bằng chứng cần thu được trước khi đưa cho ứng dụng khác tích hợp. Các lệnh dưới đây là hướng dẫn để người học chạy. Chúng **chưa được chạy trên một IAM implementation trong repository tài liệu này**.

## Ba lớp bằng chứng

1. Test nội bộ chứng minh invariants của domain và database, đặc biệt code/refresh single-use, tenant binding, revocation commit và consistency qua replica.
2. Integration test dùng `openid-client` làm client độc lập. Không dùng helper phía server để tự decode/chấp nhận token rồi gọi đó là interoperability.
3. OpenID Foundation conformance suite kiểm tra wire behavior theo profile. Qua suite không thay thế pentest, operational readiness, kiểm tra authorization hay quy trình chứng nhận.

Theo [hướng dẫn chính thức](https://openid.net/certification/connect_op_testing/), bắt đầu từ Basic OP cho code flow và Config OP cho discovery. Chọn đúng supported response types; không bật implicit để làm đẹp danh sách test. Logout có bộ test riêng. Nếu mục tiêu profile đòi hỏi feature bổ sung chưa làm, ghi rõ gap và làm milestone bổ sung; đừng đổi expected result của suite để che thiếu feature.

## Chuẩn bị môi trường

Chạy suite self-hosted theo [README chính thức của conformance suite](https://gitlab.com/openid/conformance-suite). Pin commit/tag của suite trong báo cáo. Vì `iam.local.test` là hostname local, hosted suite công cộng không truy cập được địa chỉ này; dùng self-hosted suite có trust local CA và DNS/container routing đúng, hoặc một staging issuer HTTPS công khai dành riêng test. Không mở data thật hoặc admin thật lên mạng chỉ để vượt test.

Từ root repo, người học tạo thư mục kết quả không commit credential:

```powershell
New-Item -ItemType Directory -Force lab/artifacts/conformance | Out-Null
git -C lab rev-parse HEAD
node --version
pnpm --version
curl.exe --fail --silent --show-error https://iam.local.test:8443/.well-known/openid-configuration
curl.exe --fail --silent --show-error https://iam.local.test:8443/oauth2/jwks
```

Nếu `lab/` chưa phải Git repository riêng, lấy commit của repository chứa nó và ghi thêm hash lockfile. Chứng chỉ cần được Windows, browser, Node và JVM/container của suite tin cậy độc lập. Trust trong browser không tự cấu hình trust trong Java. Không dùng `-k`, `NODE_TLS_REJECT_UNAUTHORIZED=0` hoặc callback bỏ signature check làm test pass.

Đăng ký dedicated clients theo metadata suite yêu cầu; lưu redirect URI chính xác do suite sinh, tài khoản Alice/Bob và organization test. Không dùng secret của `web-a` làm credential suite. Nếu test registration cần Dynamic Registration mà baseline chưa hỗ trợ, không giả endpoint; chọn profile/config tương ứng hoặc ghi gap cần bổ sung.

## Ma trận kiểm tra bắt buộc

| Nhóm | Case tối thiểu | Kết quả phải quan sát |
|---|---|---|
| Discovery | Issuer chính xác, HTTPS endpoints, JSON types | Client discovery thành công; issuer mismatch bị từ chối |
| Redirect | URI khác case/path/query, wildcard, URI chưa đăng ký | Lỗi local; không redirect vào URI của attacker |
| Parsing | Duplicate `client_id`, `redirect_uri`, `code`, `grant_type` | `invalid_request`, không chọn tùy tiện first/last |
| PKCE | Thiếu, `plain`, verifier sai, dài/ngắn bất hợp lệ | Không phát token; code không bị đổi sang client khác |
| Authorization code | Reuse, expiry, client/redirect mismatch | `invalid_grant`; đồng thời tối đa một exchange thành công |
| OIDC | Nonce đúng/sai, aud/iss/exp/alg sai | Client độc lập từ chối token sai |
| UserInfo | Không token, ID token thay access, `sub` sai | `401` hoặc client từ chối sub mismatch |
| Refresh | Sequential reuse, 20 requests qua hai replica | Một winner; grant bị revoke khi reuse; kết quả đã commit |
| Introspection | Token không tồn tại, session/member/user/client disabled | `active:false`; dependency lỗi trả `503` |
| Resource server | Access token của audience khác | `401`; không gọi business handler |
| Tenant | Alice chuyển Acme/Beta, Bob chỉ thuộc Beta | Grant không đổi tenant; resource Beta không lộ cho Acme |
| Revocation | Unknown token, owned token, token client khác | Unknown `200`; token khác không được client thu hồi |
| Logout | Missing hint, wrong audience, unregistered URI, old ID token | Confirmation khi cần; không open redirect; recent expired hint xét theo logout policy |
| JWKS | Rotation, old `kid`, private params | New key dùng được, old verify còn hạn, không lộ private key |

Đặc biệt test refresh không chỉ đếm số `200`. Sau khi mọi request kết thúc, introspect **mọi access token vừa nhận** và thử dùng refresh token winner. Với strict reuse policy, việc một duplicate bị phát hiện có thể khiến cả grant winner không còn dùng được; đó là kết quả bảo vệ đã định nghĩa. BFF serialize refresh theo session để giảm logout do request hợp lệ đua nhau.

## Thu thập bằng chứng mà không lộ secret

Mỗi run ghi commit implementation, commit suite, Node/PostgreSQL versions, UTC timestamp, issuer, client metadata đã redact, test-plan ID, outcome, lỗi chưa xử lý và link artifact nội bộ. HTTP capture chỉ giữ header allowlist và field không nhạy cảm. Với request chứa code/token, thay giá trị bằng marker; không hash token để làm identifier log vì người vận hành không cần correlation trực tiếp của credential. Dùng request ID/grant ID đã kiểm soát truy cập.

Mẫu report để người học điền:

```text
Run: <UTC timestamp / ID>
Implementation commit: <sha>
Conformance suite: <tag / commit>
Issuer: <staging issuer>
Profiles: Basic OP, Config OP, <logout profile nếu đã làm>
Passed / failed / not executed: <counts from actual export>
Known gaps: <explicit list>
Security reviewer: <name / date, hoặc chưa review>
Status: NOT READY / READY FOR NEXT GATE
```

Đây là **mẫu**, không phải kết quả đã xác minh. Một màn hình “login works” chỉ xác nhận happy path. Chứng nhận chính thức còn yêu cầu nộp kết quả và làm đúng quy trình OpenID Foundation; không đặt badge hoặc quảng bá “OpenID Certified” trước khi hoàn tất. [Quy trình nộp chứng nhận](https://openid.net/certification/how-to-submit-your-certification-request/).

## Fault injection và điều kiện dừng

Chạy một pass với IAM hai replica rồi restart một replica giữa authorize và callback; flow vẫn đọc state từ persistent storage. Dừng PostgreSQL primary: protected request trả `503`, không đổi thành anonymous hay “allow vì cache còn hạn”. Làm chậm introspection vượt timeout: API hủy request và không thực hiện mutation. Khôi phục DB rồi xác nhận không có invoice được tạo từ request đã thất bại.

Sau đó inject lỗi ngay trước commit rotation, ngay sau commit nhưng trước HTTP response, và trước publish audit. Trước commit: không có token mới hợp lệ. Sau commit: client có thể mất response, cần reauthentication khi retry gây reuse; document hành vi thay vì tạo grace window không kiểm soát. Audit dùng outbox cùng transaction ở chương vận hành; mất broker không được làm mất lịch sử hoặc rollback một revocation đã trả thành công.

Đừng chạy tải chỉ trên fake database: đó không tìm thấy row-lock contention hay pool exhaustion. Dùng DB thật, cùng schema và isolation production. Load test tăng dần; ghi p50/p95/p99, active DB connections, lock wait, token throughput, introspection latency và tỷ lệ `503`. Không đưa mốc latency giả định vào report như kết quả thật.

## Definition of Done

- Metadata đúng profile và không quảng bá feature chưa triển khai.
- Client độc lập đăng nhập hai BFF; kiểm tra state, nonce, PKCE, UserInfo subject.
- Negative và concurrency matrix chạy tự động với DB thật và hai replica.
- Conformance artifact được export, review và redact; mọi failure có issue hoặc quyết định scope.
- Review giao thức độc lập và pentest hoàn thành trước external production; public certification chỉ tuyên bố khi được cấp thực tế.
- Các yêu cầu vận hành ở chương cuối vẫn phải đạt; qua conformance chỉ là một cổng của release.

