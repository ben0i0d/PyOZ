//! Callable wrapper for calling Python functions from Zig
//!
//! Provides a type-safe interface for accepting Python callables as function
//! parameters and calling them with automatic argument marshalling and refcounting.
//!
//! Usage:
//!   fn apply(callback: pyoz.Callable(i64), x: i64, y: i64) ?i64 {
//!       return callback.call(.{ x, y });
//!   }

const py = @import("python.zig");
const PyObject = py.PyObject;
const conversion = @import("conversion.zig");

/// A type-safe wrapper around a Python callable object.
///
/// `RetType` is the expected return type from the Python function.
/// Use `void` for callbacks that return nothing meaningful.
///
/// Example:
///   fn apply(cb: pyoz.Callable(i64), x: i64) ?i64 {
///       return cb.call(.{x});
///   }
pub fn Callable(comptime RetType: type) type {
    return CallableWithConverter(RetType, conversion.Conversions);
}

pub fn CallableWithConverter(comptime RetType: type, comptime Conv: type) type {
    return struct {
        pub const _is_pyoz_callable = true;
        pub const ReturnType = RetType;

        obj: *PyObject,

        const Self = @This();

        /// Call the Python callable with the given arguments.
        ///
        /// Args must be a Zig tuple, e.g. `.{ x, y }` or `.{}` for no args.
        /// Returns `?RetType` (null if the call fails with a Python exception).
        /// For `Callable(void)`, returns `bool` (true = success).
        pub fn call(self: Self, args: anytype) if (RetType == void) bool else ?RetType {
            const ArgsType = @TypeOf(args);
            const args_info = @typeInfo(ArgsType);

            if (args_info != .@"struct" or !args_info.@"struct".is_tuple) {
                @compileError("Callable.call() expects a tuple argument, e.g. .{ x, y }");
            }

            const fields = args_info.@"struct".fields;

            if (fields.len == 0) {
                return self.callNoArgs();
            }

            // Build args tuple
            const py_tuple = py.PyTuple_New(@intCast(fields.len)) orelse {
                if (RetType == void) return false else return null;
            };

            // Convert each Zig arg to PyObject and set in tuple
            inline for (fields, 0..) |field, i| {
                const py_arg = Conv.toPy(field.type, @field(args, field.name)) orelse {
                    py.Py_DecRef(py_tuple);
                    if (RetType == void) return false else return null;
                };
                // PyTuple_SetItem steals the reference
                if (py.PyTuple_SetItem(py_tuple, @intCast(i), py_arg) < 0) {
                    py.Py_DecRef(py_tuple);
                    if (RetType == void) return false else return null;
                }
            }

            // Call the Python callable
            const result = py.PyObject_CallObject(self.obj, py_tuple);
            py.Py_DecRef(py_tuple);

            if (result) |r| {
                if (RetType == void) {
                    py.Py_DecRef(r);
                    return true;
                } else {
                    defer py.Py_DecRef(r);
                    return Conv.fromPy(RetType, r) catch null;
                }
            } else {
                if (RetType == void) return false else return null;
            }
        }

        /// Call the Python callable with no arguments.
        pub fn callNoArgs(self: Self) if (RetType == void) bool else ?RetType {
            const result = py.PyObject_CallObject(self.obj, null);

            if (result) |r| {
                if (RetType == void) {
                    py.Py_DecRef(r);
                    return true;
                } else {
                    defer py.Py_DecRef(r);
                    return Conv.fromPy(RetType, r) catch null;
                }
            } else {
                if (RetType == void) return false else return null;
            }
        }
    };
}
