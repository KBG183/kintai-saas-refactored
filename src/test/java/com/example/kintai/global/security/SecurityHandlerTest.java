package com.example.kintai.global.security;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.authentication.BadCredentialsException;

import static org.assertj.core.api.Assertions.assertThat;

class SecurityHandlerTest {

    private final CustomAccessDeniedHandler accessDeniedHandler = new CustomAccessDeniedHandler();
    private final CustomAuthenticationEntryPoint authenticationEntryPoint = new CustomAuthenticationEntryPoint();

    @ParameterizedTest
    @CsvSource({"Accept, application/json", "X-Requested-With, XMLHttpRequest"})
    @DisplayName("API認可例外(403)時にJSONエラーレスポンスが返却されること")
    void handle_api_returnsJsonForbidden(String header, String value) throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/api/payroll/summary");
        request.addHeader(header, value);
        MockHttpServletResponse response = new MockHttpServletResponse();

        accessDeniedHandler.handle(request, response, new AccessDeniedException("Forbidden"));

        assertThat(response.getStatus()).isEqualTo(403);
        assertThat(response.getContentType()).contains("application/json");
        assertThat(response.getContentAsString()).contains("\"status\":403");
        assertThat(response.getContentAsString()).contains("アクセス権限がありません");
    }

    @Test
    @DisplayName("画面リクエスト認可例外(403)時にログイン画面へリダイレクトされること")
    void handle_view_redirectsToLoginWithDeniedParam() throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/payroll");
        request.addHeader("Accept", "text/html");
        MockHttpServletResponse response = new MockHttpServletResponse();

        accessDeniedHandler.handle(request, response, new AccessDeniedException("Forbidden"));

        assertThat(response.getStatus()).isEqualTo(302);
        assertThat(response.getRedirectedUrl()).isEqualTo("/login?denied=true");
    }

    @ParameterizedTest
    @CsvSource({"Accept, 'text/html, application/json'", "X-Requested-With, XMLHttpRequest"})
    @DisplayName("API未認証例外(401)時にJSONエラーレスポンスが返却されること")
    void commence_api_returnsJsonUnauthorized(String header, String value) throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/api/attendance/status");
        request.addHeader(header, value);
        MockHttpServletResponse response = new MockHttpServletResponse();

        authenticationEntryPoint.commence(request, response, new BadCredentialsException("Unauthorized"));

        assertThat(response.getStatus()).isEqualTo(401);
        assertThat(response.getContentType()).contains("application/json");
        assertThat(response.getContentAsString())
                .isEqualTo("{\"error\":\"UNAUTHORIZED\",\"message\":\"Authentication required\"}");
    }

    @Test
    @DisplayName("画面リクエスト未認証例外(401)時にログイン画面へリダイレクトされること")
    void commence_view_redirectsToLogin() throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/attendance");
        request.addHeader("Accept", "text/html");
        MockHttpServletResponse response = new MockHttpServletResponse();

        authenticationEntryPoint.commence(request, response, new BadCredentialsException("Unauthorized"));

        assertThat(response.getStatus()).isEqualTo(302);
        assertThat(response.getRedirectedUrl()).isEqualTo("/login");
    }
}
