package com.example.kintai.domain.shift.service;

import com.example.kintai.domain.shift.dto.ShiftConfirmDto;
import com.example.kintai.domain.shift.dto.ShiftDto;
import com.example.kintai.domain.shift.mapper.ShiftMapper;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.AccessDeniedException;

import java.time.LocalDate;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ShiftServiceTest {

    @Test
    @DisplayName("IDOR防御: 他店舗のシフトは確定できず、ロック取得・更新も行われない")
    void confirmShift_rejectsShiftOfAnotherStore() {
        ShiftMapper shiftMapper = mock(ShiftMapper.class);
        ShiftService service = new ShiftService(shiftMapper);

        ShiftDto shift = new ShiftDto();
        shift.setStoreId(2L);
        shift.setStoreStaffId(5L);
        shift.setWorkDate(LocalDate.of(2026, 11, 24));
        when(shiftMapper.findById(100L)).thenReturn(shift);

        ShiftConfirmDto dto = new ShiftConfirmDto();
        dto.setConfirmedStartTime("09:00");
        dto.setConfirmedEndTime("17:00");

        // 呼び出し者の所属店舗は 1、シフトの店舗は 2
        assertThatThrownBy(() -> service.confirmShift(100L, dto, 1L))
                .isInstanceOf(AccessDeniedException.class);

        verify(shiftMapper, never()).lockStoreStaffForUpdate(anyLong());
        verify(shiftMapper, never()).updateShiftConfirm(org.mockito.ArgumentMatchers.any());
    }

    @Test
    @DisplayName("IDOR防御: 呼び出し者の店舗IDが不明な場合も拒否される")
    void confirmShift_rejectsUnknownCallerStore() {
        ShiftMapper shiftMapper = mock(ShiftMapper.class);
        ShiftService service = new ShiftService(shiftMapper);

        ShiftDto shift = new ShiftDto();
        shift.setStoreId(1L);
        when(shiftMapper.findById(100L)).thenReturn(shift);

        assertThatThrownBy(() -> service.confirmShift(100L, new ShiftConfirmDto(), null))
                .isInstanceOf(AccessDeniedException.class);
    }
}
