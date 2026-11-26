# 📐 ソフトウェア要件定義書 (SRS SSOT)

- **システム名**: 日本型シフト・勤怠・給与精算システム (KINTAI)
- **文書バージョン**: v1.0.2
- **ステータス**: APPROVED_FOR_AUDIT
- **ドメイン分類**: 店舗・会員認可マスタ、打刻勤怠管理、および日本国労働基準法第37条割増賃金算定エンジン
- **多言語ガバナンス**: GitHub公式正本は日本語（JA）標準、内部開発・確認用に対照版（KO）を配置

---

## 0. 言語および対外成果物基準 (日本IT市場標準)
1. **GitHub対外公式正本**: すべての公式SRS仕様書、README.md、アーキテクチャ図、およびコミットメッセージは、日本のエンタープライズ技術評価基準（ビジネス日本語）に準拠して策定される。
2. **監査確認用対照版**: 開発者の直観的な検証および多角確認のため、主要ドキュメントごとに対照版（`_KO.md`）をローカルに常時ペアリング配置する。
3. **技術スタックおよび検証エンジンの責務分離**:
   - **システム実装基盤 (Target Architecture)**: Java 21 / Spring Boot 3.x / MyBatis 3.5 / MySQL 8.4 (InnoDB, REPEATABLE READ, 悲観的ロック `FOR UPDATE NOWAIT`, BigDecimal高精度有理数演算; 代替参照: PostgreSQL 16 GiST排他制約)。
   - **品質検証エンジン (Verification Toolchain)**: C# Roslyn 決定論的リンター（`VerifySRS_Deterministic.exe`, `VerifySRS_Integrity.exe`）、ローカルGPU Qwen 27B、OpenAI Codex CLI、Anthropic Claude 5.5。

---

## 1. システム概要およびドメイン目的
本システムは、日本の飲食・小売店舗における多店舗アルバイト勤務契約、出退勤打刻データ、シフト調整、ならびに日本国労働基準法第37条に規定された割増賃金（残業・深夜・重畳割増）を1円の誤差もなく決定論的に算定・監査する高信頼性バックエンド基盤である。

---

## 2. 要件トレーサビリティ・マトリクス (Traceability Matrix)

### 2.1 [Slice 1] 店舗・会員管理および権限統制 (Store & Member Management)

#### [REQ-STORE-001] 店舗マスター登録および招待コード・QRトークン管理
- **区分**: 機能要件およびセキュリティ (Function & Security)
- **概要**: 認証済み店舗オーナー（`ROLE_OWNER`）が店舗を新規開設し、スタッフ合流用の一意な招待コードおよび店舗固有QR打刻トークンを発行・管理する。
- **入力**:
  - `storeName` (店舗名, 100文字以内, 必須)
  - `prefectureCode` (都道府県コード, CHAR(2), 例: '13'=東京都)
  - `openTime` (開店時間, TIME, デフォルト '09:00:00')
  - `closeTime` (閉店時間, TIME, デフォルト '23:00:00')
  - `payCutoffDay` (給与締め日, 整数, `1 ~ 28` または `99`=末日締め)
  - *(注: `ownerId` はリクエストパラメータから一切受け取らず、`SecurityContext` の認証済みPrincipalよりサーバー側で自動解決する)*
- **処理**:
  1. 認証コンテキストのPrincipalが有効な `ROLE_OWNER` 権限を保持していることを検証する。
  2. 8桁のセキュアな英数字からなる一意な `invite_code`（DB制約 `CONSTRAINT uq_store_invite_code UNIQUE`）およびユニークな `qr_token`（UUID v4ベース、DB制約 `CONSTRAINT uq_store_qr_token UNIQUE`）を生成する。
  3. `pay_cutoff_day` が `1 ~ 28` または `99` の許容範囲内であることをチェック制約（`chk_store_cutoff`）に適合させる。
  4. オーナーIDをFKとしてバインドし、店舗レコードを `store` テーブルに永続化する。
  5. 打刻の現場性担保および不正防止策として、静的 `qr_token` 発行に加え、未退勤状態での二重出勤をDBレベルで物理的に遮断する部分一意インデックス（`CREATE UNIQUE INDEX uq_open_attendance ON attendance (store_staff_id) WHERE clock_out_at IS NULL;`）の参照店舗キーとして機能させる。
- **出力**:
  - `storeId` (生成された店舗PK, BIGINT)
  - `inviteCode` (発行された招待コード, VARCHAR(20))
  - `qrToken` (打刻用QRトークン, VARCHAR(100))
- **例外処理**:
  - 招待コードまたはQRトークンの一意性衝突（SQLSTATE `23505`）が発生した場合、同一トランザクションの汚染を防止するためセーブポイント（`SAVEPOINT sp_store_retry`）へロールバックした上で再生成リトライ（最大5回、指数バックオフ）を行い、一意性を担保する。
  - 締め日パラメータが不正な場合、`IllegalArgumentException`（HTTP 400）を送出する。
  - 未認証または `ROLE_OWNER` 以外の呼び出しは `AccessDeniedException`（HTTP 403）で遮断する。
- **完了基準 (DoD)**:
  - リクエストJSONに偽造された `ownerId` が含まれていても完全に無視され、認証ユーザーの店舗として作成されること。
  - `store` レコードが外部キー制約（`fk_store_owner`）を満たして正常作成され、`qr_token` の一意性がDBレベルで担保されること。
  - C#リンター規則に100%適合し、単体テストを全件パスすること。

---

#### [REQ-MEMBER-001] 会員登録・BCrypt認証およびRBAC認可制御
- **区分**: セキュリティおよび認可 (Security & RBAC)
- **概要**: 一般スタッフおよび店舗オーナーのアカウントを登録し、BCrypt暗号化認証および厳格なロールベースアクセス制御（RBAC）を適用する。ロールの自己昇格を物理的に遮断する。
- **入力**:
  - `email` (ログインメールアドレス, RFC 5322準拠, 100文字以内)
  - `rawPassword` (パスワード平文, 8文字以上、英数記号混在)
  - `name` (氏名, 50文字以内)
  - `phone` (連絡先電話番号, 20文字以内)
  - *(注: クライアント入力からの `role` パラメータ指定を完全禁止。一般登録時はサーバー側で `'ROLE_STAFF'` に固定設定される)*
- **処理**:
  1. `email` の一意性を小文字正規化の上、DB層の関数ベース一意インデックス（`CREATE UNIQUE INDEX uq_member_lower_email ON member (LOWER(email))`）により同時実行TOCTOU競合を確実に遮断して照合する。
  2. パスワード強度をバリデーションし、BCryptハッシュアルゴリズム（ストレングス10以上）で不可逆暗号化する。
  3. 会員登録処理において、クライアントからのロール指定は受け付けず、サーバー側で強制的に `role = 'ROLE_STAFF'`、`is_active = TRUE` で初期化する。
  4. オーナーアカウント発行は管理権限を持つ専用フローに限定し、任意のロール自己昇格（P0脆弱性）を原初から遮断する。
  5. 認可において、全リソースアクセスは `SecurityContextHolder.getContext().getAuthentication()` の認証Principal IDに限定照会し、他者ID偽造（IDOR脆弱性）を排除する。
- **出力**:
  - `memberId` (会員PK, BIGINT)
  - `email` (登録メールアドレス, VARCHAR(100))
  - `role` (付与ロール `'ROLE_STAFF'`, VARCHAR(20))
- **例外処理**:
  - 重複メールアドレスが存在する場合（`INSERT ... ON CONFLICT (lower(email)) DO NOTHING` で更新行数0）、一貫して `DuplicateResourceException`（HTTP 409 Conflict）を送出する。
  - 不正な入力パラメータ・パスワード書式は `MethodArgumentNotValidException`（HTTP 400）を返却する。
- **完了基準 (DoD)**:
  - 一般登録リクエストで `role: "ROLE_OWNER"` を送信しても無視され、`ROLE_STAFF` で登録されること。
  - データベース上にパスワード平文が一切保存されないこと。

---

#### [REQ-STAFF-001] 店舗スタッフ所属申請・オーナー承認および多店舗アクセス制御
- **区分**: 機能要件および多店舗認可 (Function & Multi-Store Authorization)
- **概要**: アルバイトスタッフが店舗招待コードを入力して所属を申請し、店舗オーナーが承認時に時給・交通費契約を決定・有効化する。スタッフによる賃金の自己決定を禁止し、多店舗間のデータ漏洩を遮断する。
- **入力 (スタッフ申請時)**:
  - `inviteCode` (店舗招待コード, VARCHAR(20), 必須)
  - *(注: スタッフによる時給・交通費の入力は完全禁止。申請時は招待コードのみを受け付ける)*
- **入力 (オーナー承認時)**:
  - `storeStaffId` (承認対象のスタッフ所属ID, BIGINT)
  - `effectiveFrom` (契約適用開始日, DATE, 必須, 原則として承認日当日または指定開始日)
  - `hourlyWage` (オーナー決定契約時給, 整数, 最低賃金以上)
  - `dailyTransportFee` (オーナー決定1日通勤手当, 整数, 0以上)
  - `monthlyTransportLimit` (月額交通費上限, 整数, デフォルト 15000)
- **処理**:
  1. **スタッフ申請時**: `inviteCode` より対象店舗を特定し、複合ユニーク制約（`CONSTRAINT uq_store_member UNIQUE (store_id, member_id)`）および店舗所属整合性制約（`CONSTRAINT uq_store_staff_store UNIQUE (store_staff_id, store_id)`）を検証の上、`employment_status = 'PENDING'`、`application_version = 1` で `store_staff` を初期生成する。
  2. **オーナー承認時**: ログインオーナーが当該店舗の正当な所有者（`store.owner_id == principal.id`）であることを検証する。
  3. **原子的状態昇格と契約発行 (CAS防護)**: 並行承認競合や古い申請の誤承認を防ぐため、`UPDATE store_staff SET employment_status = 'ACTIVE' WHERE store_staff_id = :storeStaffId AND employment_status = 'PENDING' AND application_version = :expectedVersion` を実行し、更新行数が正確に1行であることを検証する。検証成功時のみ、オーナー指定の時給・交通費を初期契約として `store_staff_contract_history`（`effective_from = :effectiveFrom, effective_to = NULL`）に新規永続化する。
  4. **多店舗アクセス制御**: 店舗スコープを持つすべての処理（打刻・シフト・給与）において、認証ユーザーの店舗所属権限（`store_staff` / `store.owner_id`）を厳格に照合し、他店舗スタッフおよび無関係な第三者オーナーのアクセスをHTTP 403で遮断する。
  5. **雇用状態遷移マシン**:
     - `PENDING → ACTIVE` (オーナー承認)
     - `ACTIVE → RESIGNED` (退職処理: 以後の打刻・シフト申請を即時遮断、確定済み給与の監査閲覧権限のみ維持。最終契約の `effective_to` を退職日当日で確定終了させる)
     - `RESIGNED → PENDING → ACTIVE` (再雇用フロー: 複合ユニーク制約 `uq_store_member` との衝突を回避するため、既存 `store_staff` レコードの `application_version` をインクリメントし、`employment_status = 'PENDING'` として状態更新した上で、新規契約履歴とともにオーナーが再承認する。直接の `RESIGNED → ACTIVE` 不正再昇格は禁止)
- **出力**:
  - `storeStaffId` (店舗スタッフ所属PK, BIGINT)
  - `employmentStatus` (雇用確定ステータス, `'ACTIVE'` / `'RESIGNED'`)
- **例外処理**:
  - 無効な招待コードは `IllegalArgumentException`（HTTP 400）を送出する。
  - オーナー以外のユーザーが承認APIを呼び出した場合、`AccessDeniedException`（HTTP 403）を送出する。
- **完了基準 (DoD)**:
  - スタッフが自身の時給・交通費を改ざん申請できないこと。
  - 所属外店舗のデータアクセス試行が100%確実にHTTP 403でブロックされること。
  - 退職後の再雇用時に複合一意制約エラーを発生させず、新規契約履歴とともに安全に再承認されること。

---

#### [REQ-STAFF-002] 給与算定用契約条件（時給・交通費）履歴管理および期間排他制御
- **区分**: データ整合性および並行性制御 (Data Integrity & Concurrency)
- **概要**: スタッフの時給改定や通勤手当の変更が行われた際、過去の確定給与計算の不変性を担保するため、適用開始日・終了日（無期限契約は `effective_to IS NULL`）を持つ契約履歴テーブル（`store_staff_contract_history`）へ履歴保存し、MySQL 8.4のトランザクション悲観的ロックおよびアプリケーション排他検証（代替参照環境: PostgreSQL GiST排他制約）で期間重複を完全排除する。
- **入力**:
  - `storeStaffId` (店舗スタッフFK, BIGINT)
  - `effectiveFrom` (適用開始日, DATE, 必須)
  - `hourlyWage` (適用基本時給, 整数, 正の値)
  - `dailyTransportFee` (適用日別交通費, 整数, 0以上)
  - `monthlyTransportLimit` (適用月別交通費上限, 整数, デフォルト 15000)
- **処理**:
  1. トランザクション内で対象 `store_staff` 行を悲観的ロック（`SELECT ... FOR UPDATE`）でロック獲得し、競合する同時契約更新を直列化する。
  2. 当該スタッフの既存有効契約（`effective_to IS NULL`）を特定する。
  3. 新規 `effectiveFrom` が既存契約の `effective_from` より未来日であることを検証する（過去遡及による期間逆転の防止）。
  4. 既存契約の `effective_to` を新規 `effectiveFrom` の前日日付で確定更新する。
  5. 新規契約レコードを `effective_to = NULL` で新規作成し、コミットする。
  6. DB層・トランザクション防御線として、MySQL 8.4では `SELECT ... FOR UPDATE` による行ロックと期間重複チェッククエリ（NOT EXISTSガード）を必須化する（PostgreSQL 16移行時は `btree_gist` 拡張による `CONSTRAINT ex_contract_period EXCLUDE USING gist (store_staff_id WITH =, daterange(effective_from, effective_to, '[]') WITH &&)` を適用可能）。
- **出力**:
  - `contractHistoryId` (契約履歴PK, BIGINT)
  - `effectiveFrom` (適用開始確定日, DATE)
- **例外処理**:
  - 期間重複や日付逆転（`effectiveFrom <= 既存effective_from`）の場合、`InvalidPeriodException`（HTTP 400）を送出する。
  - 時給が0以下または地域別最低賃金未満の場合、`IllegalArgumentException`（HTTP 400）を送出する。
- **完了基準 (DoD)**:
  - 過去日付の給与再計算時、該当勤務日時点の有効時給が正確にスナップショット参照されること。
  - 同時に複数件の契約更新が発生しても、`SELECT ... FOR UPDATE` により期間重複レコードが一切生成されないこと。
  - C#リンター規則に100%適合すること。

---

### 2.2 [Slice 2] シフト管理および確定調停・労働基準法第34条休憩統制 (Shift Management & Concurrency Control)

#### [REQ-SHIFT-001] スタッフ希望シフト申請および排他制御（悲観的ロック）
- **区分**: 機能要件および並行性制御 (Function & Concurrency)
- **概要**: アルバイトスタッフが自身の勤務希望日時を申請し（新規申請 → SUBMITTED）、同一スタッフの多重申請レースコンディションを悲観的ロック（`SELECT ... FOR UPDATE`）により直列化して重複申請を遮断する。
- **入力**:
  - `storeId` (店舗ID, BIGINT, 必須)
  - `workDate` (勤務基準日, DATE, 必須, 当日以降の日付)
  - `requestedStartTime` (希望開始時刻, TIME, 必須, 'HH:mm' 形式)
  - `requestedEndTime` (希望終了時刻, TIME, 必須, 'HH:mm' 形式)
  - `staffMemo` (スタッフ側メモ, VARCHAR(255), 任意)
  - *(注: `storeStaffId` はリクエストボディの偽造値を信用せず、セッション認証済みPrincipalにバインドされたIDを使用する)*
- **処理**:
  1. 勤務基準日 `workDate` が店舗ローカル日付の当日より過去である場合、即時拒否する。
  2. 開始・終了時刻を解析し、終了時刻が開始時刻より前の場合は翌日跨ぎ勤務（翌日日付）として終了日時を解決する。開始時刻と終了時刻が同一の場合は拒否する。
  3. `Duration.between(startAt, endAt).compareTo(Duration.ofHours(16)) > 0` により、1回のシフト拘束時間が最大16時間以内であることをミリ秒/分単位で厳密に検証する。
  4. 対象 `store_staff_id` に対し悲観的排他ロック（`SELECT store_staff_id FROM store_staff WHERE store_staff_id = ? FOR UPDATE`）を獲得し、並行申請トランザクションを直列化する。
  5. 同一スタッフについて `status IN ('SUBMITTED', 'CONFIRMED')` の既存シフトとの時間帯重複（Overlap）を検証し、重複がある場合は登録を拒否する。
  6. 検証成功時、状態遷移（新規申請 → SUBMITTED）を行い、`status = 'SUBMITTED'`、`planned_break_minutes = 0` として `shift_schedule` テーブルに新規永続化する。
- **出力**:
  - `shiftId` (生成されたシフトPK, BIGINT)
  - `status` (初期状態 'SUBMITTED', VARCHAR(20))
- **例外処理**:
  - 時刻文字列の解析失敗時は `DateTimeParseException`（HTTP 400）を送出する。
  - 過去日付指定または16時間超過時は `IllegalArgumentException`（HTTP 400）を送出する。
  - 同一スタッフの既存シフトと時間帯重複が発生した場合は `IllegalStateException`（HTTP 409 Conflict）を送出する。
  - 他者の `store_staff_id` への偽造申請は `AccessDeniedException`（HTTP 403 Forbidden）で遮断する。
- **完了基準 (DoD)**:
  - 並行する2件の希望申請が同一スタッフ・同一時間帯に発生した場合、悲観的ロックにより一方が確実に HTTP 409 で拒否され、重複レコードが生成されないこと。
  - 翌日跨ぎのシフト（例: 22:00 `~` 翌06:00）が正常に日付跨ぎ計算され、16時間境界検証を通過すること。

#### [REQ-SHIFT-002] 店長によるシフト確定調停および労働基準法第34条法定休憩時間の算定
- **区分**: 機能要件および労働法遵守 (Function & Legal Compliance)
- **概要**: 店舗管理者が申請された希望シフトを確認・調停し、日本労働基準法第34条に基づく法定休憩時間を自動算定・検証した上で確定調停（SUBMITTED → CONFIRMED または SUBMITTED → REJECTED）へ状態遷移させる。
- **入力**:
  - `shiftId` (調停対象シフトPK, BIGINT, パス変数, 必須)
  - `confirmedStartTime` (確定開始時刻, TIME, 必須, 'HH:mm' 形式)
  - `confirmedEndTime` (確定終了時刻, TIME, 必須, 'HH:mm' 形式)
  - `plannedBreakMinutes` (計画休憩時間（分）, INT, 任意・未指定時は法定推奨値を自動設定)
  - `status` (確定状態 'CONFIRMED' または却下 'REJECTED', 必須)
  - `ownerMemo` (店長側メモ, VARCHAR(255), 任意)
  - *(注: 操作者の `storeId` はセッション認証コンテキストより取得する)*
- **処理**:
  1. 操作対象シフトの `store_id` と店長セッションの `store_id` が一致することを検証し、他店舗シフトの不正操作（クロス店舗IDOR）を即時遮断する。また、シフトテーブルに `FOREIGN KEY (store_staff_id, store_id) REFERENCES store_staff(store_staff_id, store_id)` 複合外部キー制約を強制し、他店舗所属スタッフの混入をDB層で物理排除する。
  2. 対象スタッフの先行排他ロック（`SELECT member_id FROM store_staff WHERE store_staff_id = ? FOR UPDATE`）を獲得し、多店舗並行確定や同一スタッフへの同時調停トランザクションを直列化する。
  3. 対象 `shift_schedule` レコードを行排他ロック（`SELECT ... FOR UPDATE`）で取得する。
  4. 拘束時間（`grossMinutes = Duration.between(startAt, endAt).toMinutes()`）を算出し、最大16時間以内であることを検証する。
  5. アプリケーション層の交差時間重複検証およびDB悲観的ロック（MySQL 8.4: `member_id` 対象の行ロック待機＋`REPEATABLE READ` 整合性検証；PostgreSQL 16環境では `EXCLUDE USING gist` 制約）により、同一人物（`member_id`）が複数店舗で同時刻に重複確定される競合を二重防御線で遮断する（他店舗競合時は店舗詳細を伏せてHTTP 409を返却）。
  6. 労働基準法第34条に基づく法定休憩時間の完全Fail-Closed評価：
     - 未指定時の自動算定推奨値：拘束時間 `<= 360分`（6時間以下）は `0分`、`360分 < 拘束時間 <= 525分`（6時間超8時間以下）は `45分`、`拘束時間 > 525分`（8時間超）は `60分`。
     - 手動指定時：実労働時間（`grossMinutes - plannedBreakMinutes`）に対し、`実労働 > 8時間` で休憩60分未満、または `実労働 > 6時間` で休憩45分未満の場合、警告にとどめず `BREAK_TIME_DEFICIT`（HTTP 422 Unprocessable Entity）を送出し、確定（CONFIRMED）への状態遷移を即時拒否・遮断する。
  7. CAS条件付き更新（`WHERE shift_id = ? AND store_id = ? AND status = 'SUBMITTED'`）を実行し、状態遷移（SUBMITTED → CONFIRMED または SUBMITTED → REJECTED）を行い、`affected rows == 1` を検証して確定状態へ更新する。
- **出力**:
  - `shiftId` (確定シフトPK, BIGINT)
  - `status` (確定ステータス 'CONFIRMED', VARCHAR(20))
  - `plannedBreakMinutes` (適用計画休憩時間（分）, INT)
- **例外処理**:
  - 対象シフトが存在しない場合は `SHIFT_NOT_FOUND`（HTTP 404）を返却する。
  - 店舗不一致の場合は `CROSS_STORE_ACCESS_DENIED`（HTTP 403）を送出し、監査ログへ記録する。
  - 休憩時間が拘束時間を超過する場合、または法定休憩基準に未達の場合は `BREAK_TIME_DEFICIT`（HTTP 422）を返却する。
  - 他の管理者との同時更新競合（CAS失敗）または他店舗重複確定時は `SHIFT_CONCURRENT_MODIFICATION`（HTTP 409）を返却する。
- **完了基準 (DoD)**:
  - 拘束時間8時間30分（510分）のシフトに対して休憩45分を適用した場合、実労働時間が7時間45分となり法定45分基準を満たして確定されること。
  - 実労働8時間超に対し休憩が60分未満の場合は確定が HTTP 422 で確実にブロックされること。
  - 他店舗の店長アカウントからの更新リクエストが HTTP 403 で遮断されること。

#### [REQ-SHIFT-003] 希望シフト申請の本人取消および状態遷移制御
- **区分**: 機能要件および認可制御 (Function & Authorization)
- **概要**: スタッフ本人が提出済みの希望申請中シフトを取り下げる（SUBMITTED → CANCELLED_DELETED）。確定済（CONFIRMED）シフトの無断取消は防止し、店長直接連絡を強制する。
- **入力**:
  - `shiftId` (取消対象シフトPK, BIGINT, パス変数, 必須)
  - *(注: 操作者の `storeStaffId` および `storeId` はセッション認証コンテキストより取得する)*
- **処理**:
  1. セッションの `storeStaffId` に基づき、対象シフトを行ロック（`SELECT ... FOR UPDATE`）で取得する。
  2. 対象レコードの `store_staff_id` がセッション値と一致しない場合、他者シフトの不正削除（IDOR）として即時遮断する。
  3. シフトの現在の `status` を検証する：
     - `status == 'SUBMITTED'` の場合のみ、状態遷移（SUBMITTED → CANCELLED_DELETED）による物理削除を許可する。
     - `status == 'CONFIRMED'` または `'REJECTED'` の場合は取消を拒否し、確定後の無断欠勤・自己取消を防止する。
  4. 削除クエリ実行時、`affected rows == 1` を検証して直列化を完了する。
- **出力**:
  - `success` (取消完了フラグ, BOOLEAN, `true`)
- **例外処理**:
  - 他スタッフのシフト取消試行時は `SecurityException`（HTTP 403 Forbidden）を送出し、監査ログへ記録する。
  - 確定済みシフトの取消試行時は `IllegalStateException`（HTTP 409 Conflict: "確定済のシフトは申請取消できません"）を送出する。
  - 対象シフトが存在しない場合は `IllegalArgumentException`（HTTP 404 Not Found）を送出する。
- **完了基準 (DoD)**:
  - `SUBMITTED` 状態の希望シフトのみが正常に取り消され、`CONFIRMED` 状態のシフトに対する取消リクエストが HTTP 409 で確実にブロックされること。

#### [REQ-SHIFT-004] カレンダー表示連携（FullCalendar 6.x）およびプライバシー保護
- **区分**: 機能要件およびプライバシー統制 (Function & Privacy Protection)
- **概要**: 月間カレンダー画面（FullCalendar 6.x）向けにシフトイベント一覧を配信し、時間交差判定（`event_start_at < rangeEnd AND event_end_at > rangeStart`）により前日夜勤の翌朝跨ぎ表示を担保するとともに、他スタッフへの個人情報（メモ・給与単価等）漏洩を行単位認可でマスキング遮断する。
- **入力**:
  - `storeId` (店舗ID, BIGINT, クエリパラメータ, 必須)
  - `startDate` (検索開始日, DATE, ISO-8601, 必須)
  - `endDate` (検索終了日, DATE, ISO-8601, 必須, ※FullCalendar仕様上この日付自体は含まない)
  - *(注: 操作者のスタッフIDおよび管理者権限フラグ `isManager` はセッションより解決する)*
- **処理**:
  1. 日付交差条件（`event_start_at < :rangeEnd AND event_end_at > :rangeStart`、境界は `Asia/Tokyo` タイムゾーン準拠のTIMESTAMPTZ）を適用し、前日からの夜勤跨ぎシフトを含めて正確に `shift_schedule` レコードを抽出する。
  2. 抽出された各シフトレコードに対し、操作者権限に応じたプライバシーマスキング（DTO変換）を実施する：
     - **本人または店舗管理者（店長）**: 確定/希望日時、状態、`staffMemo`、`ownerMemo`、計画休憩時間の全項目を開示する。
     - **同一店舗の他スタッフ**: 開始日時、終了日時、スタッフ表示名、状態（確定・希望）のみを開示し、`staffMemo`、`ownerMemo`、給与単価、時給等の機微情報は完全に `null` マスクする。
  3. FullCalendar用表示プロパティを構築する：
     - `CONFIRMED`: 青色表示（`#0d6efd`）、確定時間帯表示
     - `SUBMITTED`: 橙色表示（`#fd7e14`）、希望時間帯表示
     - `REJECTED`: 灰色表示（`#6c757d`）
- **出力**:
  - `events` (FullCalendar Event DTOリスト, JSON配列)
- **例外処理**:
  - 日付形式のパース失敗時は `DateTimeParseException`（HTTP 400）を送出する。
  - 無効な `storeId` または店舗未所属スタッフのアクセスは `AccessDeniedException`（HTTP 403）で遮断する。
- **完了基準 (DoD)**:
  - 他スタッフのシフト情報レスポンスに `staffMemo` や `ownerMemo` が一切漏洩せず、プライバシーが保護されること。
  - 前月末日22:00から当月初日06:00に及ぶ夜勤跨ぎシフトが当月カレンダー画面に漏れなく表示されること。

---

### 2.3 [Slice 3] 客観的打刻・勤怠管理およびドメイン整合性強化 (Attendance & Time Tracking)

#### [REQ-ATT-001] 30秒回転型TOTP QR打刻およびGPSジオフェンシング統制
- **入力**:
  - `storeId` (店舗識別子, BIGINT, パスパラメータ)
  - `deviceUuid` (登録済みスタッフ端末UUID, VARCHAR(36), 必須)
  - `eventType` (打刻種別, CLOCK_IN, BREAK_START, BREAK_END, CLOCK_OUT, 必須)
  - `qrToken` (店舗表示端末生成TOTPワンタイムトークン, 8桁数値文字列, 必須)
  - `latitude` (打刻時GPS緯度, WGS84十進度, double precision [-90.0, 90.0], 必須)
  - `longitude` (打刻時GPS経度, WGS84十進度, double precision [-180.0, 180.0], 必須)
  - `horizontalAccuracy` (GPS水平測位精度半径, double precision, メートル単位, 必須)
  - `fixTimestamp` (GPS測位確定日時, DATETIME(6), 必須)
  - `isMockProvider` (OS模擬位置情報フラグ, BOOLEAN, 必須)
  - `idempotencyKey` (クライアント生成冪等性キー, VARCHAR(36), 必須)
  - `fallbackReason` (地下店舗・GPS測位不能時申告理由, TEXT, 任意)
  - *(注: スタッフ本人およびテナントの識別は SecurityContext から抽出した認証済み Principal に限定し、クライアントからの生 staffId 指定による IDOR 脆弱性を遮断する)*
- **処理**:
  1. **本人端末バインド検証**: `attendance_device` テーブルを検索し、認証済みスタッフに紐づく `device_uuid` が有効かつ未失効（`revoked_at IS NULL`）であることを検証。不一致または失効済みの場合は即時拒否。
  2. **30秒回転型TOTP検証**: 店舗端末の固有秘密鍵（HMAC-SHA256）を用い、サーバー基準時刻におけるスロット $s = \lfloor\text{epoch\_seconds} / 30\rfloor$ を算出。申告された `qrToken` が許容時間ウィンドウ $\{s - 1, s, s + 1\}$ のいずれかと定時間比較（Constant-time comparison）で合致することを照合。
  3. **Haversine球面三角法によるGPSジオフェンシングおよび測位完全性検証**:
     - 店舗基準座標 $(store\_lat, store\_lon)$ と打刻座標 $(lat, lon)$ から直線距離 $d$ を算出：
       $$a = \sin^2\left(\frac{\Delta\phi}{2}\right) + \cos(\phi_1)\cos(\phi_2)\sin^2\left(\frac{\Delta\lambda}{2}\right)$$
       $$d = 2 \times 6371000 \times \arcsin\left(\sqrt{\min(1.0, a)}\right) \text{ (meters)}$$
     - **打刻種別ごとの動的ジオフェンシングおよび例外救済分岐**:
       - **出勤（CLOCK_IN）および退勤（CLOCK_OUT）**: 原則として許容半径 $d \le 100\text{ m}$ かつ $horizontalAccuracy \le 50.0\text{ m}$ を満たす場合のみ正常打刻（`OBJECTIVE`）を許可。
       - **地下店舗・GPS測位不能時の出勤救済（Ghost Work防止策）**: 地下店舗やGPSモジュール障害等により $horizontalAccuracy > 50.0\text{ m}$ またはGPS取得タイムアウト（null）となった場合、即時422遮断せず、本人が店舗QR読取と理由を提示して申告した場合は、`DRAFT` 状態の勤務セッションを即時生成し、`accuracy_anomaly_flag = TRUE` を記録する。これによりセッションが確立され、勤務終了時の正常な退勤（CLOCK_OUT）打刻受付および事後承認を保証する。
       - **店外休憩（BREAK_START / BREAK_END）の許容（状態遷移デッドロック防止策）**: 従業員が店舗外の飲食店・休憩施設（100m超）へ移動してから休憩開始を押下する場合、距離 $d > 100\text{ m}$ であっても状態遷移を拒否せず受理し、`off_premise_flag = TRUE` をイベントに記録して状態を `ON_BREAK` へ遷移させる。復帰時の `BREAK_END` も同様に受理し、休憩開始拒否による勤怠記録の不整合および退勤不能を防止する。
     - **スプーフィング遮断および測位信頼性ガード**:
       - `isMockProvider == true` の場合は開発者オプション等による模擬位置情報（Mock Location）と判定し、即時遮断（HTTP 422）。
       - 測位確定日時 `fixTimestamp` とサーバー受信時刻の乖離が60秒（キャッシュ・リプレイ攻撃防御）を超える場合は拒絶。
  4. **打刻イベントおよびセッション永続化**: 判定結果、観測座標、計算距離、スロット番号、各種フラグを `attendance_event` に追記専用（Append-Only）で記録。
  5. **代理打刻（Buddy Punching）脅威モデルおよび残余リスクの開示**:
     - 店舗表示QRコード（30秒回転型TOTP）を別端末のカメラで撮影し、SNS等で店舗外のスタッフへリアルタイム転送（Relay Attack）する不正シナリオに対し、本システムは「端末バインド検証（登録端末UUID一致）」、「GPSジオフェンシング（100m以内）」、「OSモック位置遮断」の3層防御によって店舗外からの代理打刻を防御する。
     - 店舗近傍（100m以内）における端末の物理的貸し借り等のソーシャルエンジニアリング型不正打刻は、AI異常検知（同一IP・Wi-Fi BSSID乖離ログ分析）および店長による目視監査を運用統制として義務付ける。
- **出力**:
  - `eventId` (打刻イベント識別子, VARCHAR(36))
  - `sessionId` (勤怠勤務セッション識別子, VARCHAR(36))
  - `effectiveAt` (サーバー確定打刻時刻, ISO 8601 UTC)
  - `businessDate` (所属勤務基準日, YYYY-MM-DD Asia/Tokyo)
  - `currentState` (更新後勤怠状態, VARCHAR(20))
- **例外処理**:
  - 端末未登録・失効・他者端末の場合: SecurityException (HTTP 403 DEVICE_BINDING_INVALID)
  - TOTP不一致・期限切れの場合: IllegalArgumentException (HTTP 422 QR_TOKEN_INVALID)
  - 出退勤時のGPS距離100m超過（救済事由なし）の場合: ValidationException (HTTP 422 LOCATION_OUT_OF_BOUNDS)
  - 模擬位置情報の検知: ValidationException (HTTP 422 LOCATION_MOCK_REJECTED)
  - 測位精度不良（>50m）かつ救済事由未指定: ValidationException (HTTP 422 LOCATION_ACCURACY_UNRELIABLE)
  - 冪等キー重複かつ要求内容不一致: DuplicateResourceException (HTTP 409 IDEMPOTENCY_CONFLICT)
- **完了基準 (DoD)**:
  - 通常出勤時の距離計算において 100.0m は許可、100.1m は拒否される単体テストが存在すること。
  - 地下店舗での測位精度不良時、申告理由付きで DRAFT セッションが生成され、退勤まで完了できること。
  - 店舗外（150m等）での休憩開始・終了が off_premise_flag 付きで受理され、状態遷移がデッドロックしないこと。
  - isMockProvider == true の打刻が確実に遮断されること。
---

#### [REQ-ATT-002] 打刻状態遷移機械および実労働・休憩区間代数検証
- **入力**:
  - `sessionId` (勤務セッション識別子, VARCHAR(36), 必須)
  - `eventType` (打刻イベント種別, CLOCK_IN, BREAK_START, BREAK_END, CLOCK_OUT, 必須)
  - `timestamp` (打刻要求日時, DATETIME(6), 必須)
- **処理**:
  1. **行レベル悲観的排他ロック（Pessimistic Write Lock）**: 対象セッション（`attendance_session`）を `FOR UPDATE` で取得し、並行打刻要求を直列化。
  2. **決定論的状態遷移機械（FSM）**:
     - `UNCLOCK` → `WORKING`（出勤 CLOCK_IN）または `DRAFT`（地下店舗等救済出勤）
     - `WORKING` / `DRAFT` → `ON_BREAK`（休憩開始 BREAK_START、店外打刻許容）
     - `ON_BREAK` → `WORKING` / `DRAFT`（休憩終了 BREAK_END）
     - `WORKING` → `CLOSED`（通常退勤 CLOCK_OUT）
     - `DRAFT` → `CLOSED_PENDING_APPROVAL`（救済セッション退勤 CLOCK_OUT、店長承認待ちへ遷移）
     - 不正な状態遷移（例: `UNCLOCK` からの `BREAK_START`、`ON_BREAK` からの `CLOCK_IN` 等）は IllegalStateException（HTTP 409 STATE_TRANSITION_INVALID）として即時遮断。
  3. **実労働時間・休憩区間の代数的一貫性検証**:
     - 実労働区間 $W = [t_{\text{in}}, t_{\text{out}}]$、休憩区間集合 $B = \{[b_{i,\text{start}}, b_{i,\text{end}}]\}$ に対し：
       $$\forall i, \quad t_{\text{in}} < b_{i,\text{start}} < b_{i,\text{end}} < t_{\text{out}}$$
       $$\forall i \ne j, \quad [b_{i,\text{start}}, b_{i,\text{end}}] \cap [b_{j,\text{start}}, b_{j,\text{end}}] = \emptyset$$
       $$T_{\text{net}} = (t_{\text{out}} - t_{\text{in}}) - \sum_i (b_{i,\text{end}} - b_{i,\text{start}}) \ge 0$$
- **出力**:
  - `sessionId` (セッションUUID)
  - `previousState` (遷移前状態)
  - `newState` (遷移後状態)
  - `netWorkMinutes` (正味労働時間・分, 退勤時確定)
- **例外処理**:
  - 状態遷移の順序矛盾: IllegalStateException (HTTP 409 STATE_TRANSITION_INVALID)
  - 休憩時間区間の包含・重複・負数矛盾: ValidationException (HTTP 422 INTERVAL_ALGEBRA_VIOLATION)
- **完了基準 (DoD)**:
  - 二重出勤・二重退勤が HTTP 409 で遮断される単体テストが存在すること。
  - DRAFT 出勤から退勤まで遷移し、CLOSED_PENDING_APPROVAL へ到達できること。
  - 休憩時間が総拘束時間を超過するデータが代数検証で確実に拒絶されること。
---

#### [REQ-STORE-002] 満18歳未満（年少者）深夜労働・時間外労働遮断ガード
- **入力**:
  - `staffId` (スタッフ識別子, BIGINT, パスパラメータ)
  - `birthDate` (生年月日, DATE, 必須)
  - `targetWorkStart` (就業開始予定日時, DATETIME(6), 必須)
  - `targetWorkEnd` (就業終了予定日時, DATETIME(6), 必須)
- **処理**:
  1. **生年月日必須マスタ管理**: `store_staff.birth_date`（DATE NOT NULL）を導入し、未来日および不正日付を拒否。うるう年（2月29日生まれ）の平年における加齢起算日は、民法第143条第2項および年齢計算に関する法律に基づき「3月1日 00:00:00（2月28日 24:00:00）」として決定論的に計算する。
  2. **年齢層別二層ガード（Per-segment区分判定）**:
     - 勤務区間をJST日付境界（00:00）および時間帯境界でセグメント分割し、各区間の就労時点における実年齢を判定（勤務開始日固定判定を排除）。
     - **児童区分（満15歳に達した日以後の最初の3月31日を迎えていない者, 労基法第56条）**: 原則雇用禁止（所轄労基署長の許可軽労働を除く）。深夜労働は 20:00〜05:00 を完全遮断（労基法第61条第5項）。
     - **年少者区分（満15歳超〜満18歳未満, 労基法第61条第1項）**: 深夜時間帯（22:00〜05:00）の就労を禁止。
  3. **事前遮断（Fail-Closed）と事後実績保護の二元統制**:
     - シフト登録・確定および出勤打刻（`CLOCK_IN`）は、深夜帯を含む場合 `YOUTH_NIGHT_WORK_PROHIBITED`（HTTP 422）で事前遮断する。
     - 実勤務において22:00（児童は20:00）を超過して稼働継続した場合、退勤打刻（`CLOCK_OUT`）をエラーで拒絶することは厳禁とする（労働時間の不法隠蔽および労基法第24条賃金全額払いの原則違反を防止）。退勤は真実の時刻で確定記録し、同時に `youth_night_violation_flag = TRUE` を記録して店長へ即時通知を発行し、実労働に対する割増賃金を全額支給する。
  4. **労働基準法第60条 法定労働時間上限ガードおよび法定休日就労遮断**:
     - **週起算日の厳格適用**: 週40時間の法定労働時間枠の集計にあたり、就業規則に定める店舗基準の週起算日（`store.week_start_day`、未設定時は1:月曜日起算）から7日間を同一週として累積実労働時間を決定論的に集計する。
     - **区分別法定労働時間上限（労基法第60条第1項・第2項）**:
       - **児童区分（満15歳到達後最初の3月31日未到来, 労基法第60条第2項）**: 学校教育との両立義務に基づき、修学時間を通算して1日7時間、週40時間を超えるシフト登録・実就労を厳格に禁止。
       - **年少者区分（満15歳超〜満18歳未満, 労基法第60条第1項）**: 1日8時間、週40時間を超えるシフト登録・実就労を禁止（変形労働時間制・三六協定による時間外労働を排他的に除外）。
     - **法定休日就労の絶対禁止**: 労働基準法第60条第1項の強行規定に基づき、満18歳未満の年少者および児童に対する法定休日（労基法第35条に基づく週1日または4週4日の法定休日）におけるシフト登録・確定および出勤打刻（CLOCK_IN）を事前遮断する。
- **出力**:
  - `isYouth` (年少者該当判定フラグ, BOOLEAN)
  - `youthClass` (年少者区分, CHILD_UNDER_15_PRE_MARCH, MINOR_15_TO_17, ADULT)
  - `exactAge` (勤務時点満年齢, 整数)
  - `allowedMaxDurationMinutes` (就労許容残分数, 整数)
- **例外処理**:
  - 18歳未満の深夜就労シフト登録・出勤打刻: YouthLaborViolationException (HTTP 422 YOUTH_NIGHT_WORK_PROHIBITED)
  - 18歳未満の法定休日就労シフト登録・出勤打刻: YouthLaborViolationException (HTTP 422 YOUTH_STATUTORY_HOLIDAY_WORK_PROHIBITED)
  - 1日8時間（児童7時間）または週40時間を超過するシフト登録: YouthLaborViolationException (HTTP 422 YOUTH_DAILY_LIMIT_EXCEEDED / YOUTH_WEEKLY_LIMIT_EXCEEDED)
  - 生年月日が未登録または未来日の場合: IllegalArgumentException (HTTP 422 STAFF_BIRTH_DATE_INVALID)
- **完了基準 (DoD)**:
  - 誕生日前日の23:00から誕生日当日の03:00に及ぶ跨ぎシフトにおいて、23:00〜24:00が違法遮断され、00:00〜03:00（18歳到達後）が適法承認される区間分割テストが存在すること。
  - 2月29日生まれの者が平年の2月28日23:00時点では17歳（遮断）、3月1日00:00以降は18歳（適法）として評価されること。
  - 満15歳到達後の最初の3月31日当日までが厳格に児童区分（1日7時間上限・20時以降禁止）として判定されること。
  - 満18歳未満の年少者による法定休日へのシフト登録および出勤打刻が機械的に遮断されること。
  - 実労働が22:00を超過した場合でも退勤打刻が正常受理され、違反フラグとともに賃金が全額算定されること。
---

#### [REQ-LABOR-005] 地域別最低賃金改定日履歴マスタおよび自動補正統制
- **入力**:
  - `storeId` (店舗識別子, BIGINT, 必須)
  - `businessDate` (勤務基準日, DATE, 必須)
  - `workStart` (勤務開始日時, DATETIME(6), 必須)
  - `workEnd` (勤務終了日時, DATETIME(6), 必須)
  - `contractHourlyWage` (契約基本時給, BIGINT, 必須)
- **処理**:
  1. **最低賃金改定日履歴マスタ検索**:
     - 店舗所在地の `prefecture_code`（01〜47）をキーとし、`minimum_wage_history` テーブルを検索。
  2. **フェイルセーフ自動補正ロジックおよび契約締結時ガードとの役割分担**:
     - **REQ-STAFF-002との境界整合**: 新規雇用契約の締結・登録時においては、締結日時点の地域別法定最低賃金を下回る契約時給の登録を REQ-STAFF-002 が即時拒絶（HTTP 422 STAFF_WAGE_BELOW_MINIMUM）する。
     - **事後改定に対するランタイム自動保障**: 本処理（REQ-LABOR-005）は、適法に締結された既存契約が毎年10月1日等の法定改定によって事後的に最低賃金を下回った場合に限定して発動し、計算停止による賃金未払い（労基法第24条違反）を回避するため、支給時給を自動引き上げる：
       $$\text{applied\_rate} = \max(\text{contract\_rate}, \text{minimum\_rate})$$
     - 給与明細行に `wage_adjusted = TRUE`、補正前契約時給、法定額、差額を明記し、店長・管理者宛てに警告通知（Outboxイベント）を発行。
  3. **改定日跨ぎ勤務のJST 00:00境界分割算定（Segmented Wage Basis）**:
     - 10月1日等の改定日を跨ぐ夜勤勤務（例: 9月30日 22:00 〜 10月1日 02:00）においては、所属基準日（`businessDate`）を始業日（9月30日）に維持しつつ、賃金算定対象区間を発効日当日 JST 00:00:00 の境界で2つのセグメントに厳格分割する：
       - **セグメント1 [22:00〜24:00]**: 9月30日時点の改定前最低時給（例: 950円）を基準に判定。
       - **セグメント2 [00:00〜02:00]**: 10月1日時点の改定後新最低時給（例: 1,000円）を基準に自動引き上げ適用。
     - 各セグメントごとに `attendance_wage_basis` レコードを独立生成し、給与算定エンジン（REQ-LABOR-001）へ各区間の適用単価を正確に引き継ぐことで、改定日以降の過少支払い（最低賃金法第4条違反）を完全に防止する。
  4. **給与算定エンジン（REQ-LABOR-001）への単一支給時給連携**:
     - REQ-LABOR-001 の割増賃金計算における基本支給時給 `payableRate` は、本処理が算出した `appliedHourlyWage` を唯一の真実原書として参照し、モジュール間での時給乖離を防止する。
- **出力**:
  - `appliedHourlyWage` (適用基本時給, BIGINT)
  - `isAdjusted` (最低賃金自動補正フラグ, BOOLEAN)
  - `adjustmentDifference` (時給差額補正分, BIGINT)
  - `segments` (分割算定区間配列, JSON)
- **例外処理**:
  - 店舗の都道府県に該当する履歴データが一切存在しない場合: IllegalStateException (HTTP 422 MINIMUM_WAGE_HISTORY_MISSING)
- **完了基準 (DoD)**:
  - 契約時給950円の店舗で最低賃金が1,000円に改定された場合、自動的に1,000円で計算され差額50円の補正証跡が残ること。
  - 改定日を跨ぐ夜勤勤務において、00:00以前は旧基準、00:00以降は新基準で正しく2分割算定される単体テストが存在すること。
  - REQ-STAFF-002による契約登録時拒絶と、REQ-LABOR-005による事後改定時自動補正が矛盾なく連携すること。
---

#### [REQ-ATT-003] 打刻事後修正の二者承認フローおよび不変監査ログ
- **入力**:
  - `sessionId` (修正対象勤務セッションUUID, VARCHAR(36), 必須)
  - `baseVersion` (修正要求の基準バージョン, BIGINT, 必須)
  - `correctionReason` (修正申請理由, 文字列, 必須)
  - `proposedEvents` (修正後打刻イベント列, JSON, 必須)
  - *(注: 申請者の識別は認証コンテキストの Principal から取得)*
- **処理**:
  1. **職務分掌（SoD）に基づく二者承認フロー統制および単独オーナー特例**:
     - PENDING_FIRST → PENDING_SECOND → APPLIED (通常二者承認フロー)
     - 修正申請は PENDING_FIRST（第1承認待ち）として登録。
     - **第1承認（一次事実確認）**: 店舗管理者権限を有するスタッフ（ROLE_STAFF かつ is_manager = TRUE）またはオーナー（ROLE_OWNER）がシフト計画および店舗事実関係を照合して承認。
     - **第2承認（最終統括承認）**: オーナー（ROLE_OWNER）が労働基準法準拠性および給与影響を照合して確定承認（APPLIED へ遷移）。
     - **自己承認および同一人承認の完全排除**: 申請者本人による承認、および同一人物による第1・第2二重承認をRBAC層およびサービス層で排他的に拒否（異なる2名の承認権限者を義務化）。
     - **単独オーナー店舗の特例分岐**: 管理代行スタッフが存在しない1人運営店舗においては、物理的な2名承認が不可能なため、ROLE_OWNER 単独の1段階承認で直接 APPLIED への遷移を認める。ただし、監査ログに `is_single_owner_bypass = TRUE` および単独承認理由（`single_owner_reason`）を記録することを必須とする。
  2. **年少者深夜実労働の事後訂正整合性（労基法第24条保護）**:
     - 修正申請において満18歳未満の年少者の実労働が22:00（児童は20:00）を超過している場合、事前シフト申請とは異なり **HTTP 422 での申請・承認遮断を厳禁**とする（事後修正の遮断による実労働時間の隠蔽および未払いを防止）。
     - 事後修正は真実の実績時刻で承認（APPLIED）を受理し、同時にセッションおよび監査ログに `youth_night_violation_flag = TRUE` を強制記録した上で、店長および労務統括宛に是正勧告通知（Outboxイベント）を発行し、実就労時間に応じた割増賃金を全額支給する。
  3. **楽観的並行性制御（OCC）**: 承認反映時、セッションの現行バージョンが `base_version` と一致することを検証。不一致の場合は StaleObjectStateException を送出し競合を遮断。
  4. **テナント直列化排他ロックおよびSHA-256ハッシュ連鎖による不変監査ログ**:
     - **テナント直列化排他ロック**: 並行承認・修正による監査ログのチェーン分岐（フォーク）を物理的に防ぐため、`attendance_audit_log` の採番・追記トランザクション内でテナント単位の悲観的排他ロック（Pessimistic Lock）を獲得し、直列実行を保証する。
     - **ハッシュ連鎖**: 承認・否認・適用の各イベントを `attendance_audit_log` に追記（UPDATE / DELETE 権限を剥奪）。前レコードの `entry_hash` と現レコード内容を連結して SHA-256 を計算し、ブロックチェーン型の改ざん防止チェーンを形成。
- **出力**:
  - `requestId` (修正申請識別子, VARCHAR(36))
  - `status` (申請状態, PENDING_FIRST, PENDING_SECOND, APPLIED, REJECTED)
  - `newVersion` (適用後新バージョン, BIGINT)
  - `auditEntryHash` (生成された不変監査ハッシュ, VARCHAR(64))
- **例外処理**:
  - 申請者本人による承認、同一人の重複承認: SecurityException (HTTP 403 APPROVAL_FORBIDDEN)
  - 承認権限不足: AccessDeniedException (HTTP 403 INSUFFICIENT_APPROVAL_ROLE)
  - 承認反映時にバージョン競合が発生した場合: OptimisticLockingFailureException (HTTP 409 STALE_VERSION)
- **完了基準 (DoD)**:
  - 通常店舗では異なる2名（店長代行スタッフとオーナー）の承認を経て初めて勤務時間が訂正され、単独オーナー店舗では特例フラグ付きで1名承認が受理されること。
  - 申請者本人が承認ボタンを押下した場合に HTTP 403 で確実に遮断されること。
  - 年少者の深夜実績訂正が HTTP 422 で拒否されず、違反フラグ付きで正常承認され賃金が全額支給されること。
  - テナント直列化排他ロックにより、並行承認環境下でも監査ログの sequence_no とハッシュ連鎖が一切分岐せず直列に記録されること。
---

### 2.3.1 Slice 3 永続化仕様 (DDL & Schema Definitions - MySQL 8.4 Standard)

下表で `!` は `NOT NULL`、`?` は `NULL` 許容を表す。本プロジェクトの標準RDBMSである **MySQL 8.4 (InnoDB)** に準拠し、物理型を定義する：
- `ts`: `DATETIME(6)` (UTC基準)
- `id`: `VARCHAR(36)` (UUID v4標準文字列)
- `hash`: `BINARY(32)` (SHA-256生バイナリ)
- `rate`: `DECIMAL(12,4)` (時給・割増計算精度)
- `json`: `JSON` (MySQLネイティブJSON型)
- 条件付き索引（Partial Index）は、MySQL 8.4の仕様に基づき **仮想生成列（Virtual Generated Column）+ 一意索引（Unique Index）** により等価に実装する（例: `revoked_staff_id VARCHAR(36) AS (CASE WHEN revoked_at IS NULL THEN staff_id ELSE NULL END) VIRTUAL`, `UNIQUE KEY uq_active_device (tenant_id, revoked_staff_id)`）。

| ID・表 | 列・型・NULL 性 | PK・FK・制約 | 追加索引 |
|---|---|---|---|
| [DDL-001] `store_staff` / `store` 拡張 | `store_staff.birth_date date!`、`is_manager boolean!`。`store.latitude double precision!`、`longitude double precision!`、`prefecture_code char(2)!`、`week_start_day smallint!` | 既存 PK・FK 維持。座標は [REQ-ATT-001] の範囲、都道府県は `01`〜`47`、`week_start_day` は 1〜7（ISO-8601、1:月曜日〜7:日曜日）。同一人物の生年月日は所属間で整合させる | `store_staff(tenant_id,staff_id,store_id)` |
| [DDL-002] `attendance_device` | `tenant_id id!`, `device_uuid id!`, `staff_id id!`, `credential_ref text!`, `registered_at ts!`, `revoked_at ts?` | PK `(tenant_id,device_uuid)`、FK `(tenant_id,staff_id)→staff`、UQ `(tenant_id,credential_ref)`。失効は登録以降 | 仮想生成列による有効端末UQ `(tenant_id, active_staff_id)` |
| [DDL-003] `qr_terminal` | `tenant_id id!`, `terminal_id id!`, `store_id bigint!`, `registered_at ts!`, `revoked_at ts?` | PK `(tenant_id,terminal_id)`、FK `(tenant_id,store_id)→store`。端末の店舗間転用は禁止 | `(tenant_id,store_id)` |
| [DDL-004] `qr_terminal_key` | `tenant_id id!`, `terminal_id id!`, `key_version integer!`, `secret_ref text!`, `valid_from ts!`, `valid_until ts?`, `revoked_at ts?` | PK `(tenant_id,terminal_id,key_version)`、FK `(tenant_id,terminal_id)→qr_terminal`。`key_version>0`、終了は開始後。鍵素材は秘密管理基盤に置く | `(tenant_id,terminal_id,valid_from)` |
| [DDL-005] `attendance_session` | `tenant_id id!`, `session_id id!`, `store_id bigint!`, `staff_id id!`, `business_date date!`, `state varchar(30)!`, `version bigint!`, `started_at ts?`, `ended_at ts?` | PK `(tenant_id,session_id)`、FK `(tenant_id,store_id,staff_id)→store_staff`。状態は `UNCLOCK, WORKING, ON_BREAK, DRAFT, CLOSED_PENDING_APPROVAL, CLOSED, VOID`。未記録救済出勤時は `DRAFT` 生成 | 仮想生成列による開セッションUQ `(tenant_id, open_staff_id)`、`(tenant_id,staff_id,business_date)` |
| [DDL-006] `attendance_event` | `tenant_id id!`, `event_id id!`, `session_id id!`, `staff_id id!`, `kind varchar(20)!`, `effective_at ts!`, `received_at ts!`, `device_uuid id!`, `terminal_id id!`, `key_version integer!`, `slot bigint!`, `latitude double precision!`, `longitude double precision!`, `store_lat double precision!`, `store_lon double precision!`, `distance_m double precision!`, `horizontal_accuracy double precision!`, `fix_timestamp ts!`, `is_mock_provider boolean!`, `accuracy_anomaly_flag boolean!`, `off_premise_flag boolean!`, `youth_night_violation_flag boolean!`, `location_source varchar(30)!`, `idempotency_key id!`, `request_hash hash!`, `result_json json!` | PK `(tenant_id,event_id)`、FK→対象勤務、スタッフ、登録端末、端末鍵版。UQ `(tenant_id,staff_id,idempotency_key)`、UQ `(tenant_id,staff_id,terminal_id,key_version,slot,kind)`。追記専用 | `(tenant_id,session_id,effective_at)` |
| [DDL-007] `attendance_revision` | `tenant_id id!`, `session_id id!`, `version bigint!`, `source varchar(30)!`, `event_id id?`, `request_id id?`, `youth_night_violation_flag boolean!`, `timeline json!`, `created_at ts!` | PK `(tenant_id,session_id,version)`、FK→勤務、原イベント、修正申請。`OBJECTIVE` はイベントのみ、`APPROVED_CORRECTION` は申請のみ参照。時系列の各要素は種別・絶対時刻・由来を必須とする。追記専用 | UQ `(tenant_id,event_id)`、UQ `(tenant_id,request_id)`（各非 NULL 時） |
| [DDL-008] `minimum_wage_history` | `prefecture_code char(2)!`, `effective_date date!`, `hourly_wage decimal(10,2)!` | PK `(prefecture_code,effective_date)`、都道府県 `01`〜`47`、`hourly_wage>0`。地域別共通マスタ | PK で発効日降順検索 |
| [DDL-009] `attendance_wage_basis` | `tenant_id id!, basis_id id!, payroll_line_id id!, session_id id!, session_version bigint!, line_version bigint!, segment_index int!, segment_start ts!, segment_end ts!, business_date date!, prefecture_code char(2)!, effective_date date!, contract_rate rate!, minimum_rate rate!, applied_rate rate!, rate_difference rate!, warning boolean!, created_at ts!` | PK `(tenant_id,basis_id)`、FK→給与明細、勤務版、地域・発効日。UQ `(tenant_id,payroll_line_id,session_id,segment_index)`。最低賃金改定日跨ぎ夜勤時は segment_index 0,1 で2行生成。追記専用 | `(tenant_id,session_id,session_version)` |
| [DDL-010] `attendance_outbox` | `tenant_id id!`, `message_id id!`, `kind varchar(50)!`, `dedupe_key varchar(100)!`, `payload json!`, `created_at ts!`, `available_at ts!`, `attempts integer!`, `delivered_at ts?`, `last_error_code varchar(50)?` | PK `(tenant_id,message_id)`、UQ `(tenant_id,kind,dedupe_key)`、`attempts≥0`。給与・店舗・対象勤務の識別子を種別別ペイロードで検証 | 仮想生成列による未配信索引 `(available_at, undelivered_message_id)` |
| [DDL-011] `attendance_correction` | `tenant_id id!`, `request_id id!`, `session_id id!`, `base_version bigint!`, `applicant_id id!`, `reason text!`, `single_owner_reason text?`, `proposed_timeline json!`, `proposal_hash hash!`, `status varchar(30)!`, `is_single_owner_bypass boolean!`, `created_at ts!`, `resolved_at ts?` | PK `(tenant_id,request_id)`、FK→勤務、申請主体。`base_version≥0`。状態は [REQ-ATT-003]。理由は空白のみ不可、単独オーナー特例承認時は `is_single_owner_bypass=TRUE` かつ `single_owner_reason` 必須。追記専用 | `(tenant_id,session_id,base_version)`、`(tenant_id,status,created_at)` |
| [DDL-012] `attendance_decision` | `tenant_id id!`, `request_id id!`, `stage smallint!`, `actor_id id!`, `decision varchar(20)!`, `reason text?`, `proposal_hash hash!`, `decided_at ts!` | PK `(tenant_id,request_id,stage)`、UQ `(tenant_id,request_id,actor_id)`、FK→申請、主体。`stage IN (1,2)`、`decision IN ('APPROVE','REJECT')`。否認理由必須。追記専用 | `(tenant_id,actor_id,decided_at)` |
| [DDL-013] `attendance_audit_log` | `tenant_id id!`, `sequence_no bigint!`, `action varchar(50)!`, `actor_id id!`, `entity_type varchar(50)!`, `entity_id id!`, `correlation_id id!`, `occurred_at ts!`, `reason text?`, `old_version bigint?`, `new_version bigint?`, `before_hash hash?`, `after_hash hash?`, `previous_hash hash!`, `entry_hash hash!` | PK `(tenant_id,sequence_no)`、FK→主体（自動処理はサービス主体）。テナント別直列採番。初項の前ハッシュは 32 バイトのゼロ。各項は版固定の正規化表現を SHA-256 で連結。追記専用 | `(tenant_id,entity_type,entity_id,sequence_no)`、`(tenant_id,correlation_id)` |
| [DDL-014] `payroll_settlement` | `tenant_id id!`, `settlement_id id!`, `store_id id!`, `target_month varchar(7)!`, `status varchar(20)!`, `total_staff_count int!`, `total_gross_pay numeric!`, `confirmed_by id?`, `confirmed_at ts?`, `closed_at ts?`, `version bigint!`, `created_at ts!`, `updated_at ts!` | PK `(tenant_id,settlement_id)`、UQ `(tenant_id,store_id,target_month)`、FK `(tenant_id,store_id)→store`。状態は `OPEN, CONFIRMED, CLOSED`。CAS更新および不変締め統制 | `(tenant_id,store_id,target_month)`、`(tenant_id,confirmed_by)` |
| [DDL-015] `payroll_settlement_line` | `tenant_id id!`, `line_id id!`, `settlement_id id!`, `staff_id id!`, `contract_type text!`, `base_hourly_rate numeric!`, `total_work_seconds bigint!`, `total_work_minutes numeric!`, `overtime_under60_minutes numeric!`, `overtime_over60_minutes numeric!`, `night_minutes numeric!`, `holiday_minutes numeric!`, `base_pay numeric!`, `overtime_pay numeric!`, `night_pay numeric!`, `holiday_pay numeric!`, `gross_pay numeric!`, `calculation_snapshot_json json!`, `created_at ts!` | PK `(tenant_id,line_id)`、FK `(tenant_id,settlement_id)→payroll_settlement`、UQ `(tenant_id,settlement_id,staff_id)`。秒精度正準保持（循環小数遮断）および確定スナップショット不変保存 | `(tenant_id,settlement_id,staff_id)`、`(tenant_id,staff_id,settlement_id)` |
### 2.4 [Slice 4] 労働基準法第37条 割増賃金算定エンジンおよび並行性制御 (Payroll Engine)

#### [REQ-LABOR-001] 法定労働時間超過・時間外割増手当（日8時間および週40時間基準）の算定
- **区分**: 機能要件および労働法遵守 (Function & Legal Compliance)
- **概要**: 労働基準法第32条、第37条、および第38条（事業場を異にする場合の通算）に基づき、同一労働者の同一法定労働日（LWD）における全勤務セグメントを通算合算し、1日8時間超過（日次法定外残業）および週40時間超過（週次法定外残業）の実労働時間を厳密に算出して基本時給の1.25倍（基本100% + 残業割増25%）を適用する。法定休日労働（第35条）は時間外労働算定（週40h・日8h）から完全に除外して独立算定する。同日複数回勤務（中抜け勤務等）における8時間超過漏れを完全排除し、月次確定時まで秒単位・有理数（BigDecimal）の精度を維持する。
- **入力**: 
  - `clockInAt` (出勤日時, ISO-8601, 秒精度)
  - `clockOutAt` (退勤日時, ISO-8601, 秒精度)
  - `breakIntervals` (休憩開始・終了日時リスト, 半開区間, 秒精度)
  - `hourlyWage` (基本時給, JPY 整数)
  - `isStatutoryHoliday` (法定休日該当フラグ, BOOLEAN, 週1日または4週4日の法定休日)
  - `priorDailyMinutes` (同一法定労働日内の先行動務の実労働累計時間, 分)
  - `priorWeeklyMinutes` (同一週内の既算定実労働累計時間（法定休日および日次残業算定済分を除く）, 分)
- **処理**:
  1. **二元属性判定（Dual Attribution）および継続勤務評価**:
     - **日次8時間枠算入（第32条）**: 始業時刻の属する日（就業規則上の起算時刻）を法定労働日（LWD）とし、日跨ぎシフト全体を始業日単一勤務として扱う（昭63.1.1基発第150号通達）。
     - **法定休日判定（第35条）**: 暦日（00:00:00〜24:00:00）を厳密な単位とし、通常日（土曜等）から法定休日（日曜等）へ跨ぐ勤務は暦日午前0時（00:00）で区間分割する。休日区間（00:00〜退勤）は休日労働（+35%）として算定し、日次・週次の時間外労働枠からは完全に除外する。
  2. 秒精度実労働時間の算出：総滞在時間（秒）から有効休憩時間の和集合（秒）を控除し、実労働秒数および分数を算出する。
  3. **同日複数勤務の日次8時間超過通算（SPEC-WAGE-01）**:
     - 同一労働者・同一法定労働日の勤務セグメントに対し、`currentEligibleMinutes` を算出する。
     - 日次残業時間を `dailyOvertimeMinutes = max(0, priorDailyMinutes + currentEligibleMinutes - 480) - max(0, priorDailyMinutes - 480)` として決定論的に抽出し、中抜け勤務や複数回打刻時にも8時間超過分が確実に割増対象となることを担保する。
  4. 通常勤務日の週次法定外残業判定（日次・週次二重計上防止）：
     - 当該勤務の週次算入基準時間（`weeklyAddition`）を `min(currentEligibleMinutes, max(0, 480 - priorDailyMinutes))` と決定論的に固定する。
     - 週累計実労働時間に対し、`priorWeeklyMinutes + weeklyAddition > 2400`（40時間）となる場合、その超過部分 `max(0, (priorWeeklyMinutes + weeklyAddition) - max(2400, priorWeeklyMinutes))` を `weeklyOvertimeMinutes` として計上する。
  5. 合計時間外労働時間：`totalOvertimeMinutes = dailyOvertimeMinutes + weeklyOvertimeMinutes`。
  6. 最低賃金自動補正との連携（単一支給時給の継承）：支給基本時給 `payableRate` は、REQ-LABOR-005（地域別最低賃金改定日履歴マスタおよび自動補正統制）において決定論的に算出された `appliedHourlyWage`（`applied_rate`）を単一の真実原書としてそのまま受領・適用し、本要件内での独自判定や再計算による時給乖離を完全に排除する。
  7. 金額計算：日次での通貨切捨ては実施せず、乗算先行かつ除算時スケール指定により `overtimePayExact = payableRate.multiply(BigDecimal.valueOf(0.25)).multiply(BigDecimal.valueOf(totalOvertimeMinutes)).divide(BigDecimal.valueOf(60), 10, RoundingMode.HALF_UP)` を高精度 `BigDecimal` として算出し、月次集計へ連携する。
- **出力**:
  - `dailyOvertimeMinutes` (日次8h超残業時間, 分)
  - `weeklyOvertimeMinutes` (週40h超残業時間, 分)
  - `totalOvertimeMinutes` (合計時間外労働時間, 分)
  - `overtimePayExact` (高精度残業割増手当, BigDecimal)
- **例外処理**:
  - `clockOutAt` が未打刻の状態である場合、`IllegalStateException`（HTTP 409）を送出して算定を中断する。
- **完了基準 (DoD)**:
  - 同一日に 09:00〜14:00（5時間）と 16:00〜21:00（5時間）の複数回勤務を行った場合、通算10時間となり、19:00以降の2時間が確実に日次時間外割増（25%）として算定されること。
  - C#リンター規則に100%適合し、日次切捨てによる1円未満の過少払いが一切発生しないこと。

---

#### [REQ-LABOR-002] 深夜労働割増手当（深夜手当・半開区間境界）の算定
- **区分**: 機能要件および労働法遵守 (Function & Legal Compliance)
- **概要**: 労働基準法第37条第4項および昭和63年3月14日基発第150号通達に基づき、夜間深夜時間帯（当日22:00:00から翌日05:00:00直前まで）に実施された実労働時間に対し、法定割増分25%を加算適用する。暦日を跨ぐ勤務の所属日判定および深夜時間帯の積集合を高精度に算定する。
- **入力**:
  - 勤務所属日（出勤打刻の始業時刻が属する暦日）
  - 出退勤打刻日時（ISO 8601 形式 `YYYY-MM-DDTHH:mm:ss`, 秒精度）
  - 深夜時間帯定義: 当日 `22:00:00` から翌日 `05:00:00` 直前まで（半開区間 `[22:00, 05:00)`）
  - `hourlyWage` (基本時給, JPY 整数)
- **処理**:
  1. 暦日・所属日判定ルール（基発第150号準拠）：
     - 始業時刻（出勤打刻）が属する暦日を当該勤務の「所属日（起算日）」とし、暦日を跨いで翌日に及ぶ一継続勤務は、翌日の勤務を含めて始業日の単一勤務として通算する。
     - 翌日深夜（例: 00:00〜05:00）に新たに始業（出勤）した勤務は、前日の延長ではなく、当日始業の新規勤務として独立して取り扱い、当日早朝の深夜労働として算定する。
  2. 出退勤打刻区間と深夜時間帯（22:00:00〜翌日05:00:00）の重複積集合を秒精度で抽出する。
  3. 深夜区間内に交差する休憩時間を厳密に控除し、純粋な深夜実労働時間（`nightSeconds` および `nightMinutes`）を算出する（22:00境界または05:00境界に跨る休憩は深夜該当部分のみ按分控除）。
  4. 金額計算：日次での通貨切捨ては実施せず、月次集計用分子として `hourlyWage * nightSeconds * 25` を蓄積し、高精度を維持する。
- **出力**:
  - `nightMinutes` (深夜実労働時間, 分)
  - `nightSeconds` (深夜実労働時間, 秒)
  - `nightPayExact` (高精度深夜加算手当, BigDecimal)
- **例外処理**:
  - 境界値検証：21:59:59退勤時は深夜時間0秒、22:00:00在籍時は秒単位算定開始、05:00:00退勤時は04:59:59までの深夜区間のみを算定対象とすること。
- **完了基準 (DoD)**:
  - 深夜時間帯（22:00 `~` 05:00）に休憩が含まれる場合、深夜実労働から正確に休憩分が控除されること。
  - 暦日跨ぎ勤務および未明（00:00〜05:00）始業勤務の所属日判定が基発第150号と完全に合致すること。
  - C#リンター規則を100%通過し、境界値打刻テスト（21:59、22:01）を完全に満足すること。

---

#### [REQ-LABOR-003] 時間外・深夜・法定休日の重畳割増マトリクスおよび基発第150号月次端数処理統制
- **区分**: 機能要件および労働法遵守 (Function & Legal Compliance)
- **概要**: 2023年4月1日施行の改正労働基準法第37条（月60時間超の時間外労働割増率50%引上げ、中小企業猶予撤廃済、代替休暇制度はスコープ外）、法定休日労働（35%割増）、および深夜労働（25%割増）の完全な重畳割増マトリクスを決定論的に適用する。平日から法定休日（暦日00:00:00）へ跨ぐ勤務は暦日午前0時で区間分割し、休日区間（00:00〜退勤）を休日労働（+35%）として優先算定して日次8時間・週次40時間・月60時間の時間外枠から完全に分離・除外する（F-DAY4-001解決）。時間量は正準表現として秒精度（`total_work_seconds bigint`）を完全保持して秒打刻の循環小数を排除し（F-DAY4-003解決）、端数処理は昭和63年3月14日基発第150号通達の許容枠内において、就業規則に基づく事業者規約として時間外手当・深夜手当・法定休日手当の各成分月合計に対して単一の `RoundingMode.HALF_UP`（50銭未満切捨て、50銭以上1円切上げ）を適用する。1か月の時間数に対する30分単位の丸め（通達②）は労働者不利益防止のため一切不採用とし、実時間秒数を厳格に維持する（F-DAY4-002解決）。
- **入力**:
  - `workSeconds` (総実労働時間, 秒精度, bigint)
  - `workMinutes` (総実労働時間, 分換算 numeric, 参考表示)
  - `overtimeSecondsUnder60` (月60時間以下の時間外労働時間, 秒)
  - `overtimeSecondsOver60` (月60時間超の時間外労働時間, 秒, 法定休日労働は完全除外)
  - `nightSeconds` (深夜実労働時間, 秒)
  - `holidaySeconds` (法定休日実労働時間, 秒)
  - `hourlyWage` (基本時給, JPY 整数, REQ-LABOR-005最低賃金補正済み `applied_rate`)
- **処理**:
  1. **割増判定マトリクスおよび法定休日最優先分離統制（F-DAY4-001）**:
     - 出退勤打刻および休憩区間より、全実労働時間を以下の重複のない相互排他的セグメントへ分解する。
     - | 勤務区分 | 時間外加算 | 深夜加算 | 法定休日加算 | 支給率（基本給含む） |
       |---|---:|---:|---:|---:|
       | 通常実労働 | 0% | 0% | 0% | 100% |
       | 通常・深夜 | 0% | 25% | 0% | 125% |
       | 時間外（月60h以下） | 25% | 0% | 0% | 125% |
       | 同・深夜重複 | 25% | 25% | 0% | 150% |
       | 時間外（月60h超） | 50% | 0% | 0% | 150% |
       | 同・深夜重複 | 50% | 25% | 0% | 175% |
       | 法定休日労働 | 0% | 0% | 35% | 135% |
       | 法定休日・深夜重複 | 0% | 25% | 35% | 160% |
     - 平日始業から翌日法定休日に跨る勤務（例: 平日19:00〜翌法定休日03:00）は、暦日00:00:00で強制区間分割する。00:00以前は平日の日次8時間枠で評価し、00:00以降の全労働は法定休日労働（+35%）を優先適用して平日の日次8時間カウンタ・週40時間枠・月60時間枠から完全に分離・算入除外する。
  2. **秒精度正準計算および共通分母方式（F-DAY4-003）**:
     - 中間除算による丸め誤差および秒単位の循環小数を完全排除するため、`BigInteger` による分子累計 `numerator += hourlyWage * seconds * rateFactor`（基本給 100, 割増 25, 35, 50, 60, 75）を整数として保持し、共通分母を `3600 * 100 = 360000` とする。
  3. **基発第150号成分別月次端数処理および事業者規約統制（F-DAY4-002）**:
     - 月次集計確定時、50銭未満切捨て・50銭以上1円切上げ（`HALF_UP`）は「時間外割増手当総額」「深夜割増手当総額」「法定休日割増手当総額」の各手当成分別に月合計に対して適用し、確定整数円を算出する。基本給（`base_pay`）は就業規則上の事業者規約として同様に月合計で単一 `HALF_UP` 確定する。日次・週次での途中通貨切捨ては一切禁止する。
  4. **複数店舗勤務におけるLargest Remainder法配賦およびスナップショット整合（F-DAY4-005）**:
     - 同一従業員が同月に複数店舗で勤務した場合、従業員月全体で各成分を一度だけ確定し、各店舗へ正確額の整数部分を配賦後、残余小数（厳密有理数）の大きい店舗から順に1円ずつ配賦する（同率時は `store_id` 昇順）。全店舗の勤怠が承認・固定されていることを事前検証し、各店舗明細の `calculation_snapshot_json` に当該店舗へ帰属した月60h超（50%）時間・配賦根拠を完全に保存する。
- **出力**:
  - `monthlyGrossPay` (確定月次総支給額, JPY 整数)
  - `breakdown` (基本給、残業手当(<=60h)、残業手当(>60h)、深夜手当、休日手当の各確定明細および秒数・分数)
  - `calculation_snapshot_json` (スキーマ版、入力版、各成分の丸め前有理数分子・分母、店舗配賦根拠)
- **例外処理**:
  - `DateTimeParseException` は HTTP 400 `INVALID_ISO_TIMESTAMP` を返却する。
  - 実労働時間がゼロまたは負となる場合は `InvalidWorkTimeException`（HTTP 422）を送出する。
  - 複数店舗配賦時に対象従業員の他店舗勤怠に未承認勤務データが存在する場合は `PayrollSourceConflictException`（HTTP 409）を送出する。
- **完了基準 (DoD)**:
  - 平日19:00から翌法定休日03:00（8時間拘束）の連続勤務において、00:00以降の3時間が確実に法定休日割増（+35%）かつ深夜割増（+25%）の合計160%として算定され、平日の8時間残業枠に算入されないこと。
  - 秒単位打刻（30秒×2回で1分）において循環小数エラーを発生させず、正準秒精度で計算が完結すること。
  - 月60時間を超える残業が深夜時間帯に発生した場合、正確に175%の乗率で算定されること。
  - C#リンター規則に100%適合し、中間丸めに起因する1円の差異も生じないこと。

---

#### [REQ-LABOR-004] 階層的悲観的ロック・複合一意制約および冪等給与確定トランザクション整合性
- **区分**: セキュリティおよび並行性制御 (Security & Concurrency)
- **概要**: 給与精算テーブルに初回確定レコードが存在しない場合でも二重確定レースコンディション（ファントム確定）を100%遮断するため、親テーブル（`store`）の先行悲観的ロック、複合一意制約（`uq_settlement_store_month`）、および行レベル排他ロック（`SELECT ... FOR UPDATE`）の三重防御線を確立する。複数店舗通算時のデッドロックを防止するためロック階層順序を厳格統一し、`lock_timeout` を設定する（F-DAY4-004解決）。未承認勤怠が存在する場合は `blocking_staff_ids` を明示して運用デッドロックを防ぎ（F-DAY4-006解決）、締め後の訂正は次月精算調整ラインへ繰り越す不変ライフサイクルを確立する（F-DAY4-007解決）。
- **入力**:
  - `storeId` (店舗ID, UUID, 必須)
  - `targetMonth` (精算対象年月, VARCHAR(7), 'YYYY-MM' 形式, 必須)
  - `SecurityContext` (テナントID `tenant_id`, 操作者ID `staff_id`, 店舗権限)
- **処理**:
  1. **所有権検証・先行店舗排他ロックおよびデッドロック防止順序（F-DAY4-004）**:
     - トランザクション開始直後、`SET LOCAL lock_timeout = '3s'` を設定する。
     - システム全体のロック獲得順序を「`store` → `store_staff` → `payroll_settlement` → `payroll_settlement_line`」に厳格統一する。複数店舗が依存集合に含まれる場合は、第1階層において `ORDER BY (tenant_id, store_id)` の主キー昇順で全対象店舗を先行排他ロックし、ロック前の読取TOCTOUを排除する。競合タイムアウト時はジッタ付き指数バックオフにより最大3回自動再試行する。
  2. **未承認勤怠の検出およびブロッキング従業員明示（F-DAY4-006）**:
     - 店舗ロック保護下で対象月の全所属従業員の勤怠承認状態を走査する。未承認（`DRAFT`、`CLOSED_PENDING_APPROVAL`）の勤怠セグメントが1件でも存在する場合、確定処理を即時中断し、エラー応答に確定を阻害している対象者ID配列（`blocking_staff_ids`）を明示して `PayrollInputNotFinalException`（HTTP 409）を送出する。
  3. **初回確定および複合一意制約保護**:
     - 給与精算テーブル（`payroll_settlement`）において `(tenant_id, store_id, target_month)` を指定して既存レコードを取得する（`SELECT ... FOR UPDATE`）。
     - 初回確定時（レコード未存在時）は、PostgreSQL/MySQLの複合一意制約（`uq_settlement_store_month`）の保護下で、初期ステータス `'OPEN'` の精算ヘッダーレコードを安全に発行する。
  4. **明細の一括不変スナップショット永続化およびCAS状態更新**:
     - 各対象従業員の確定給与明細を `payroll_settlement_line`（DDL-015）へ一括挿入する。
     - ヘッダーステータスを `'OPEN' → 'CONFIRMED'` へCAS更新（`WHERE tenant_id = :tenant AND settlement_id = :id AND status = 'OPEN'`）し、`affected rows == 1` を確認してコミットとともにロックを解放する。確定再送時は既存の `CONFIRMED` 結果を冪等返却する。
  5. **締鎖（CLOSED）統制および事後遡及調整ライフサイクル（F-DAY4-007）**:
     - 締鎖要求時は `CONFIRMED → CLOSED` へ遷移させ、以後の再開や確定明細の変更・削除を不可逆的に完全禁止する。
     - 締鎖後に過去勤怠の遡及訂正（未払い精算等）が発生した場合、確定済み月次レコードの改変を禁止し、差額精算を次月以降の精算ライン（`adjustment_line`）として繰り越して調整する業務規約を適用する。
- **出力**:
  - `settlementId` (確定給与精算PK, UUID)
  - `settlementStatus` (確定ステータス 'CONFIRMED' / 'CLOSED')
  - `totalStaffCount` (確定対象従業員数, INT)
  - `totalGrossPay` (確定総支給額, NUMERIC)
- **例外処理**:
  - 店舗権限不足は `AccessDeniedException`（HTTP 403）を送出する。
  - 未承認勤怠が存在する場合は `PayrollInputNotFinalException`（HTTP 409、`blocking_staff_ids` 付与）を送出する。
  - 3秒のロック獲得待機がタイムアウトした場合は `SettlementConcurrencyException`（HTTP 409 / 503、再試行推奨）を返却する。
  - 既に確定済みのヘッダーに対する重複確定競合は `DuplicateSettlementException`（HTTP 409）を送出して二重支払いを確実に阻止する。
- **完了基準 (DoD)**:
  - 2件の並行確定リクエストが同時に実行された際、先行店舗ロックおよび複合一意制約により確実に1件のみが成功し、もう1件は重複競合として HTTP 409 で遮断されること。
  - 未承認勤怠が存在する場合、HTTP 409 とともに `blocking_staff_ids` が返却され、管理者が対象者を即座に特定できること。
  - C#リンター規則に100%適合し、確定・締鎖後の過去勤務データ変更が確定済み給与額に一切影響を与えないこと。
