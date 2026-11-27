// SPDX-License-Identifier: MPL-2.0
#ifndef LOBBY_ICE_H
#define LOBBY_ICE_H
#include <stdint.h>
#include <stddef.h>
// One ICE agent with a UDP socket on 127.0.0.1. What QUIC sends to that port goes out over the chosen
// path (direct or the owner's TURN), what arrives goes back to the port QUIC sends from.
typedef struct {
    const char *stun_host; uint16_t stun_port;
    const char *turn_host; uint16_t turn_port; const char *turn_user; const char *turn_password;
    const char *bind;
} lobby_ice_config;
// Events: 0 = gathering done, 1 = state changed (value is juice_state_t).
typedef void (*lobby_ice_event)(int32_t id, int32_t event, int32_t value);
int32_t lobby_ice_open(const lobby_ice_config *config, lobby_ice_event event);   // id, or -1
int lobby_ice_gather(int32_t id);
int lobby_ice_local(int32_t id, char *buffer, size_t size);
int lobby_ice_remote(int32_t id, const char *sdp);
int lobby_ice_pair(int32_t id, char *local, char *remote, size_t size);
uint16_t lobby_ice_port(int32_t id);
// Milliseconds since the last packet came from the other end over the path (UINT64_MAX: none yet,
// or no such agent). STUN of the agent's own is not counted: only what QUIC hears.
uint64_t lobby_ice_quiet_ms(int32_t id);
void lobby_ice_close(int32_t id);
#endif
