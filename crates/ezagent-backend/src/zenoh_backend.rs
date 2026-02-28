//! Zenoh-based network backend.
//!
//! [`ZenohBackend`] implements [`NetworkBackend`] on top of a
//! [Zenoh](https://zenoh.io) session, providing pub/sub, queryable
//! registration, and request/reply semantics (bus-spec 4.3).

use std::sync::Arc;

use async_trait::async_trait;

use crate::traits::{BackendError, NetworkBackend};

/// Configuration wrapper for creating a [`ZenohBackend`].
pub struct ZenohConfig {
    /// The underlying Zenoh configuration.
    pub config: zenoh::Config,
}

impl ZenohConfig {
    /// Default peer configuration with multicast scouting enabled.
    pub fn peer_default() -> Self {
        Self {
            config: zenoh::Config::default(),
        }
    }

    /// Peer configuration that connects to a specific router endpoint.
    ///
    /// # Arguments
    /// * `endpoint` - A Zenoh endpoint string, e.g. `"tcp/127.0.0.1:7447"`.
    pub fn peer_with_router(endpoint: &str) -> Self {
        let mut config = zenoh::Config::default();
        let endpoints_json = serde_json::json!([endpoint]).to_string();
        config
            .insert_json5("connect/endpoints", &endpoints_json)
            .expect("valid connect/endpoints config");
        Self { config }
    }

    /// Peer configuration with multicast scouting disabled (for isolated tests).
    pub fn peer_isolated() -> Self {
        let mut config = zenoh::Config::default();
        config
            .insert_json5("scouting/multicast/enabled", "false")
            .expect("valid scouting config");
        Self { config }
    }
}

/// Network backend built on a Zenoh session.
pub struct ZenohBackend {
    session: zenoh::Session,
}

impl ZenohBackend {
    /// Open a new Zenoh session with the given configuration.
    pub async fn new(config: ZenohConfig) -> Result<Self, BackendError> {
        let session = zenoh::open(config.config)
            .await
            .map_err(|e| BackendError::Network(e.to_string()))?;
        Ok(Self { session })
    }

    /// Return a reference to the underlying Zenoh session.
    pub fn session(&self) -> &zenoh::Session {
        &self.session
    }
}

#[async_trait]
impl NetworkBackend for ZenohBackend {
    async fn publish(&self, key_expr: &str, payload: &[u8]) -> Result<(), BackendError> {
        self.session
            .put(key_expr, payload.to_vec())
            .await
            .map_err(|e| BackendError::Network(e.to_string()))
    }

    async fn subscribe(
        &self,
        key_expr: &str,
    ) -> Result<tokio::sync::mpsc::Receiver<Vec<u8>>, BackendError> {
        let subscriber = self
            .session
            .declare_subscriber(key_expr)
            .await
            .map_err(|e| BackendError::Network(e.to_string()))?;

        let (tx, rx) = tokio::sync::mpsc::channel(256);

        tokio::spawn(async move {
            while let Ok(sample) = subscriber.recv_async().await {
                let bytes = sample.payload().to_bytes().to_vec();
                if tx.send(bytes).await.is_err() {
                    // Receiver dropped; stop the loop.
                    break;
                }
            }
        });

        Ok(rx)
    }

    async fn register_queryable(
        &self,
        key_expr: &str,
        handler: Arc<dyn Fn(Vec<u8>) -> Vec<u8> + Send + Sync>,
    ) -> Result<(), BackendError> {
        let queryable = self
            .session
            .declare_queryable(key_expr)
            .await
            .map_err(|e| BackendError::Network(e.to_string()))?;

        let key = key_expr.to_string();

        tokio::spawn(async move {
            while let Ok(query) = queryable.recv_async().await {
                let payload_bytes: Vec<u8> = query
                    .payload()
                    .map(|p| p.to_bytes().to_vec())
                    .unwrap_or_default();
                let response = handler(payload_bytes);
                if let Err(e) = query.reply(&key, response).await {
                    eprintln!("queryable reply error: {e}");
                }
            }
        });

        Ok(())
    }

    async fn query(&self, key_expr: &str, payload: Option<&[u8]>) -> Result<Vec<u8>, BackendError> {
        let mut builder = self.session.get(key_expr);
        if let Some(p) = payload {
            builder = builder.payload(p.to_vec());
        }
        let replies = builder
            .await
            .map_err(|e| BackendError::Network(e.to_string()))?;

        let reply = replies
            .recv_async()
            .await
            .map_err(|e| BackendError::Network(e.to_string()))?;

        match reply.result() {
            Ok(sample) => Ok(sample.payload().to_bytes().to_vec()),
            Err(err) => Err(BackendError::Network(format!(
                "query error reply: {:?}",
                err.payload().to_bytes()
            ))),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn session_opens_with_peer_default() {
        let backend = ZenohBackend::new(ZenohConfig::peer_default()).await;
        assert!(backend.is_ok(), "session should open: {:?}", backend.err());
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn pub_sub_roundtrip() {
        // Use isolated config so tests don't interfere with each other.
        let backend = ZenohBackend::new(ZenohConfig::peer_isolated())
            .await
            .expect("session should open");

        let key = "test/ezagent/roundtrip";
        let mut rx = backend.subscribe(key).await.expect("subscribe should work");

        // Give subscriber a moment to be established.
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;

        let payload = b"hello zenoh";
        backend
            .publish(key, payload)
            .await
            .expect("publish should work");

        let received = tokio::time::timeout(std::time::Duration::from_secs(2), rx.recv())
            .await
            .expect("should receive within 2s")
            .expect("channel should not be closed");

        assert_eq!(received, payload.to_vec());
    }
}
