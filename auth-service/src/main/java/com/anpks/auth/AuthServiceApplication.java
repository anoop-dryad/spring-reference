package com.anpks.auth;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;

@SpringBootApplication
public class AuthServiceApplication {

	public static void main(String[] args) {
		System.out.println("password ::: " + new BCryptPasswordEncoder().encode("OpTAZdAhOopNfyF6AKwP"));
		SpringApplication.run(AuthServiceApplication.class, args);
	}

}
