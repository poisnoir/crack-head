import threading

import mujoco


class Arm:
    def __init__(self, name, mujoco_model, mujoco_data, sub):
        self.mujoco_model = mujoco_model
        self.mujoco_data = mujoco_data
        self.sub = sub

        joint_id1 = mujoco.mj_name2id(mujoco_model, mujoco.mjtObj.mjOBJ_JOINT, "joint1")

        joint_id2 = mujoco.mj_name2id(mujoco_model, mujoco.mjtObj.mjOBJ_JOINT, "joint2")

        joint_id3 = mujoco.mj_name2id(mujoco_model, mujoco.mjtObj.mjOBJ_JOINT, "joint3")

        joint_id4 = mujoco.mj_name2id(mujoco_model, mujoco.mjtObj.mjOBJ_JOINT, "joint4")

        joint_id5 = mujoco.mj_name2id(mujoco_model, mujoco.mjtObj.mjOBJ_JOINT, "joint5")

        joint_id6 = mujoco.mj_name2id(mujoco_model, mujoco.mjtObj.mjOBJ_JOINT, "joint6")

        self.joint_ids = [
            joint_id1,
            joint_id2,
            joint_id3,
            joint_id4,
            joint_id5,
            joint_id6,
        ]

        self.worker_thread = threading.Thread(target=self._run, daemon=True)

    def set_joints(self, joints):
        self.mujoco_data.qpos[self.joint_ids[0]] = joints[0]
        self.mujoco_data.qpos[self.joint_ids[1]] = joints[1]
        self.mujoco_data.qpos[self.joint_ids[2]] = joints[2]
        self.mujoco_data.qpos[self.joint_ids[3]] = joints[3]
        self.mujoco_data.qpos[self.joint_ids[4]] = joints[4]
        self.mujoco_data.qpos[self.joint_ids[5]] = joints[5]

    def start(self):
        self.worker_thread.start()

    def _run(self):
        while True:
            joints = self.sub.get_data()
            self.set_joints(joints)
