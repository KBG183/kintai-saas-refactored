package com.example.kintai.global.security;

import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import lombok.extern.slf4j.Slf4j;
import org.springframework.http.MediaType;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.web.access.AccessDeniedHandler;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.Collections;

/**
 * 認可例外（403 Forbidden）ハンドラー
 * REST API (application/json) と画面リクエスト (text/html) を適切に分離処理
 */
@Component
@Slf4j
public class CustomAccessDeniedHandler implements AccessDeniedHandler {

    @Override
    public void handle(
            HttpServletRequest request,
            HttpServletResponse response,
            AccessDeniedException accessDeniedException
    ) throws IOException, ServletException {
        Authentication authentication = SecurityContextHolder.getContext().getAuthentication();
        log.warn("Access denied: ip={}, uri={}, user={}, authorities={}",
                request.getRemoteAddr(), request.getRequestURI(),
                authentication == null ? "anonymous" : authentication.getName(),
                authentication == null ? Collections.emptyList() : authentication.getAuthorities());

        if (CustomAuthenticationEntryPoint.requestsJson(request)) {
            response.setStatus(HttpServletResponse.SC_FORBIDDEN);
            response.setContentType(MediaType.APPLICATION_JSON_VALUE);
            response.setCharacterEncoding(StandardCharsets.UTF_8.name());

            String jsonResponse = "{\"success\":false,\"status\":403,\"message\":\"リクエストされたリソースに対するアクセス権限がありません。\"}";
            response.getWriter().write(jsonResponse);
        } else {
            response.sendRedirect(request.getContextPath() + "/login?denied=true");
        }
    }
}
