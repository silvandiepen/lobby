// SPDX-License-Identifier: MPL-2.0
// One libjuice agent joined to a UDP socket on 127.0.0.1, so that Apple's QUIC can speak through it.
#include "CLobbyIce.h"
#include "juice/juice.h"
#include <arpa/inet.h>
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define MAX_AGENTS 8

typedef struct {
    juice_agent_t *agent;
    int fd;
    uint16_t port;
    lobby_ice_event event;
    int32_t id;
    pthread_t thread;
    atomic_bool stop;
    _Atomic uint16_t peer;
    // When the other end was last heard, in milliseconds of the system's steady clock. 0: never.
    _Atomic uint64_t heard;
    int users;
} agent_t;

static agent_t *agents[MAX_AGENTS];
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t idle = PTHREAD_COND_INITIALIZER;
static int32_t counter = 0;

// A call into an agent holds it, so that closing waits until no call is inside.
static agent_t *enter(int32_t id) {
    agent_t *found = NULL;
    pthread_mutex_lock(&lock);
    for (int i = 0; i < MAX_AGENTS; i++) {
        if (agents[i] && agents[i]->id == id) {
            found = agents[i];
            found->users++;
        }
    }
    pthread_mutex_unlock(&lock);
    return found;
}

static void leave(agent_t *one) {
    pthread_mutex_lock(&lock);
    one->users--;
    pthread_cond_broadcast(&idle);
    pthread_mutex_unlock(&lock);
}

static struct sockaddr_in loopback(uint16_t port) {
    struct sockaddr_in to = {
        .sin_len = sizeof to, .sin_family = AF_INET, .sin_port = port, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    return to;
}

static void on_state(juice_agent_t *agent, juice_state_t state, void *user) {
    (void)agent;
    agent_t *one = user;
    one->event(one->id, 1, (int32_t)state);
}

static void on_gathered(juice_agent_t *agent, void *user) {
    (void)agent;
    agent_t *one = user;
    one->event(one->id, 0, 0);
}

static uint64_t now_ms(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000000;
}

static void on_receive(juice_agent_t *agent, const char *data, size_t size, void *user) {
    (void)agent;
    agent_t *one = user;
    atomic_store(&one->heard, now_ms());
    uint16_t port = atomic_load(&one->peer);
    if (!port) return;
    struct sockaddr_in to = loopback(port);
    // A full buffer is a lost packet, and QUIC handles those.
    sendto(one->fd, data, size, 0, (struct sockaddr *)&to, sizeof to);
}

static void *pump(void *user) {
    agent_t *one = user;
    char buffer[2048];
    while (!atomic_load(&one->stop)) {
        struct sockaddr_in from;
        socklen_t length = sizeof from;
        ssize_t size = recvfrom(one->fd, buffer, sizeof buffer, 0, (struct sockaddr *)&from, &length);
        if (size < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
            // The system took the socket away, as it does with a suspended app's: not a loop.
            usleep(100000);
            continue;
        }
        if (size <= 0) continue;
        // The first to speak is our own QUIC. Nobody else on this machine gets a word in.
        uint16_t none = 0;
        atomic_compare_exchange_strong(&one->peer, &none, from.sin_port);
        if (from.sin_addr.s_addr == htonl(INADDR_LOOPBACK) && from.sin_port == atomic_load(&one->peer)) {
            juice_send(one->agent, buffer, (size_t)size);
        }
    }
    return NULL;
}

int32_t lobby_ice_open(const lobby_ice_config *config, lobby_ice_event event) {
    juice_set_log_level(JUICE_LOG_LEVEL_NONE);
    agent_t *one = calloc(1, sizeof *one);
    if (!one) return -1;
    one->event = event;
    one->fd = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in own = loopback(0);
    socklen_t length = sizeof own;
    int size = 2 << 20;
    struct timeval wait = {.tv_sec = 0, .tv_usec = 200000};
    if (one->fd >= 0) {
        setsockopt(one->fd, SOL_SOCKET, SO_RCVBUF, &size, sizeof size);
        setsockopt(one->fd, SOL_SOCKET, SO_SNDBUF, &size, sizeof size);
        setsockopt(one->fd, SOL_SOCKET, SO_RCVTIMEO, &wait, sizeof wait);
    }
    if (one->fd < 0 || bind(one->fd, (struct sockaddr *)&own, sizeof own) ||
        getsockname(one->fd, (struct sockaddr *)&own, &length)) {
        if (one->fd >= 0) close(one->fd);
        free(one);
        return -1;
    }
    one->port = ntohs(own.sin_port);

    juice_turn_server_t turn = {
        .host = config->turn_host,
        .port = config->turn_port,
        .username = config->turn_user,
        .password = config->turn_password};
    juice_config_t settings;
    memset(&settings, 0, sizeof settings);
    settings.stun_server_host = config->stun_host;
    settings.stun_server_port = config->stun_port;
    settings.bind_address = config->bind;
    if (config->turn_host) {
        settings.turn_servers = &turn;
        settings.turn_servers_count = 1;
    }
    settings.cb_state_changed = on_state;
    settings.cb_gathering_done = on_gathered;
    settings.cb_recv = on_receive;
    settings.user_ptr = one;

    pthread_mutex_lock(&lock);
    int place = -1;
    for (int i = 0; i < MAX_AGENTS; i++) {
        if (!agents[i]) {
            place = i;
            break;
        }
    }
    if (place >= 0) one->agent = juice_create(&settings);
    if (!one->agent) {
        pthread_mutex_unlock(&lock);
        close(one->fd);
        free(one);
        return -1;
    }
    one->id = ++counter;
    if (pthread_create(&one->thread, NULL, pump, one)) {
        juice_destroy(one->agent);
        pthread_mutex_unlock(&lock);
        close(one->fd);
        free(one);
        return -1;
    }
    agents[place] = one;
    pthread_mutex_unlock(&lock);
    return one->id;
}

int lobby_ice_gather(int32_t id) {
    agent_t *one = enter(id);
    if (!one) return -1;
    int result = juice_gather_candidates(one->agent);
    leave(one);
    return result;
}

int lobby_ice_local(int32_t id, char *buffer, size_t size) {
    agent_t *one = enter(id);
    if (!one) return -1;
    int result = juice_get_local_description(one->agent, buffer, size);
    leave(one);
    return result;
}

int lobby_ice_remote(int32_t id, const char *sdp) {
    agent_t *one = enter(id);
    if (!one) return -1;
    int result = juice_set_remote_description(one->agent, sdp);
    if (!result) juice_set_remote_gathering_done(one->agent);
    leave(one);
    return result;
}

int lobby_ice_pair(int32_t id, char *local, char *remote, size_t size) {
    agent_t *one = enter(id);
    if (!one) return -1;
    int result = juice_get_selected_candidates(one->agent, local, size, remote, size);
    leave(one);
    return result;
}

uint16_t lobby_ice_port(int32_t id) {
    agent_t *one = enter(id);
    if (!one) return 0;
    uint16_t port = one->port;
    leave(one);
    return port;
}

uint64_t lobby_ice_quiet_ms(int32_t id) {
    agent_t *one = enter(id);
    if (!one) return UINT64_MAX;
    uint64_t heard = atomic_load(&one->heard);
    leave(one);
    if (!heard) return UINT64_MAX;
    uint64_t now = now_ms();
    return now > heard ? now - heard : 0;
}

void lobby_ice_close(int32_t id) {
    agent_t *one = NULL;
    pthread_mutex_lock(&lock);
    for (int i = 0; i < MAX_AGENTS; i++) {
        if (agents[i] && agents[i]->id == id) {
            one = agents[i];
            agents[i] = NULL;
        }
    }
    while (one && one->users) pthread_cond_wait(&idle, &lock);
    pthread_mutex_unlock(&lock);
    if (!one) return;
    atomic_store(&one->stop, true);
    pthread_join(one->thread, NULL);
    juice_destroy(one->agent);
    close(one->fd);
    free(one);
}
