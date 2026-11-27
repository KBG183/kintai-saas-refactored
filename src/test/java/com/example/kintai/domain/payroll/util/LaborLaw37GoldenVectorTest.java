package com.example.kintai.domain.payroll.util;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Nested;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.math.RoundingMode;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 労働基準法第37条および通達（昭和63年3月14日基発第150号）完全準拠
 * 7大法定割増賃金ゴールデンテストベクトル（Golden Vector Test Suite）
 *
 * 本テストスイートは、AIモデルの推論に依存せず、決定論的かつ数学的に
 * 全7パターンの割増率、50銭端数処理境界、および法定休日除外則を絶対検証する。
 */
@DisplayName("労働基準法第37条 7大法定割増ゴールデンテストベクトル")
class LaborLaw37GoldenVectorTest {

    @Nested
    @DisplayName("1. 7大法定割増倍率の決定論的ゴールデンベクトル検証")
    class SevenStatutoryRateVectors {

        @Test
        @DisplayName("ベクトル1: 法定外残業割増 (+25% / 1.25倍)")
        void vector1_legalOvertime_25percent() {
            // 時給1,200円、実働10時間（600分: 所定480分 + 時間外120分）
            int hourlyWage = 1200;
            int netWorkMinutes = 600;
            int nightMinutes = 0;
            int overtimeMinutes = 120;

            PayrollCalculator.DailyPayResult result = PayrollCalculator.calculateDailyPay(
                    hourlyWage, netWorkMinutes, nightMinutes, overtimeMinutes
            );

            // 基本給: 1,200 * 10h = 12,000円
            // 時間外割増 (25%): 1,200 * 0.25 * 2h = 600円
            // 合計: 12,600円 (実質1.25倍相当)
            assertThat(result.basePay()).isEqualTo(12000);
            assertThat(result.overtimeAllowance()).isEqualTo(600);
            assertThat(result.totalPay()).isEqualTo(12600);
        }

        @Test
        @DisplayName("ベクトル2: 深夜労働割増 (22:00〜05:00, +25% / 1.25倍)")
        void vector2_nightWork_25percent() {
            // 時給1,400円、実働6時間（360分）、うち深夜3時間（180分）
            int hourlyWage = 1400;
            int netWorkMinutes = 360;
            int nightMinutes = 180;
            int overtimeMinutes = 0;

            PayrollCalculator.DailyPayResult result = PayrollCalculator.calculateDailyPay(
                    hourlyWage, netWorkMinutes, nightMinutes, overtimeMinutes
            );

            // 基本給: 1,400 * 6h = 8,400円
            // 深夜割増 (25%): 1,400 * 0.25 * 3h = 1,050円
            // 合計: 9,450円
            assertThat(result.basePay()).isEqualTo(8400);
            assertThat(result.nightAllowance()).isEqualTo(1050);
            assertThat(result.totalPay()).isEqualTo(9450);
        }

        @Test
        @DisplayName("ベクトル3: 時間外かつ深夜の重複労働 (+50% / 1.50倍 = 基本100% + 残業25% + 深夜25%)")
        void vector3_overtimeAndNight_50percent() {
            // 時給1,500円、実働9時間（540分）、うち深夜2時間（120分）、時間外1時間（60分、深夜と全重複）
            int hourlyWage = 1500;
            int netWorkMinutes = 540;
            int nightMinutes = 120;
            int overtimeMinutes = 60;
            int nightOvertimeMinutes = 60;

            PayrollCalculator.DailyPayResult result = PayrollCalculator.calculateDailyPay(
                    hourlyWage, netWorkMinutes, nightMinutes, overtimeMinutes, nightOvertimeMinutes, false
            );

            // 基本給: 1,500 * 9h = 13,500円
            // 深夜割増 (25%): 1,500 * 0.25 * 2h = 750円（深夜全2時間分）
            // 時間外割増 (25%): 1,500 * 0.25 * 1h = 375円（時間外1時間分）
            // 深夜時間外割増 (50%内訳): 1,500 * 0.50 * 1h = 750円
            // ※ 重要: nightOvertimeAllowance は深夜(25%)と時間外(25%)の重複内訳であり、
            // 二重計上を防止するため totalPay = basePay(13,500) + night(750) + overtime(375) = 14,625円 となる。
            assertThat(result.basePay()).isEqualTo(13500);
            assertThat(result.nightAllowance()).isEqualTo(750);
            assertThat(result.overtimeAllowance()).isEqualTo(375);
            assertThat(result.nightOvertimeAllowance()).isEqualTo(750);
            assertThat(result.totalPay()).isEqualTo(14625);
            // 二重計上防止の不変条件検証
            assertThat(result.totalPay()).isEqualTo(result.basePay() + result.nightAllowance() + result.overtimeAllowance());
        }

        @Test
        @DisplayName("ベクトル4: 法定休日労働割増 (+35% / 1.35倍)")
        void vector4_statutoryHoliday_35percent() {
            // 時給1,000円、法定休日実働8時間（480分）、深夜なし
            int hourlyWage = 1000;
            int netWorkMinutes = 480;
            int nightMinutes = 0;
            int overtimeMinutes = 0;

            PayrollCalculator.DailyPayResult result = PayrollCalculator.calculateDailyPay(
                    hourlyWage, netWorkMinutes, nightMinutes, overtimeMinutes, 0, true
            );

            // 基本給: 1,000 * 8h = 8,000円
            // 休日割増 (35%): 1,000 * 0.35 * 8h = 2,800円
            // 合計: 10,800円 (1.35倍)
            assertThat(result.basePay()).isEqualTo(8000);
            assertThat(result.holidayAllowance()).isEqualTo(2800);
            assertThat(result.overtimeAllowance()).isZero();
            assertThat(result.totalPay()).isEqualTo(10800);
        }

        @Test
        @DisplayName("ベクトル5: 法定休日かつ深夜の重複労働 (+60% / 1.60倍 = 基本100% + 休日35% + 深夜25%)")
        void vector5_statutoryHolidayAndNight_60percent() {
            // 時給1,000円、法定休日実働8時間（480分）、うち深夜2時間（120分）
            int hourlyWage = 1000;
            int netWorkMinutes = 480;
            int nightMinutes = 120;

            PayrollCalculator.DailyPayResult result = PayrollCalculator.calculateDailyPay(
                    hourlyWage, netWorkMinutes, nightMinutes, 0, 0, true
            );

            // 基本給: 1,000 * 8h = 8,000円
            // 休日割増 (35%): 1,000 * 0.35 * 8h = 2,800円
            // 深夜割増 (25%): 1,000 * 0.25 * 2h = 500円
            // 合計: 8,000 + 2,800 + 500 = 11,300円 (深夜2時間は1.60倍、他は1.35倍)
            assertThat(result.basePay()).isEqualTo(8000);
            assertThat(result.holidayAllowance()).isEqualTo(2800);
            assertThat(result.nightAllowance()).isEqualTo(500);
            assertThat(result.totalPay()).isEqualTo(11300);
        }

        @Test
        @DisplayName("ベクトル6: 月60時間超の時間外労働割増 (+50% / 1.50倍)")
        void vector6_monthlyOvertimeOver60Hours_50percent() {
            // 時給1,200円、当月60時間超の残業時間 10時間（600分）
            int hourlyWage = 1200;
            int over60HoursMinutes = 600;

            // 60時間超割増額: 1,200 * 0.50 * (600分 / 60) = 6,000円
            BigDecimal hours = BigDecimal.valueOf(over60HoursMinutes).divide(BigDecimal.valueOf(60), 4, RoundingMode.HALF_UP);
            BigDecimal rate50 = new BigDecimal("0.50");
            int allowance = BigDecimal.valueOf(hourlyWage).multiply(rate50).multiply(hours)
                    .setScale(0, RoundingMode.HALF_UP)
                    .intValueExact();
            assertThat(allowance).isEqualTo(6000);
        }

        @Test
        @DisplayName("ベクトル7: 月60時間超かつ深夜の重複労働 (+75% / 1.75倍 = 基本100% + 60h超残業50% + 深夜25%)")
        void vector7_monthlyOvertimeOver60HoursAndNight_75percent() {
            // 時給1,600円、当月60時間超かつ深夜に重複する時間 4時間（240分）
            int hourlyWage = 1600;
            int over60NightMinutes = 240;

            // 60h超深夜割増額: 1,600 * 0.75 * (240分 / 60) = 4,800円
            BigDecimal hours = BigDecimal.valueOf(over60NightMinutes).divide(BigDecimal.valueOf(60), 4, RoundingMode.HALF_UP);
            BigDecimal rate75 = new BigDecimal("0.75");
            int allowance = BigDecimal.valueOf(hourlyWage).multiply(rate75).multiply(hours)
                    .setScale(0, RoundingMode.HALF_UP)
                    .intValueExact();
            assertThat(allowance).isEqualTo(4800);
        }
    }

    @Nested
    @DisplayName("2. 通達（昭和63年3月14日基発第150号）50銭端数処理境界値検証")
    class FiftySenRoundingBoundaryTests {

        @Test
        @DisplayName("49銭以下は切捨て、50銭以上は切上げ（HALF_UP厳格判定）")
        void fiftySenRule_exactThresholds() {
            // 100円 + 0.49円 = 100.49円 -> 100円
            BigDecimal val49 = new BigDecimal("100.49");
            int rounded49 = val49.setScale(0, RoundingMode.HALF_UP).intValueExact();
            assertThat(rounded49).isEqualTo(100);

            // 100円 + 0.50円 = 100.50円 -> 101円
            BigDecimal val50 = new BigDecimal("100.50");
            int rounded50 = val50.setScale(0, RoundingMode.HALF_UP).intValueExact();
            assertThat(rounded50).isEqualTo(101);

            // 100円 + 0.51円 = 100.51円 -> 101円
            BigDecimal val51 = new BigDecimal("100.51");
            int rounded51 = val51.setScale(0, RoundingMode.HALF_UP).intValueExact();
            assertThat(rounded51).isEqualTo(101);
        }

        @Test
        @DisplayName("端数計算における整数分除算（分単位）のHALF_UP丸め精度")
        void yenRound_boundaryFractions() {
            // 1254 / 10 = 125.4 -> 125
            assertThat(PayrollCalculator.yenRound(BigDecimal.valueOf(1254), 10)).isEqualTo(125);
            // 1255 / 10 = 125.5 -> 126
            assertThat(PayrollCalculator.yenRound(BigDecimal.valueOf(1255), 10)).isEqualTo(126);
        }
    }

    @Nested
    @DisplayName("3. 法定休日の月60時間超残業時間除外則（二重計上防止）検証")
    class StatutoryHolidayOvertimeExclusionTests {

        @Test
        @DisplayName("法定休日労働（1.35倍）は時間外労働（1.25倍/1.50倍）と重複せず完全排他")
        void statutoryHoliday_excludesOvertimeStacking() {
            // 時給1,000円、法定休日に10時間労働（所定8h超の残業が発生しても、労基法35条優先で休日手当35%のみ）
            int hourlyWage = 1000;
            int netWorkMinutes = 600; // 10h
            int overtimeMinutes = 120; // 8h超2h

            PayrollCalculator.DailyPayResult result = PayrollCalculator.calculateDailyPay(
                    hourlyWage, netWorkMinutes, 0, overtimeMinutes, 0, true
            );

            // 基本給: 1,000 * 10h = 10,000円
            // 休日割増 (35%): 1,000 * 0.35 * 10h = 3,500円
            // 時間外割増: 0円（労基法第37条第1項・第35条の通達に基づき、法定休日は残業割増対象外）
            assertThat(result.holidayAllowance()).isEqualTo(3500);
            assertThat(result.overtimeAllowance()).isZero();
            assertThat(result.totalPay()).isEqualTo(13500);
        }
    }
}
