package com.example.kintai.domain.payroll.controller;

import com.example.kintai.domain.payroll.dto.PayrollCalculateRequestDto;
import com.example.kintai.domain.payroll.dto.PayrollConfirmRequestDto;
import com.example.kintai.domain.payroll.dto.PayrollDetailResponseDto;
import com.example.kintai.domain.payroll.dto.PayrollDto;
import com.example.kintai.domain.payroll.service.PayrollService;
import com.example.kintai.global.common.ApiResponse;
import com.example.kintai.global.security.CustomUserDetails;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.*;

import java.io.IOException;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.List;

@RestController
@RequestMapping("/api/payroll")
public class PayrollApiController {

    private final PayrollService payrollService;

    public PayrollApiController(PayrollService payrollService) {
        this.payrollService = payrollService;
    }

    /**
     * 月別給与一覧取得
     */
    @GetMapping("/list")
    public ResponseEntity<ApiResponse<List<PayrollDto>>> getPayrollList(
            @RequestParam("storeId") Long storeId,
            @RequestParam("yearMonth") String yearMonth,
            @AuthenticationPrincipal CustomUserDetails userDetails
    ) {
        validateStoreOwnerAccess(userDetails, storeId);
        List<PayrollDto> list = payrollService.getPayrollsByStoreAndMonth(storeId, yearMonth);
        return ResponseEntity.ok(ApiResponse.ok("給与一覧を取得しました。", list));
    }

    /**
     * 月別給与一括計算 (Upsert)
     */
    @PostMapping("/calculate")
    public ResponseEntity<ApiResponse<Void>> calculateMonthlyPayroll(
            @RequestBody PayrollCalculateRequestDto requestDto,
            @AuthenticationPrincipal CustomUserDetails userDetails
    ) {
        validateStoreOwnerAccess(userDetails, requestDto.getStoreId());
        payrollService.calculateMonthlyPayroll(requestDto.getStoreId(), requestDto.getTargetYearMonth());
        return ResponseEntity.ok(ApiResponse.ok("給与計算が完了しました。", null));
    }

    /**
     * 給与確定処理 (帳簿ロック・排他制御適用)
     */
    @PostMapping("/{payrollId}/confirm")
    public ResponseEntity<ApiResponse<Void>> confirmPayroll(
            @PathVariable("payrollId") Long payrollId,
            @RequestBody(required = false) PayrollConfirmRequestDto confirmDto,
            @AuthenticationPrincipal CustomUserDetails userDetails
    ) {
        validatePayrollAccess(userDetails, payrollId);
        payrollService.confirmPayroll(payrollId, confirmDto);
        return ResponseEntity.ok(ApiResponse.ok("給与が確定されました。", null));
    }

    /**
     * スタッフ個人別給与明細詳細取得 (日別勤怠および計算内訳)
     */
    @GetMapping("/{payrollId}/detail")
    public ResponseEntity<ApiResponse<PayrollDetailResponseDto>> getPayrollDetail(
            @PathVariable("payrollId") Long payrollId,
            @AuthenticationPrincipal CustomUserDetails userDetails
    ) {
        validatePayrollAccess(userDetails, payrollId);
        PayrollDetailResponseDto detail = payrollService.getPayrollDetail(payrollId);
        return ResponseEntity.ok(ApiResponse.ok("給与明細詳細を取得しました。", detail));
    }

    /**
     * 給与台帳 Excel エクスポート
     */
    @GetMapping("/excel")
    public ResponseEntity<byte[]> downloadExcel(
            @RequestParam("storeId") Long storeId,
            @RequestParam("yearMonth") String yearMonth,
            @AuthenticationPrincipal CustomUserDetails userDetails
    ) throws IOException {
        validateStoreOwnerAccess(userDetails, storeId);
        byte[] excelBytes = payrollService.exportPayrollToExcel(storeId, yearMonth);

        String fileName = URLEncoder.encode("給与台帳_" + yearMonth + ".xlsx", StandardCharsets.UTF_8).replace("+", "%20");

        return ResponseEntity.ok()
                .header(HttpHeaders.CONTENT_DISPOSITION, "attachment; filename=\"" + fileName + "\"; filename*=UTF-8''" + fileName)
                .contentType(MediaType.parseMediaType("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"))
                .body(excelBytes);
    }

    private void validateStoreOwnerAccess(CustomUserDetails userDetails, Long storeId) {
        if (userDetails == null || !"ROLE_OWNER".equals(userDetails.getRole())) {
            throw new AccessDeniedException("オーナー権限が必要です。");
        }
        if (userDetails.getStoreId() != null && !userDetails.getStoreId().equals(storeId)) {
            throw new AccessDeniedException("アクセス権限のない店舗です。(ID: " + storeId + ")");
        }
    }

    private void validatePayrollAccess(CustomUserDetails userDetails, Long payrollId) {
        if (userDetails == null) {
            throw new AccessDeniedException("認証が必要です。");
        }
        PayrollDetailResponseDto detail = payrollService.getPayrollDetail(payrollId);
        if (detail == null) {
            throw new IllegalArgumentException("存在しない給与データです。(ID: " + payrollId + ")");
        }
        Long payrollStoreId = detail.getStoreId();
        Long staffId = detail.getStoreStaffId();

        if ("ROLE_OWNER".equals(userDetails.getRole())) {
            if (userDetails.getStoreId() != null && !userDetails.getStoreId().equals(payrollStoreId)) {
                throw new AccessDeniedException("他店舗の給与データにはアクセスできません。");
            }
        } else {
            if (userDetails.getStoreStaffId() == null || !userDetails.getStoreStaffId().equals(staffId)) {
                throw new AccessDeniedException("他スタッフの給与明細にはアクセスできません。");
            }
        }
    }
}
