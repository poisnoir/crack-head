import re
import threading
import time

import mujoco
import mujoco.viewer
import numpy as np
from spine import Namespace, Subscriber

from kinematic import KinematicsEnginePink
from model import XboxController

model = mujoco.MjModel.from_xml_path("model.xml")
data = mujoco.MjData(model)

HOME_JOINTS = np.array(
    [0.0000000, -13.6120005, 12.7543001, 0.0000000, 30.8575993, 0.0000000]
)
MECADEMIC_URDF_LAST_JOINT_NAME = "meca_axis_6_link"
urdfPath = "meca_500/meca_500.urdf"
pink = KinematicsEnginePink(
    urdfPath, MECADEMIC_URDF_LAST_JOINT_NAME, 1e-12, 10, 1, HOME_JOINTS
)

ns = Namespace("rime", "ppap")
sub = Subscriber(ns, "xbox-controller", XboxController)

Home_Matrix = pink.forwardKinematics(HOME_JOINTS)
print(Home_Matrix)


def r1_set_joints(joint_val):
    joint_val = np.deg2rad(joint_val)
    joint1_id = mujoco.mj_name2id(
        model, mujoco.mjtObj.mjOBJ_JOINT, "r1_meca_axis_1_joint"
    )

    joint2_id = mujoco.mj_name2id(
        model, mujoco.mjtObj.mjOBJ_JOINT, "r1_meca_axis_2_joint"
    )

    joint3_id = mujoco.mj_name2id(
        model, mujoco.mjtObj.mjOBJ_JOINT, "r1_meca_axis_3_joint"
    )

    joint4_id = mujoco.mj_name2id(
        model, mujoco.mjtObj.mjOBJ_JOINT, "r1_meca_axis_4_joint"
    )

    joint5_id = mujoco.mj_name2id(
        model, mujoco.mjtObj.mjOBJ_JOINT, "r1_meca_axis_5_joint"
    )

    joint6_id = mujoco.mj_name2id(
        model, mujoco.mjtObj.mjOBJ_JOINT, "r1_meca_axis_6_joint"
    )

    data.qpos[joint1_id] = joint_val[0]
    data.qpos[joint2_id] = joint_val[1]
    data.qpos[joint3_id] = joint_val[2]
    data.qpos[joint4_id] = joint_val[3]
    data.qpos[joint5_id] = joint_val[4]
    data.qpos[joint6_id] = joint_val[5]


def r2_set_joints(joint_val):
    joint_val = np.deg2rad(joint_val)
    joint1_id = mujoco.mj_name2id(
        model, mujoco.mjtObj.mjOBJ_JOINT, "r2_meca_axis_1_joint"
    )

    joint2_id = mujoco.mj_name2id(
        model, mujoco.mjtObj.mjOBJ_JOINT, "r2_meca_axis_2_joint"
    )

    joint3_id = mujoco.mj_name2id(
        model, mujoco.mjtObj.mjOBJ_JOINT, "r2_meca_axis_3_joint"
    )

    joint4_id = mujoco.mj_name2id(
        model, mujoco.mjtObj.mjOBJ_JOINT, "r2_meca_axis_4_joint"
    )

    joint5_id = mujoco.mj_name2id(
        model, mujoco.mjtObj.mjOBJ_JOINT, "r2_meca_axis_5_joint"
    )

    joint6_id = mujoco.mj_name2id(
        model, mujoco.mjtObj.mjOBJ_JOINT, "r2_meca_axis_6_joint"
    )

    data.qpos[joint1_id] = joint_val[0]
    data.qpos[joint2_id] = joint_val[1]
    data.qpos[joint3_id] = joint_val[2]
    data.qpos[joint4_id] = joint_val[3]
    data.qpos[joint5_id] = joint_val[4]
    data.qpos[joint6_id] = joint_val[5]


def set_joints():
    current_Matrix1 = Home_Matrix
    current_Matrix2 = Home_Matrix

    while True:
        joint_id = mujoco.mj_name2id(
            model, mujoco.mjtObj.mjOBJ_JOINT, "r1_meca_axis_1_joint"
        )
        input = sub.get_data()

        transition_matrix1 = np.eye(4)
        transition_matrix2 = np.eye(4)

        transition_matrix1[1, 3] = (input.LeftStick.X / 32767) / 1000
        transition_matrix1[2, 3] = (input.LeftStick.Y / 32767) / 1000
        transition_matrix2[1, 3] = (input.RightStick.X / 32767) / 1000
        transition_matrix2[2, 3] = (input.RightStick.Y / 32767) / 1000

        goal1 = np.matmul(current_Matrix1, transition_matrix1)
        goal2 = np.matmul(current_Matrix2, transition_matrix2)
        result1, has_sucess1 = pink.inverseKinematics(goal1)
        result2, has_sucess2 = pink.inverseKinematics(goal2)

        if has_sucess1:
            r1_set_joints(result1)
            current_Matrix1 = goal1

        if has_sucess2:
            r2_set_joints(result2)
            current_Matrix2 = goal2


t = 0
with mujoco.viewer.launch_passive(model, data) as viewer:
    my_thread = threading.Thread(target=set_joints)
    my_thread.start()

    r1_set_joints(HOME_JOINTS)

    while viewer.is_running():
        step_start = time.time()

        mujoco.mj_forward(model, data)
        viewer.sync()

        t += model.opt.timestep
        time_until_next_step = model.opt.timestep - (time.time() - step_start)
        if time_until_next_step > 0:
            time.sleep(time_until_next_step)
