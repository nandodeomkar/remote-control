//! Embeds the Windows exe icon + VERSIONINFO (branding, quick 260716-ns1).
//!
//! Gated on the TARGET os (`CARGO_CFG_TARGET_OS`, not `cfg!(target_os)` —
//! build scripts compile for the HOST) so a hypothetical cross-compile of
//! the workspace never trips rc.exe. `server-core` has no build.rs and is
//! untouched; CI Linux compiles server-core only.

fn main() {
    println!("cargo:rerun-if-changed=assets/icon/icon.ico");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        winresource::WindowsResource::new()
            .set_icon("assets/icon/icon.ico")
            .set("ProductName", "Remote Control")
            .set("FileDescription", "Remote Control")
            .compile()
            .expect("winresource: failed to embed exe icon/VERSIONINFO");
    }
}
