// SPDX-License-Identifier: MPL-2.0
//! lobby-direct: the Pi's end of a direct connection.
//!
//! Lobby Server starts it, tells it what to do on stdin and hears back on stdout, one JSON object
//! a line. It ends when stdin does. For every session it finds a path to one device (ICE), speaks
//! QUIC over it, lets that device prove itself, and joins each stream to a new connection to
//! Lobby Server's own socket. It opens nothing else, and it listens on loopback only.

use lobby_direct::{
    auth,
    control::{self, Certificate, Command, Open, Start},
    juice::{self, Agent, Candidate, Event},
    rate::Rate,
};
use quic::{
    Connection, Endpoint, RecvStream, SendStream, TransportConfig, VarInt,
    crypto::rustls::QuicServerConfig,
};
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    net::SocketAddr,
    sync::{Arc, Mutex, MutexGuard},
    time::Duration,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    net::UnixStream,
    sync::{
        mpsc::{channel, unbounded_channel},
        watch,
    },
    time::timeout,
};

const MAX_SESSIONS: usize = 16;
const MAX_STREAMS: u32 = 28;
/// From the offer to a device that proved itself.
const SETUP: Duration = Duration::from_secs(30);
/// A server that does not answer must not hold the answer up.
const GATHER: Duration = Duration::from_secs(3);
/// For the last packet to go out.
const GOODBYE: Duration = Duration::from_millis(400);
const PROOF: Duration = Duration::from_secs(10);
const UNPROVEN_STREAMS: usize = 4;
const IDLE: Duration = Duration::from_secs(30);
const KEEP_ALIVE: Duration = Duration::from_secs(8);
/// How much may be under way to one device: what an abandoned film can still cost. Enough for
/// about 80 Mbit/s at 100 ms.
const SEND_WINDOW: u64 = 1 << 20;
/// What a device sends is requests.
const STREAM_RECEIVE_WINDOW: u32 = 128 << 10;
const RECEIVE_WINDOW: u32 = 512 << 10;
const CHUNK: usize = 16 << 10;

const CODE_CLOSED: VarInt = VarInt::from_u32(0);
const CODE_REFUSED: VarInt = VarInt::from_u32(1);
const CODE_GONE: VarInt = VarInt::from_u32(2);

fn say(value: Value) {
    use std::io::Write;
    let mut out = std::io::stdout().lock();
    // Nobody is there any more: stdin ends too, and with it this program.
    let _ = writeln!(out, "{value}");
    let _ = out.flush();
}

struct Session {
    agent: Arc<Agent>,
    device: [u8; 32],
    bridge: SocketAddr,
    connection: Option<Connection>,
    /// Goes to true when the session is over.
    over: watch::Sender<bool>,
}

struct Shared {
    start: Start,
    rate: Option<Rate>,
    sessions: Mutex<HashMap<String, Session>>,
}

impl Shared {
    fn sessions(&self) -> MutexGuard<'_, HashMap<String, Session>> {
        self.sessions.lock().expect("nobody panics in here")
    }

    /// Ends a session, once, and says why.
    fn end(&self, id: &str, reason: &str) {
        let Some(session) = self.sessions().remove(id) else {
            return;
        };
        let mut sent = 0;
        let mut lost = 0;
        if let Some(connection) = &session.connection {
            let stats = connection.stats();
            sent = stats.udp_tx.bytes;
            lost = stats.path.lost_packets;
            connection.close(CODE_CLOSED, b"");
        }
        let _ = session.over.send(true);
        // The path stays a moment, so that the device hears that it is over.
        let agent = session.agent;
        tokio::spawn(async move {
            tokio::time::sleep(GOODBYE).await;
            drop(agent);
        });
        say(json!({"event": "closed", "id": id, "reason": reason, "sent": sent, "lost": lost}));
    }
}

fn tls(certificate: Certificate) -> Result<QuicServerConfig, Box<dyn std::error::Error>> {
    let chain = certificate
        .chain
        .into_iter()
        .map(CertificateDer::from)
        .collect();
    let key = PrivateKeyDer::Pkcs8(certificate.key.into());
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let mut tls = rustls::ServerConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])?
        // The device proves itself on its first stream instead (auth.rs).
        .with_no_client_auth()
        .with_single_cert(chain, key)?;
    tls.alpn_protocols = vec![auth::ALPN.to_vec()];
    // Every connection proves everything again.
    tls.send_tls13_tickets = 0;
    Ok(QuicServerConfig::try_from(tls)?)
}

fn server_config(
    certificate: Certificate,
) -> Result<quic::ServerConfig, Box<dyn std::error::Error>> {
    let mut transport = TransportConfig::default();
    transport
        .max_concurrent_bidi_streams(MAX_STREAMS.into())
        .max_concurrent_uni_streams(0u8.into())
        .max_idle_timeout(Some(IDLE.try_into()?))
        .keep_alive_interval(Some(KEEP_ALIVE))
        .send_window(SEND_WINDOW)
        .stream_receive_window(STREAM_RECEIVE_WINDOW.into())
        .receive_window(RECEIVE_WINDOW.into())
        .datagram_receive_buffer_size(None)
        .initial_mtu(1200)
        .mtu_discovery_config({
            let mut discovery = quic::MtuDiscoveryConfig::default();
            discovery.upper_bound(1350);
            Some(discovery)
        })
        .congestion_controller_factory(congestion());
    let mut config = quic::ServerConfig::with_crypto(Arc::new(tls(certificate)?));
    config
        .transport_config(Arc::new(transport))
        // ICE moves packets. A peer address that changes is not a device that moved.
        .migration(false)
        .max_incoming(MAX_SESSIONS)
        .incoming_buffer_size(64 << 10)
        .incoming_buffer_size_total(256 << 10);
    Ok(config)
}

fn congestion() -> Arc<dyn quic::congestion::ControllerFactory + Send + Sync> {
    #[cfg(feature = "measure")]
    match std::env::var("LOBBY_DIRECT_CC").as_deref() {
        Ok("cubic") => return Arc::new(quic::congestion::CubicConfig::default()),
        Ok("newreno") => return Arc::new(quic::congestion::NewRenoConfig::default()),
        _ => {}
    }
    Arc::new(quic::congestion::BbrConfig::default())
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> std::process::ExitCode {
    // A panic's message can hold anything.
    std::panic::set_hook(Box::new(|info| {
        let at = info
            .location()
            .map(|one| format!("{}:{}", one.file(), one.line()));
        eprintln!("lobby-direct: panic at {}", at.unwrap_or_default());
    }));
    match run().await {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("lobby-direct: {error}");
            std::process::ExitCode::FAILURE
        }
    }
}

async fn run() -> Result<(), Box<dyn std::error::Error>> {
    juice::silence();
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    let Some(first) = lines.next_line().await? else {
        return Ok(());
    };
    let Some(Command::Start(mut start)) = control::read(&first) else {
        return Err("the first line must say how to start".into());
    };
    drop(first);
    let certificate = std::mem::replace(
        &mut start.certificate,
        Certificate {
            chain: vec![],
            key: vec![],
        },
    );
    let endpoint = Endpoint::server(server_config(certificate)?, "127.0.0.1:0".parse()?)?;
    let quic = endpoint.local_addr()?;
    let shared = Arc::new(Shared {
        rate: Rate::new(start.max_upload_bits),
        start,
        sessions: Mutex::default(),
    });
    say(json!({"event": "ready", "version": env!("CARGO_PKG_VERSION")}));

    tokio::spawn(accept(endpoint.clone(), shared.clone()));
    while let Some(line) = lines.next_line().await? {
        match control::read(&line) {
            Some(Command::Open(open)) => {
                let id = open.id.clone();
                if let Err(reason) = open_session(open, quic, &shared) {
                    say(
                        json!({"event": "closed", "id": id, "reason": reason, "sent": 0, "lost": 0}),
                    );
                }
            }
            Some(Command::Close(id)) => shared.end(&id, "asked"),
            Some(Command::Certificate(certificate)) => match server_config(certificate) {
                Ok(config) => endpoint.set_server_config(Some(config)),
                Err(error) => eprintln!("lobby-direct: the certificate cannot be used: {error}"),
            },
            Some(Command::Start(_)) | None => {
                eprintln!("lobby-direct: a line that means nothing")
            }
        }
    }
    // Told to go: say goodbye to whoever is here, so that nobody waits for a timeout.
    endpoint.close(CODE_CLOSED, b"");
    tokio::time::sleep(GOODBYE).await;
    Ok(())
}

// ---- A session: the path to one device ----

fn open_session(open: Open, quic: SocketAddr, shared: &Arc<Shared>) -> Result<(), &'static str> {
    if shared.sessions().contains_key(&open.id) {
        return Err("twice");
    }
    if shared.sessions().len() >= MAX_SESSIONS {
        return Err("full");
    }
    let (events, mut heard) = unbounded_channel();
    let agent =
        Agent::open(events, quic, open.stun, open.turn, open.bind).map_err(|_| "no agent")?;
    let bridge = agent
        .bridge()
        .and_then(|one| one.local_addr())
        .map_err(|_| "no bridge")?;
    // The device's side first: that makes this end the one that answers.
    if !agent.set_remote(&open.offer) {
        return Err("the offer is not one");
    }
    juice::carry(&agent, quic).map_err(|_| "no thread")?;
    let (over, mut ended) = watch::channel(false);
    shared.sessions().insert(
        open.id.clone(),
        Session {
            agent: agent.clone(),
            device: open.device,
            bridge,
            connection: None,
            over,
        },
    );
    if !agent.gather() {
        shared.end(&open.id, "could not look for addresses");
        return Ok(());
    }

    let (id, shared) = (open.id, shared.clone());
    let weak = Arc::downgrade(&agent);
    drop(agent);
    tokio::spawn(async move {
        let mut answered = false;
        let answer = |answered: &mut bool| {
            if !*answered && let Some(agent) = weak.upgrade() {
                *answered = true;
                say(json!({"event": "answer", "id": id, "sdp": agent.local()}));
            }
        };
        let gathered = tokio::time::sleep(GATHER);
        let setup = tokio::time::sleep(SETUP);
        tokio::pin!(gathered, setup);
        loop {
            tokio::select! {
                event = heard.recv() => match event {
                    Some(Event::Gathered) => answer(&mut answered),
                    Some(Event::State(juice::STATE_FAILED)) => {
                        shared.end(&id, "no path");
                        return;
                    }
                    Some(Event::State(_)) => {}
                    None => return,
                },
                () = &mut gathered, if !answered => answer(&mut answered),
                () = &mut setup, if !setup.is_elapsed() => {
                    let up = shared
                        .sessions()
                        .get(&id)
                        .is_some_and(|one| one.connection.is_some());
                    if !up {
                        shared.end(&id, "too late");
                        return;
                    }
                }
                _ = ended.changed() => return,
            }
        }
    });
    Ok(())
}

// ---- A connection: QUIC over that path ----

async fn accept(endpoint: Endpoint, shared: Arc<Shared>) {
    while let Some(incoming) = endpoint.accept().await {
        let from = incoming.remote_address();
        let wanted = shared
            .sessions()
            .iter()
            .find(|(_, one)| one.bridge == from && one.connection.is_none())
            .map(|(id, one)| (id.clone(), one.device));
        // Anything on this machine can send a packet here. Only our own bridges are heard.
        let Some((id, device)) = wanted else {
            incoming.ignore();
            continue;
        };
        let shared = shared.clone();
        tokio::spawn(async move {
            let Ok(Ok(connection)) = timeout(PROOF, incoming).await else {
                return;
            };
            let mut over = {
                let sessions = shared.sessions();
                match sessions.get(&id) {
                    Some(session) if session.connection.is_none() => session.over.subscribe(),
                    _ => {
                        connection.close(CODE_REFUSED, b"");
                        return;
                    }
                }
            };
            let proven = tokio::select! {
                proven = timeout(PROOF, prove(&connection, &device, &shared.start.box_id)) => {
                    matches!(proven, Ok(Some(())))
                }
                _ = over.changed() => false,
            };
            if !proven {
                connection.close(CODE_REFUSED, b"");
                shared.end(&id, "not the device");
                return;
            }
            let (local, remote) = {
                let mut sessions = shared.sessions();
                match sessions.get_mut(&id) {
                    // One connection a session: a second handshake on the same path is refused.
                    Some(session) if session.connection.is_none() => {
                        session.connection = Some(connection.clone());
                        session.agent.pair()
                    }
                    _ => {
                        drop(sessions);
                        connection.close(CODE_REFUSED, b"");
                        return;
                    }
                }
            };
            say(up(&id, &local, &remote));
            serve(&connection, &id, &shared, over).await;
            let reason = if connection
                .close_reason()
                .is_some_and(|one| matches!(one, quic::ConnectionError::TimedOut))
            {
                "silent"
            } else {
                "left"
            };
            shared.end(&id, reason);
        });
    }
}

fn up(id: &str, local: &Candidate, remote: &Candidate) -> Value {
    // A relay's address says nothing about the device.
    let address = (remote.kind != "relay").then_some(&remote.address);
    json!({"event": "up", "id": id, "local": local.kind, "remote": remote.kind, "address": address})
}

/// Waits for the device to prove itself on one of its first streams. It need not be the very
/// first: Apple's QUIC opens one by itself, on which nothing is ever said.
async fn prove(connection: &Connection, device: &[u8; 32], box_id: &str) -> Option<()> {
    let mut exporter = [0u8; auth::EXPORTER_LENGTH];
    connection
        .export_keying_material(&mut exporter, auth::EXPORTER_LABEL, b"")
        .ok()?;
    let (found, mut frames) = channel(UNPROVEN_STREAMS);
    let mut streams = 0;
    loop {
        tokio::select! {
            stream = connection.accept_bi() => {
                let (send, mut receive) = stream.ok()?;
                streams += 1;
                if streams > UNPROVEN_STREAMS {
                    return None;
                }
                let found = found.clone();
                // Kept for as long as the connection: to stop a stream is something Apple's QUIC
                // does not take well.
                tokio::spawn(async move {
                    let mut frame = [0u8; auth::FRAME_LENGTH];
                    if receive.read_exact(&mut frame).await.is_ok() {
                        let _ = found.send((frame, send)).await;
                    }
                });
            }
            Some((frame, mut send)) = frames.recv() => {
                if !auth::proves(&frame, device, box_id, &exporter) {
                    return None;
                }
                send.write_all(auth::ACCEPTED).await.ok()?;
                return send.finish().ok();
            }
        }
    }
}

async fn serve(
    connection: &Connection,
    id: &str,
    shared: &Arc<Shared>,
    mut over: watch::Receiver<bool>,
) {
    loop {
        tokio::select! {
            stream = connection.accept_bi() => match stream {
                Ok((send, receive)) => {
                    let (id, shared, over) = (id.to_string(), shared.clone(), over.clone());
                    let connection = connection.clone();
                    tokio::spawn(async move {
                        tokio::select! {
                            () = join(send, receive, &id, &shared) => {}
                            _ = gone(over) => {}
                            _ = connection.closed() => {}
                        }
                    });
                }
                Err(_) => return,
            },
            _ = over.changed() => {
                connection.close(CODE_GONE, b"");
                return;
            }
        }
    }
}

async fn gone(mut over: watch::Receiver<bool>) {
    let _ = over.wait_for(|one| *one).await;
}

/// Joins one stream to a new connection to Lobby Server.
async fn join(mut send: SendStream, mut receive: RecvStream, id: &str, shared: &Shared) {
    // Nothing is opened for a stream on which nothing is said.
    let mut first = vec![0u8; CHUNK / 4];
    let size = match receive.read(&mut first).await {
        Ok(Some(size)) => size,
        _ => {
            let _ = send.finish();
            return;
        }
    };
    let Ok(mut socket) = UnixStream::connect(&shared.start.socket).await else {
        let _ = send.finish();
        return;
    };
    let hello = format!("LOBBY/1 {} {id}\n", shared.start.secret);
    if socket.write_all(hello.as_bytes()).await.is_err()
        || socket.write_all(&first[..size]).await.is_err()
    {
        let _ = send.finish();
        return;
    }
    drop(first);
    let (from_server, to_server) = socket.into_split();
    // The device keeps its side open while it reads. When that side ends, the player went away,
    // and what it asked for is not sent any further.
    tokio::select! {
        () = up_stream(receive, to_server) => {}
        () = down_stream(from_server, &mut send, shared.rate.as_ref()) => {}
    }
    // A clean end, never a reset: Apple's QUIC takes the whole connection down with a reset
    // stream that still has data under way.
    if send.finish().is_ok() {
        let _ = timeout(IDLE, send.stopped()).await;
    }
}

async fn up_stream(mut receive: RecvStream, mut to: tokio::net::unix::OwnedWriteHalf) {
    let mut chunk = vec![0u8; CHUNK / 4];
    while let Ok(Some(size)) = receive.read(&mut chunk).await {
        if to.write_all(&chunk[..size]).await.is_err() {
            return;
        }
    }
}

async fn down_stream(
    mut from: tokio::net::unix::OwnedReadHalf,
    send: &mut SendStream,
    rate: Option<&Rate>,
) {
    let mut chunk = vec![0u8; CHUNK];
    while let Ok(size) = from.read(&mut chunk).await {
        if size == 0 {
            return;
        }
        if let Some(rate) = rate {
            rate.take(size).await;
        }
        if send.write_all(&chunk[..size]).await.is_err() {
            return;
        }
    }
}
