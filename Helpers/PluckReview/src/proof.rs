// The approval proof (spec §13.8), host side: a one-page A4 PDF 1.4 with base-14 Helvetica in
// WinAnsi. Characters outside WinAnsi print as "?" on the page; the /Info dictionary keeps the
// exact name (/Title) and the full canonical record (/Subject) as UTF-16BE, so nothing is lost.
// shortcut: non-Latin names show as "?" on the page; upgrade by embedding DejaVu (in the image) if owners ask.
use serde_json::{Map, Value, json};

/// The record's fields, as the canonical JSON (keys sorted, UTF-8, no spaces) that "Record" hashes.
pub struct Proof {
    pub project: String,
    pub asset: String,
    pub version: i64,
    pub file: String,
    pub sha256: String,
    pub hash_of: String, // "original" | "copy"
    pub decision: String, // "approve" | "changes"
    pub name: String,
    pub email: Option<String>,
    pub time: String,
    pub link_title: String,
    pub link: String,
    pub approval: String,
    pub served_by: String,
    pub generated: String,
}

impl Proof {
    pub fn record(&self) -> Value {
        let mut m = Map::new();
        for (k, v) in [("project", json!(self.project)), ("asset", json!(self.asset)), ("version", json!(self.version)),
            ("file", json!(self.file)), ("sha256", json!(self.sha256)), ("hashOf", json!(self.hash_of)), ("decision", json!(self.decision)),
            ("name", json!(self.name)), ("time", json!(self.time)), ("linkTitle", json!(self.link_title)), ("link", json!(self.link)),
            ("approval", json!(self.approval)), ("servedBy", json!(self.served_by)), ("generated", json!(self.generated))] {
            m.insert(k.into(), v);
        }
        if let Some(e) = self.email.as_ref().filter(|e| !e.is_empty()) {
            m.insert("email".into(), json!(e));
        }
        Value::Object(m) // serde_json's Map is a BTreeMap here: keys come out sorted
    }

    /// base64url SHA-256 of the canonical JSON.
    pub fn record_hash(&self) -> String {
        crate::keys::sha256_b64(self.record().to_string().as_bytes())
    }

    pub fn pdf(&self) -> Vec<u8> {
        let heading = if self.decision == "approve" { "Approval" } else { "Changes requested" };
        let sha = if self.sha256.len() == 64 { format!("{}\n{}", &self.sha256[..32], &self.sha256[32..]) } else { self.sha256.clone() };
        let sha = if self.hash_of == "copy" { format!("{sha}\nof the review copy") } else { sha };
        let mut rows: Vec<(&str, String)> = vec![
            ("Project", self.project.clone()), ("Asset", self.asset.clone()), ("Version", format!("v{}", self.version)),
            ("File", self.file.clone()), ("SHA-256", sha),
            ("Decision", if self.decision == "approve" { "Approved".into() } else { "Changes requested".into() }),
            ("Name", self.name.clone()),
        ];
        if let Some(e) = self.email.as_ref().filter(|e| !e.is_empty()) {
            rows.push(("Email", e.clone()));
        }
        rows.extend([("Time", self.time.clone()), ("Link", format!("{}\n{}", self.link_title, self.link)), ("Approval id", self.approval.clone()),
            ("Served by", self.served_by.clone()), ("Generated", self.generated.clone()), ("Record", self.record_hash())]);
        let mut c = format!("BT /F2 22 Tf 56 770 Td ({}) Tj ET\n", pdf_text(heading));
        let mut y = 730;
        for (label, value) in rows {
            c.push_str(&format!("BT /F2 10 Tf 56 {y} Td ({}) Tj ET\n", pdf_text(label)));
            for (i, line) in value.split('\n').enumerate() {
                let font = if label == "SHA-256" || label == "Record" || label == "Approval id" { "/F3 9" } else { "/F1 10" };
                c.push_str(&format!("BT {font} Tf 160 {} Td ({}) Tj ET\n", y - 14 * i as i64, pdf_text(&line.chars().take(90).collect::<String>())));
            }
            y -= 14 * value.split('\n').count() as i64 + 8;
        }
        let info = format!("<< /Title {} /Subject {} /Producer (pluck-review) >>",
            utf16(&format!("{heading} – {} v{} – {}", self.asset, self.version, self.name)), utf16(&self.record().to_string()));
        let objs = [
            "<< /Type /Catalog /Pages 2 0 R >>".to_owned(),
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>".to_owned(),
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 5 0 R /F2 6 0 R /F3 8 0 R >> >> /Contents 4 0 R >>".to_owned(),
            format!("<< /Length {} >>\nstream\n{c}endstream", c.len()),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>".to_owned(),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>".to_owned(),
            info,
            "<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >>".to_owned(),
        ];
        let mut out = b"%PDF-1.4\n%\xE2\xE3\xCF\xD3\n".to_vec();
        let mut offs = vec![];
        for (i, o) in objs.iter().enumerate() {
            offs.push(out.len());
            out.extend(format!("{} 0 obj\n", i + 1).bytes());
            out.extend(o.bytes());
            out.extend(b"\nendobj\n");
        }
        let xref = out.len();
        out.extend(format!("xref\n0 {}\n0000000000 65535 f \n", objs.len() + 1).bytes());
        for o in offs {
            out.extend(format!("{o:010} 00000 n \n").bytes());
        }
        out.extend(format!("trailer\n<< /Size {} /Root 1 0 R /Info 7 0 R >>\nstartxref\n{xref}\n%%EOF\n", objs.len() + 1).bytes());
        out
    }
}

/// A PDF literal string body in WinAnsi (cp1252): escaped, anything else as "?". The content
/// stream is written as Latin-1 bytes, so each char here must be ≤ U+00FF.
fn pdf_text(s: &str) -> String {
    let mut out = String::new();
    for ch in s.chars() {
        let b: u8 = match ch {
            '(' | ')' | '\\' => { out.push('\\'); ch as u8 }
            ' '..='~' => ch as u8,
            '\u{A0}'..='\u{FF}' => ch as u8,
            '€' => 0x80, '‚' => 0x82, '„' => 0x84, '…' => 0x85, '‘' => 0x91, '’' => 0x92, '“' => 0x93, '”' => 0x94,
            '•' => 0x95, '–' => 0x96, '—' => 0x97, '™' => 0x99, 'Š' => 0x8A, 'š' => 0x9A, 'Œ' => 0x8C, 'œ' => 0x9C,
            'Ž' => 0x8E, 'ž' => 0x9E, 'Ÿ' => 0x9F,
            _ => b'?',
        };
        if b >= 0x80 {
            out.push_str(&format!("\\{b:03o}")); // octal escape keeps the stream ASCII
        } else {
            out.push(b as char);
        }
    }
    out
}

/// A PDF text string as UTF-16BE with the BOM, in hex.
fn utf16(s: &str) -> String {
    let mut h = String::from("<FEFF");
    for u in s.encode_utf16() {
        h.push_str(&format!("{u:04X}"));
    }
    h.push('>');
    h
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(name: &str) -> Proof {
        Proof { project: "Spring".into(), asset: "Hero 30s".into(), version: 3, file: "Hero 30s v3.mov".into(), sha256: "ab".repeat(32),
            hash_of: "original".into(), decision: "approve".into(), name: name.into(), email: Some("anna@example.com".into()),
            time: "2026-11-16T10:00:00Z".into(), link_title: "Spring – cuts".into(), link: "L1".into(), approval: "AP1".into(),
            served_by: "Office NAS".into(), generated: "2026-11-16T10:05:00Z".into() }
    }

    #[test]
    fn proof_pdf_parses() {
        let p = sample("Zoë 李");
        let pdf = p.pdf();
        assert!(pdf.starts_with(b"%PDF-1.4"));
        let text = String::from_utf8_lossy(&pdf).to_string();
        // The xref adds up: every offset points at "<n> 0 obj", and startxref at "xref".
        let start: usize = text.rsplit("startxref\n").next().unwrap().lines().next().unwrap().parse().unwrap();
        assert_eq!(&pdf[start..start + 4], b"xref");
        let xref = &text[start..];
        for (n, l) in xref.lines().skip(3).take_while(|l| l.ends_with(" n ")).enumerate() {
            let off: usize = l[..10].parse().unwrap();
            assert!(pdf[off..].starts_with(format!("{} 0 obj", n + 1).as_bytes()), "object {}", n + 1);
        }
        let len: usize = text.split("<< /Length ").nth(1).unwrap().split(' ').next().unwrap().parse().unwrap();
        let s = text.find("stream\n").unwrap() + 7;
        assert!(text[s + len..].starts_with("endstream"), "the stream length is right");
        // The page: WinAnsi with "?" for the rest; the Info: UTF-16BE with the exact name.
        assert!(text.contains("(Zo\\353 ?) Tj"), "ë as WinAnsi, 李 as ?");
        assert!(text.contains("/Title <FEFF") && text.contains("674E"), "李 = U+674E in the Info title");
        assert!(text.contains(&format!("({}) Tj", p.record_hash())), "the record hash is printed");
        assert!(text.contains(&format!("({}) Tj", "ab".repeat(16))), "the hash on two lines of 32");
    }

    #[test]
    fn record_is_canonical() {
        let p = sample("Anna");
        let r = p.record().to_string();
        assert!(r.starts_with(r#"{"approval":"AP1","asset":"Hero 30s","decision":"approve","email":"anna@example.com","file":"#), "{r}");
        assert!(!r.contains(": ") && !r.contains(", "));
        let mut q = sample("Anna");
        q.email = None;
        assert!(!q.record().to_string().contains("email"));
        assert_ne!(p.record_hash(), q.record_hash());
        // The same vector is checked in Pluck's self-test (round3: proof record matches the host's).
        assert_eq!(p.record_hash(), "3zAxWNkwTPPJGJbnroL-p9NIsaUvWaTcgANzF8WEuS8");
    }
}
