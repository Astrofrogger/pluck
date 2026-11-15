//! Runs the shell tests for the host packaging scripts (updater, Proxmox installer, signer, compose
//! templates). They use stub commands and a temp folder, and skip themselves when OpenSSL 3, jq or
//! python3 are missing.
use std::process::Command;

#[test]
fn packaging_scripts() {
    if Command::new("bash").arg("--version").output().is_err() {
        eprintln!("skipped: bash not found");
        return;
    }
    let dir = env!("CARGO_MANIFEST_DIR");
    let out = Command::new("bash")
        .arg("tests/scripts/run.sh")
        .current_dir(dir)
        .output()
        .expect("run bash");
    let text = String::from_utf8_lossy(&out.stdout);
    println!("{text}{}", String::from_utf8_lossy(&out.stderr));
    assert!(out.status.success(), "tests/scripts/run.sh failed:\n{text}");
}
