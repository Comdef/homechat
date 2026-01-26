--liquibase formatted sql

--changeset homechat:001
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    id_keyclock UUID UNIQUE,
    username VARCHAR(255) NOT NULL,
    email VARCHAR(255),
    first_name VARCHAR(255),
    last_name VARCHAR(255),
    enabled BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT now(),
    updated_at TIMESTAMP DEFAULT now()
);

--changeset homechat:001 rollback
DROP TABLE users;

