// Mirrors spined/src/globals.zig and spine-go's internal/globals — only the
// constants needed so far (node + subscriber + publisher). Add more here as
// more of the protocol gets implemented.

pub const SPINED_PATH = "/tmp/spine/spined";

// Mirrors spine-go's network.go: publisher listeners bind to
// "/tmp/spine/publisher/{namespace}/{topic}" (unix socket).
pub const PUBLISHER_SOCKET_DIR = "/tmp/spine/publisher/";

// Mirrors spine-go's service_common.go: service listeners bind to
// "/tmp/spine/service/{namespace}/{name}" (unix socket).
pub const SERVICE_SOCKET_DIR = "/tmp/spine/service/";

pub const MAX_PACKET_SIZE: usize = 4096;

// Cap on concurrent subscribers a single Publisher will track. Mirrors
// spined's own fixed-size-arrays style (MAX_NODES/MAX_ENTITIES) rather than
// spine-go's unbounded slice, since that's the pattern this codebase already
// uses for anything shared across connections.
pub const MAX_SUBSCRIBERS_PER_PUBLISHER: usize = 32;

pub const OK_STATUS: u8 = 0;

// Mirrors spine-go's internal/globals ERROR_MISMATCH_PAYLOAD_CODE: sent back
// to a subscriber whose mad type-fingerprint doesn't match the publisher's.
pub const ERROR_MISMATCH_PAYLOAD_CODE: u8 = 254;

// Mirrors spine-go's internal/globals — service request/response status
// bytes. These are a separate namespace from the RegisterEntityPayload
// codes below (different protocol, different socket), so the numeric
// overlap with e.g. TOO_MANY_ENTITIES is coincidental, not a collision.
pub const ERROR_SERIALIZER_ERROR_CODE: u8 = 251;
pub const ERROR_SERVICE_ERROR_CODE: u8 = 252;

// Error responses spined can send back for RegisterNodePayload.
pub const NODE_ALREADY_REGISTERED: u8 = 249;
pub const TOO_MANY_NODES: u8 = 250;
pub const INVALID_NAMESPACE: u8 = 255;

// Error responses spined can send back for RegisterEntityPayload.
pub const TOO_MANY_UNKNOWN_ENTITIES: u8 = 248;
pub const TOO_MANY_ENTITIES: u8 = 251;
pub const INVALID_ENTITY_TYPE: u8 = 252;
pub const ENTITY_ALREADY_REGISTERED: u8 = 253;

// Entity types (RegisterEntityPayload.entity_type).
pub const PUBLISHER_TYPE: u8 = 0;
pub const SUBSCRIBER_TYPE: u8 = 1;
pub const SERVICE_TYPE: u8 = 2;
pub const SERVICE_CALLER_TYPE: u8 = 3;
