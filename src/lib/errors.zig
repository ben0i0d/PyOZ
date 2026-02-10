//! Error Mapping
//!
//! Provides utilities for mapping Zig errors to Python exceptions.

const std = @import("std");
const py = @import("python.zig");
const exceptions = @import("exceptions.zig");
const ExcBase = exceptions.ExcBase;

/// Define how a Zig error maps to a Python exception type
pub const ErrorMapping = struct {
    /// The Zig error name (e.g., "OutOfMemory", "InvalidArgument")
    error_name: []const u8,
    /// The Python exception type to use
    exc_type: ExcBase,
    /// Custom message (if null, uses the error name)
    message: ?[*:0]const u8 = null,
};

/// Create an error mapping entry
pub fn mapError(comptime error_name: []const u8, comptime exc_type: ExcBase) ErrorMapping {
    return .{
        .error_name = error_name,
        .exc_type = exc_type,
        .message = null,
    };
}

/// Create an error mapping with custom message
pub fn mapErrorMsg(comptime error_name: []const u8, comptime exc_type: ExcBase, comptime message: [*:0]const u8) ErrorMapping {
    return .{
        .error_name = error_name,
        .exc_type = exc_type,
        .message = message,
    };
}

/// Helper to set a Python exception from a Zig error using the mapping
pub fn setErrorFromMapping(comptime mappings: []const ErrorMapping, err: anyerror) void {
    // If a Python exception is already set (e.g., by conversion code), preserve it
    if (py.PyErr_Occurred() != null) {
        return;
    }

    const err_name = @errorName(err);

    // Search for a mapping
    inline for (mappings) |mapping| {
        if (std.mem.eql(u8, err_name, mapping.error_name)) {
            const exc = mapping.exc_type.toPyObject();
            if (mapping.message) |msg| {
                py.PyErr_SetString(exc, msg);
            } else {
                py.PyErr_SetString(exc, err_name.ptr);
            }
            return;
        }
    }

    // Default: map well-known error names to their Python exception types
    const exc = mapWellKnownError(err_name);
    py.PyErr_SetString(exc, err_name.ptr);
}

/// Map Zig error names to their corresponding Python exception types.
///
/// First tries an exact match against ExcBase enum field names (covers all
/// standard Python exceptions like TypeError, ValueError, IndexError, etc.).
/// Then checks common Zig-idiomatic aliases (e.g., DivisionByZero -> ZeroDivisionError).
/// Falls back to RuntimeError for unrecognized errors.
pub fn mapWellKnownError(err_name: []const u8) *py.PyObject {
    // Exact match against all Python exception names
    if (std.meta.stringToEnum(ExcBase, err_name)) |exc| {
        return exc.toPyObject();
    }

    // Common Zig-idiomatic aliases
    const eql = std.mem.eql;
    if (eql(u8, err_name, "DivisionByZero")) return py.PyExc_ZeroDivisionError();
    if (eql(u8, err_name, "Overflow")) return py.PyExc_OverflowError();
    if (eql(u8, err_name, "OutOfMemory")) return py.PyExc_MemoryError();
    if (eql(u8, err_name, "IndexOutOfBounds")) return py.PyExc_IndexError();
    if (eql(u8, err_name, "KeyNotFound")) return py.PyExc_KeyError();
    if (eql(u8, err_name, "FileNotFound")) return py.PyExc_FileNotFoundError();
    if (eql(u8, err_name, "PermissionDenied")) return py.PyExc_PermissionError();
    if (eql(u8, err_name, "AttributeNotFound")) return py.PyExc_AttributeError();
    if (eql(u8, err_name, "NotImplemented")) return py.PyExc_NotImplementedError();
    if (eql(u8, err_name, "NegativeValue") or eql(u8, err_name, "ValueTooLarge") or eql(u8, err_name, "ForbiddenValue") or eql(u8, err_name, "InvalidValue")) return py.PyExc_ValueError();
    if (eql(u8, err_name, "ConnectionRefused")) return py.PyExc_ConnectionRefusedError();
    if (eql(u8, err_name, "ConnectionReset")) return py.PyExc_ConnectionResetError();
    if (eql(u8, err_name, "BrokenPipe")) return py.PyExc_BrokenPipeError();
    if (eql(u8, err_name, "TimedOut") or eql(u8, err_name, "Timeout")) return py.PyExc_TimeoutError();

    return py.PyExc_RuntimeError();
}
