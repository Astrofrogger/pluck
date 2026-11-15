// A hand-written RFC 5389 Binding Request, sent on the peers' own UDP socket, so browsers get our
// public (server-reflexive) address. str0m doesn't gather srflx candidates itself.
use std::{
    collections::HashMap,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    sync::{Arc, Mutex},
    time::Duration,
};

use tokio::{net::UdpSocket, sync::oneshot};

const MAGIC: u32 = 0x2112_A442;

/// Transactions in flight: the socket's reader hands each matching response to its waiter.
pub type Pending = Arc<Mutex<HashMap<[u8; 12], oneshot::Sender<SocketAddr>>>>;

pub fn request(txid: [u8; 12]) -> [u8; 20] {
    let mut m = [0u8; 20];
    m[0..2].copy_from_slice(&0x0001u16.to_be_bytes()); // Binding Request, no attributes
    m[4..8].copy_from_slice(&MAGIC.to_be_bytes());
    m[8..20].copy_from_slice(&txid);
    m
}

/// The transaction id and mapped address of a Binding Success Response; None for anything else.
pub fn parse_response(b: &[u8]) -> Option<([u8; 12], SocketAddr)> {
    if b.len() < 20 || b[0..2] != [0x01, 0x01] || b[4..8] != MAGIC.to_be_bytes() {
        return None;
    }
    let len = u16::from_be_bytes([b[2], b[3]]) as usize;
    let body = b.get(20..20 + len)?;
    let txid: [u8; 12] = b[8..20].try_into().ok()?;
    let (mut i, mut plain) = (0, None);
    while i + 4 <= body.len() {
        let typ = u16::from_be_bytes([body[i], body[i + 1]]);
        let alen = u16::from_be_bytes([body[i + 2], body[i + 3]]) as usize;
        let v = body.get(i + 4..i + 4 + alen)?;
        match typ {
            0x0020 => return Some((txid, address(v, Some(&b[4..20]))?)), // XOR-MAPPED-ADDRESS
            0x0001 => plain = address(v, None),                          // MAPPED-ADDRESS (old servers)
            _ => {}
        }
        i += 4 + alen.div_ceil(4) * 4;
    }
    Some((txid, plain?))
}

/// An address attribute; `xor` is magic cookie + transaction id for the XOR form.
fn address(v: &[u8], xor: Option<&[u8]>) -> Option<SocketAddr> {
    let x = |i: usize| xor.map_or(0, |k| k[i]);
    let port = u16::from_be_bytes([v.get(2)? ^ x(0), v.get(3)? ^ x(1)]);
    let ip = match v.get(1)? {
        1 => {
            let o = v.get(4..8)?;
            IpAddr::V4(Ipv4Addr::from(std::array::from_fn::<u8, 4, _>(|i| o[i] ^ x(i))))
        }
        2 => {
            let o = v.get(4..20)?;
            IpAddr::V6(Ipv6Addr::from(std::array::from_fn::<u8, 16, _>(|i| o[i] ^ x(i))))
        }
        _ => return None,
    };
    Some(SocketAddr::new(ip, port))
}

/// Ask `server` for our mapped address, retrying twice (0.5, 1 and 2 s).
pub async fn bind(sock: &UdpSocket, server: SocketAddr, pending: &Pending) -> Option<SocketAddr> {
    let txid: [u8; 12] = rand::random();
    let (tx, mut rx) = oneshot::channel();
    pending.lock().unwrap().insert(txid, tx);
    let mut got = None;
    for wait in [500, 1000, 2000] {
        if sock.send_to(&request(txid), server).await.is_err() {
            break;
        }
        if let Ok(Ok(a)) = tokio::time::timeout(Duration::from_millis(wait), &mut rx).await {
            got = Some(a);
            break;
        }
    }
    pending.lock().unwrap().remove(&txid);
    got
}

#[cfg(test)]
mod tests {
    use super::*;

    const TXID: [u8; 12] = [0xb7, 0xe7, 0xa7, 0x01, 0xbc, 0x34, 0xd6, 0x86, 0xfa, 0x87, 0xdf, 0xae];

    fn response(attrs: &[u8]) -> Vec<u8> {
        let mut m = vec![0x01, 0x01];
        m.extend((attrs.len() as u16).to_be_bytes());
        m.extend(MAGIC.to_be_bytes());
        m.extend(TXID);
        m.extend(attrs);
        m
    }

    // RFC 5769 §2.2 and §2.3 sample responses (SOFTWARE + XOR-MAPPED-ADDRESS; integrity left out).
    #[test]
    fn rfc5769_ipv4() {
        let a = [
            0x80, 0x22, 0x00, 0x0b, b't', b'e', b's', b't', b' ', b'v', b'e', b'c', b't', b'o', b'r', 0x20,
            0x00, 0x20, 0x00, 0x08, 0x00, 0x01, 0xa1, 0x47, 0xe1, 0x12, 0xa6, 0x43,
        ];
        let (id, addr) = parse_response(&response(&a)).unwrap();
        assert_eq!(id, TXID);
        assert_eq!(addr, "192.0.2.1:32853".parse().unwrap());
    }

    #[test]
    fn rfc5769_ipv6() {
        let a = [
            0x00, 0x20, 0x00, 0x14, 0x00, 0x02, 0xa1, 0x47, 0x01, 0x13, 0xa9, 0xfa, 0xa5, 0xd3, 0xf1, 0x79,
            0xbc, 0x25, 0xf4, 0xb5, 0xbe, 0xd2, 0xb9, 0xd9,
        ];
        let (_, addr) = parse_response(&response(&a)).unwrap();
        assert_eq!(addr, "[2001:db8:1234:5678:11:2233:4455:6677]:32853".parse().unwrap());
    }

    #[test]
    fn rejects_other_packets() {
        assert!(parse_response(&request(TXID)).is_none()); // a request, not a response
        assert!(parse_response(&[0x01, 0x01, 0, 0]).is_none()); // short
        let mut r = response(&[0x00, 0x20, 0x00, 0x08, 0x00, 0x01, 0xa1]); // cut-off attribute
        assert!(parse_response(&r).is_none());
        r[4] = 0; // wrong cookie
        assert!(parse_response(&r).is_none());
        assert!(parse_response(&response(&[])).is_none()); // no address
    }

    #[test]
    fn request_layout() {
        let r = request(TXID);
        assert_eq!(&r[..8], &[0, 1, 0, 0, 0x21, 0x12, 0xa4, 0x42]);
        assert_eq!(&r[8..], &TXID);
    }
}
