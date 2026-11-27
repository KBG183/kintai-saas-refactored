package com.example.kintai.domain.shift.controller;

import com.example.kintai.domain.shift.dto.CalendarEventDto;
import com.example.kintai.domain.shift.dto.ShiftConfirmDto;
import com.example.kintai.domain.shift.dto.ShiftRequestDto;
import com.example.kintai.domain.shift.service.ShiftService;
import com.example.kintai.global.common.ApiResponse;
import com.example.kintai.global.security.CustomUserDetails;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.server.ResponseStatusException;

import java.time.LocalDate;
import java.util.List;

@RestController
@RequestMapping("/api/shifts")
public class ShiftApiController {

    private final ShiftService shiftService;

    public ShiftApiController(ShiftService shiftService) {
        this.shiftService = shiftService;
    }

    /**
     * 月間カレンダー用シフトイベント一覧取得
     */
    @GetMapping("/events")
    public ResponseEntity<List<CalendarEventDto>> getEvents(
            @RequestParam("storeId") Long storeId,
            @RequestParam("start") @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate start,
            @RequestParam("end") @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate end,
            @AuthenticationPrincipal CustomUserDetails userDetails
    ) {
        if (userDetails == null || userDetails.getStoreId() == null) {
            throw new ResponseStatusException(HttpStatus.UNAUTHORIZED, "認証情報が不正です。");
        }
        if (!userDetails.getStoreId().equals(storeId)) {
            throw new ResponseStatusException(HttpStatus.FORBIDDEN, "他店舗のシフトを閲覧する権限がありません。");
        }
        List<CalendarEventDto> events = shiftService.getCalendarEvents(storeId, start, end);
        return ResponseEntity.ok(events);
    }

    /**
     * スタッフによる希望シフト提出
     */
    @PostMapping("/request")
    public ResponseEntity<ApiResponse<Long>> requestShift(
            @RequestBody ShiftRequestDto requestDto,
            @AuthenticationPrincipal CustomUserDetails userDetails
    ) {
        if (userDetails == null || userDetails.getStoreStaffId() == null || userDetails.getStoreId() == null) {
            throw new ResponseStatusException(HttpStatus.UNAUTHORIZED, "認証情報が不正です。");
        }
        if (!userDetails.getStoreStaffId().equals(requestDto.getStoreStaffId())) {
            throw new ResponseStatusException(HttpStatus.FORBIDDEN, "他スタッフ名義のシフト申請は禁止されています。");
        }
        if (!userDetails.getStoreId().equals(requestDto.getStoreId())) {
            throw new ResponseStatusException(HttpStatus.FORBIDDEN, "所属外店舗へのシフト申請は禁止されています。");
        }
        Long shiftId = shiftService.requestShift(requestDto);
        return ResponseEntity.ok(ApiResponse.ok("希望シフトが登録されました。", shiftId));
    }

    /**
     * 店長によるシフト確定・更新
     */
    @PutMapping("/{shiftId}/confirm")
    public ResponseEntity<ApiResponse<Void>> confirmShift(
            @PathVariable("shiftId") Long shiftId,
            @RequestBody ShiftConfirmDto confirmDto,
            @AuthenticationPrincipal CustomUserDetails userDetails
    ) {
        if (userDetails == null || (!"OWNER".equalsIgnoreCase(userDetails.getRole())
                && !"ROLE_OWNER".equalsIgnoreCase(userDetails.getRole()))) {
            throw new ResponseStatusException(HttpStatus.FORBIDDEN, "シフト確定は管理者権限が必要です。");
        }
        shiftService.confirmShift(shiftId, confirmDto, userDetails.getStoreId());
        return ResponseEntity.ok(ApiResponse.ok("シフトが確定されました。", null));
    }
}
