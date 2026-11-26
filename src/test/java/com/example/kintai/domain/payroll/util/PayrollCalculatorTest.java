package com.example.kintai.domain.payroll.util;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Nested;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * 労働基準法第37条準拠 給与計算エンジン（PayrollCalculator）単体テスト
 */
class PayrollCalculatorTest {

    @Nested
    @DisplayName("労働基準法第37条 割増賃金計算テスト")
    class StatutoryLaborPayTests {

        @Test
        @DisplayName("所定労働時間内（8時間以内・深夜なし）の基本給計算")
        void calculateDailyPay_standardHours_noOvertime_noNight() {
            // 時給1,300円、実働7時間（420分）
            int hourlyWage = 1300;
            int netWorkMinutes = 420;
            int nightMinutes = 0;
            int overtimeMinutes = 0;

            PayrollCalculator.DailyPayResult result = PayrollCalculator.calculateDailyPay(
                    hourlyWage, netWorkMinutes, nightMinutes, overtimeMinutes
            );

            // 1,300 * 7 = 9,100円
            assertThat(result.basePay()).isEqualTo(9100);
            assertThat(result.nightAllowance()).isZero();
            assertThat(result.overtimeAllowance()).isZero();
            assertThat(result.holidayAllowance()).isZero();
            assertThat(result.totalPay()).isEqualTo(9100);
        }

        @Test
        @DisplayName("時間外労働（8時間超過、25%割増）の計算")
        void calculateDailyPay_withOvertime() {
            // 時給1,200円、実働10時間（600分: 所定480分 + 時間外120分）
            int hourlyWage = 1200;
            int netWorkMinutes = 600;
            int nightMinutes = 0;
            int overtimeMinutes = 120;

            PayrollCalculator.DailyPayResult result = PayrollCalculator.calculateDailyPay(
                    hourlyWage, netWorkMinutes, nightMinutes, overtimeMinutes
            );

            // 基本給: 1,200 * 10 = 12,000円
            // 時間外手当 (25%): 1,200 * 0.25 * 2h = 600円
            assertThat(result.basePay()).isEqualTo(12000);
            assertThat(result.overtimeAllowance()).isEqualTo(600);
            assertThat(result.nightAllowance()).isZero();
            assertThat(result.totalPay()).isEqualTo(12600);
        }

        @Test
        @DisplayName("深夜労働（22:00〜05:00、25%割増）の計算")
        void calculateDailyPay_withNightWork() {
            // 時給1,400円、実働6時間（360分）、うち深夜3時間（180分）
            int hourlyWage = 1400;
            int netWorkMinutes = 360;
            int nightMinutes = 180;
            int overtimeMinutes = 0;

            PayrollCalculator.DailyPayResult result = PayrollCalculator.calculateDailyPay(
                    hourlyWage, netWorkMinutes, nightMinutes, overtimeMinutes
            );

            // 基本給: 1,400 * 6 = 8,400円
            // 深夜割増 (25%): 1,400 * 0.25 * 3h = 1,050円
            assertThat(result.basePay()).isEqualTo(8400);
            assertThat(result.nightAllowance()).isEqualTo(1050);
            assertThat(result.overtimeAllowance()).isZero();
            assertThat(result.totalPay()).isEqualTo(9450);
        }

        @Test
        @DisplayName("深夜かつ時間外の重複労働（150%割増 = 基本100% + 深夜25% + 時間外25%）の計算")
        void calculateDailyPay_withNightAndOvertimeOverlap() {
            // 時給1,500円、実働9時間（540分）、うち深夜2時間（120分）、時間外1時間（60分、深夜と重複）
            int hourlyWage = 1500;
            int netWorkMinutes = 540;
            int nightMinutes = 120;
            int overtimeMinutes = 60;
            int nightOvertimeMinutes = 60;

            PayrollCalculator.DailyPayResult result = PayrollCalculator.calculateDailyPay(
                    hourlyWage, netWorkMinutes, nightMinutes, overtimeMinutes, nightOvertimeMinutes, false
            );

            // 基本給: 1,500 * 9h = 13,500円
            // 深夜割増 (25%): 1,500 * 0.25 * 2h = 750円
            // 時間外割増 (25%): 1,500 * 0.25 * 1h = 375円
            // 重複確認用 (50%): 1,500 * 0.50 * 1h = 750円
            assertThat(result.basePay()).isEqualTo(13500);
            assertThat(result.nightAllowance()).isEqualTo(750);
            assertThat(result.overtimeAllowance()).isEqualTo(375);
            assertThat(result.nightOvertimeAllowance()).isEqualTo(750);
            assertThat(result.totalPay()).isEqualTo(14625);
        }

        @Test
        @DisplayName("法定休日労働（35%割増）および休日深夜（35% + 25% = 60%加算 / 160%）の計算")
        void calculateDailyPay_withStatutoryHolidayAndNight() {
            // 時給1,000円、法定休日実働8時間（480分）、うち深夜2時間（120分）
            int hourlyWage = 1000;
            int netWorkMinutes = 480;
            int nightMinutes = 120;
            int overtimeMinutes = 0; // 法定休日は1日8時間超であっても35%休日手当が優先（労基法第37条第1項・第35条）

            PayrollCalculator.DailyPayResult result = PayrollCalculator.calculateDailyPay(
                    hourlyWage, netWorkMinutes, nightMinutes, overtimeMinutes, 0, true
            );

            // 基本給: 1,000 * 8h = 8,000円
            // 休日割増 (35%): 1,000 * 0.35 * 8h = 2,800円
            // 深夜割増 (25%): 1,000 * 0.25 * 2h = 500円
            // 合計: 8,000 + 2,800 + 500 = 11,300円
            assertThat(result.basePay()).isEqualTo(8000);
            assertThat(result.holidayAllowance()).isEqualTo(2800);
            assertThat(result.nightAllowance()).isEqualTo(500);
            assertThat(result.totalPay()).isEqualTo(11300);
        }
    }

    @Nested
    @DisplayName("端数処理および期間算出テスト")
    class UtilityTests {

        @Test
        @DisplayName("50銭ルールに基づく四捨五入（RoundingMode.HALF_UP）検証")
        void yenRound_halfUpPrecision() {
            // 125.4円 -> 125円
            assertThat(PayrollCalculator.yenRound(BigDecimal.valueOf(1254), 10)).isEqualTo(125);
            // 125.5円 -> 126円
            assertThat(PayrollCalculator.yenRound(BigDecimal.valueOf(1255), 10)).isEqualTo(126);
            // 125.6円 -> 126円
            assertThat(PayrollCalculator.yenRound(BigDecimal.valueOf(1256), 10)).isEqualTo(126);
        }

        @Test
        @DisplayName("給与締日による対象期間算出（末日締め payCutoffDay = 99）")
        void resolveDateRange_monthEnd() {
            PayrollCalculator.DateRange range = PayrollCalculator.resolveDateRange("2026-10", 99);
            assertThat(range.startDate()).isEqualTo(LocalDate.of(2026, 10, 1));
            assertThat(range.endDate()).isEqualTo(LocalDate.of(2026, 10, 31));
        }

        @Test
        @DisplayName("給与締日による対象期間算出（20日締め payCutoffDay = 20）")
        void resolveDateRange_cutoff20() {
            PayrollCalculator.DateRange range = PayrollCalculator.resolveDateRange("2026-10", 20);
            assertThat(range.startDate()).isEqualTo(LocalDate.of(2026, 9, 21));
            assertThat(range.endDate()).isEqualTo(LocalDate.of(2026, 10, 20));
        }

        @Test
        @DisplayName("無効な年月フォーマット時の例外スロー検証")
        void resolveDateRange_invalidFormatThrowsException() {
            assertThatThrownBy(() -> PayrollCalculator.resolveDateRange("invalid-date", 99))
                    .isInstanceOf(IllegalArgumentException.class)
                    .hasMessageContaining("無効な年月フォーマットです");
        }
    }
}
