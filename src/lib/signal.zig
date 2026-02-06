//! Signal handling for cooperative interruption of long-running Zig code.
//!
//! Call `checkSignals()` periodically in long-running loops to allow
//! Python signal handlers (e.g., Ctrl+C / KeyboardInterrupt) to fire.

const py = @import("python.zig");

pub const SignalError = error{Interrupted};

/// Check for pending Python signals (e.g., SIGINT from Ctrl+C).
///
/// Returns normally if no signal is pending. Returns `error.Interrupted`
/// if a signal was received — the corresponding Python exception
/// (e.g., KeyboardInterrupt) is already set and will propagate automatically.
///
/// Usage:
/// ```zig
/// fn compute(n: i64) !i64 {
///     var sum: i64 = 0;
///     var i: i64 = 0;
///     while (i < n) : (i += 1) {
///         if (@mod(i, 100000) == 0) try pyoz.checkSignals();
///         sum +%= i;
///     }
///     return sum;
/// }
/// ```
pub fn checkSignals() SignalError!void {
    if (py.PyErr_CheckSignals() < 0) {
        return SignalError.Interrupted;
    }
}
