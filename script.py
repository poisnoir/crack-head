import mujoco
import mujoco.viewer
import time
import numpy as np

model = mujoco.MjModel.from_xml_path("model.xml")
data = mujoco.MjData(model)

def set_joint(name, angle):
    joint_id = mujoco.mj_name2id(model, mujoco.mjtObj.mjOBJ_JOINT, name)
    data.qpos[joint_id] = angle

t = 0
with mujoco.viewer.launch_passive(model, data) as viewer:
    while viewer.is_running():
        step_start = time.time()

        # Slowly oscillate r1 axis 1 between -45 and +45 degrees
        angle = np.deg2rad(45) * np.sin(t * 0.5)  # 0.5 controls speed
        set_joint("r1_meca_axis_1_joint", angle)
        set_joint("r2_meca_axis_4_joint", -angle)
        set_joint("r1_meca_axis_3_joint", -angle/2)


        mujoco.mj_forward(model, data)
        viewer.sync()

        t += model.opt.timestep
        time_until_next_step = model.opt.timestep - (time.time() - step_start)
        if time_until_next_step > 0:
            time.sleep(time_until_next_step)