//! Shared public error set.

pub const Error = error{
    InvalidFont,
    ShapingFailed,
    GlyphEncodingFailed,
    GlyphCapacityExceeded,
    PoolExhausted,
    BackendUnavailable,
    BackendResourceExhausted,
    FrameNotActive,
    FrameAlreadySubmitted,
};
