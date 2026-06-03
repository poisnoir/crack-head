import re
import threading
import time

import mujoco
import mujoco.viewer
import numpy as np
from mad import MadType
from spine import Namespace, Subscriber

from arm import Arm

model = mujoco.MjModel.from_xml_path("./arctos_robot_mujoco.xml")
data = mujoco.MjData(model)

spine_namespace = Namespace("rime", "ppap")
r1_sub = Subscriber(spine_namespace, "joints", tuple[MadType.float64, 6])

r1_arm = Arm("r1", model, data, r1_sub)

t = 0
with mujoco.viewer.launch_passive(model, data) as viewer:
    r1_arm.start()

    while viewer.is_running():
        step_start = time.time()

        mujoco.mj_forward(model, data)
        viewer.sync()

        t += model.opt.timestep
        time_until_next_step = model.opt.timestep - (time.time() - step_start)
        if time_until_next_step > 0:
            time.sleep(time_until_next_step)
