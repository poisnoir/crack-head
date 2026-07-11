# crack-head

Proof of concept: driving MuJoCo directly from Zig via `@cImport`, no wrapper
language in between. Companion to the Python version of `crack-head` in
`spine/demo/crack-head`.

## Layout

- `vendor/mujoco/` — vendored MuJoCo 3.8.0 headers + `libmujoco.so`, copied
  from the Python package so this project doesn't depend on that venv.
- `models/ball.xml` — trivial MJCF model (a ball dropped onto a plane), used
  to sanity-check the binding.
- `src/main.zig` — loads the model, steps the sim 500 times, prints the
  ball's resting height.

## Run

```
zig build run
```

Expect the ball to settle at ~0.0996 (its radius), confirming gravity and
contact resolution are running correctly through the C API.
