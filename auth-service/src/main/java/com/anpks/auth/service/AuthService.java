package com.anpks.auth.service;

import org.springframework.security.authentication.BadCredentialsException;
import org.springframework.stereotype.Service;

import com.anpks.auth.dto.LoginRequest;
import com.anpks.auth.dto.LoginResponse;
import com.anpks.auth.model.User;
import com.anpks.auth.repository.UserRepository;
import org.springframework.security.crypto.password.PasswordEncoder;
import lombok.RequiredArgsConstructor;

@Service
@RequiredArgsConstructor
public class AuthService {

    private final UserRepository userRepository;
    private final PasswordEncoder passwordEncoder;

    public LoginResponse login(LoginRequest request) {
        User user = userRepository.findByUsername(request.getUsername())
                .orElseThrow(() -> new BadCredentialsException("Invalid username or Password"));
        if (!passwordEncoder.matches(request.getPassword(), user.getPassword())) {
            throw new BadCredentialsException("Invalid username or password");
        }
        String token = "";
        return new LoginResponse(token, user.getUsername(), user.getRole().name(), 123456);
    }

}
