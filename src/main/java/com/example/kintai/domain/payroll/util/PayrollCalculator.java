package com.example.kintai.domain.payroll.util;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDate;
import java.time.YearMonth;
import java.time.format.DateTimeParseException;

public final class PayrollCalculator {

    private PayrollCalculator() {}

    public record DateRange(LocalDate startDate, LocalDate endDate) {}

    public record DailyPayResult(
            int basePay,
            int nightAllowance,
            int overtimeAllowance,
            int nightOvertimeAllowance,
            int holidayAllowance,
            int nightOvertimeMinutes,
            int totalPay
    ) {}

    /**
     * 店舗の給与締日（payCutoffDay: 1~28 または 99=末日締）に基づく実際の集計期間を算出
     */
    public static DateRange resolveDateRange(String targetYearMonthStr, int payCutoffDay) {
        if (targetYearMonthStr == null) {
            throw new IllegalArgumentException("対象年月は必須です。");
        }

        if (payCutoffDay != 99 && (payCutoffDay < 1 || payCutoffDay > 28)) {
            throw new IllegalArgumentException("無効な給与締日です (1~28 または 99=末日締): " + payCutoffDay);
        }

        YearMonth ym;
        try {
            ym = YearMonth.parse(targetYearMonthStr);
        } catch (DateTimeParseException e) {
            throw new IllegalArgumentException("無効な年月フォーマットです。(例: 2026-10): " + targetYearMonthStr, e);
        }

        if (payCutoffDay == 99) {
            LocalDate start = ym.atDay(1);
            LocalDate end = ym.atEndOfMonth();
            return new DateRange(start, end);
        } else {
            YearMonth prevYm = ym.minusMonths(1);
            // 2月の28日締め等で atDay(29) の例外発生を防止するため plusDays(1) を適用
            LocalDate start = prevYm.atDay(payCutoffDay).plusDays(1);
            LocalDate end = ym.atDay(payCutoffDay);
            return new DateRange(start, end);
        }
    }

    /**
     * 労働基準法第37条に準拠した日別支給額および法定割増手当算出
     *
     * @param hourlyWage 勤務日基準の適用契約時給
     * @param totalNetWorkMinutes 該当日の総実労働時間 (分)
     * @param totalNightMinutes 該当日の総深夜労働時間 (分)
     * @param totalOvertimeMinutes 該当日の総時間外労働時間 (分)
     */
    public static DailyPayResult calculateDailyPay(
            int hourlyWage,
            int totalNetWorkMinutes,
            int totalNightMinutes,
            int totalOvertimeMinutes
    ) {
        return calculateDailyPay(hourlyWage, totalNetWorkMinutes, totalNightMinutes, totalOvertimeMinutes, 0, false);
    }

    /**
     * 労働基準法第37条の多段階割増（法定休日労働 135%/160%、深夜時間外 150%）完全対応算出
     *
     * @param hourlyWage 勤務日基準の適用契約時給
     * @param totalNetWorkMinutes 該当日の総実労働時間 (分)
     * @param totalNightMinutes 該当日の総深夜労働時間 (分)
     * @param totalOvertimeMinutes 該当日の総時間外労働時間 (分)
     * @param nightOvertimeMinutes 深夜かつ時間外に重複する労働時間 (分, 150%割増対象)
     * @param isStatutoryHoliday 法定休日労働該当フラグ (trueの場合35%加算)
     */
    public static DailyPayResult calculateDailyPay(
            int hourlyWage,
            int totalNetWorkMinutes,
            int totalNightMinutes,
            int totalOvertimeMinutes,
            int nightOvertimeMinutes,
            boolean isStatutoryHoliday
    ) {
        if (hourlyWage < 0 || totalNetWorkMinutes < 0 || totalNightMinutes < 0 || totalOvertimeMinutes < 0 || nightOvertimeMinutes < 0) {
            throw new IllegalArgumentException("時給および勤務時間は0以上である必要があります。");
        }
        if (totalNightMinutes > totalNetWorkMinutes || totalOvertimeMinutes > totalNetWorkMinutes) {
            throw new IllegalArgumentException("深夜または時間外労働時間が総実労働時間を超過することはできません。");
        }

        // 基本給 (100%): 時給 * 実労働分 / 60
        int basePay = yenRound(BigDecimal.valueOf(hourlyWage).multiply(BigDecimal.valueOf(totalNetWorkMinutes)), 60);

        // 法定休日割増 (35%加算): 時給 * 0.35 * 実労働分 / 60
        int holidayAllowance = 0;
        int effectiveOvertimeMinutes = totalOvertimeMinutes;
        int effectiveNightOvertimeMinutes = nightOvertimeMinutes;

        if (isStatutoryHoliday) {
            holidayAllowance = yenRound(BigDecimal.valueOf(hourlyWage).multiply(BigDecimal.valueOf(35L)).multiply(BigDecimal.valueOf(totalNetWorkMinutes)), 6000);
            // 労基法第37条第1項・通達に基づき、法定休日労働は時間外労働割増(25%)の対象外（35%休日手当または60%休日深夜手当が優先）
            effectiveOvertimeMinutes = 0;
            effectiveNightOvertimeMinutes = 0;
        }

        // 深夜割増 (25%加算): 時給 * 0.25 * 深夜分 / 60 = 時給 * 深夜分 / 240
        int nightAllowance = yenRound(BigDecimal.valueOf(hourlyWage).multiply(BigDecimal.valueOf(totalNightMinutes)), 240);

        // 時間外割増 (25%加算): 時給 * 0.25 * 残業分 / 60 = 時給 * 残業分 / 240
        int overtimeAllowance = yenRound(BigDecimal.valueOf(hourlyWage).multiply(BigDecimal.valueOf(effectiveOvertimeMinutes)), 240);

        // 深夜時間外割増 (50%重複の整合性監査用内訳): 時給 * 0.50 * 深夜残業分 / 60
        // ※ 労基法第37条の加算原則に基づき、重複分は nightAllowance(25%) と overtimeAllowance(25%) に内包されて合計50%を満たします。
        // ※ 二重計上防止のため、totalPay は独立加算された各手当の合計値として厳密に一致させます。
        int nightOvertimeAllowance = 0;
        if (effectiveNightOvertimeMinutes > 0) {
            nightOvertimeAllowance = yenRound(BigDecimal.valueOf(hourlyWage).multiply(BigDecimal.valueOf(effectiveNightOvertimeMinutes)), 120);
        }

        int totalPay = basePay + holidayAllowance + nightAllowance + overtimeAllowance;
        return new DailyPayResult(basePay, nightAllowance, overtimeAllowance, nightOvertimeAllowance, holidayAllowance, effectiveNightOvertimeMinutes, totalPay);
    }

    /**
     * 日本円の整数四捨五入 (RoundingMode.HALF_UP)
     */
    public static int yenRound(BigDecimal numerator, int denominator) {
        return numerator.divide(BigDecimal.valueOf(denominator), 0, RoundingMode.HALF_UP)
                .intValueExact();
    }
}
