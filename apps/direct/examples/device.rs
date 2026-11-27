// SPDX-License-Identifier: MPL-2.0
//! A device, as the apps are one: for the tests and the measurements. Not part of the product.
//!
//! One JSON object a line. `gather` gives an offer; `connect` takes the answer, connects, proves
//! itself and opens a port on loopback on which every TCP connection is a stream of its own.
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use lobby_direct::{
    auth,
    juice::{self, Agent, Event},
};
use rustls::{
    DigitallySignedStruct, SignatureScheme,
    client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
    pki_types::{CertificateDer, ServerName, UnixTime},
};
use serde_json::{Value, json};
use std::{net::SocketAddr, sync::Arc, time::Duration};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    sync::mpsc::unbounded_channel,
};

fn say(value: Value) {
    println!("{value}");
}

/// Only the certificate that is pinned.
#[derive(Debug)]
struct Pinned {
    sha256: Vec<u8>,
    provider: Arc<rustls::crypto::CryptoProvider>,
}

impl ServerCertVerifier for Pinned {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _: &[CertificateDer<'_>],
        _: &ServerName<'_>,
        _: &[u8],
        _: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        let digest = ring::digest::digest(&ring::digest::SHA256, end_entity);
        if digest.as_ref() == self.sha256 {
            Ok(ServerCertVerified::assertion())
        } else {
            Err(rustls::Error::General("another certificate".into()))
        }
    }
    fn verify_tls12_signature(
        &self,
        _: &[u8],
        _: &CertificateDer<'_>,
        _: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Err(rustls::Error::General("TLS 1.3 only".into()))
    }
    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            signature,
            &self.provider.signature_verification_algorithms,
        )
    }
    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider
            .signature_verification_algorithms
            .supported_schemes()
    }
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    juice::silence();
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    // QUIC's socket first: the agent has to know where it is.
    let socket = std::net::UdpSocket::bind("127.0.0.1:0")?;
    let quic = socket.local_addr()?;
    let (events, mut heard) = unbounded_channel();
    let mut agent: Option<Arc<Agent>> = None;
    let mut socket = Some(socket);
    let mut held = None;
    while let Some(line) = lines.next_line().await? {
        let message: Value = serde_json::from_str(&line)?;
        match message["op"].as_str() {
            Some("gather") => {
                let bind = message["bind"].as_str().map(String::from);
                let one = Agent::open(events.clone(), quic, None, None, bind)?;
                one.gather();
                while let Some(event) = heard.recv().await {
                    if matches!(event, Event::Gathered) {
                        break;
                    }
                }
                say(json!({"event": "offer", "sdp": one.local()}));
                agent = Some(one);
            }
            Some("connect") => {
                let one = agent.clone().ok_or("gather first")?;
                if !one.set_remote(message["sdp"].as_str().unwrap_or("")) {
                    say(json!({"event": "failed", "error": "answer"}));
                    continue;
                }
                juice::carry(&one, quic)?;
                let socket = socket.take().ok_or("once")?;
                match connect(&message, one, socket, &mut heard).await {
                    Ok(connection) => held = Some(connection),
                    Err(error) => say(json!({"event": "failed", "error": error.to_string()})),
                }
            }
            Some("stats") => {
                if let Some(connection) = &held {
                    let connection: &quic::Connection = connection;
                    let stats = connection.stats();
                    say(json!({"event": "stats", "received": stats.udp_rx.bytes}));
                }
            }
            _ => {}
        }
    }
    Ok(())
}

async fn connect(
    message: &Value,
    agent: Arc<Agent>,
    socket: std::net::UdpSocket,
    heard: &mut tokio::sync::mpsc::UnboundedReceiver<Event>,
) -> Result<quic::Connection, Box<dyn std::error::Error>> {
    let wait = tokio::time::sleep(Duration::from_secs(20));
    tokio::pin!(wait);
    loop {
        tokio::select! {
            event = heard.recv() => match event {
                Some(Event::State(juice::STATE_CONNECTED | juice::STATE_COMPLETED)) => break,
                Some(Event::State(juice::STATE_FAILED)) | None => return Err("no path".into()),
                _ => {}
            },
            () = &mut wait => return Err("no path in time".into()),
        }
    }
    let text = |key: &str| message[key].as_str().unwrap_or("").to_string();
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let mut tls = rustls::ClientConfig::builder_with_provider(provider.clone())
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(Pinned {
            sha256: URL_SAFE_NO_PAD.decode(text("fingerprint"))?,
            provider,
        }))
        .with_no_client_auth();
    tls.alpn_protocols = vec![auth::ALPN.to_vec()];
    let mut config = quic::ClientConfig::new(Arc::new(
        quic::crypto::rustls::QuicClientConfig::try_from(tls)?,
    ));
    let mut transport = quic::TransportConfig::default();
    transport
        .stream_receive_window((1u32 << 20).into())
        .receive_window((4u32 << 20).into())
        .max_idle_timeout(Some(Duration::from_secs(30).try_into()?));
    config.transport_config(Arc::new(transport));
    socket.set_nonblocking(true)?;
    let mut endpoint = quic::Endpoint::new(
        quic::EndpointConfig::default(),
        None,
        socket,
        Arc::new(quic::TokioRuntime),
    )?;
    endpoint.set_default_client_config(config);
    let bridge: SocketAddr = agent.bridge()?.local_addr()?;
    let connection = endpoint.connect(bridge, "lobby-direct")?.await?;

    // Apple's QUIC opens a stream of its own, on which nothing comes.
    let (mut silent, _unread) = connection.open_bi().await?;
    silent.write_all(b"-").await?;
    let proof = text("proof");
    if proof != "none" {
        let seed = URL_SAFE_NO_PAD.decode(text("seed"))?;
        let key =
            ring::signature::Ed25519KeyPair::from_seed_unchecked(&seed).map_err(|_| "not a key")?;
        let mut exporter = [0u8; auth::EXPORTER_LENGTH];
        connection
            .export_keying_material(&mut exporter, auth::EXPORTER_LABEL, b"")
            .map_err(|_| "no exporter")?;
        if proof == "replayed" {
            exporter = [9; auth::EXPORTER_LENGTH];
        }
        let (mut send, mut receive) = connection.open_bi().await?;
        send.write_all(&auth::frame(&key, &text("boxId"), &exporter))
            .await?;
        let mut answer = [0u8; 1];
        receive.read_exact(&mut answer).await?;
        if answer != auth::ACCEPTED {
            return Err("not accepted".into());
        }
    }
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let (local, remote) = agent.pair();
    say(
        json!({"event": "up", "port": listener.local_addr()?.port(), "local": local.kind, "remote": remote.kind}),
    );
    let (opened, ended) = (connection.clone(), connection.clone());
    tokio::spawn(async move {
        let reason = ended.closed().await;
        say(json!({"event": "down", "error": reason.to_string()}));
    });
    tokio::spawn(async move {
        let _agent = agent;
        let _silent = (silent, _unread);
        let _endpoint = endpoint;
        while let Ok((tcp, _)) = listener.accept().await {
            let connection = opened.clone();
            tokio::spawn(async move {
                let Ok((mut send, mut receive)) = connection.open_bi().await else {
                    return;
                };
                let (mut from, mut to) = tcp.into_split();
                let up = async {
                    let mut chunk = vec![0u8; 4096];
                    while let Ok(size) = from.read(&mut chunk).await {
                        if size == 0 || send.write_all(&chunk[..size]).await.is_err() {
                            break;
                        }
                    }
                    let _ = send.finish();
                };
                let down = async {
                    let mut chunk = vec![0u8; 16 << 10];
                    while let Ok(Some(size)) = receive.read(&mut chunk).await {
                        if to.write_all(&chunk[..size]).await.is_err() {
                            break;
                        }
                    }
                };
                // The player went away: end our side, and drain what is still on its way, as the
                // app has to with Apple's QUIC.
                let left = tokio::select! { () = up => true, () = down => false };
                if left {
                    let mut chunk = vec![0u8; 16 << 10];
                    while let Ok(Some(_)) = receive.read(&mut chunk).await {}
                }
            });
        }
    });
    Ok(connection)
}
