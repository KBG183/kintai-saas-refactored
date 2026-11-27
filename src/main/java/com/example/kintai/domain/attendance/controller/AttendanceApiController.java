package com.example.kintai.domain.attendance.controller;

import com.example.kintai.domain.attendance.dto.*;
import com.example.kintai.domain.attendance.service.AttendanceService;
import com.example.kintai.global.common.ApiResponse;
import com.example.kintai.global.security.CustomUserDetails;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.*;

import java.util.List;

/**
 * 勤怠管理 REST API コントローラー
 */
@RestController
@RequestMapping("/api/attendance")
public class AttendanceApiController {

    private final AttendanceService attendanceService;

    public AttendanceApiController(AttendanceService attendanceService) {
        this.attendanceService = attendanceService;
    }

    /**
     * リアルタイム出退勤・休憩打刻 API
     * 認証済みスタッフの storeStaffId を優先適用し IDOR（なりすまし打刻）を防止
     */
    @PostMapping("/punch")
    public ResponseEntity<ApiResponse<AttendanceDto>> punch(
            @RequestBody AttendancePunchDto punchDto,
            @AuthenticationPrincipal CustomUserDetails userDetails
    ) {
        if (userDetails != null && userDetails.getStoreStaffId() != null) {
            punchDto.setStoreStaffId(userDetails.getStoreStaffId());
        }
        AttendanceDto result = attendanceService.punch(punchDto);
        return ResponseEntity.ok(ApiResponse.ok("打刻が完了しました。", result));
    }

    /**
     * 現在進行中の勤務実績取得 API
     */
    @GetMapping("/active")
    public ResponseEntity<ApiResponse<AttendanceDto>> getActiveAttendance(
            @RequestParam(name = "storeStaffId", required = false) Long storeStaffId,
            @AuthenticationPrincipal CustomUserDetails userDetails
    ) {
        if (userDetails == null) {
            throw new org.springframework.security.access.AccessDeniedException("認証セッションが存在しません。");
        }
        Long targetStaffId = userDetails.getStoreStaffId();
        if ("ROLE_OWNER".equals(userDetails.getRole()) && storeStaffId != null) {
            targetStaffId = storeStaffId;
        } else if (targetStaffId == null) {
            throw new org.springframework.security.access.AccessDeniedException("所属スタッフ情報が存在しません。");
        }

        AttendanceDto active = attendanceService.getActiveAttendance(targetStaffId);
        return ResponseEntity.ok(ApiResponse.ok(active));
    }

    /**
     * 勤怠修正申請登録 API（スタッフ申請）
     */
    @PostMapping("/mod-request")
    public ResponseEntity<ApiResponse<Long>> requestModification(
            @RequestBody AttendanceModRequestDto requestDto,
            @AuthenticationPrincipal CustomUserDetails userDetails
    ) {
        if (userDetails == null || userDetails.getStoreStaffId() == null) {
            throw new org.springframework.security.access.AccessDeniedException("スタッフ認証セッションが必要です。");
        }
        requestDto.setStoreStaffId(userDetails.getStoreStaffId());
        if (userDetails.getStoreId() != null) {
            requestDto.setStoreId(userDetails.getStoreId());
        }
        Long modRequestId = attendanceService.requestModification(requestDto);
        return ResponseEntity.ok(ApiResponse.ok("勤怠修正申請を受け付けました。", modRequestId));
    }

    /**
     * 勤怠修正申請一覧取得 API（店長・管理者用）
     */
    @GetMapping("/mod-requests")
    public ResponseEntity<ApiResponse<List<AttendanceModResponseDto>>> getModRequests(
            @RequestParam(name = "storeId", required = false) Long storeId,
            @RequestParam(name = "status", required = false) String status,
            @AuthenticationPrincipal CustomUserDetails userDetails
    ) {
        if (userDetails == null || !"ROLE_OWNER".equals(userDetails.getRole())) {
            throw new org.springframework.security.access.AccessDeniedException("オーナー権限が必要です。");
        }
        Long targetStoreId = (storeId != null) ? storeId : userDetails.getStoreId();
        if (targetStoreId == null) {
            throw new IllegalArgumentException("対象店舗IDが指定されていません。");
        }
        if (userDetails.getStoreId() != null && !userDetails.getStoreId().equals(targetStoreId)) {
            throw new org.springframework.security.access.AccessDeniedException("アクセス権限のない店舗です。(ID: " + targetStoreId + ")");
        }

        List<AttendanceModResponseDto> list = attendanceService.getModRequests(targetStoreId, status);
        return ResponseEntity.ok(ApiResponse.ok(list));
    }

    /**
     * 勤怠修正申請の承認・却下審査 API（店長・オーナー用）
     */
    @PostMapping("/mod-requests/{modRequestId}/review")
    public ResponseEntity<ApiResponse<Void>> reviewModification(
            @PathVariable("modRequestId") Long modRequestId,
            @RequestBody AttendanceModReviewDto reviewDto,
            @AuthenticationPrincipal CustomUserDetails userDetails
    ) {
        if (userDetails == null || !"ROLE_OWNER".equals(userDetails.getRole())) {
            throw new org.springframework.security.access.AccessDeniedException("オーナー権限が必要です。");
        }
        Long reviewerId = userDetails.getMemberId();
        attendanceService.reviewModification(modRequestId, reviewerId, reviewDto);
        return ResponseEntity.ok(ApiResponse.ok("審査処理が完了しました。", null));
    }
}
