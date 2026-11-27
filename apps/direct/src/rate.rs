// SPDX-License-Identifier: MPL-2.0
//! Keeps everything that is sent together under one speed, so that the home's upload stays usable.

use std::{sync::Mutex, time::Duration};
use tokio::time::Instant;

/// How far ahead of the steady speed a burst may run.
const BURST: Duration = Duration::from_millis(20);

pub struct Rate {
    bits_per_second: u64,
    next: Mutex<Instant>,
}

impl Rate {
    /// `None` for no limit.
    pub fn new(bits_per_second: u64) -> Option<Self> {
        (bits_per_second > 0).then(|| Self {
            bits_per_second,
            next: Mutex::new(Instant::now()),
        })
    }

    fn cost(&self, bytes: usize) -> Duration {
        Duration::from_nanos(bytes as u64 * 8 * 1_000_000_000 / self.bits_per_second)
    }

    /// Waits until `bytes` may go out. First come, first served, whichever stream asks.
    pub async fn take(&self, bytes: usize) {
        let at = {
            let mut next = self.next.lock().expect("nobody panics in here");
            let now = Instant::now();
            let at = (*next).max(now.checked_sub(BURST).unwrap_or(now));
            *next = at + self.cost(bytes);
            at
        };
        tokio::time::sleep_until(at).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn none_is_no_limit() {
        assert!(Rate::new(0).is_none());
    }

    #[tokio::test(start_paused = true)]
    async fn holds_the_speed() {
        let rate = Rate::new(8_000_000).expect("a limit"); // a byte per microsecond
        let start = Instant::now();
        for _ in 0..100 {
            rate.take(10_000).await;
        }
        // One second's worth; what the last one costs is paid by the next.
        let took = start.elapsed();
        assert!(took >= Duration::from_millis(960), "{took:?}");
        assert!(took <= Duration::from_millis(1_000), "{took:?}");
    }

    #[tokio::test(start_paused = true)]
    async fn two_streams_share_it() {
        let rate = std::sync::Arc::new(Rate::new(8_000_000).expect("a limit"));
        let start = Instant::now();
        let each = |rate: std::sync::Arc<Rate>| async move {
            for _ in 0..50 {
                rate.take(10_000).await;
            }
        };
        tokio::join!(each(rate.clone()), each(rate.clone()));
        assert!(start.elapsed() >= Duration::from_millis(960));
    }
}
