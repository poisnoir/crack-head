const c = @import("c.zig").c;

const joint_names = [6][:0]const u8{ "joint1", "joint2", "joint3", "joint4", "joint5", "joint6" };

pub const Robot = struct {
    name: []const u8,
    model: *c.mjModel,
    data: *c.mjData,

    pub fn init(name: []const u8, model: *c.mjModel, data: *c.mjData) Robot {
        return .{ .name = name, .model = model, .data = data };
    }

    pub fn setJoints(self: Robot, angles: [6]f64) void {
        for (joint_names, angles) |jname, angle| {
            const id = c.mj_name2id(self.model, c.mjOBJ_JOINT, jname.ptr);
            if (id < 0) continue;
            const qpos_adr: usize = @intCast(self.model.jnt_qposadr[@intCast(id)]);
            self.data.qpos[qpos_adr] = angle;
        }
    }
};
