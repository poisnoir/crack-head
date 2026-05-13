import math

import numpy as np
import pink
import pinocchio as pin


class KinematicsEnginePink:
    def __init__(
        self, urdfPath, lastJoint, damping, randomTimes, dt, homeJointsDegrees
    ):
        self.randomTimes = randomTimes
        self.dt = dt
        self.damping = damping
        self.homeJointsRad = np.deg2rad(homeJointsDegrees)

        self.model = pin.buildModelFromUrdf(urdfPath)
        self.data = self.model.createData()
        self.lastJoint = lastJoint

    def forwardKinematics(self, jointsInDegrees: np.ndarray) -> np.ndarray:
        pin.forwardKinematics(self.model, self.data, np.radians(jointsInDegrees))
        pin.updateFramePlacements(self.model, self.data)
        goal = self.data.oMf[self.model.getFrameId(self.lastJoint)]

        return goal.np

    """
        Pink Inverse Kinematics uses an initial position to determine the final solution.
        Its normal success rate is 54%, but with sufficient random initial positions, reachability increases to 100%.

        success rate: 99%
        problems:
            - Pink's default kinematic function has a very low success rate, which was addressed with a workaround.
            However, this approach significantly increases the time required to find a solution.

        TODOs:
            - Exploring methods to tune variables for improving algorithm speed.
    """

    def inverseKinematics(
        self, flangeTransform, positionError=1e-6, orientationError=1e-6
    ) -> (np.ndarray, bool):

        FlangeTransformInPink = flangeTransform
        flangeTransformGoal = pin.SE3(FlangeTransformInPink)

        joints, hasSolution = self.inverseKinematicsAttempt(
            flangeTransformGoal, self.homeJointsRad, positionError, orientationError
        )

        if hasSolution:
            return np.rad2deg(joints), True

        upperLimits = self.model.upperPositionLimit
        lowerLimits = self.model.lowerPositionLimit

        # Limiting J1 Joint
        lowerLimits[0] = -np.pi / 4
        upperLimits[0] = np.pi / 4

        for i in range(self.randomTimes):
            randomInitialGuess = np.random.uniform(low=lowerLimits, high=upperLimits)
            joints, hasSolution = self.inverseKinematicsAttempt(
                flangeTransformGoal, randomInitialGuess, positionError, orientationError
            )
            if hasSolution:
                return np.rad2deg(joints), True

        return None, False

    # TODO
    # Error has to be fixed
    # Tolerance has to be fixed
    def inverseKinematicsAttempt(
        self, FlangeTransformGoal, initialGuess, positionError, orientationError
    ) -> (np.ndarray, bool):

        tolerance = 1e-6

        task = pink.tasks.FrameTask(
            frame=self.lastJoint,
            position_cost=1.0,
            orientation_cost=0.75,
        )

        task.set_target(FlangeTransformGoal)

        configuration = pink.configuration.Configuration(
            self.model, self.data, initialGuess
        )

        # TODO: Understand the (0, 30) range and dt step.
        for _ in np.arange(0, 30, self.dt):
            velocity = pink.solve_ik(
                configuration, (task,), self.dt, solver="clarabel", damping=self.damping
            )
            configuration.integrate_inplace(velocity, self.dt)

            tcp_pose = configuration.get_transform_frame_to_world(self.lastJoint)
            error = pin.log(tcp_pose.actInv(FlangeTransformGoal)).vector
            if (
                np.linalg.norm(error[:3]) < tolerance
                and np.linalg.norm(error[3:]) < tolerance
            ):
                return configuration.q, True

        return None, False
