--liquibase formatted sql

--changeset homechat:002
CREATE INDEX idx_users_username ON users(username);

--changeset homechat:002 rollback
DROP INDEX idx_users_username;

