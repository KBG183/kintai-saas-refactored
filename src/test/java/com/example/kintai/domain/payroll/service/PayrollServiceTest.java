package com.example.kintai.domain.payroll.service;

import com.example.kintai.domain.attendance.dto.AttendanceDto;
import com.example.kintai.domain.attendance.mapper.AttendanceMapper;
import com.example.kintai.domain.payroll.dto.PayrollDto;
import com.example.kintai.domain.payroll.mapper.PayrollMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.mockito.InOrder;

import java.time.DayOfWeek;
import java.time.LocalDate;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class PayrollServiceTest {

    private static final long STAFF_ID = 1L;
    private static final long STORE_ID = 1L;
    private static final String YEAR_MONTH = "2026-11";
    private static final LocalDate START = LocalDate.of(2026, 11, 1);
    private static final LocalDate END = LocalDate.of(2026, 11, 30);
    // 2026-11-24 は火曜日、2026-11-29 は日曜日
    private static final LocalDate TUESDAY = LocalDate.of(2026, 11, 24);
    private static final LocalDate SUNDAY = LocalDate.of(2026, 11, 29);

    private PayrollMapper payrollMapper;
    private AttendanceMapper attendanceMapper;
    private PayrollService service;

    @BeforeEach
    void setUp() {
        payrollMapper = mock(PayrollMapper.class);
        attendanceMapper = mock(AttendanceMapper.class);
        service = new PayrollService(payrollMapper, attendanceMapper, DayOfWeek.SUNDAY);
        when(payrollMapper.findHourlyWageForStaffOnDate(anyLong(), any())).thenReturn(1000);
    }

    private AttendanceDto attendance(LocalDate date, int netMinutes) {
        AttendanceDto att = new AttendanceDto();
        att.setStoreStaffId(STAFF_ID);
        att.setWorkDate(date);
        att.setNetWorkMinutes(netMinutes);
        att.setNightWorkMinutes(0);
        att.setOvertimeMinutes(0);
        return att;
    }

    private PayrollDto calculate(AttendanceDto att) {
        when(attendanceMapper.findCompletedAttendancesForStaffAndPeriod(STAFF_ID, START, END))
                .thenReturn(List.of(att));
        return service.calculatePayrollForStaff(STORE_ID, STAFF_ID, YEAR_MONTH, START, END);
    }

    @Test
    @DisplayName("設定した法定休日の曜日に勤務した場合、休日割増(35%)が計上される")
    void statutoryHolidayDayOfWeek_appliesHolidayAllowance() {
        // 時給1,000円 x 8時間 x 35% = 2,800円
        PayrollDto payroll = calculate(attendance(SUNDAY, 480));

        assertThat(payroll.getHolidayAllowance()).isEqualTo(2800);
    }

    @Test
    @DisplayName("法定休日以外の曜日では休日割増は計上されない")
    void nonHolidayDay_hasNoHolidayAllowance() {
        PayrollDto payroll = calculate(attendance(TUESDAY, 480));

        assertThat(payroll.getHolidayAllowance()).isZero();
    }

    @Test
    @DisplayName("月60時間超の追加割増は平日の時間外労働のみが対象であり、法定休日労働は算入されない")
    void over60HourAllowance_excludesStatutoryHolidayWork() {
        // 同一の長時間勤務(実働4,200分)を平日と法定休日で比較
        PayrollDto weekday = calculate(attendance(TUESDAY, 4200));
        PayrollDto holiday = calculate(attendance(SUNDAY, 4200));

        assertThat(weekday.getOvertimeAllowance()).isGreaterThan(0);
        // 法定休日労働は時間外累積に算入されないため、時間外手当(60h超加算を含む)は0
        assertThat(holiday.getOvertimeAllowance()).isZero();
    }

    @Test
    @DisplayName("支払処理のロック順序は store_staff -> payroll である")
    void payPayroll_locksStoreStaffBeforePayroll() {
        PayrollDto preview = new PayrollDto();
        preview.setStoreStaffId(STAFF_ID);
        PayrollDto locked = new PayrollDto();
        locked.setStoreStaffId(STAFF_ID);
        locked.setPayrollStatus("CONFIRMED");
        when(payrollMapper.findById(10L)).thenReturn(preview);
        when(payrollMapper.findByIdForUpdate(10L)).thenReturn(locked);
        when(payrollMapper.updatePayrollStatusPaid(anyLong(), any())).thenReturn(1);

        service.payPayroll(10L);

        InOrder order = inOrder(payrollMapper);
        order.verify(payrollMapper).lockStoreStaffForUpdate(STAFF_ID);
        order.verify(payrollMapper).findByIdForUpdate(10L);
    }
}
