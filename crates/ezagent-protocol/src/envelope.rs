//! Signed envelope for authenticated CRDT updates.

use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::crypto::{Keypair, PublicKey, Signature};
use crate::error::ProtocolError;

/// Current envelope version.
pub const ENVELOPE_VERSION: u8 = 1;

/// Serde helper for `[u8; 64]` signature fields.
mod serde_sig {
    use serde::{self, Deserializer, Serializer};

    pub fn serialize<S>(sig: &[u8; 64], serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_bytes(sig)
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<[u8; 64], D::Error>
    where
        D: Deserializer<'de>,
    {
        struct SigVisitor;

        impl<'de> serde::de::Visitor<'de> for SigVisitor {
            type Value = [u8; 64];

            fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
                formatter.write_str("64 bytes for an Ed25519 signature")
            }

            fn visit_bytes<E: serde::de::Error>(self, v: &[u8]) -> Result<[u8; 64], E> {
                if v.len() != 64 {
                    return Err(E::invalid_length(v.len(), &"64 bytes"));
                }
                let mut bytes = [0u8; 64];
                bytes.copy_from_slice(v);
                Ok(bytes)
            }

            fn visit_seq<A: serde::de::SeqAccess<'de>>(
                self,
                mut seq: A,
            ) -> Result<[u8; 64], A::Error> {
                let mut bytes = [0u8; 64];
                for (i, byte) in bytes.iter_mut().enumerate() {
                    *byte = seq
                        .next_element()?
                        .ok_or_else(|| serde::de::Error::invalid_length(i, &"64 bytes"))?;
                }
                Ok(bytes)
            }
        }

        deserializer.deserialize_bytes(SigVisitor)
    }
}

/// A signed envelope wrapping a CRDT update payload.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignedEnvelope {
    /// Protocol version (MUST be 1).
    pub version: u8,
    /// The signer's EntityId in string form.
    pub signer_id: String,
    /// The document ID (a key_pattern instance path).
    pub doc_id: String,
    /// Unix timestamp in milliseconds UTC.
    pub timestamp: i64,
    /// The CRDT update binary payload.
    pub payload: Vec<u8>,
    /// Ed25519 signature over the canonical signing bytes.
    #[serde(with = "serde_sig")]
    pub signature: Signature,
}

impl SignedEnvelope {
    /// Create and sign a new envelope with the current timestamp.
    pub fn sign(keypair: &Keypair, signer_id: String, doc_id: String, payload: Vec<u8>) -> Self {
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock before UNIX epoch")
            .as_millis() as i64;

        let signing_bytes =
            Self::build_signing_bytes(ENVELOPE_VERSION, &signer_id, &doc_id, timestamp, &payload);
        let signature = keypair.sign(&signing_bytes);

        Self {
            version: ENVELOPE_VERSION,
            signer_id,
            doc_id,
            timestamp,
            payload,
            signature,
        }
    }

    /// Verify the envelope's signature using the given public key.
    pub fn verify(&self, pubkey: &PublicKey) -> Result<(), ProtocolError> {
        if self.version != ENVELOPE_VERSION {
            return Err(ProtocolError::InvalidEnvelopeVersion {
                got: self.version,
                expected: ENVELOPE_VERSION,
            });
        }

        let signing_bytes = Self::build_signing_bytes(
            self.version,
            &self.signer_id,
            &self.doc_id,
            self.timestamp,
            &self.payload,
        );

        pubkey.verify(&signing_bytes, &self.signature)
    }

    /// Build the canonical bytes for signing/verification.
    ///
    /// Format: version(1B) + length-prefixed signer_id + length-prefixed doc_id
    ///         + timestamp(8B BE) + payload
    fn build_signing_bytes(
        version: u8,
        signer_id: &str,
        doc_id: &str,
        timestamp: i64,
        payload: &[u8],
    ) -> Vec<u8> {
        let signer_bytes = signer_id.as_bytes();
        let doc_bytes = doc_id.as_bytes();

        let mut buf = Vec::with_capacity(
            1 + 4 + signer_bytes.len() + 4 + doc_bytes.len() + 8 + payload.len(),
        );

        // version (1 byte)
        buf.push(version);

        // length-prefixed signer_id
        buf.extend_from_slice(&(signer_bytes.len() as u32).to_be_bytes());
        buf.extend_from_slice(signer_bytes);

        // length-prefixed doc_id
        buf.extend_from_slice(&(doc_bytes.len() as u32).to_be_bytes());
        buf.extend_from_slice(doc_bytes);

        // timestamp (8 bytes big-endian)
        buf.extend_from_slice(&timestamp.to_be_bytes());

        // payload (no length prefix, remainder of buffer)
        buf.extend_from_slice(payload);

        buf
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::Keypair;

    #[test]
    fn sign_and_verify() {
        let kp = Keypair::generate();
        let pk = kp.public_key();

        let env = SignedEnvelope::sign(
            &kp,
            "@alice:relay.com".into(),
            "rooms/abc/messages".into(),
            b"crdt-update".to_vec(),
        );

        assert_eq!(env.version, 1);
        assert_eq!(env.signer_id, "@alice:relay.com");
        assert_eq!(env.doc_id, "rooms/abc/messages");
        assert_eq!(env.payload, b"crdt-update");
        assert!(env.verify(&pk).is_ok());
    }

    #[test]
    fn wrong_key_fails() {
        let kp1 = Keypair::generate();
        let kp2 = Keypair::generate();

        let env = SignedEnvelope::sign(
            &kp1,
            "@alice:relay.com".into(),
            "doc/1".into(),
            b"data".to_vec(),
        );

        assert!(env.verify(&kp2.public_key()).is_err());
    }

    #[test]
    fn tampered_signer_id_fails() {
        let kp = Keypair::generate();
        let pk = kp.public_key();

        let mut env = SignedEnvelope::sign(
            &kp,
            "@alice:relay.com".into(),
            "doc/1".into(),
            b"data".to_vec(),
        );

        env.signer_id = "@eve:evil.com".into();
        assert!(env.verify(&pk).is_err());
    }

    #[test]
    fn tampered_doc_id_fails() {
        let kp = Keypair::generate();
        let pk = kp.public_key();

        let mut env = SignedEnvelope::sign(
            &kp,
            "@alice:relay.com".into(),
            "doc/1".into(),
            b"data".to_vec(),
        );

        env.doc_id = "doc/2".into();
        assert!(env.verify(&pk).is_err());
    }

    #[test]
    fn tampered_payload_fails() {
        let kp = Keypair::generate();
        let pk = kp.public_key();

        let mut env = SignedEnvelope::sign(
            &kp,
            "@alice:relay.com".into(),
            "doc/1".into(),
            b"data".to_vec(),
        );

        env.payload = b"evil-data".to_vec();
        assert!(env.verify(&pk).is_err());
    }

    #[test]
    fn tampered_timestamp_fails() {
        let kp = Keypair::generate();
        let pk = kp.public_key();

        let mut env = SignedEnvelope::sign(
            &kp,
            "@alice:relay.com".into(),
            "doc/1".into(),
            b"data".to_vec(),
        );

        env.timestamp += 1;
        assert!(env.verify(&pk).is_err());
    }

    #[test]
    fn invalid_version_fails() {
        let kp = Keypair::generate();
        let pk = kp.public_key();

        let mut env = SignedEnvelope::sign(
            &kp,
            "@alice:relay.com".into(),
            "doc/1".into(),
            b"data".to_vec(),
        );

        env.version = 2;
        let err = env.verify(&pk).unwrap_err();
        assert!(err.to_string().contains("invalid envelope version"));
    }

    #[test]
    fn serde_roundtrip() {
        let kp = Keypair::generate();
        let pk = kp.public_key();

        let env = SignedEnvelope::sign(
            &kp,
            "@alice:relay.com".into(),
            "doc/1".into(),
            b"payload".to_vec(),
        );

        let json = serde_json::to_string(&env).unwrap();
        let env2: SignedEnvelope = serde_json::from_str(&json).unwrap();

        assert_eq!(env.version, env2.version);
        assert_eq!(env.signer_id, env2.signer_id);
        assert_eq!(env.doc_id, env2.doc_id);
        assert_eq!(env.timestamp, env2.timestamp);
        assert_eq!(env.payload, env2.payload);
        assert_eq!(env.signature, env2.signature);
        assert!(env2.verify(&pk).is_ok());
    }
}
