package com.example.kintai.domain.attendance.util;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.time.LocalDateTime;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

class AttendanceTimeCalculatorTest {

    @Test
    @DisplayName("通常日勤8時間（休憩1時間）の計算")
    void calculate_standardWork() {
        LocalDateTime clockIn = LocalDateTime.of(2026, 11, 2, 9, 0);
        LocalDateTime clockOut = LocalDateTime.of(2026, 11, 2, 18, 0);
        List<AttendanceTimeCalculator.BreakInterval> breaks = List.of(
                new AttendanceTimeCalculator.BreakInterval(
                        LocalDateTime.of(2026, 11, 2, 12, 0),
                        LocalDateTime.of(2026, 11, 2, 13, 0)
                )
        );

        AttendanceTimeCalculator.CalculationResult result = AttendanceTimeCalculator.calculate(clockIn, clockOut, breaks);

        assertThat(result.totalStayMinutes()).isEqualTo(540);
        assertThat(result.totalBreakMinutes()).isEqualTo(60);
        assertThat(result.netWorkMinutes()).isEqualTo(480);
        assertThat(result.nightWorkMinutes()).isZero();
        assertThat(result.overtimeMinutes()).isZero();
        assertThat(result.nightOvertimeMinutes()).isZero();
    }

    @Test
    @DisplayName("深夜かつ時間外重複勤務の計算（13:00〜翌01:00、実働11時間、深夜22:00〜01:00の3時間が時間外かつ深夜）")
    void calculate_nightAndOvertimeOverlap() {
        LocalDateTime clockIn = LocalDateTime.of(2026, 11, 2, 13, 0);
        LocalDateTime clockOut = LocalDateTime.of(2026, 11, 3, 1, 0);
        List<AttendanceTimeCalculator.BreakInterval> breaks = List.of(
                new AttendanceTimeCalculator.BreakInterval(
                        LocalDateTime.of(2026, 11, 2, 17, 0),
                        LocalDateTime.of(2026, 11, 2, 18, 0)
                )
        );

        AttendanceTimeCalculator.CalculationResult result = AttendanceTimeCalculator.calculate(clockIn, clockOut, breaks);

        // 滞在: 12時間(720分), 休憩: 1時間(60分), 実働: 11時間(660分)
        assertThat(result.totalStayMinutes()).isEqualTo(720);
        assertThat(result.netWorkMinutes()).isEqualTo(660);
        // 残業: 660 - 480 = 180分 (3時間)
        assertThat(result.overtimeMinutes()).isEqualTo(180);
        // 深夜: 22:00〜01:00 = 180分 (3時間)
        assertThat(result.nightWorkMinutes()).isEqualTo(180);
        // 実働8時間達成時点は 13:00 + 休憩1h + 実働8h = 22:00。したがって22:00以降の3時間は残業かつ深夜
        assertThat(result.nightOvertimeMinutes()).isEqualTo(180);
    }
}
