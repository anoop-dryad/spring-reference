CREATE TABLE IF NOT EXISTS auth.users (
    id BIGSERIAL PRIMARY KEY,
    username VARCHAR(50) UNIQUE NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    password VARCHAR(255) NOT NULL,
    role VARCHAR(30) NOT NULL DEFAULT 'USER',
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

INSERT INTO auth.users (username, email, password, role)
VALUES
  ('admin', 'admin@dryad.com', '$2a$10$6sHnM3Mo84vSEJkmdIqkJOdsh0ixLDHjcfbYPuqR0HSaCJMH88rVW', 'ADMIN'),
  ('user', 'user@dryad.com', '$2a$10$2J5IqJPsAgad9Jr39f0NLe6KRzgUsE3ItVB85NhlA0DAQI4dHJRA6', 'USER')
ON CONFLICT DO NOTHING;