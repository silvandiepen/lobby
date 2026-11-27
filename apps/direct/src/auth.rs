// SPDX-License-Identifier: MPL-2.0
//! How a device proves itself on a connection: it signs the connection's own TLS exporter.
//!
//! The exporter is known to both ends of one TLS session and to nobody else, so a signature over
//! it cannot be carried over to another connection, nor be made by who only reads along.

use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use ring::signature::{ED25519, UnparsedPublicKey};

pub const ALPN: &[u8] = b"lobby-direct/1";
pub const EXPORTER_LABEL: &[u8] = b"EXPORTER-lobby-direct-1";
pub const EXPORTER_LENGTH: usize = 32;
const MAGIC: &[u8; 4] = b"LDA1";
/// Magic, public key, signature.
pub const FRAME_LENGTH: usize = 4 + 32 + 64;
/// What the first stream answers with.
pub const ACCEPTED: &[u8] = &[0];

/// What is signed.
pub fn message(box_id: &str, exporter: &[u8; EXPORTER_LENGTH]) -> Vec<u8> {
    format!(
        "lobby-direct/1|connect|{box_id}|{}",
        URL_SAFE_NO_PAD.encode(exporter)
    )
    .into_bytes()
}

/// Whether the frame comes from the device this connection was made for.
pub fn proves(
    frame: &[u8; FRAME_LENGTH],
    device: &[u8; 32],
    box_id: &str,
    exporter: &[u8; EXPORTER_LENGTH],
) -> bool {
    let (magic, rest) = frame.split_at(MAGIC.len());
    let (key, signature) = rest.split_at(32);
    magic == MAGIC
        && key == device
        && UnparsedPublicKey::new(&ED25519, key)
            .verify(&message(box_id, exporter), signature)
            .is_ok()
}

/// A device's frame. For the tests and the stand-in device.
pub fn frame(
    key: &ring::signature::Ed25519KeyPair,
    box_id: &str,
    exporter: &[u8; EXPORTER_LENGTH],
) -> [u8; FRAME_LENGTH] {
    use ring::signature::KeyPair;
    let mut out = [0u8; FRAME_LENGTH];
    out[..4].copy_from_slice(MAGIC);
    out[4..36].copy_from_slice(key.public_key().as_ref());
    out[36..].copy_from_slice(key.sign(&message(box_id, exporter)).as_ref());
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use ring::signature::{Ed25519KeyPair, KeyPair};

    fn key(seed: u8) -> (Ed25519KeyPair, [u8; 32]) {
        let pair = Ed25519KeyPair::from_seed_unchecked(&[seed; 32]).expect("a seed");
        let public = pair.public_key().as_ref().try_into().expect("32 bytes");
        (pair, public)
    }

    #[test]
    fn only_the_device_on_this_connection() {
        let (pair, public) = key(1);
        let (other, other_public) = key(2);
        let exporter = [7u8; 32];
        let good = frame(&pair, "box", &exporter);
        assert!(proves(&good, &public, "box", &exporter));
        // Another connection, another box, another device.
        assert!(!proves(&good, &public, "box", &[8u8; 32]));
        assert!(!proves(&good, &public, "xob", &exporter));
        assert!(!proves(&good, &other_public, "box", &exporter));
        // Another key under this device's name, and this device's signature changed.
        let mut forged = frame(&other, "box", &exporter);
        forged[4..36].copy_from_slice(&public);
        assert!(!proves(&forged, &public, "box", &exporter));
        for at in [0, 5, 40, 99] {
            let mut changed = good;
            changed[at] ^= 1;
            assert!(!proves(&changed, &public, "box", &exporter), "byte {at}");
        }
    }
}
