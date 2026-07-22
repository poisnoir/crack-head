# crack-head

MuJoCo simulation and visualizer for the Arctos arm, driven live over
[spine](https://github.com/poisnoir/spine). It's the last stage of the
`keyboard-controller` → `kinematic-engine` → `crack-head` pipeline: the
kinematics engine publishes joint angles on the `"joints"` topic, and
crack-head subscribes to them and renders the arm in MuJoCo as they arrive.

MuJoCo is driven directly from Zig via `@cImport` — no wrapper language in
between.

## Layout

- `vendor/mujoco/` — vendored MuJoCo 3.8.0 headers + `libmujoco.so`.
- `models/arctos_robot_mujoco.xml` + `models/meshes/` — the Arctos arm's MJCF
  model and STL meshes.
- `src/c.zig` — the `@cImport` of `mujoco.h` and `GLFW/glfw3.h`.
- `src/robot.zig` — applies a `[6]f64` joint-angle array to the MuJoCo model's
  joint qpos entries.
- `src/visualizer.zig` — GLFW window + MuJoCo's rendering/camera/mouse-control
  APIs.
- `src/main.zig` — wires it together: joins the `"rime"` namespace, subscribes
  to `"joints"`, and on each render frame applies whatever the latest
  received joint angles are (received on a background task, decoupled from
  the render loop so the visualizer doesn't stall waiting on the network).

## Requirements

- Zig `0.16.0`.
- `glfw` installed as a system library (linked via `linkSystemLibrary`, not
  vendored).
- A display (X11/Wayland) — this opens a real visualizer window.

## Run

```sh
zig build run
```

This only shows something moving if a `kinematic-engine` instance is also
running and publishing on `"joints"` in the same namespace (`"rime"`) —
on its own, crack-head just sits with the arm at rest, retrying the
subscription in the background. See `../run-demo.sh` at the repo root for
running the whole `keyboard-controller` → `kinematic-engine` → `crack-head`
pipeline together.

Since this doesn't register under spined's one recognized namespace
(`"common"`), it needs spined either stopped or unreachable — otherwise
`Node.init` fails outright trying to register `"rime"` instead of falling
back to local-only mode (see `run-demo.sh`'s guard for the same reason).
