const std = @import("std");
const c = @import("c.zig").c;
const Robot = @import("robot.zig").Robot;
const visualizer = @import("visualizer.zig");
const spine = @import("spine_zig");

// Updated by receiveJoints (a background task) and read once per render
// frame in main's loop, so the visualizer keeps rendering smoothly between
// "joints" messages instead of blocking the frame loop on the network.
var current_joints: [6]f64 = .{ 0, 0, 0, 0, 0, 0 };
var joints_lock: std.Io.Mutex = .init;

fn receiveJoints(io: std.Io, subscriber: *spine.Subscriber([6]f64)) void {
    while (true) {
        const joints = subscriber.next() catch |err| {
            std.debug.print("crack-head: failed to receive joints: {any}\n", .{err});
            continue;
        };

        joints_lock.lock(io) catch return;
        current_joints = joints;
        joints_lock.unlock(io);
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();

    var error_buf: [1024]u8 = undefined;
    const model = c.mj_loadXML("models/arctos_robot_mujoco.xml", null, &error_buf, error_buf.len) orelse {
        std.debug.print("failed to load model: {s}\n", .{error_buf});
        return error.ModelLoadFailed;
    };
    defer c.mj_deleteModel(model);

    const data = c.mj_makeData(model) orelse return error.DataAllocFailed;
    defer c.mj_deleteData(data);

    const robot = Robot.init("arctos", model, data);

    var node = try spine.Node.init("rime", "crack-head", io, allocator);
    defer node.deinit();

    const subscriber = try node.subscribe([6]f64, "joints");
    _ = try io.concurrent(receiveJoints, .{ io, subscriber });

    try visualizer.init(model, data);
    defer visualizer.deinit();

    while (true) {
        joints_lock.lock(io) catch break;
        const joints = current_joints;
        joints_lock.unlock(io);

        robot.setJoints(joints);
        c.mj_forward(model, data);

        if (!visualizer.update()) break;
    }
}
