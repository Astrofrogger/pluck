// Spec §3 crypto for host mode: the fingerprint-bound proofs and the link password check.
// A host holds only the per-room reg, authKey, signing seed and join hash (never the link key) and a password hash.
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD as B64};
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};

type HmacSha256 = Hmac<Sha256>;

pub fn b64(b: &[u8]) -> String {
    B64.encode(b)
}

pub fn unb64(s: &str) -> Option<Vec<u8>> {
    B64.decode(s).ok()
}

pub fn sha256_b64(b: &[u8]) -> String {
    b64(&Sha256::digest(b))
}

fn proof_mac(auth_key: &[u8], role: &str, mac_nonce: &[u8], browser_nonce: &[u8], fp_mac: &str, fp_browser: &str) -> HmacSha256 {
    let mut m = HmacSha256::new_from_slice(auth_key).expect("any key length");
    m.update(format!("pluck-review/1 {role}\n").as_bytes());
    m.update(mac_nonce);
    m.update(browser_nonce);
    m.update(fp_mac.as_bytes());
    m.update(b"\n");
    m.update(fp_browser.as_bytes());
    m
}

pub fn proof(auth_key: &[u8], role: &str, mac_nonce: &[u8], browser_nonce: &[u8], fp_mac: &str, fp_browser: &str) -> String {
    b64(&proof_mac(auth_key, role, mac_nonce, browser_nonce, fp_mac, fp_browser).finalize().into_bytes())
}

/// Constant-time check of a browser's proof.
pub fn check_proof(auth_key: &[u8], given: &str, mac_nonce: &[u8], browser_nonce: &[u8], fp_mac: &str, fp_browser: &str) -> bool {
    let Some(given) = unb64(given) else { return false };
    proof_mac(auth_key, "browser", mac_nonce, browser_nonce, fp_mac, fp_browser).verify_slice(&given).is_ok()
}

/// "pbkdf2-sha256$<iterations>$<salt b64url>$<hash b64url>", compared in constant time.
pub fn check_password(stored: &str, password: &str) -> bool {
    let p: Vec<&str> = stored.split('$').collect();
    let [kind, iter, salt, hash] = p[..] else { return false };
    let (Ok(iter), Some(salt), Some(hash)) = (iter.parse::<u32>(), unb64(salt), unb64(hash)) else { return false };
    if kind != "pbkdf2-sha256" || !(1_000..=10_000_000).contains(&iter) || hash.len() != 32 {
        return false;
    }
    let mut out = [0u8; 32];
    pbkdf2::pbkdf2_hmac::<Sha256>(password.as_bytes(), &salt, iter, &mut out);
    subtle_eq(&out, &hash)
}

/// HKDF-SHA256 with the spec's salt: "room" (16 bytes), "register" and "auth" (32).
pub fn derive(key: &[u8], info: &str, n: usize) -> Vec<u8> {
    let mut out = vec![0; n];
    hkdf::Hkdf::<Sha256>::new(Some(b"pluck-review/1"), key).expand(info.as_bytes(), &mut out).expect("n ≤ 8160");
    out
}

/// Protocol 2: from the owner-only root R (never in the link), salt "pluck-review/2": "register" (the
/// Worker registration secret) and "sign" (the room's Ed25519 seed).
pub fn owner(r: &[u8], info: &str) -> Vec<u8> {
    let mut out = vec![0; 32];
    hkdf::Hkdf::<Sha256>::new(Some(b"pluck-review/2"), r).expand(info.as_bytes(), &mut out).expect("32 ≤ 8160");
    out
}

/// What the browser sends in browser-join (derivable from the link) and its hash, which the server registers.
pub fn join_hash(key: &[u8]) -> String {
    sha256_b64(&derive(key, "join", 32))
}

fn pair(seed: &[u8]) -> Option<ring::signature::Ed25519KeyPair> {
    ring::signature::Ed25519KeyPair::from_seed_unchecked(seed).ok()
}

/// The room's Ed25519 public key (the `<pub>` in the link) from its seed.
pub fn public(seed: &[u8]) -> Option<Vec<u8>> {
    use ring::signature::KeyPair;
    pair(seed).map(|k| k.public_key().as_ref().to_vec())
}

/// "pluck-review/2 server\n" ‖ macNonce ‖ fpMac ‖ "\n" ‖ fpBrowser: what the server signs in `hello`.
fn hello_msg(mac_nonce: &[u8], fp_mac: &str, fp_browser: &str) -> Vec<u8> {
    [b"pluck-review/2 server\n".as_slice(), mac_nonce, fp_mac.as_bytes(), b"\n", fp_browser.as_bytes()].concat()
}

/// The `hello` signature, so a browser knows the far end holds the room's signing key (link holders don't).
pub fn sign_hello(seed: &[u8], mac_nonce: &[u8], fp_mac: &str, fp_browser: &str) -> Option<String> {
    Some(b64(pair(seed)?.sign(&hello_msg(mac_nonce, fp_mac, fp_browser)).as_ref()))
}

/// The browser's check of `hello` (tests stand in for the browser).
#[cfg(test)]
pub fn verify_hello(public: &[u8], sig: &str, mac_nonce: &[u8], fp_mac: &str, fp_browser: &str) -> bool {
    let Some(sig) = unb64(sig) else { return false };
    ring::signature::UnparsedPublicKey::new(&ring::signature::ED25519, public).verify(&hello_msg(mac_nonce, fp_mac, fp_browser), &sig).is_ok()
}

/// Protocol 3 (§13.24): the link carries a 12-character base62 code; `linkKey` from it does what level 2's key does.
pub const CODE_LEN: usize = 12;
const BASE62: &[u8] = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

#[cfg(test)]
pub fn is_code(s: &str) -> bool {
    s.len() == CODE_LEN && s.bytes().all(|b| b.is_ascii_alphanumeric())
}

/// A fresh code from the CSPRNG: bytes < 248 taken mod 62, so no modulo bias.
pub fn new_code() -> String {
    let mut out = String::with_capacity(CODE_LEN);
    while out.len() < CODE_LEN {
        let b: u8 = rand::random();
        if b < 248 {
            out.push(BASE62[usize::from(b % 62)] as char);
        }
    }
    out
}

/// PBKDF2 rounds for a level-3 code (§13.24): each guess costs what 300,000 HMACs do; about 20 ms on a recent Mac.
pub const LINK_ITERATIONS: u32 = 300_000;

/// linkKey = PBKDF2-HMAC-SHA256(code, salt "pluck-link-v3", LINK_ITERATIONS, 32 bytes): the salt names the version, so
/// it can't meet a level-2 key. A host derives it only to make a link on its admin page.
pub fn link_key(code: &str) -> Vec<u8> {
    let mut out = vec![0; 32];
    pbkdf2::pbkdf2_hmac::<Sha256>(code.as_bytes(), b"pluck-link-v3", LINK_ITERATIONS, &mut out);
    out
}

fn hello_mac_v3(auth_key: &[u8], mac_nonce: &[u8], fp_mac: &str, fp_browser: &str) -> HmacSha256 {
    let mut m = HmacSha256::new_from_slice(auth_key).expect("any key length");
    for part in [b"pluck-link-v3 server\n".as_slice(), mac_nonce, fp_mac.as_bytes(), b"\n", fp_browser.as_bytes()] {
        m.update(part);
    }
    m
}

/// The level-3 hello's `mac`: the server knows the code-derived authKey (§13.24).
pub fn hello_v3(auth_key: &[u8], mac_nonce: &[u8], fp_mac: &str, fp_browser: &str) -> String {
    b64(&hello_mac_v3(auth_key, mac_nonce, fp_mac, fp_browser).finalize().into_bytes())
}

/// The browser's check of a level-3 hello (tests stand in for the browser).
#[cfg(test)]
pub fn check_hello_v3(auth_key: &[u8], given: &str, mac_nonce: &[u8], fp_mac: &str, fp_browser: &str) -> bool {
    unb64(given).is_some_and(|g| hello_mac_v3(auth_key, mac_nonce, fp_mac, fp_browser).verify_slice(&g).is_ok())
}

/// A new (level 3) link and what a host keeps of it, all base64url.
pub struct NewLink {
    pub fragment: String, // the code: the link's #-part
    pub room: String,
    pub reg: String,
    pub auth: String,
    pub join: String, // joinHash
}

pub fn new_link() -> NewLink {
    let code = new_code();
    let key = link_key(&code);
    let r: [u8; 32] = rand::random();
    NewLink {
        room: b64(&derive(&key, "room", 16)), reg: b64(&owner(&r, "register")), auth: b64(&derive(&key, "auth", 32)),
        join: join_hash(&key), fragment: code,
    }
}

/// The spec's stored form: "pbkdf2-sha256$210000$<salt>$<hash>".
pub fn hash_password(password: &str) -> String {
    let salt: [u8; 16] = rand::random();
    let mut out = [0u8; 32];
    pbkdf2::pbkdf2_hmac::<Sha256>(password.as_bytes(), &salt, 210_000, &mut out);
    format!("pbkdf2-sha256$210000${}${}", b64(&salt), b64(&out))
}

pub fn subtle_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |d, (x, y)| d | (x ^ y)) == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The §3 test vector, end to end.
    #[test]
    fn spec_vector() {
        let key: Vec<u8> = (0..32).collect();
        assert_eq!(b64(&key), "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8");
        assert_eq!(b64(&derive(&key, "room", 16)), "7E1RkYmx_jTN80i5w8xmOg");
        let reg = derive(&key, "register", 32);
        assert_eq!(b64(&reg), "6kqGs061u6f57cVUAmB3ckvupr9A5by3Zemup9bWVmg");
        assert_eq!(sha256_b64(&reg), "QvAq7JjcoxMYqu9X8K9EjffD9MOmnHg7Y5LSVajGemc");
        let auth = derive(&key, "auth", 32);
        assert_eq!(b64(&auth), "FndhJOuo-7ZZiHHA7b4rC1jnZIGaNtKo1ipv9OAqI5c");
        let fp_mac = vec!["AA"; 32].join(":");
        let fp_br = vec!["BB"; 32].join(":");
        let (mn, bn) = ([1u8; 32], [2u8; 32]);
        assert_eq!(proof(&auth, "browser", &mn, &bn, &fp_mac, &fp_br), "0nRJucbI9oMMyGivqbz2b-6UPmaplHZ9xWxmesvyKgA");
        assert_eq!(proof(&auth, "mac", &mn, &bn, &fp_mac, &fp_br), "L6anGk8H7cRlDjPG4LDJJA5lJQMzxuhMuZ28789Yj04");
        assert!(check_proof(&auth, "0nRJucbI9oMMyGivqbz2b-6UPmaplHZ9xWxmesvyKgA", &mn, &bn, &fp_mac, &fp_br));
        assert!(!check_proof(&auth, "0nRJucbI9oMMyGivqbz2b-6UPmaplHZ9xWxmesvyKgA", &mn, &bn, &fp_br, &fp_mac), "swapped fingerprints fail");
    }

    /// The protocol 2 vector (afix contract): R = 0x20…0x3f.
    #[test]
    fn level2_vector() {
        let key: Vec<u8> = (0..32).collect();
        let r: Vec<u8> = (32..64).collect();
        assert_eq!(b64(&derive(&key, "join", 32)), "rRaYJs5-07URNfm3gxhQ2HtP8i4RLTQ_J4wsbiDMdL4");
        assert_eq!(join_hash(&key), "DDk_aLVe7_lpSrn2FJsnpy4x8AsymOK8AZOx9K_7OAo");
        let reg = owner(&r, "register");
        assert_eq!(b64(&reg), "thuSTJX_ex8_hafj-qs5coPH00wqbknCQ-ON70RP0zQ");
        assert_eq!(sha256_b64(&reg), "VmzTzijRRc5lZmA19N2AjvkxZCpZfrEn3EiP8ltqTFU");
        let seed = owner(&r, "sign");
        assert_eq!(b64(&seed), "R85Juszx1tmPSUJlpjYA3DtFmqHJDUUU0Z1HyoU0Mb4");
        let public = public(&seed).unwrap();
        assert_eq!(b64(&public), "d-VE2PQpTDJ6Rw_vkvYI0nCJ34xkdCgQRSVNa3LdIFw");
        let (fp_mac, fp_br) = (vec!["AA"; 32].join(":"), vec!["BB"; 32].join(":"));
        let sig = sign_hello(&seed, &[1u8; 32], &fp_mac, &fp_br).unwrap();
        assert_eq!(sig, "TJYKK-3bhNymZRPwZjASrwz-HOJ7OKZNO5Ub0oNAYMu8qdGouSU4mIj8M0m4Ts56M25urFTxsWlzfcyR_YidAA");
        assert!(verify_hello(&public, &sig, &[1u8; 32], &fp_mac, &fp_br));
        assert!(!verify_hello(&public, &sig, &[1u8; 32], &fp_br, &fp_mac), "swapped fingerprints fail");
        // A link holder knows key (so authKey and join) but not R: a hello it signs with any other key fails.
        let forged = sign_hello(&derive(&key, "auth", 32), &[1u8; 32], &fp_mac, &fp_br).unwrap();
        assert!(!verify_hello(&public, &forged, &[1u8; 32], &fp_mac, &fp_br));
    }

    /// §13.24, from the shared vector file (the web tests read the same one).
    #[test]
    fn level3_vector() {
        let v: serde_json::Value = serde_json::from_str(include_str!("../../../docs/superpowers/plans/link-v3-vectors.json")).unwrap();
        let s = |k: &str| v[k].as_str().unwrap().to_owned();
        assert_eq!(v["iterations"], LINK_ITERATIONS, "PBKDF2 rounds as in the vector");
        let key = link_key(&s("code"));
        assert_eq!(b64(&key), s("linkKey"));
        assert_eq!(b64(&derive(&key, "room", 16)), s("roomId"));
        let auth = derive(&key, "auth", 32);
        assert_eq!(b64(&auth), s("authKey"));
        assert_eq!(b64(&derive(&key, "join", 32)), s("join"));
        assert_eq!(join_hash(&key), s("joinHash"));
        let (mn, bn) = (unb64(&s("macNonce")).unwrap(), unb64(&s("browserNonce")).unwrap());
        let (fp_mac, fp_br) = (s("fpMac"), s("fpBrowser"));
        assert_eq!(hello_v3(&auth, &mn, &fp_mac, &fp_br), s("helloMac"));
        assert_eq!(proof(&auth, "browser", &mn, &bn, &fp_mac, &fp_br), s("proofBrowser"));
        assert_eq!(proof(&auth, "mac", &mn, &bn, &fp_mac, &fp_br), s("proofMac"));
        assert!(check_hello_v3(&auth, &s("helloMac"), &mn, &fp_mac, &fp_br));
        assert!(!check_hello_v3(&auth, &s("helloMac"), &mn, &fp_br, &fp_mac), "swapped fingerprints fail");
        // A wrong code gives other keys: its hello and proofs fail.
        let wrong = derive(&link_key("Mt0Rkt98Xy3R"), "auth", 32);
        assert!(!check_hello_v3(&wrong, &s("helloMac"), &mn, &fp_mac, &fp_br));
        assert!(!check_proof(&wrong, &s("proofBrowser"), &mn, &bn, &fp_mac, &fp_br));
        // Versions can't be confused: the v3 key isn't the code as a v2 key, and a v3 hello isn't a §3 proof.
        assert_ne!(b64(&derive(s("code").as_bytes(), "room", 16)), s("roomId"));
        assert_ne!(hello_v3(&auth, &mn, &fp_mac, &fp_br), proof(&auth, "mac", &mn, &[0u8; 32], &fp_mac, &fp_br));
    }

    #[test]
    fn new_links_are_level3() {
        let l = new_link();
        assert!(is_code(&l.fragment) && !l.fragment.contains('.'));
        let key = link_key(&l.fragment);
        assert_eq!(l.room, b64(&derive(&key, "room", 16)));
        assert_eq!(l.join, join_hash(&key));
        assert_ne!(l.reg, b64(&derive(&key, "register", 32)), "reg isn't derivable from the link");
        assert_ne!(l.reg, b64(&owner(&key, "register")));
        assert!(!is_code("Mt0Rkt98Xy3") && !is_code("Mt0Rkt98Xy3Q_") && !is_code("Mt0Rkt98Xy-Q"));
        // All 62 characters show up and none other (a cheap bias check).
        let all: std::collections::HashSet<char> = (0..400).flat_map(|_| new_code().chars().collect::<Vec<_>>()).collect();
        assert_eq!(all.len(), 62);
    }

    #[test]
    fn password() {
        let salt = [9u8; 16];
        let mut h = [0u8; 32];
        pbkdf2::pbkdf2_hmac::<Sha256>(b"test", &salt, 1000, &mut h);
        let stored = format!("pbkdf2-sha256$1000${}${}", b64(&salt), b64(&h));
        assert!(check_password(&stored, "test"));
        assert!(!check_password(&stored, "Test"));
        assert!(!check_password("pbkdf2-sha256$1$x$y", "test"));
        assert!(!check_password("", "test"));
        assert!(check_password(&hash_password("pw"), "pw"));
    }
}
