//! build — 构建脚本
//!
//! `sqlx::migrate!` 在稳定版 Rust 上不会自动登记迁移目录的变更检测：
//! 新增/修改 .sql 迁移文件不会触发重编译，嵌入的二进制仍是旧迁移集。
//! 此脚本显式声明 rerun-if-changed，迁移目录任何变动都会重编译 orbit_core。
fn main() {
    println!("cargo:rerun-if-changed=src/db/migrations");
}
