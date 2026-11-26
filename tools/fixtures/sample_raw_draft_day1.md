# 📝 仕様書ドラフト検証用ベンチマークフィクスチャ 1 (Clean Spec)

### [REQ-BENCH-001] 基本打刻および実労働時間算定
- **区分**: 機能要件 (Function)
- **概要**: 従業員の出勤および退勤打刻データから、休憩時間を除外した純粋実労働時間を分単位で算定する。
- **入力**: `clockInAt`, `clockOutAt`, `breakMinutes`
- **処理**: 実労働時間 = `(clockOutAt - clockInAt) - breakMinutes`。
- **出力**: `actualWorkMinutes`
- **完了条件 (DoD)**: 休憩時間が勤務時間を超える場合は例外をスローすること。
