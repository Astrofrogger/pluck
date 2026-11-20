// pluck-relay: starts iroh-relay (the same iroh version as Helpers/PluckIroh) for an office's own relay, with a
// config made from environment variables Pluck fills into the compose file. It never starts an open relay: the
// access is always an allowlist of node ids, TLS is always on, and nothing listens on port 80.
//
//   PLUCK_RELAY_HOSTNAME  the relay's (sub)domain, pointed at the office's public IP         (required)
//   PLUCK_RELAY_ALLOW     node ids allowed to use it, comma separated (64 hex characters)     (required, not empty)
//   PLUCK_RELAY_TLS       "acme" (default: Let's Encrypt over TLS-ALPN on 443, no port 80) or
//                         "files" (certificates a DNS-challenge sidecar writes to /certs/certificates)
//   PLUCK_RELAY_CONTACT   e-mail for Let's Encrypt                                            (required for acme)
//   PLUCK_RELAY_STAGING   "1": Let's Encrypt's staging server (tests)
//
// Inside the container: https on 8443, the QUIC address discovery on 7842/udp, the captive-portal http (which
// iroh-relay always starts) on 8080, which the compose file never publishes.
use std::{collections::HashMap, os::unix::process::CommandExt, process::Command};

const CONFIG: &str = "/tmp/iroh-relay.toml";

fn main() {
    let env: HashMap<String, String> = std::env::vars().collect();
    match config(&env) {
        Ok(toml) => {
            if let Err(e) = std::fs::write(CONFIG, toml) {
                eprintln!("pluck-relay: can't write the config: {e}");
                std::process::exit(1);
            }
            let e = Command::new("/usr/local/bin/iroh-relay").args(["--config-path", CONFIG]).exec();
            eprintln!("pluck-relay: can't start iroh-relay: {e}");
            std::process::exit(1);
        }
        Err(e) => {
            eprintln!("pluck-relay: {e}");
            std::process::exit(2);
        }
    }
}

fn is_node_id(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit())
}

fn is_hostname(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 253
        && s.contains('.')
        && s.split('.').all(|l| !l.is_empty() && l.len() <= 63 && !l.starts_with('-') && !l.ends_with('-')
            && l.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-'))
}

fn is_email(s: &str) -> bool {
    let mut parts = s.splitn(2, '@');
    matches!((parts.next(), parts.next()), (Some(a), Some(d)) if !a.is_empty() && is_hostname(d)
        && !s.contains(['"', '\\', '\n', '\r', ' ']))
}

/// iroh-relay's TOML (field names checked against iroh-relay 1.4.1's src/main.rs `Config` / `TlsConfig`).
fn config(env: &HashMap<String, String>) -> Result<String, String> {
    let get = |k: &str| env.get(k).map(|v| v.trim().to_string()).unwrap_or_default();
    let host = get("PLUCK_RELAY_HOSTNAME").to_ascii_lowercase();
    if !is_hostname(&host) {
        return Err("PLUCK_RELAY_HOSTNAME must be a domain name".into());
    }
    let mut allow: Vec<String> = get("PLUCK_RELAY_ALLOW")
        .split(',')
        .map(|s| s.trim().to_ascii_lowercase())
        .filter(|s| !s.is_empty())
        .collect();
    if allow.is_empty() {
        return Err("PLUCK_RELAY_ALLOW is empty: an open relay is never started".into());
    }
    if let Some(bad) = allow.iter().find(|s| !is_node_id(s)) {
        return Err(format!("not a node id: {bad}"));
    }
    allow.sort();
    allow.dedup();
    let tls = match get("PLUCK_RELAY_TLS").as_str() {
        "" | "acme" => {
            let contact = get("PLUCK_RELAY_CONTACT");
            if !is_email(&contact) {
                return Err("PLUCK_RELAY_CONTACT must be an e-mail address for Let's Encrypt".into());
            }
            let prod = get("PLUCK_RELAY_STAGING") != "1";
            format!("cert_mode = \"LetsEncrypt\"\ncert_dir = \"/certs\"\ncontact = \"{contact}\"\nprod_tls = {prod}\n")
        }
        "files" => format!(
            "cert_mode = \"Reloading\"\nmanual_cert_path = \"/certs/certificates/{host}.crt\"\nmanual_key_path = \"/certs/certificates/{host}.key\"\n"
        ),
        other => return Err(format!("PLUCK_RELAY_TLS must be acme or files, not {other}")),
    };
    let ids = allow.iter().map(|s| format!("\"{s}\"")).collect::<Vec<_>>().join(", ");
    Ok(format!(
        "enable_relay = true\nhttp_bind_addr = \"[::]:8080\"\nenable_quic_addr_discovery = true\nenable_metrics = false\n\n\
         [tls]\nhttps_bind_addr = \"[::]:8443\"\nquic_bind_addr = \"[::]:7842\"\nhostname = \"{host}\"\n{tls}\n\
         [access]\nallowlist = [{ids}]\n"
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    const A: &str = "aa00000000000000000000000000000000000000000000000000000000000001";
    const B: &str = "BB00000000000000000000000000000000000000000000000000000000000002";

    fn env(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
    }

    #[test]
    fn acme_with_allowlist() {
        let c = config(&env(&[("PLUCK_RELAY_HOSTNAME", "Relay.Example.com"), ("PLUCK_RELAY_ALLOW", &format!("{B}, {A},{A}")),
                              ("PLUCK_RELAY_CONTACT", "owner@example.com")])).unwrap();
        assert!(c.contains("hostname = \"relay.example.com\""));
        assert!(c.contains("cert_mode = \"LetsEncrypt\""));
        assert!(c.contains("prod_tls = true"));
        assert!(c.contains(&format!("allowlist = [\"{A}\", \"{}\"]", B.to_ascii_lowercase())));
        assert!(c.contains("https_bind_addr = \"[::]:8443\"") && c.contains("quic_bind_addr = \"[::]:7842\""));
        assert!(!c.contains(":80\""), "nothing on port 80");
        assert!(!c.contains("everyone"));
    }

    #[test]
    fn files_mode_reads_the_sidecars_certificates() {
        let c = config(&env(&[("PLUCK_RELAY_HOSTNAME", "relay.example.com"), ("PLUCK_RELAY_ALLOW", A), ("PLUCK_RELAY_TLS", "files")])).unwrap();
        assert!(c.contains("cert_mode = \"Reloading\""));
        assert!(c.contains("/certs/certificates/relay.example.com.crt"));
    }

    #[test]
    fn refuses_what_would_be_open_or_broken() {
        let base = [("PLUCK_RELAY_HOSTNAME", "relay.example.com"), ("PLUCK_RELAY_CONTACT", "a@example.com")];
        assert!(config(&env(&base)).is_err(), "no allowlist");
        assert!(config(&env(&[base[0], base[1], ("PLUCK_RELAY_ALLOW", " , ")])).is_err(), "empty allowlist");
        assert!(config(&env(&[base[0], base[1], ("PLUCK_RELAY_ALLOW", "nope")])).is_err(), "bad id");
        assert!(config(&env(&[("PLUCK_RELAY_HOSTNAME", "relay.example.com"), ("PLUCK_RELAY_ALLOW", A)])).is_err(), "acme without contact");
        assert!(config(&env(&[("PLUCK_RELAY_HOSTNAME", "bad\"host"), ("PLUCK_RELAY_ALLOW", A), base[1]])).is_err(), "hostname");
        assert!(config(&env(&[base[0], ("PLUCK_RELAY_CONTACT", "a\"@example.com"), ("PLUCK_RELAY_ALLOW", A)])).is_err(), "contact quote");
        assert!(config(&env(&[base[0], base[1], ("PLUCK_RELAY_ALLOW", A), ("PLUCK_RELAY_TLS", "none")])).is_err(), "tls off");
    }

    #[test]
    fn staging() {
        let c = config(&env(&[("PLUCK_RELAY_HOSTNAME", "relay.example.com"), ("PLUCK_RELAY_ALLOW", A),
                              ("PLUCK_RELAY_CONTACT", "a@example.com"), ("PLUCK_RELAY_STAGING", "1")])).unwrap();
        assert!(c.contains("prod_tls = false"));
    }
}
