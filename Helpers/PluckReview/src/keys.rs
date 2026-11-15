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

/// A new link and what a host keeps of it, all base64url.
pub struct NewLink {
    pub fragment: String, // "<key>.<pub>": the link's #-part
    pub room: String,
    pub reg: String,
    pub auth: String,
    pub sign: String,
    pub join: String, // joinHash
}

pub fn new_link() -> NewLink {
    let key: [u8; 32] = rand::random();
    let r: [u8; 32] = rand::random();
    let seed = owner(&r, "sign");
    NewLink {
        fragment: format!("{}.{}", b64(&key), b64(&public(&seed).expect("32-byte seed"))),
        room: b64(&derive(&key, "room", 16)), reg: b64(&owner(&r, "register")), auth: b64(&derive(&key, "auth", 32)),
        sign: b64(&seed), join: join_hash(&key),
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
        let l = new_link();
        let (k, p) = l.fragment.split_once('.').unwrap();
        assert_eq!((k.len(), p.len()), (43, 43));
        assert_eq!(unb64(p).unwrap(), super::public(&unb64(&l.sign).unwrap()).unwrap());
        assert_eq!(l.room, b64(&derive(&unb64(k).unwrap(), "room", 16)));
        assert_ne!(l.reg, b64(&derive(&unb64(k).unwrap(), "register", 32)), "reg isn't derivable from the link");
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
