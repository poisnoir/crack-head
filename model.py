from dataclasses import dataclass

from mad import MadType


@dataclass
class Joystick:
    # Left is negative, Right is positive
    X: MadType.int32
    # Up is negative, Down is positive
    Y: MadType.int32


@dataclass
class XboxController:
    # Face Buttons
    A: MadType.bool
    B: MadType.bool
    X: MadType.bool
    Y: MadType.bool

    # Bumpers
    LB: MadType.bool
    RB: MadType.bool

    # Triggers
    LT: MadType.int32
    RT: MadType.int32

    # Joysticks
    LeftStick: Joystick
    RightStick: Joystick

    # Thumbstick Clicks
    LSB: MadType.bool
    RSB: MadType.bool

    # D-Pad
    Up: MadType.bool
    Down: MadType.bool
    Left: MadType.bool
    Right: MadType.bool

    # Menu Buttons
    Back: MadType.bool
    Start: MadType.bool
    Guide: MadType.bool
