package com.example.kintai.global.security;

import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.http.MediaType;
import org.springframework.security.core.AuthenticationException;
import org.springframework.security.web.AuthenticationEntryPoint;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.Locale;

/**
 * 未認証例外（401 Unauthorized）エントリーポイント
 * REST API (application/json) と画面リクエスト (text/html) を適切に分離処理
 */
@Component
public class CustomAuthenticationEntryPoint implements AuthenticationEntryPoint {

    @Override
    public void commence(
            HttpServletRequest request,
            HttpServletResponse response,
            AuthenticationException authException
    ) throws IOException, ServletException {
        if (requestsJson(request)) {
            response.setStatus(HttpServletResponse.SC_UNAUTHORIZED);
            response.setContentType(MediaType.APPLICATION_JSON_VALUE);
            response.setCharacterEncoding(StandardCharsets.UTF_8.name());

            String jsonResponse = "{\"error\":\"UNAUTHORIZED\",\"message\":\"Authentication required\"}";
            response.getWriter().write(jsonResponse);
        } else {
            response.sendRedirect(request.getContextPath() + "/login");
        }
    }

    static boolean requestsJson(HttpServletRequest request) {
        return "XMLHttpRequest".equalsIgnoreCase(request.getHeader("X-Requested-With"))
                || Collections.list(request.getHeaders("Accept")).stream()
                        .anyMatch(value -> value.toLowerCase(Locale.ROOT).contains(MediaType.APPLICATION_JSON_VALUE));
    }
}
