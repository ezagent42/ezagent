//! Cryptographic primitives for the EZAgent protocol.
//!
//! Wraps `ed25519-dalek` to provide signing and verification.

use ed25519_dalek::{Signer, SigningKey, Verifier, VerifyingKey};
use serde::{Deserialize, Serialize};

use crate::error::ProtocolError;

/// An Ed25519 signature (64 bytes).
pub type Signature = [u8; 64];

/// An Ed25519 signing keypair.
#[derive(Debug, Clone)]
pub struct Keypair {
    inner: SigningKey,
}

impl Keypair {
    /// Generate a new random keypair.
    pub fn generate() -> Self {
        let mut rng = rand::thread_rng();
        Self {
            inner: SigningKey::generate(&mut rng),
        }
    }

    /// Construct a keypair from 32 secret key bytes.
    pub fn from_bytes(bytes: &[u8; 32]) -> Self {
        Self {
            inner: SigningKey::from_bytes(bytes),
        }
    }

    /// Return the 32-byte secret key.
    pub fn to_bytes(&self) -> [u8; 32] {
        self.inner.to_bytes()
    }

    /// Derive the public key from this keypair.
    pub fn public_key(&self) -> PublicKey {
        PublicKey {
            inner: self.inner.verifying_key(),
        }
    }

    /// Sign a message, returning a 64-byte signature.
    pub fn sign(&self, message: &[u8]) -> Signature {
        let sig = self.inner.sign(message);
        sig.to_bytes()
    }
}

/// An Ed25519 public (verifying) key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PublicKey {
    inner: VerifyingKey,
}

impl PublicKey {
    /// Return the 32-byte public key.
    pub fn as_bytes(&self) -> &[u8; 32] {
        self.inner.as_bytes()
    }

    /// Construct a public key from 32 bytes.
    pub fn from_bytes(bytes: &[u8; 32]) -> Result<Self, ProtocolError> {
        VerifyingKey::from_bytes(bytes)
            .map(|inner| Self { inner })
            .map_err(|_| ProtocolError::InvalidSignature)
    }

    /// Verify a signature over a message.
    pub fn verify(&self, message: &[u8], signature: &Signature) -> Result<(), ProtocolError> {
        let sig = ed25519_dalek::Signature::from_bytes(signature);
        self.inner
            .verify(message, &sig)
            .map_err(|_| ProtocolError::InvalidSignature)
    }
}

impl Serialize for PublicKey {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_bytes(self.as_bytes())
    }
}

impl<'de> Deserialize<'de> for PublicKey {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct BytesVisitor;

        impl<'de> serde::de::Visitor<'de> for BytesVisitor {
            type Value = PublicKey;

            fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
                formatter.write_str("32 bytes for an Ed25519 public key")
            }

            fn visit_bytes<E: serde::de::Error>(self, v: &[u8]) -> Result<PublicKey, E> {
                if v.len() != 32 {
                    return Err(E::invalid_length(v.len(), &"32 bytes"));
                }
                let mut bytes = [0u8; 32];
                bytes.copy_from_slice(v);
                PublicKey::from_bytes(&bytes).map_err(E::custom)
            }

            fn visit_seq<A: serde::de::SeqAccess<'de>>(
                self,
                mut seq: A,
            ) -> Result<PublicKey, A::Error> {
                let mut bytes = [0u8; 32];
                for (i, byte) in bytes.iter_mut().enumerate() {
                    *byte = seq
                        .next_element()?
                        .ok_or_else(|| serde::de::Error::invalid_length(i, &"32 bytes"))?;
                }
                PublicKey::from_bytes(&bytes).map_err(serde::de::Error::custom)
            }
        }

        deserializer.deserialize_bytes(BytesVisitor)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generate_keypair() {
        let kp = Keypair::generate();
        let pk = kp.public_key();
        assert_eq!(pk.as_bytes().len(), 32);
    }

    #[test]
    fn sign_and_verify() {
        let kp = Keypair::generate();
        let pk = kp.public_key();
        let msg = b"hello world";
        let sig = kp.sign(msg);
        assert!(pk.verify(msg, &sig).is_ok());
    }

    #[test]
    fn wrong_key_fails() {
        let kp1 = Keypair::generate();
        let kp2 = Keypair::generate();
        let msg = b"hello";
        let sig = kp1.sign(msg);
        assert!(kp2.public_key().verify(msg, &sig).is_err());
    }

    #[test]
    fn tampered_message_fails() {
        let kp = Keypair::generate();
        let pk = kp.public_key();
        let msg = b"original";
        let sig = kp.sign(msg);
        assert!(pk.verify(b"tampered", &sig).is_err());
    }

    #[test]
    fn from_bytes_roundtrip() {
        let kp = Keypair::generate();
        let bytes = kp.to_bytes();
        let kp2 = Keypair::from_bytes(&bytes);
        assert_eq!(kp.public_key(), kp2.public_key());
    }

    #[test]
    fn public_key_from_bytes_roundtrip() {
        let kp = Keypair::generate();
        let pk = kp.public_key();
        let bytes = *pk.as_bytes();
        let pk2 = PublicKey::from_bytes(&bytes).unwrap();
        assert_eq!(pk, pk2);
    }

    #[test]
    fn serde_roundtrip_json() {
        let kp = Keypair::generate();
        let pk = kp.public_key();
        let json = serde_json::to_string(&pk).unwrap();
        let pk2: PublicKey = serde_json::from_str(&json).unwrap();
        assert_eq!(pk, pk2);
    }
}
