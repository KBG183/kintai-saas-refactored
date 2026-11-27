package com.example.kintai.domain.payroll.service;

import com.example.kintai.domain.attendance.dto.AttendanceDto;
import com.example.kintai.domain.attendance.mapper.AttendanceMapper;
import com.example.kintai.domain.payroll.dto.*;
import com.example.kintai.domain.payroll.mapper.PayrollMapper;
import com.example.kintai.domain.payroll.util.PayrollCalculator;
import com.example.kintai.domain.payroll.util.PayrollExcelExporter;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.io.IOException;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.util.*;

@Service
@Transactional(readOnly = true)
public class PayrollService {

    private final PayrollMapper payrollMapper;
    private final AttendanceMapper attendanceMapper;

    public PayrollService(PayrollMapper payrollMapper, AttendanceMapper attendanceMapper) {
        this.payrollMapper = payrollMapper;
        this.attendanceMapper = attendanceMapper;
    }

    public List<PayrollDto> getPayrollsByStoreAndMonth(Long storeId, String targetYearMonth) {
        return payrollMapper.findPayrollsByStoreAndMonth(storeId, targetYearMonth);
    }

    /**
     * 月別給与の一括集計および計算 (Upsert)
     */
    @Transactional
    public void calculateMonthlyPayroll(Long storeId, String targetYearMonth) {
        Integer cutoffDay = payrollMapper.getPayCutoffDayByStoreId(storeId);
        int payCutoffDay = (cutoffDay != null) ? cutoffDay : 99;

        PayrollCalculator.DateRange range = PayrollCalculator.resolveDateRange(targetYearMonth, payCutoffDay);
        LocalDate startDate = range.startDate();
        LocalDate endDate = range.endDate();

        List<Long> staffIds = payrollMapper.findActiveStaffIdsByStoreId(storeId);

        for (Long staffId : staffIds) {
            calculatePayrollForStaff(storeId, staffId, targetYearMonth, startDate, endDate);
        }
    }

    @Transactional
    public PayrollDto calculatePayrollForStaff(Long storeId, Long staffId, String targetYearMonth, LocalDate startDate, LocalDate endDate) {
        // 排他制御: 同時計算競合を防止する悲観的ロック (Level 1: store_staff)
        payrollMapper.lockStoreStaffForUpdate(staffId);

        // 不変性検証: 既に確定(CONFIRMED)または支払済(PAID)の給与データが存在する場合は再計算・上書きを遮断
        PayrollDto existingPayroll = payrollMapper.findByStaffAndMonthForUpdate(staffId, targetYearMonth);
        if (existingPayroll != null && !"DRAFT".equals(existingPayroll.getPayrollStatus())) {
            throw new IllegalStateException("既に確定または支払済みの給与データは再計算・上書きできません。(状態: " + existingPayroll.getPayrollStatus() + ")");
        }

        // 未処理勤怠の確認（打刻途中や未承認申請がある場合は計算中断）
        int unresolvedCount = payrollMapper.countUnresolvedAttendance(staffId, startDate, endDate);
        if (unresolvedCount > 0) {
            throw new IllegalStateException("未承認または打刻途中の勤怠が存在するため、給与計算を中断しました。(職員ID: " + staffId + ")");
        }

        List<AttendanceDto> attendances = attendanceMapper.findCompletedAttendancesForStaffAndPeriod(staffId, startDate, endDate);

        // 通勤手当上限額（1回の精算あたりの上限）の取得
        Integer transportLimitVal = payrollMapper.findTransportLimitForStaffOnDate(staffId, endDate);
        int transportLimit = (transportLimitVal != null) ? transportLimitVal : 15000;

        int totalWorkMinutes = 0;
        int totalNightMinutes = 0;
        int totalOvertimeMinutes = 0;
        int totalBasePay = 0;
        int totalNightAllowance = 0;
        int totalOvertimeAllowance = 0;
        int totalHolidayAllowance = 0;
        int totalTransportAllowance = 0;

        Set<Integer> uniqueWages = new HashSet<>();
        Set<LocalDate> workedDates = new HashSet<>();

        List<PayrollDailyDetailDto> detailsToInsert = new ArrayList<>();

        // 分割勤務（Split Shift）対応: 同一日付の勤務をグルーピングし、1日8時間(480分)超過判定を日次累積で補正
        Map<LocalDate, List<AttendanceDto>> attendancesByDate = new LinkedHashMap<>();
        for (AttendanceDto att : attendances) {
            attendancesByDate.computeIfAbsent(att.getWorkDate(), k -> new ArrayList<>()).add(att);
        }

        // 分割勤務の時間外労働時間の再配分
        for (Map.Entry<LocalDate, List<AttendanceDto>> entry : attendancesByDate.entrySet()) {
            List<AttendanceDto> dayList = entry.getValue();
            // 出勤時刻順の厳密なソート保証 (ADV-002 欠陥是正)
            dayList.sort(java.util.Comparator.comparing(AttendanceDto::getClockInAt, java.util.Comparator.nullsLast(java.util.Comparator.naturalOrder())));
            int dayAccumulatedNet = 0;
            for (AttendanceDto att : dayList) {
                int prevAccumulated = dayAccumulatedNet;
                dayAccumulatedNet += att.getNetWorkMinutes();
                if (dayAccumulatedNet > 480) {
                    int dayOvertime = (prevAccumulated >= 480)
                            ? att.getNetWorkMinutes()
                            : (dayAccumulatedNet - 480);
                    att.setOvertimeMinutes(dayOvertime);
                } else {
                    att.setOvertimeMinutes(0);
                }
            }
        }

        for (AttendanceDto att : attendances) {
            LocalDate workDate = att.getWorkDate();
            Integer hourlyWageVal = payrollMapper.findHourlyWageForStaffOnDate(staffId, workDate);
            if (hourlyWageVal == null || hourlyWageVal <= 0) {
                throw new IllegalStateException("勤務日 (" + workDate + ") に有効な契約時給データが存在しません。");
            }
            int hourlyWage = hourlyWageVal;
            uniqueWages.add(hourlyWage);

            // 有効な契約時給 (1円以上の正数) を検証
            if (hourlyWage <= 0) {
                throw new IllegalStateException("勤務日 (" + workDate + ") の契約時給が無効です。(時給: " + hourlyWage + "円)");
            }

            boolean isStatutoryHoliday = Boolean.TRUE.equals(att.getIsStatutoryHoliday());
            int nightOvertime = (att.getOvertimeMinutes() > 0 && att.getNightWorkMinutes() > 0)
                    ? Math.min(att.getOvertimeMinutes(), att.getNightWorkMinutes())
                    : 0;

            // 6引数完全版日別計算（労基法第37条: 法定休日35%、休日深夜60%、時間外25%、深夜25%、深夜時間外50%）
            PayrollCalculator.DailyPayResult dailyPay = PayrollCalculator.calculateDailyPay(
                    hourlyWage,
                    att.getNetWorkMinutes(),
                    att.getNightWorkMinutes(),
                    att.getOvertimeMinutes(),
                    nightOvertime,
                    isStatutoryHoliday
            );

            // 1日1回通勤手当支給および月額上限枠内での配分
            int transportAmount = 0;
            if (!workedDates.contains(workDate)) {
                workedDates.add(workDate);
                Integer dailyTransportVal = payrollMapper.findDailyTransportFeeForStaffOnDate(staffId, workDate);
                int dailyTransport = (dailyTransportVal != null) ? dailyTransportVal : 0;
                int remainingLimit = Math.max(0, transportLimit - totalTransportAllowance);
                transportAmount = Math.min(dailyTransport, remainingLimit);
                totalTransportAllowance += transportAmount;
            }

            totalWorkMinutes += att.getNetWorkMinutes();
            totalNightMinutes += att.getNightWorkMinutes();
            totalOvertimeMinutes += att.getOvertimeMinutes();
            totalBasePay += dailyPay.basePay();
            totalNightAllowance += dailyPay.nightAllowance();
            totalOvertimeAllowance += dailyPay.overtimeAllowance();
            totalHolidayAllowance += dailyPay.holidayAllowance();

            PayrollDailyDetailDto detail = new PayrollDailyDetailDto();
            detail.setAttendanceId(att.getAttendanceId());
            detail.setWorkDate(workDate);
            detail.setAppliedHourlyWage(hourlyWage);
            detail.setTotalBreakMinutes(att.getTotalBreakMinutes());
            detail.setNetWorkMinutes(att.getNetWorkMinutes());
            detail.setNightWorkMinutes(att.getNightWorkMinutes());
            detail.setOvertimeMinutes(att.getOvertimeMinutes());
            detail.setNightOvertimeMinutes(dailyPay.nightOvertimeMinutes());
            detail.setIsStatutoryHoliday(isStatutoryHoliday);
            detail.setBasePay(dailyPay.basePay());
            detail.setNightAllowance(dailyPay.nightAllowance());
            detail.setOvertimeAllowance(dailyPay.overtimeAllowance());
            detail.setHolidayAllowance(dailyPay.holidayAllowance());
            detail.setTransportAmount(transportAmount);

            detailsToInsert.add(detail);
        }

        Integer appliedHourlyWage = (uniqueWages.size() == 1) ? uniqueWages.iterator().next() : null;

        // 労働基準法第37条第1項但書: 月60時間超法定時間外労働割増 (25%追加加算 = 計50%割増、深夜重複時は計75%割増/175%支給)
        // 累積3,600分 (60時間) を超える残業分に対して追加法定割増を算出（時給変更時も発生日の契約時給で正確に加算）
        int cumulativeOvertime = 0;
        int over60OvertimeAllowance = 0;
        for (AttendanceDto att : attendances) {
            int dayOvertime = (att.getOvertimeMinutes() != null) ? att.getOvertimeMinutes() : 0;
            if (dayOvertime <= 0) continue;

            Integer wageVal = payrollMapper.findHourlyWageForStaffOnDate(staffId, att.getWorkDate());
            int wage = (wageVal != null) ? wageVal : 0;
            if (wage <= 0) continue;

            int prevCumulative = cumulativeOvertime;
            cumulativeOvertime += dayOvertime;

            if (cumulativeOvertime > 3600) {
                int excessInThisDay = (prevCumulative >= 3600)
                        ? dayOvertime
                        : (cumulativeOvertime - 3600);

                int additionalAllowance = PayrollCalculator.yenRound(
                        java.math.BigDecimal.valueOf(wage).multiply(java.math.BigDecimal.valueOf(excessInThisDay)),
                        240
                );
                over60OvertimeAllowance += additionalAllowance;
            }
        }
        totalOvertimeAllowance += over60OvertimeAllowance;

        int grossPay = totalBasePay + totalNightAllowance + totalOvertimeAllowance + totalHolidayAllowance + totalTransportAllowance;

        PayrollDto payroll = new PayrollDto();
        payroll.setStoreId(storeId);
        payroll.setStoreStaffId(staffId);
        payroll.setTargetYearMonth(targetYearMonth);
        payroll.setRangeStartDate(startDate);
        payroll.setRangeEndDate(endDate);
        payroll.setWorkDaysCount(workedDates.size());
        payroll.setTotalWorkMinutes(totalWorkMinutes);
        payroll.setTotalNightMinutes(totalNightMinutes);
        payroll.setTotalOvertimeMinutes(totalOvertimeMinutes);
        payroll.setAppliedHourlyWage(appliedHourlyWage);
        payroll.setAppliedTransportLimit(transportLimit);
        payroll.setBasePay(totalBasePay);
        payroll.setNightAllowance(totalNightAllowance);
        payroll.setOvertimeAllowance(totalOvertimeAllowance);
        payroll.setHolidayAllowance(totalHolidayAllowance);
        payroll.setTransportAllowance(totalTransportAllowance);
        payroll.setGrossPay(grossPay);
        payroll.setPayrollStatus("DRAFT");

        payrollMapper.upsertPayroll(payroll);

        // 日別詳細スナップショットの再保存
        payrollMapper.deleteDailyDetailsByPayrollId(payroll.getPayrollId());
        for (PayrollDailyDetailDto detail : detailsToInsert) {
            detail.setPayrollId(payroll.getPayrollId());
            payrollMapper.insertPayrollDailyDetail(detail);
        }

        return payroll;
    }

    /**
     * 給与確定ロック処理（帳簿の不変性を保証）
     */
    @Transactional
    public void confirmPayroll(Long payrollId, PayrollConfirmRequestDto confirmDto) {
        // 排他制御: 先行して行ロック(FOR UPDATE)を獲得
        PayrollDto existing = payrollMapper.findByIdForUpdate(payrollId);
        if (existing == null) {
            throw new IllegalArgumentException("存在しない給与データです。(ID: " + payrollId + ")");
        }

        // 階層型排他制御: store_staff ロック
        payrollMapper.lockStoreStaffForUpdate(existing.getStoreStaffId());

        // ロック獲得後の最新ステータス検証
        if (!"DRAFT".equals(existing.getPayrollStatus())) {
            throw new IllegalStateException("既に確定済みの給与データです。");
        }

        // 精算対象期間終了の検証（締め期間終了前の早期確定を防止, JSTタイムゾーン基準）
        LocalDate todayJst = LocalDate.now(ZoneId.of("Asia/Tokyo"));
        if (!todayJst.isAfter(existing.getRangeEndDate())) {
            throw new IllegalStateException("精算対象期間 (" + existing.getRangeEndDate() + ") が終了する前に給与を確定することはできません。");
        }

        // 未処理勤怠の確認
        int unresolved = payrollMapper.countUnresolvedAttendance(existing.getStoreStaffId(), existing.getRangeStartDate(), existing.getRangeEndDate());
        if (unresolved > 0) {
            throw new IllegalStateException("未処理の勤怠修正申請または勤務中打刻が存在するため、確定できません。");
        }

        // 最新データによる再計算
        PayrollDto recalculated = calculatePayrollForStaff(
                existing.getStoreId(),
                existing.getStoreStaffId(),
                existing.getTargetYearMonth(),
                existing.getRangeStartDate(),
                existing.getRangeEndDate()
        );

        // 店長が確認した金額と再計算金額の不一致チェック
        if (confirmDto != null && confirmDto.getExpectedGrossPay() != null) {
            int expected = confirmDto.getExpectedGrossPay();
            int actual = recalculated.getGrossPay();
            if (expected != actual) {
                throw new IllegalStateException("確認時と金額が一致しません。(確認額: " + expected + "円, 再計算額: " + actual + "円)。再確認が必要です。");
            }
        }

        payrollMapper.updatePayrollStatusConfirm(payrollId, LocalDateTime.now());
    }

    /**
     * 給与支払確定処理 (Level 1: store_staff -> Level 2: payroll の階層型ロック保証)
     */
    @Transactional
    public void payPayroll(Long payrollId) {
        // 排他制御: 先行して行ロック(FOR UPDATE)を獲得
        PayrollDto existing = payrollMapper.findByIdForUpdate(payrollId);
        if (existing == null) {
            throw new IllegalArgumentException("存在しない給与データです。(ID: " + payrollId + ")");
        }

        // 階層型排他制御: Level 1 store_staff ロック
        payrollMapper.lockStoreStaffForUpdate(existing.getStoreStaffId());

        // ロック獲得後の最新ステータス検証
        if (!"CONFIRMED".equals(existing.getPayrollStatus())) {
            throw new IllegalStateException("確定(CONFIRMED)状態の給与データのみ支払処理が可能です。(現在の状態: " + existing.getPayrollStatus() + ")");
        }

        int updated = payrollMapper.updatePayrollStatusPaid(payrollId, LocalDateTime.now());
        if (updated == 0) {
            throw new IllegalStateException("給与支払ステータスの更新に失敗しました。既に支払済か競合が発生しています。(ID: " + payrollId + ")");
        }
    }

    /**
     * スタッフ個人別給与明細詳細モーダル用データ取得
     */
    public PayrollDetailResponseDto getPayrollDetail(Long payrollId) {
        PayrollDto payroll = payrollMapper.findById(payrollId);
        if (payroll == null) {
            throw new IllegalArgumentException("存在しない給与データです。(ID: " + payrollId + ")");
        }

        List<PayrollDailyDetailDto> details = payrollMapper.findDailyDetailsByPayrollId(payrollId);

        PayrollDetailResponseDto response = new PayrollDetailResponseDto();
        response.setPayrollId(payroll.getPayrollId());
        response.setStoreId(payroll.getStoreId());
        response.setStoreStaffId(payroll.getStoreStaffId());
        response.setStaffName(payroll.getStaffName());
        response.setTargetYearMonth(payroll.getTargetYearMonth());
        response.setAppliedHourlyWage(payroll.getAppliedHourlyWage());

        PayrollDetailResponseDto.PayrollSummary summary = new PayrollDetailResponseDto.PayrollSummary();
        summary.setWorkDaysCount(payroll.getWorkDaysCount());
        summary.setTotalWorkMinutes(payroll.getTotalWorkMinutes());
        summary.setTotalNightMinutes(payroll.getTotalNightMinutes());
        summary.setTotalOvertimeMinutes(payroll.getTotalOvertimeMinutes());
        summary.setBasePay(payroll.getBasePay());
        summary.setNightAllowance(payroll.getNightAllowance());
        summary.setOvertimeAllowance(payroll.getOvertimeAllowance());
        summary.setTransportAllowance(payroll.getTransportAllowance());
        summary.setGrossPay(payroll.getGrossPay());
        summary.setPayrollStatus(payroll.getPayrollStatus());
        response.setSummary(summary);

        DateTimeFormatter timeFormatter = DateTimeFormatter.ofPattern("HH:mm");
        List<PayrollDetailResponseDto.DailyAttendanceDetail> dailyList = new ArrayList<>();

        for (PayrollDailyDetailDto d : details) {
            PayrollDetailResponseDto.DailyAttendanceDetail daily = new PayrollDetailResponseDto.DailyAttendanceDetail();
            daily.setWorkDate(d.getWorkDate().toString());
            daily.setBreakMinutes(d.getTotalBreakMinutes());
            daily.setNetWorkMinutes(d.getNetWorkMinutes());
            daily.setNightMinutes(d.getNightWorkMinutes());
            daily.setOvertimeMinutes(d.getOvertimeMinutes());
            daily.setAppliedHourlyWage(d.getAppliedHourlyWage());
            daily.setBasePay(d.getBasePay());
            daily.setNightAllowance(d.getNightAllowance());
            daily.setOvertimeAllowance(d.getOvertimeAllowance());
            daily.setTransportAmount(d.getTransportAmount());

            // 元勤怠データから打刻時刻情報を補完
            AttendanceDto originalAtt = attendanceMapper.findById(d.getAttendanceId());
            if (originalAtt != null) {
                daily.setClockInAt(originalAtt.getClockInAt() != null ? originalAtt.getClockInAt().format(timeFormatter) : "-");
                daily.setClockOutAt(originalAtt.getClockOutAt() != null ? originalAtt.getClockOutAt().format(timeFormatter) : "-");
            } else {
                daily.setClockInAt("-");
                daily.setClockOutAt("-");
            }

            dailyList.add(daily);
        }

        response.setDailyAttendances(dailyList);
        return response;
    }

    /**
     * 給与台帳 Excel エクスポート
     */
    public byte[] exportPayrollToExcel(Long storeId, String targetYearMonth) throws IOException {
        List<PayrollDto> payrolls = getPayrollsByStoreAndMonth(storeId, targetYearMonth);
        return PayrollExcelExporter.exportToExcel(targetYearMonth, payrolls);
    }
}
