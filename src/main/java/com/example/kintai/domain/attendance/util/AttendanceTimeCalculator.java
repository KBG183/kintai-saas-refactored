package com.example.kintai.domain.attendance.util;

import java.time.Duration;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.LocalTime;
import java.util.Collections;
import java.util.List;

public final class AttendanceTimeCalculator {

    private AttendanceTimeCalculator() {}

    public record BreakInterval(LocalDateTime startAt, LocalDateTime endAt) {
        public BreakInterval {
            if (startAt == null || endAt == null) {
                throw new IllegalArgumentException("休憩の開始・終了日時は必須です。");
            }
            if (!endAt.isAfter(startAt)) {
                throw new IllegalArgumentException("休憩終了日時は開始日時より後である必要があります。");
            }
        }
    }

    public record CalculationResult(
            int totalStayMinutes,
            int totalBreakMinutes,
            int netWorkMinutes,
            int nightWorkMinutes,
            int overtimeMinutes,
            int nightOvertimeMinutes
    ) {
        public CalculationResult(
                int totalStayMinutes,
                int totalBreakMinutes,
                int netWorkMinutes,
                int nightWorkMinutes,
                int overtimeMinutes
        ) {
            this(totalStayMinutes, totalBreakMinutes, netWorkMinutes, nightWorkMinutes, overtimeMinutes, 0);
        }
    }

    /**
     * 出退勤時刻および休憩区間一覧に基づき、実労働、深夜労働、法定時間外残業を分単位で厳密に算出
     */
    public static CalculationResult calculate(
            LocalDateTime clockInAt,
            LocalDateTime clockOutAt,
            List<BreakInterval> rawBreaks
    ) {
        if (clockInAt == null || clockOutAt == null) {
            throw new IllegalArgumentException("出勤および退勤日時は必須です。");
        }
        if (!clockOutAt.isAfter(clockInAt)) {
            throw new IllegalArgumentException("退勤日時は出勤日時より後である必要があります。");
        }

        List<BreakInterval> breaks = (rawBreaks != null) ? rawBreaks : Collections.emptyList();

        // 休憩区間の整合性検証（出退勤範囲内かつ重複禁止）
        for (int i = 0; i < breaks.size(); i++) {
            BreakInterval b = breaks.get(i);
            if (b.startAt().isBefore(clockInAt) || b.endAt().isAfter(clockOutAt)) {
                throw new IllegalArgumentException("休憩時間は勤務時間内である必要があります。");
            }
            for (int j = i + 1; j < breaks.size(); j++) {
                BreakInterval other = breaks.get(j);
                if (b.startAt().isBefore(other.endAt()) && b.endAt().isAfter(other.startAt())) {
                    throw new IllegalArgumentException("休憩時間帯同士が重複しています。");
                }
            }
        }

        int totalStayMinutes = Math.toIntExact(Duration.between(clockInAt, clockOutAt).toMinutes());
        int totalBreakMinutes = 0;
        for (BreakInterval b : breaks) {
            totalBreakMinutes = Math.addExact(totalBreakMinutes,
                    Math.toIntExact(Duration.between(b.startAt(), b.endAt()).toMinutes()));
        }

        if (totalBreakMinutes >= totalStayMinutes) {
            throw new IllegalArgumentException("休憩時間が総滞在時間以上になることはできません。");
        }

        // 分単位シミュレーションによる深夜労働・時間外・深夜残業の厳密な判定
        int workedMinutes = 0;
        int nightWorkMinutes = 0;
        int overtimeMinutes = 0;
        int nightOvertimeMinutes = 0;

        for (int m = 0; m < totalStayMinutes; m++) {
            LocalDateTime currentMinute = clockInAt.plusMinutes(m);
            LocalDateTime nextMinute = currentMinute.plusMinutes(1);

            // 当該1分が休憩区間に含まれるか判定
            boolean isBreak = false;
            for (BreakInterval b : breaks) {
                if (!currentMinute.isBefore(b.startAt()) && !nextMinute.isAfter(b.endAt())) {
                    isBreak = true;
                    break;
                }
            }

            if (!isBreak) {
                workedMinutes++;
                int hour = currentMinute.getHour();
                boolean isNight = (hour >= 22 || hour < 5);
                boolean isOvertime = (workedMinutes > 480); // 1日8時間(480分)超過

                if (isNight) {
                    nightWorkMinutes++;
                }
                if (isOvertime) {
                    overtimeMinutes++;
                }
                if (isNight && isOvertime) {
                    nightOvertimeMinutes++;
                }
            }
        }

        return new CalculationResult(
                totalStayMinutes,
                totalBreakMinutes,
                workedMinutes,
                nightWorkMinutes,
                overtimeMinutes,
                nightOvertimeMinutes
        );
    }

    /**
     * 指定区間と法定深夜時間帯（22:00 ~ 翌05:00）の重複分数を算出
     */
    private static int calculateNightMinutesInRange(LocalDateTime start, LocalDateTime end) {
        LocalDate startDate = start.toLocalDate();
        LocalDate endDate = end.toLocalDate();
        int total = 0;

        for (LocalDate d = startDate.minusDays(1); !d.isAfter(endDate.plusDays(1)); d = d.plusDays(1)) {
            LocalDateTime nightStart = LocalDateTime.of(d, LocalTime.of(22, 0));
            LocalDateTime nightEnd = LocalDateTime.of(d.plusDays(1), LocalTime.of(5, 0));

            LocalDateTime overlapStart = start.isAfter(nightStart) ? start : nightStart;
            LocalDateTime overlapEnd = end.isBefore(nightEnd) ? end : nightEnd;

            if (overlapEnd.isAfter(overlapStart)) {
                total = Math.addExact(total,
                        Math.toIntExact(Duration.between(overlapStart, overlapEnd).toMinutes()));
            }
        }
        return total;
    }
}
