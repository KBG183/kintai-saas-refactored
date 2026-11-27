package com.example.kintai.config;

import com.example.kintai.global.security.CustomAccessDeniedHandler;
import com.example.kintai.global.security.CustomAuthenticationEntryPoint;
import com.example.kintai.global.security.CustomAuthenticationSuccessHandler;
import com.example.kintai.global.security.CustomUserDetailsService;
import lombok.RequiredArgsConstructor;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.authentication.AuthenticationManager;
import org.springframework.security.config.annotation.authentication.builders.AuthenticationManagerBuilder;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.security.web.SecurityFilterChain;

import org.springframework.security.web.session.HttpSessionEventPublisher;

/**
 * Spring Security 6 セキュリティ設定クラス
 * セッションベースの認証・権限管理およびアクセス制御を統合設定
 */
@Configuration
@EnableWebSecurity
@EnableMethodSecurity(prePostEnabled = true)
@RequiredArgsConstructor
public class SecurityConfig {

    private final CustomUserDetailsService userDetailsService;
    private final CustomAuthenticationSuccessHandler successHandler;
    private final CustomAccessDeniedHandler accessDeniedHandler;
    private final CustomAuthenticationEntryPoint authenticationEntryPoint;

    @Bean
    public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
        http
                // REST API および SPA/Fetch API との連携を考慮した Cookie ベースの CSRF 保護
                .csrf(csrf -> csrf
                        .csrfTokenRepository(org.springframework.security.web.csrf.CookieCsrfTokenRepository.withHttpOnlyFalse())
                )
                .authorizeHttpRequests(auth -> auth
                        // 静的リソースおよび認証関連エンドポイントの開放
                        .requestMatchers(
                                "/css/**",
                                "/js/**",
                                "/images/**",
                                "/favicon.ico"
                        ).permitAll()
                        // オーナー専用エンドポイント（給与計算、勤怠修正承認、シフト確定、会員管理等）
                        .requestMatchers(
                                "/payroll/**",
                                "/api/payroll/**",
                                "/attendance/mod-requests/**",
                                "/api/attendance/mod-requests/**",
                                "/api/shifts/*/confirm",
                                "/members/**",
                                "/api/members/**"
                        ).hasRole("OWNER")
                        // 勤怠打刻およびシフト管理（スタッフ・オーナー共通）
                        .requestMatchers(
                                "/attendance",
                                "/attendance/**",
                                "/shifts",
                                "/shifts/**",
                                "/api/attendance/**",
                                "/api/shifts/**"
                        ).hasAnyRole("STAFF", "OWNER")
                        // その他の全リクエストは認証必須
                        .anyRequest().authenticated()
                )
                // フォームログイン設定
                .formLogin(login -> login
                        .loginPage("/login")
                        .loginProcessingUrl("/login-process")
                        .usernameParameter("email")
                        .passwordParameter("password")
                        .successHandler(successHandler)
                        .failureUrl("/login?error=true")
                        .permitAll()
                )
                // ログアウト設定
                .logout(logout -> logout
                        .logoutUrl("/logout")
                        .logoutSuccessUrl("/login?logout=true")
                        .clearAuthentication(true)
                        .invalidateHttpSession(true)
                        .deleteCookies("JSESSIONID")
                        .permitAll()
                )
                // 認証・認可例外ハンドリング（API/画面に応じた動的分離）
                .exceptionHandling(ex -> ex
                        .accessDeniedHandler(accessDeniedHandler)
                        .authenticationEntryPoint(authenticationEntryPoint)
                )
                // セッション管理設定
                .sessionManagement(session -> session
                        .maximumSessions(2)
                        .maxSessionsPreventsLogin(true)
                );

        return http.build();
    }

    @Bean
    public PasswordEncoder passwordEncoder() {
        return new BCryptPasswordEncoder();
    }

    /**
     * セッション破棄イベントを検知し、ConcurrentSessionControlAuthenticationStrategyへ通知するBean
     */
    @Bean
    public HttpSessionEventPublisher httpSessionEventPublisher() {
        return new HttpSessionEventPublisher();
    }
}
