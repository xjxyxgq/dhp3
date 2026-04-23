-- Grants dumped by pt-show-grants
-- Dumped from server 127.0.0.1 via TCP/IP, MySQL 5.7.32-debug-log at 2026-04-23 17:07:13
-- Grants for 'mydbs'@'%'
CREATE USER IF NOT EXISTS 'mydbs'@'%';
ALTER USER 'mydbs'@'%' IDENTIFIED WITH 'mysql_native_password' AS '*7FF42A04A02A44D9E1E7035FA45C39F41AA3ED71' REQUIRE NONE PASSWORD EXPIRE DEFAULT ACCOUNT UNLOCK;
GRANT USAGE ON *.* TO 'mydbs'@'%';
-- Grants for 'mysql.session'@'localhost'
CREATE USER IF NOT EXISTS 'mysql.session'@'localhost';
ALTER USER 'mysql.session'@'localhost' IDENTIFIED WITH 'mysql_native_password' AS '*THISISNOTAVALIDPASSWORDTHATCANBEUSEDHERE' REQUIRE NONE PASSWORD EXPIRE DEFAULT ACCOUNT LOCK;
GRANT SELECT ON `mysql`.`user` TO 'mysql.session'@'localhost';
GRANT SELECT ON `performance_schema`.* TO 'mysql.session'@'localhost';
GRANT SUPER ON *.* TO 'mysql.session'@'localhost';
-- Grants for 'mysql.sys'@'localhost'
CREATE USER IF NOT EXISTS 'mysql.sys'@'localhost';
ALTER USER 'mysql.sys'@'localhost' IDENTIFIED WITH 'mysql_native_password' AS '*THISISNOTAVALIDPASSWORDTHATCANBEUSEDHERE' REQUIRE NONE PASSWORD EXPIRE DEFAULT ACCOUNT LOCK;
GRANT SELECT ON `sys`.`sys_config` TO 'mysql.sys'@'localhost';
GRANT TRIGGER ON `sys`.* TO 'mysql.sys'@'localhost';
GRANT USAGE ON *.* TO 'mysql.sys'@'localhost';
-- Grants for 'mytest'@'123.1.1.1'
CREATE USER IF NOT EXISTS 'mytest'@'123.1.1.1';
ALTER USER 'mytest'@'123.1.1.1' IDENTIFIED WITH 'mysql_native_password' AS '*AB03CD8F75DC2E2E3B16FF7824323A34A356EAD2' REQUIRE NONE PASSWORD EXPIRE DEFAULT ACCOUNT UNLOCK;
GRANT USAGE ON *.* TO 'mytest'@'123.1.1.1';
-- Grants for 'myuser'@'%'
CREATE USER IF NOT EXISTS 'myuser'@'%';
ALTER USER 'myuser'@'%' IDENTIFIED WITH 'mysql_native_password' AS '*CBA73BBE5D9AF59311C3F4D7E8C20AA847F7B188' REQUIRE NONE PASSWORD EXPIRE DEFAULT ACCOUNT UNLOCK;
GRANT ALL PRIVILEGES ON `cmdb2`.* TO 'myuser'@'%';
GRANT ALL PRIVILEGES ON `purchasing`.* TO 'myuser'@'%';
GRANT USAGE ON *.* TO 'myuser'@'%';
-- Grants for 'root'@'%'
CREATE USER IF NOT EXISTS 'root'@'%';
ALTER USER 'root'@'%' IDENTIFIED WITH 'mysql_native_password' AS '*8D2A927C3052BCB1AB130AE5732F7D79B3CFACF7' REQUIRE NONE PASSWORD EXPIRE DEFAULT ACCOUNT UNLOCK;
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
-- Grants for 'root'@'localhost'
CREATE USER IF NOT EXISTS 'root'@'localhost';
ALTER USER 'root'@'localhost' IDENTIFIED WITH 'mysql_native_password' REQUIRE NONE PASSWORD EXPIRE DEFAULT ACCOUNT UNLOCK;
GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION;
GRANT PROXY ON ''@'' TO 'root'@'localhost' WITH GRANT OPTION;
-- Grants for 'xgq'@'%'
CREATE USER IF NOT EXISTS 'xgq'@'%';
ALTER USER 'xgq'@'%' IDENTIFIED WITH 'mysql_native_password' AS '*79647B39C88D7C8E07BB316796ACB3536FC764B4' REQUIRE NONE PASSWORD EXPIRE DEFAULT ACCOUNT UNLOCK;
GRANT ALL PRIVILEGES ON *.* TO 'xgq'@'%';
