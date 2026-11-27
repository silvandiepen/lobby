// SPDX-License-Identifier: MPL-2.0
//! A thin binding to libjuice: one ICE agent, joined to a UDP socket on loopback.
//!
//! QUIC runs on its own loopback socket and sees every agent as one peer address. That address is
//! the agent's bridge, and the endpoint takes nothing from any other.

use std::{
    ffi::{CStr, CString, c_char, c_int, c_void},
    net::{SocketAddr, UdpSocket},
    sync::Arc,
};
use tokio::sync::mpsc::UnboundedSender;

#[repr(C)]
struct Turn {
    host: *const c_char,
    username: *const c_char,
    password: *const c_char,
    port: u16,
}

#[repr(C)]
struct Config {
    mode: c_int,
    stun_host: *const c_char,
    stun_port: u16,
    turns: *const Turn,
    turn_count: c_int,
    bind: *const c_char,
    port_begin: u16,
    port_end: u16,
    on_state: Option<extern "C" fn(*mut c_void, c_int, *mut c_void)>,
    on_candidate: Option<extern "C" fn(*mut c_void, *const c_char, *mut c_void)>,
    on_gathered: Option<extern "C" fn(*mut c_void, *mut c_void)>,
    on_recv: Option<extern "C" fn(*mut c_void, *const c_char, usize, *mut c_void)>,
    user: *mut c_void,
}

unsafe extern "C" {
    fn juice_set_log_level(level: c_int);
    fn juice_set_log_handler(handler: Option<extern "C" fn(c_int, *const c_char)>);
    fn juice_create(config: *const Config) -> *mut c_void;
    fn juice_destroy(agent: *mut c_void);
    fn juice_gather_candidates(agent: *mut c_void) -> c_int;
    fn juice_get_local_description(agent: *mut c_void, out: *mut c_char, size: usize) -> c_int;
    fn juice_set_remote_description(agent: *mut c_void, sdp: *const c_char) -> c_int;
    fn juice_set_remote_gathering_done(agent: *mut c_void) -> c_int;
    fn juice_send(agent: *mut c_void, data: *const c_char, size: usize) -> c_int;
    fn juice_get_selected_candidates(
        agent: *mut c_void,
        local: *mut c_char,
        local_size: usize,
        remote: *mut c_char,
        remote_size: usize,
    ) -> c_int;
}

pub const STATE_CONNECTED: i32 = 3;
pub const STATE_COMPLETED: i32 = 4;
pub const STATE_FAILED: i32 = 5;
const DESCRIPTION_SIZE: usize = 4096;
const CANDIDATE_SIZE: usize = 256;
/// What one agent may hold between QUIC and the network.
const SOCKET_BUFFER: usize = 512 << 10;

pub enum Event {
    Gathered,
    State(i32),
}

pub struct Stun {
    pub host: String,
    pub port: u16,
}

pub struct TurnServer {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub pass: String,
}

/// One side of the pair that won, as far as it may be told.
#[derive(Default, Clone)]
pub struct Candidate {
    pub kind: String,
    pub address: String,
}

struct Context {
    events: UnboundedSender<Event>,
    socket: UdpSocket,
    quic: SocketAddr,
}

pub struct Agent {
    raw: *mut c_void,
    /// Always there until `drop` takes it.
    context: Option<Box<Context>>,
}

// SAFETY: libjuice takes its own lock inside every call, and the context is only read.
unsafe impl Send for Agent {}
unsafe impl Sync for Agent {}

extern "C" fn discard(_level: c_int, _message: *const c_char) {}

extern "C" fn on_state(_agent: *mut c_void, state: c_int, user: *mut c_void) {
    // SAFETY: `user` is the agent's own context, which outlives the agent.
    let context = unsafe { &*(user as *const Context) };
    let _ = context.events.send(Event::State(state));
}

extern "C" fn on_gathered(_agent: *mut c_void, user: *mut c_void) {
    // SAFETY: as above.
    let context = unsafe { &*(user as *const Context) };
    let _ = context.events.send(Event::Gathered);
}

extern "C" fn on_recv(_agent: *mut c_void, data: *const c_char, size: usize, user: *mut c_void) {
    // SAFETY: as above, and libjuice owns `size` bytes at `data` during the call.
    let (context, packet) = unsafe {
        (
            &*(user as *const Context),
            std::slice::from_raw_parts(data as *const u8, size),
        )
    };
    // A full buffer is a lost packet, which is QUIC's everyday business.
    let _ = context.socket.send_to(packet, context.quic);
}

/// Its log goes to stdout, which is the control channel: none of it may be written anywhere.
pub fn silence() {
    const NONE: c_int = 6;
    // SAFETY: plain setters, called once before any agent exists.
    unsafe {
        juice_set_log_level(NONE);
        juice_set_log_handler(Some(discard));
    }
}

impl Agent {
    pub fn open(
        events: UnboundedSender<Event>,
        quic: SocketAddr,
        stun: Option<Stun>,
        turn: Option<TurnServer>,
        bind: Option<String>,
    ) -> std::io::Result<Arc<Self>> {
        let socket = UdpSocket::bind("127.0.0.1:0")?;
        let context = Box::new(Context {
            events,
            socket,
            quic,
        });
        // Kept until juice_create returns: it makes copies of all of them.
        let mut keep: Vec<CString> = Vec::new();
        let mut text = |value: &str| -> std::io::Result<*const c_char> {
            let owned = CString::new(value).map_err(std::io::Error::other)?;
            let pointer = owned.as_ptr();
            keep.push(owned);
            Ok(pointer)
        };
        let turn = match &turn {
            Some(one) => Some(Turn {
                host: text(&one.host)?,
                username: text(&one.user)?,
                password: text(&one.pass)?,
                port: one.port,
            }),
            None => None,
        };
        let config = Config {
            mode: 0,
            stun_host: match &stun {
                Some(one) => text(&one.host)?,
                None => std::ptr::null(),
            },
            stun_port: stun.as_ref().map_or(0, |one| one.port),
            turns: turn
                .as_ref()
                .map_or(std::ptr::null(), |one| one as *const _),
            turn_count: turn.is_some().into(),
            bind: match &bind {
                Some(one) => text(one)?,
                None => std::ptr::null(),
            },
            port_begin: 0,
            port_end: 0,
            on_state: Some(on_state),
            on_candidate: None,
            on_gathered: Some(on_gathered),
            on_recv: Some(on_recv),
            user: &*context as *const Context as *mut c_void,
        };
        // SAFETY: every pointer in `config` lives until the end of this function, and `user`
        // until the agent is destroyed.
        let raw = unsafe { juice_create(&config) };
        if raw.is_null() {
            return Err(std::io::Error::other("no agent"));
        }
        Ok(Arc::new(Agent {
            raw,
            context: Some(context),
        }))
    }

    pub fn set_remote(&self, sdp: &str) -> bool {
        let Ok(text) = CString::new(sdp) else {
            return false;
        };
        // SAFETY: a live agent and a terminated string.
        unsafe {
            juice_set_remote_description(self.raw, text.as_ptr()) == 0
                && juice_set_remote_gathering_done(self.raw) == 0
        }
    }

    pub fn gather(&self) -> bool {
        // SAFETY: a live agent.
        unsafe { juice_gather_candidates(self.raw) == 0 }
    }

    pub fn local(&self) -> String {
        let mut out = vec![0 as c_char; DESCRIPTION_SIZE];
        // SAFETY: the buffer is as long as it says, and stays terminated.
        unsafe {
            juice_get_local_description(self.raw, out.as_mut_ptr(), out.len());
            CStr::from_ptr(out.as_ptr())
        }
        .to_string_lossy()
        .into()
    }

    /// The pair in use: this end's and the other's.
    pub fn pair(&self) -> (Candidate, Candidate) {
        let mut local = vec![0 as c_char; CANDIDATE_SIZE];
        let mut remote = vec![0 as c_char; CANDIDATE_SIZE];
        // SAFETY: both buffers are as long as they say.
        unsafe {
            juice_get_selected_candidates(
                self.raw,
                local.as_mut_ptr(),
                local.len(),
                remote.as_mut_ptr(),
                remote.len(),
            );
        }
        (read_candidate(&local), read_candidate(&remote))
    }

    /// The loopback socket on which QUIC finds this agent.
    pub fn bridge(&self) -> std::io::Result<UdpSocket> {
        self.context
            .as_ref()
            .ok_or(std::io::ErrorKind::NotConnected)?
            .socket
            .try_clone()
    }

    pub fn send(&self, packet: &[u8]) {
        // SAFETY: a live agent, and it copies what it is given.
        unsafe { juice_send(self.raw, packet.as_ptr() as *const c_char, packet.len()) };
    }
}

impl Drop for Agent {
    fn drop(&mut self) {
        struct Raw(*mut c_void);
        // SAFETY: libjuice agents may be used from any thread.
        unsafe impl Send for Raw {}
        impl Raw {
            fn destroy(self) {
                // SAFETY: the last owner let go, so no call is inside, and after this none comes
                // back from it.
                unsafe { juice_destroy(self.0) };
            }
        }
        let raw = Raw(self.raw);
        let context = self.context.take();
        // It waits for a name that is being looked up, which can take seconds.
        std::thread::spawn(move || {
            raw.destroy();
            drop(context);
        });
    }
}

fn read_candidate(text: &[c_char]) -> Candidate {
    // SAFETY: zeroed before, and the last byte is never written by libjuice.
    let text = unsafe { CStr::from_ptr(text.as_ptr()) }.to_string_lossy();
    let fields: Vec<&str> = text.split(' ').collect();
    Candidate {
        address: fields.get(4).map(|one| one.to_string()).unwrap_or_default(),
        kind: fields.get(7).map(|one| one.to_string()).unwrap_or_default(),
    }
}

/// Carries packets from QUIC to the agent on a thread of its own, so that a busy loop does not
/// delay them. Ends when the agent is gone.
pub fn carry(agent: &Arc<Agent>, quic: SocketAddr) -> std::io::Result<()> {
    let socket = agent.bridge()?;
    socket.set_read_timeout(Some(std::time::Duration::from_millis(500)))?;
    grow(&socket);
    let weak = Arc::downgrade(agent);
    std::thread::Builder::new()
        .stack_size(128 << 10)
        .spawn(move || {
            let mut packet = [0u8; 2048];
            loop {
                let received = socket.recv_from(&mut packet);
                let Some(agent) = weak.upgrade() else { break };
                if let Ok((size, from)) = received
                    && from == quic
                {
                    agent.send(&packet[..size]);
                }
            }
        })?;
    Ok(())
}

fn grow(socket: &UdpSocket) {
    // Best effort: the system may give less, and a packet that does not fit is one that is lost.
    let reference = socket2::SockRef::from(socket);
    let _ = reference.set_recv_buffer_size(SOCKET_BUFFER);
    let _ = reference.set_send_buffer_size(SOCKET_BUFFER);
}
