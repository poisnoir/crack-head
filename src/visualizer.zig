const c = @import("c.zig").c;

var model: *c.mjModel = undefined;
var data: *c.mjData = undefined;
var window: *c.GLFWwindow = undefined;

var cam: c.mjvCamera = undefined;
var opt: c.mjvOption = undefined;
var scn: c.mjvScene = undefined;
var con: c.mjrContext = undefined;

var button_left = false;
var button_middle = false;
var button_right = false;
var lastx: f64 = 0;
var lasty: f64 = 0;

fn keyboard(win: ?*c.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.c) void {
    _ = win;
    _ = scancode;
    _ = mods;
    if (key == c.GLFW_KEY_BACKSPACE and action == c.GLFW_PRESS) {
        c.mj_resetData(model, data);
        c.mj_forward(model, data);
    }
}

fn mouseButton(win: ?*c.GLFWwindow, button: c_int, action: c_int, mods: c_int) callconv(.c) void {
    _ = button;
    _ = action;
    _ = mods;
    button_left = c.glfwGetMouseButton(win, c.GLFW_MOUSE_BUTTON_LEFT) == c.GLFW_PRESS;
    button_middle = c.glfwGetMouseButton(win, c.GLFW_MOUSE_BUTTON_MIDDLE) == c.GLFW_PRESS;
    button_right = c.glfwGetMouseButton(win, c.GLFW_MOUSE_BUTTON_RIGHT) == c.GLFW_PRESS;
    c.glfwGetCursorPos(win, &lastx, &lasty);
}

fn mouseMove(win: ?*c.GLFWwindow, xpos: f64, ypos: f64) callconv(.c) void {
    if (!button_left and !button_middle and !button_right) return;

    const dx = xpos - lastx;
    const dy = ypos - lasty;
    lastx = xpos;
    lasty = ypos;

    var width: c_int = 0;
    var height: c_int = 0;
    c.glfwGetWindowSize(win, &width, &height);

    const mod_shift = c.glfwGetKey(win, c.GLFW_KEY_LEFT_SHIFT) == c.GLFW_PRESS or
        c.glfwGetKey(win, c.GLFW_KEY_RIGHT_SHIFT) == c.GLFW_PRESS;

    const action: c_int = if (button_right)
        (if (mod_shift) c.mjMOUSE_MOVE_H else c.mjMOUSE_MOVE_V)
    else if (button_left)
        (if (mod_shift) c.mjMOUSE_ROTATE_H else c.mjMOUSE_ROTATE_V)
    else
        c.mjMOUSE_ZOOM;

    c.mjv_moveCamera(model, action, dx / @as(f64, @floatFromInt(height)), dy / @as(f64, @floatFromInt(height)), &scn, &cam);
}

fn scroll(win: ?*c.GLFWwindow, xoffset: f64, yoffset: f64) callconv(.c) void {
    _ = win;
    _ = xoffset;
    c.mjv_moveCamera(model, c.mjMOUSE_ZOOM, 0, -0.05 * yoffset, &scn, &cam);
}

pub fn init(m: *c.mjModel, d: *c.mjData) !void {
    model = m;
    data = d;

    if (c.glfwInit() == 0) return error.GlfwInitFailed;

    window = c.glfwCreateWindow(1200, 900, "crack-head", null, null) orelse return error.WindowCreateFailed;
    c.glfwMakeContextCurrent(window);
    c.glfwSwapInterval(1);

    c.mjv_defaultCamera(&cam);
    c.mjv_defaultOption(&opt);
    c.mjv_defaultScene(&scn);
    c.mjr_defaultContext(&con);

    c.mjv_makeScene(model, &scn, 2000);
    c.mjr_makeContext(model, &con, c.mjFONTSCALE_150);

    cam.distance = 3;
    cam.azimuth = 90;
    cam.elevation = -20;

    _ = c.glfwSetKeyCallback(window, keyboard);
    _ = c.glfwSetMouseButtonCallback(window, mouseButton);
    _ = c.glfwSetCursorPosCallback(window, mouseMove);
    _ = c.glfwSetScrollCallback(window, scroll);
}

// Renders one frame; returns false once the window should close.
pub fn update() bool {
    if (c.glfwWindowShouldClose(window) != 0) return false;

    var viewport = c.mjrRect{ .left = 0, .bottom = 0, .width = 0, .height = 0 };
    c.glfwGetFramebufferSize(window, &viewport.width, &viewport.height);

    c.mjv_updateScene(model, data, &opt, null, &cam, c.mjCAT_ALL, &scn);
    c.mjr_render(viewport, &scn, &con);

    c.glfwSwapBuffers(window);
    c.glfwPollEvents();
    return true;
}

pub fn deinit() void {
    c.mjv_freeScene(&scn);
    c.mjr_freeContext(&con);
    c.glfwTerminate();
}
