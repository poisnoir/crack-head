import threading
import time

import mujoco
import mujoco.viewer
import numpy as np
from spine import Namespace, Subscriber

from model import XboxController

model = mujoco.MjModel.from_xml_path("model.xml")
data = mujoco.MjData(model)


ns = Namespace("rime", "ppap")
sub = Subscriber(ns, "xbox-controller", XboxController)


def set_joints():
    while True:
        joint_id = mujoco.mj_name2id(
            model, mujoco.mjtObj.mjOBJ_JOINT, "r1_meca_axis_1_joint"
        )
        input = sub.get_data()
        print(input.LeftStick.X)
        joint_val = (input.LeftStick.X / 32767) * np.pi
        # print(joint_val)
        data.qpos[joint_id] = joint_val


t = 0
with mujoco.viewer.launch_passive(model, data) as viewer:
    my_thread = threading.Thread(target=set_joints)
    my_thread.start()

    while viewer.is_running():
        step_start = time.time()

        mujoco.mj_forward(model, data)
        viewer.sync()

        t += model.opt.timestep
        time_until_next_step = model.opt.timestep - (time.time() - step_start)
        if time_until_next_step > 0:
            time.sleep(time_until_next_step)
